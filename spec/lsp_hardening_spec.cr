require "json"
require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/lsp_client"

class LspHardeningClient < Adamantine::Lsp::Client
  def attach_stdin(io : IO) : Nil
    @stdin = io
  end

  def send_payload_public(payload : String) : Nil
    send_payload(payload)
  end

  def read_message_public(io : IO) : JSON::Any
    read_message(io)
  end

  def attach_running_process(io : IO, process : Process) : Nil
    @stdin = io
    @process = process
    @connected = true
  end
end

class BlockingLspSink < IO
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  @blocked = false

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    unless @blocked
      @blocked = true
      @entered.send(nil)
      @release.receive
    end
  end

  def close : Nil
    select
    when @release.send(nil)
    else
    end
    super
  end
end

class YieldingMemory < IO::Memory
  def write(slice : Bytes) : Nil
    Fiber.yield
    super
  end
end

def with_lsp_hardening_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-lsp-hardening-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

def write_lsp_hardening_server(path : Path) : Nil
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
  JSON.parse(STDIN.read(length))
end

def write_msg(obj)
  payload = JSON.generate(obj)
  STDOUT.write("Content-Length: \#{payload.bytesize}\r\n\r\n\#{payload}")
  STDOUT.flush
end

mode = ARGV[0]
log_path = ARGV[1]
loop do
  msg = read_msg
  break unless msg
  method = msg["method"]
  id = msg["id"]

  if method.nil? && msg.key?("id") && log_path
    File.open(log_path, "a") { |file| file.puts(JSON.generate(msg)) }
  end

  case method
  when "initialize"
    write_msg({"jsonrpc" => "2.0", "id" => id, "result" => {"capabilities" => {}}})
    if mode == "disconnect"
      # The client must fail a pending request as soon as this stream ends.
      # Keep the initialize response above intact, then close stdout on hover.
    end
  when "initialized"
  when "textDocument/hover"
    if mode == "collision"
      write_msg({"jsonrpc" => "2.0", "id" => "server-string", "method" => "workspace/semanticTokens/refresh", "params" => {}})
      write_msg({"jsonrpc" => "2.0", "id" => id, "method" => "workspace/semanticTokens/refresh", "params" => {}})
      write_msg({"jsonrpc" => "2.0", "id" => id, "result" => {"contents" => "hover result"}})
    elsif mode == "malformed"
      STDOUT.write("not-json\n")
      STDOUT.flush
      STDOUT.close
      exit!
    elsif mode == "eof"
      STDOUT.close
      exit!
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

describe "LSP hardening" do
  it "bounds stop when another writer is blocked on the server pipe" do
    client = LspHardeningClient.new("", Path.new(Dir.current))
    sink = BlockingLspSink.new
    process = Process.new("/usr/bin/true")
    client.attach_running_process(sink, process)

    spawn { client.send_payload_public(%({"jsonrpc":"2.0","method":"blocked"})) }
    sink.entered.receive

    stopped = Channel(Nil).new(1)
    spawn do
      client.stop
      stopped.send(nil)
    end

    disconnect_deadline = Time.instant + 250.milliseconds
    while client.connected? && Time.instant < disconnect_deadline
      Fiber.yield
    end
    raise "a stopping client must reject new requests immediately" if client.connected?

    select
    when stopped.receive
    when timeout(3.seconds)
      select
      when sink.release.send(nil)
      else
      end
      raise "stop must not wait forever behind a blocked writer"
    end
  ensure
    sink.try &.close
  end

  it "rejects an oversized newline-delimited JSON frame" do
    client = LspHardeningClient.new("", Path.new(Dir.current))
    oversized = %({"value":"#{"x" * Adamantine::Lsp::Client::MAX_JSON_BUFFER}"}\n)

    expect_raises(Exception, "LSP response too large") do
      client.read_message_public(IO::Memory.new(oversized))
    end
  end

  it "serializes complete LSP frames across concurrent writers" do
    client = LspHardeningClient.new("", Path.new(Dir.current))
    io = YieldingMemory.new
    client.attach_stdin(io)

    done = Channel(Nil).new(2)
    2.times do |index|
      spawn do
        client.send_payload_public({"jsonrpc" => "2.0", "id" => index, "result" => {"value" => index}}.to_json)
        done.send(nil)
      end
    end
    2.times { done.receive }

    wire = io.to_s
    offset = 0
    payloads = [] of JSON::Any
    2.times do
      header_end = wire.index("\r\n\r\n", offset)
      raise "frame headers must not interleave" unless header_end
      header = wire[offset...header_end]
      match = header.match(/Content-Length: (\d+)/)
      raise "missing Content-Length" unless match
      length = match[1].to_i
      payload_start = header_end + 4
      raise "truncated frame" if wire.bytesize < payload_start + length
      payloads << JSON.parse(wire[payload_start, length])
      offset = payload_start + length
    end

    raise "expected two complete frames" unless payloads.size == 2
    raise "unexpected trailing bytes" unless offset == wire.bytesize
  end

  it "distinguishes server requests from colliding responses and preserves string ids" do
    with_lsp_hardening_workspace do |tmp|
      server = tmp / "fake_lsp"
      log = tmp / "responses.log"
      write_lsp_hardening_server(server)
      client = Adamantine::Lsp::Client.new(server.to_s, tmp, ["collision", log.to_s])
      refreshes = Channel(Nil).new(1)
      client.on_semantic_tokens_refresh = -> { refreshes.send(nil) }

      begin
        raise "client should start" unless client.start
        hover = client.hover("file:///main.cr", 0, 0)
        raise "colliding server request must not consume the pending response" unless hover && hover.text == "hover result"
        select
        when refreshes.receive
        when timeout(1.second)
          raise "server request callbacks must be delivered"
        end
      ensure
        client.stop
      end

      responses = File.read(log.to_s).lines.map { |line| JSON.parse(line) }
      string_response = responses.find { |response| response["id"]?.try(&.as_s) == "server-string" }
      raise "string server request ids must be echoed" unless string_response && string_response["result"]?.try(&.raw) == nil
      numeric_response = responses.find { |response| response["id"]?.try(&.as_i64?) == 2 && response["result"]?.try(&.raw) == nil }
      raise "numeric colliding server request ids must be answered" unless numeric_response
    end
  end

  it "disconnects and promptly fails pending requests on EOF or malformed input" do
    ["eof", "malformed"].each do |mode|
      with_lsp_hardening_workspace do |tmp|
        server = tmp / "fake_lsp"
        write_lsp_hardening_server(server)
        client = Adamantine::Lsp::Client.new(server.to_s, tmp, [mode])
        begin
          raise "client should start for #{mode}" unless client.start
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
            raise "#{mode} must fail a pending request promptly"
          end
          raise "#{mode} must return an error" unless error
          raise "#{mode} must mark the client disconnected" if client.connected?
        ensure
          client.stop
        end
      end
    end
  end
end
