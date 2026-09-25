require "json"
require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"
require "../src/adamantine/lsp_client"

private class AsyncTransportTestApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def set_lsp_client_public(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def trigger_hover_public : Bool
    on_capture(Tui::KeyEvent.new(Tui::Key::F6))
  end

  def type_public(char : Char) : Bool
    handle_event(Tui::KeyEvent.new(char))
  end

  def lsp_popup_open_public : Bool
    @lsp_popup.open
  end

  def lsp_popup_lines_public : Array(String)
    @lsp_popup.lines
  end

  def editor_text_public : String
    current_editor.not_nil!.text
  end

  def buffer_version_public : Int32
    current_buffer.not_nil!.version
  end
end

private def with_async_lsp_transport_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-lsp-async-transport-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def write_async_lsp_transport_server(path : Path) : Nil
  File.write(path.to_s, <<-RUBY)
#!/usr/bin/env ruby
require "json"

mode = ARGV[0] || "immediate"
request_log_path = ARGV[1]
release_path = ARGV[2]
response_log_path = ARGV[3]
accepted_path = ARGV[4]

def read_msg
  headers = {}
  loop do
    line = STDIN.gets
    return nil unless line
    line = line.sub(/\r?\n$/, "")
    break if line.empty?
    key, value = line.split(":", 2)
    headers[key.downcase] = value.strip if key && value
  end

  length = headers["content-length"].to_i
  return nil if length <= 0
  payload = STDIN.read(length)
  return nil unless payload && payload.bytesize == length
  JSON.parse(payload)
end

def write_msg(message)
  payload = JSON.generate(message)
  STDOUT.write("Content-Length: " + payload.bytesize.to_s + "\r\n\r\n" + payload)
  STDOUT.flush
end

def log_json(path, value)
  return if path.nil? || path.empty?
  File.open(path, "a") { |file| file.puts(JSON.generate(value)) }
end

def write_response(message, response_log_path)
  log_json(response_log_path, message)
  write_msg(message)
end

hover_requests = []
hover_count = 0

loop do
  message = read_msg
  break unless message
  log_json(request_log_path, message)

  method = message["method"]
  id = message["id"]

  case method
  when "initialize"
    write_response({"jsonrpc" => "2.0", "id" => id, "result" => {"capabilities" => {}}}, response_log_path)
  when "initialized", "textDocument/didOpen", "textDocument/didChange"
  when "textDocument/hover"
    hover_count += 1
    if mode == "reorder"
      hover_requests << message
      if hover_requests.size >= 2
        hover_requests.reverse_each do |request|
          position = request.dig("params", "position", "character")
          response = {
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => {"contents" => "hover-" + position.to_s}
          }
          write_response(response, response_log_path)
        end
        hover_requests.clear
      end
    elsif mode == "hold" && hover_count == 1
      File.write(accepted_path, "hover held") if accepted_path && !accepted_path.empty?
      until release_path && !release_path.empty? && File.exist?(release_path)
        sleep 0.01
      end
      write_response({"jsonrpc" => "2.0", "id" => id, "result" => {"contents" => "late-hover"}}, response_log_path)
    elsif mode == "hold"
      write_response({"jsonrpc" => "2.0", "id" => id, "result" => {"contents" => "fresh-hover"}}, response_log_path)
    else
      write_response({"jsonrpc" => "2.0", "id" => id, "result" => {"contents" => "replacement-hover"}}, response_log_path)
    end
  when "shutdown"
    write_response({"jsonrpc" => "2.0", "id" => id, "result" => nil}, response_log_path)
  when "exit"
    break
  end
end
RUBY
  File.chmod(path.to_s, 0o755)
end

private def async_transport_json_lines(path : Path) : Array(JSON::Any)
  return [] of JSON::Any unless File.exists?(path.to_s)

  File.read(path.to_s).lines.compact_map do |line|
    begin
      JSON.parse(line)
    rescue
      nil
    end
  end
end

private def wait_for_async_transport_file(path : Path, timeout_span : Time::Span = 1.second) : Nil
  deadline = Time.instant + timeout_span
  loop do
    return if File.exists?(path.to_s)
    raise "timed out waiting for #{path.basename}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def wait_for_async_transport_request(path : Path, method : String, timeout_span : Time::Span = 1.second) : Nil
  deadline = Time.instant + timeout_span
  loop do
    requests = async_transport_json_lines(path)
    return if requests.any? { |message| message["method"]?.try(&.as_s?) == method }
    raise "timed out waiting for LSP request #{method}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def wait_for_async_transport_response(path : Path, contents : String, timeout_span : Time::Span = 1.second) : Nil
  deadline = Time.instant + timeout_span
  loop do
    responses = async_transport_json_lines(path)
    matched = responses.any? do |message|
      result = message["result"]?
      result && result["contents"]?.try(&.as_s?) == contents
    end
    return if matched
    raise "timed out waiting for LSP response #{contents}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

describe "asynchronous LSP stdio transport" do
  it "routes reversed stdio replies to the matching hover requests" do
    with_async_lsp_transport_workspace do |tmp|
      server = tmp / "fake_lsp"
      requests = tmp / "requests.log"
      responses = tmp / "responses.log"
      write_async_lsp_transport_server(server)
      client = Adamantine::Lsp::Client.new(server.to_s, tmp, ["reorder", requests.to_s, "", responses.to_s, ""])

      result = Channel(Tuple(Int32, String?, Exception?)).new(2)
      begin
        raise "client should start" unless client.start

        spawn do
          begin
            hover = client.hover("file:///main.cr", 0, 10)
            result.send({10, hover.try(&.text), nil})
          rescue ex
            result.send({10, nil, ex})
          end
        end
        spawn do
          begin
            hover = client.hover("file:///main.cr", 0, 20)
            result.send({20, hover.try(&.text), nil})
          rescue ex
            result.send({20, nil, ex})
          end
        end

        wait_for_async_transport_request(requests, "textDocument/hover")
        deadline = Time.instant + 1.second
        replies = [] of Tuple(Int32, String?, Exception?)
        while replies.size < 2
          select
          when reply = result.receive
            replies << reply
          when timeout(5.milliseconds)
            raise "timed out waiting for reordered hover replies" if Time.instant >= deadline
          end
        end

        replies.each do |reply|
          raise "hover request #{reply[0]} failed: #{reply[2]}" if reply[2]
          raise "wrong response for hover request #{reply[0]}: #{reply[1].inspect}" unless reply[1] == "hover-#{reply[0]}"
        end
      ensure
        client.stop
      end
    end
  end

  it "keeps input responsive and ignores a late hover after an edit" do
    with_async_lsp_transport_workspace do |tmp|
      source = tmp / "main.cr"
      server = tmp / "fake_lsp"
      requests = tmp / "requests.log"
      responses = tmp / "responses.log"
      release = tmp / "release"
      accepted = tmp / "accepted"
      File.write(source.to_s, "puts 1\n")
      write_async_lsp_transport_server(server)

      client = Adamantine::Lsp::Client.new(server.to_s, tmp, ["hold", requests.to_s, release.to_s, responses.to_s, accepted.to_s])
      app = AsyncTransportTestApp.new(project_root: tmp, lsp_command: "")
      begin
        raise "client should start" unless client.start
        app.set_lsp_client_public(client)
        raise "source file should open" unless app.open_file_public(source)

        started = Time.instant
        handled = app.trigger_hover_public
        elapsed = Time.instant - started
        raise "hover key should be handled" unless handled
        raise "hover dispatch blocked input for #{elapsed}" if elapsed > 250.milliseconds

        wait_for_async_transport_file(accepted)
        original_version = app.buffer_version_public
        raise "editor input should be handled while hover is held" unless app.type_public('x')
        raise "editor input should advance the document version" unless app.buffer_version_public > original_version
        raise "editor input should change the document" unless app.editor_text_public.includes?('x')

        File.write(release.to_s, "release")
        wait_for_async_transport_response(responses, "late-hover")
        sleep 50.milliseconds
        raise "late hover must not open a popup after an edit" if app.lsp_popup_open_public

        raise "a subsequent hover should be accepted" unless app.trigger_hover_public
        wait_for_async_transport_response(responses, "fresh-hover")
        deadline = Time.instant + 1.second
        until app.lsp_popup_open_public
          raise "fresh hover was not published" if Time.instant >= deadline
          sleep 5.milliseconds
        end
        raise "fresh hover popup is missing its result" unless app.lsp_popup_lines_public.includes?("fresh-hover")
      ensure
        File.write(release.to_s, "release")
        client.stop
      end
    end
  end

  it "releases a stopped hover worker so a replacement client can answer" do
    with_async_lsp_transport_workspace do |tmp|
      source = tmp / "main.cr"
      server = tmp / "fake_lsp"
      requests = tmp / "requests.log"
      responses = tmp / "responses.log"
      accepted = tmp / "accepted"
      File.write(source.to_s, "puts 1\n")
      write_async_lsp_transport_server(server)

      client = Adamantine::Lsp::Client.new(server.to_s, tmp, ["hold", requests.to_s, "", responses.to_s, accepted.to_s])
      app = AsyncTransportTestApp.new(project_root: tmp, lsp_command: "")
      replacement : Adamantine::Lsp::Client? = nil
      begin
        raise "client should start" unless client.start
        app.set_lsp_client_public(client)
        raise "source file should open" unless app.open_file_public(source)
        raise "hover key should be handled" unless app.trigger_hover_public
        wait_for_async_transport_file(accepted)

        stopped = Channel(Nil).new(1)
        spawn do
          client.stop
          stopped.send(nil)
        end
        select
        when stopped.receive
        when timeout(3.seconds)
          raise "stopping a held LSP server must be bounded"
        end
        raise "stopped client must be disconnected" if client.connected?

        replacement_server = tmp / "replacement_lsp"
        replacement_requests = tmp / "replacement_requests.log"
        replacement_responses = tmp / "replacement_responses.log"
        write_async_lsp_transport_server(replacement_server)
        replacement = Adamantine::Lsp::Client.new(
          replacement_server.to_s,
          tmp,
          ["immediate", replacement_requests.to_s, "", replacement_responses.to_s, ""]
        )
        raise "replacement client should start" unless replacement.not_nil!.start
        app.set_lsp_client_public(replacement.not_nil!)
        raise "hover key should be handled after replacement" unless app.trigger_hover_public
        wait_for_async_transport_response(replacement_responses, "replacement-hover", 2.seconds)

        deadline = Time.instant + 1.second
        until app.lsp_popup_open_public
          raise "replacement hover was not published" if Time.instant >= deadline
          sleep 5.milliseconds
        end
        raise "replacement hover popup is missing its result" unless app.lsp_popup_lines_public.includes?("replacement-hover")
      ensure
        replacement.try &.stop
        client.stop
      end
    end
  end
end
