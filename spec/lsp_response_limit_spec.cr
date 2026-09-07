require "json"
require "spec"
require "crystal_tui"
require "file_utils"

require "../src/adamantine/lsp_client"

private class LspResponseLimitProbe < Adamantine::Lsp::Client
  @test_discard_timeout : Time::Span?

  def initialize(command : String = "", root : Path = Path.new(Dir.current), args : Array(String) = [] of String)
    super(command, root, args)
  end

  def discard_timeout=(value : Time::Span) : Nil
    @test_discard_timeout = value
  end

  private def response_discard_timeout : Time::Span
    @test_discard_timeout || super
  end

  def read_message_public(io : IO) : JSON::Any
    read_message(io)
  end
end

private def with_lsp_response_limit_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-lsp-response-limit-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def write_lsp_response_limit_server(path : Path) : Nil
  File.write(path.to_s, <<-RUBY)
#!/usr/bin/env ruby
require "json"

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

oversized_sent = false
loop do
  message = read_msg
  break unless message

  method = message["method"]
  id = message["id"]
  case method
  when "initialize"
    write_msg({"jsonrpc" => "2.0", "id" => id, "result" => {"capabilities" => {}}})
  when "initialized"
  when "textDocument/hover"
    if !oversized_sent
      oversized_sent = true
      payload = JSON.generate({
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => {"text" => "x" * (2 * 1024 * 1024)},
      })
      STDOUT.write("Content-Length: " + payload.bytesize.to_s + "\r\n\r\n" + payload)
      STDOUT.flush
    else
      write_msg({"jsonrpc" => "2.0", "id" => id, "result" => {"text" => "small"}})
    end
  when "shutdown"
    write_msg({"jsonrpc" => "2.0", "id" => id, "result" => nil})
  when "exit"
    break
  end
end
RUBY
  File.chmod(path.to_s, 0o755)
end

private def write_lsp_response_limit_stall_server(path : Path) : Nil
  File.write(path.to_s, <<-RUBY)
#!/usr/bin/env ruby
require "json"

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

loop do
  message = read_msg
  break unless message
  method = message["method"]
  id = message["id"]
  case method
  when "initialize"
    payload = JSON.generate({"jsonrpc" => "2.0", "id" => id, "result" => {"capabilities" => {}}})
    STDOUT.write("Content-Length: " + payload.bytesize.to_s + "\r\n\r\n" + payload)
    STDOUT.flush
  when "initialized"
  when "textDocument/hover"
    # Announce a body larger than the configured cap, then stop producing it.
    STDOUT.write("Content-Length: 2097152\r\n\r\nX")
    STDOUT.flush
    sleep 2
  when "shutdown"
    payload = JSON.generate({"jsonrpc" => "2.0", "id" => id, "result" => nil})
    STDOUT.write("Content-Length: " + payload.bytesize.to_s + "\r\n\r\n" + payload)
    STDOUT.flush
  when "exit"
    break
  end
end
RUBY
  File.chmod(path.to_s, 0o755)
end

private def lsp_frame(payload : String) : String
  "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}"
end

describe "LSP response limits" do
  it "validates the public response limit range" do
    client = LspResponseLimitProbe.new
    client.max_response_bytes = 1 * 1024 * 1024
    raise "minimum response limit should be accepted" unless client.max_response_bytes == 1 * 1024 * 1024
    client.max_response_bytes = 64 * 1024 * 1024
    raise "maximum response limit should be accepted" unless client.max_response_bytes == 64 * 1024 * 1024

    expect_raises(ArgumentError) { client.max_response_bytes = 1 * 1024 * 1024 - 1 }
    expect_raises(ArgumentError) { client.max_response_bytes = 64 * 1024 * 1024 + 1 }
  end

  it "accepts a framed body above the legacy 4 MiB buffer under the default limit" do
    client = LspResponseLimitProbe.new
    raise "default response limit should be 16 MiB" unless client.max_response_bytes == 16 * 1024 * 1024

    payload = {
      "jsonrpc" => "2.0",
      "id"      => 1,
      "result"  => {"text" => "x" * (Adamantine::Lsp::Client::MAX_JSON_BUFFER + 1024)},
    }.to_json

    response = client.read_message_public(IO::Memory.new(lsp_frame(payload)))
    raise "response id should survive the larger framed body" unless response["id"].as_i == 1
    raise "response body should be parsed" unless response["result"]["text"].as_s.bytesize > Adamantine::Lsp::Client::MAX_JSON_BUFFER
  end

  it "accepts a body exactly at the configured limit and drains one byte above it" do
    client = LspResponseLimitProbe.new
    client.max_response_bytes = 1 * 1024 * 1024
    prefix = %({"jsonrpc":"2.0","id":1,"result":{"text":"})
    suffix = %("}})
    exact_payload = prefix + ("x" * (client.max_response_bytes - prefix.bytesize - suffix.bytesize)) + suffix
    raise "boundary fixture must be exactly one MiB" unless exact_payload.bytesize == client.max_response_bytes

    response = client.read_message_public(IO::Memory.new(lsp_frame(exact_payload)))
    raise "body at the configured limit should be parsed" unless response["id"].as_i == 1

    warnings = Channel(String).new(1)
    client.on_warning = ->(message : String) { warnings.send(message) }
    one_byte_over = "x" * (client.max_response_bytes + 1)
    discarded = client.read_message_public(IO::Memory.new(lsp_frame(one_byte_over)))
    raise "body above the configured limit should be discarded" unless discarded.raw.nil?
    select
    when warnings.receive
    when timeout(1.second)
      raise "one-byte-over response should be visible"
    end
  end

  it "drains an oversized framed body and preserves the following small frame" do
    client = LspResponseLimitProbe.new
    client.max_response_bytes = 1 * 1024 * 1024
    warnings = Channel(String).new(1)
    client.on_warning = ->(message : String) { warnings.send(message) }

    oversized = {"jsonrpc" => "2.0", "id" => 1, "result" => {"text" => "x" * (2 * 1024 * 1024)}}.to_json
    small = {"jsonrpc" => "2.0", "id" => 2, "result" => {"text" => "small"}}.to_json
    io = IO::Memory.new(lsp_frame(oversized) + lsp_frame(small))

    discarded = client.read_message_public(io)
    raise "discarded frame must not be parsed" unless discarded.raw.nil?
    warning = select
    when message = warnings.receive
      message
    when timeout(1.second)
      raise "oversized response warning should be visible"
    end
    raise "warning should include the observed body size" unless warning.includes?(oversized.bytesize.to_s)
    raise "warning should name the configured limit" unless warning.includes?((1 * 1024 * 1024).to_s)
    raise "warning should point to F10 settings" unless warning.includes?("F10 Settings LSP response limit")

    response = client.read_message_public(io)
    raise "following small response should remain readable" unless response["id"].as_i == 2
    raise "following small response should be parsed" unless response["result"]["text"].as_s == "small"
  end

  it "rejects a frame above the absolute discard cap with a visible warning" do
    client = LspResponseLimitProbe.new
    warnings = Channel(String).new(1)
    client.on_warning = ->(message : String) { warnings.send(message) }
    frame = "Content-Length: #{Adamantine::Lsp::Client::MAX_DISCARD_BYTES + 1}\r\n\r\n"

    expect_raises(Exception) { client.read_message_public(IO::Memory.new(frame)) }
    warning = select
    when message = warnings.receive
      message
    when timeout(1.second)
      raise "hard-cap rejection should be visible"
    end
    raise "hard-cap warning should identify the reason" unless warning.includes?("above hard discard cap")
    raise "hard-cap warning should include the observed size" unless warning.includes?((Adamantine::Lsp::Client::MAX_DISCARD_BYTES + 1).to_s)
    raise "hard-cap warning should point to F10 settings" unless warning.includes?("F10 Settings LSP response limit")
  end

  it "rejects EOF before the framed header separator" do
    client = LspResponseLimitProbe.new

    expect_raises(Exception, "headers truncated") do
      client.read_message_public(IO::Memory.new("Content-Length: 2\r\n"))
    end
  end

  it "fails pending work conservatively while keeping the live transport usable" do
    with_lsp_response_limit_workspace do |tmp|
      server = tmp / "fake_lsp"
      write_lsp_response_limit_server(server)
      client = LspResponseLimitProbe.new(server.to_s, tmp)
      client.max_response_bytes = 1 * 1024 * 1024
      warning_seen = Channel(Nil).new(1)
      client.on_warning = ->(_message : String) do
        warning_seen.send(nil)
        raise "warning sink failure"
      end

      begin
        raise "client should start" unless client.start

        first_error : Exception? = nil
        begin
          client.request_raw("textDocument/hover", {"textDocument" => {"uri" => "file:///main.cr"}})
        rescue ex
          first_error = ex
        end
        raise "oversized response should fail the pending request" unless first_error
        raise "fully drained oversized response should not disconnect" unless client.connected?

        select
        when warning_seen.receive
        when timeout(1.second)
          raise "oversized response warning callback should run"
        end

        result = client.request_raw("textDocument/hover", {"textDocument" => {"uri" => "file:///main.cr"}})
        raise "small response after oversized frame should succeed" unless result["text"].as_s == "small"
      ensure
        client.stop
      end
    end
  end

  it "closes a stalled oversized frame by its absolute discard deadline" do
    with_lsp_response_limit_workspace do |tmp|
      server = tmp / "stall_lsp"
      write_lsp_response_limit_stall_server(server)
      client = LspResponseLimitProbe.new(server.to_s, tmp)
      client.max_response_bytes = 1 * 1024 * 1024
      client.discard_timeout = 50.milliseconds
      warnings = Channel(String).new(1)
      client.on_warning = ->(message : String) { warnings.send(message) }

      begin
        raise "client should start" unless client.start
        result = Channel(Exception?).new(1)
        spawn do
          begin
            client.request_raw("textDocument/hover", {"textDocument" => {"uri" => "file:///main.cr"}})
            result.send(nil)
          rescue ex
            result.send(ex)
          end
        end

        error = select
        when value = result.receive
          value
        when timeout(1.second)
          raise "stalled oversized response should fail promptly"
        end
        raise "stalled oversized response should fail the pending request" unless error
        raise "stalled oversized response should disconnect" if client.connected?

        warning = select
        when message = warnings.receive
          message
        when timeout(1.second)
          raise "stalled oversized response should warn"
        end
        raise "warning should identify the stalled discard" unless warning.includes?("stalled")
      ensure
        client.stop
      end
    end
  end
end
