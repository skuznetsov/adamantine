require "json"
require "spec"
require "file_utils"

require "../src/adamantine/lsp_client"

private class LspWriteQueueProbe < Adamantine::Lsp::Client
  def enqueue_payload(payload : String) : Nil
    send_payload(payload)
  end

  def pending_size : Int32
    @pending_mutex.synchronize { @pending.size.to_i32 }
  end

  def process_public : Process?
    @process
  end
end

private def with_lsp_write_queue_workspace(&)
  root = Path.new(Dir.tempdir, "adamantine-lsp-write-queue-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def write_lsp_write_queue_server(path : Path) : Nil
  File.write(path.to_s, <<-RUBY)
#!/usr/bin/env ruby
require "json"

ready_path = ARGV.fetch(0)
release_path = ARGV.fetch(1)
log_path = ARGV[2]

def read_message
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

def write_message(message)
  payload = JSON.generate(message)
  STDOUT.write("Content-Length: \#{payload.bytesize}\r\n\r\n\#{payload}")
  STDOUT.flush
end

def log_method(path, message)
  return if path.nil? || path.empty?
  File.open(path, "a") { |file| file.puts(message["method"] || "<response>") }
end

loop do
  message = read_message
  break unless message
  log_method(log_path, message)

  case message["method"]
  when "initialize"
    write_message({"jsonrpc" => "2.0", "id" => message["id"], "result" => {"capabilities" => {}}})
  when "initialized"
    File.write(ready_path, "ready")
    if release_path && !release_path.empty?
      sleep 0.01 until File.exist?(release_path)
    end
  when "test/request"
    write_message({"jsonrpc" => "2.0", "id" => message["id"], "result" => {"ok" => true}})
  when "shutdown"
    write_message({"jsonrpc" => "2.0", "id" => message["id"], "result" => nil})
  when "exit"
    break
  end
end
RUBY
  File.chmod(path.to_s, 0o755)
end

private def wait_for_lsp_write_queue_file(path : Path, timeout_span : Time::Span = 2.seconds) : Nil
  deadline = Time.instant + timeout_span
  loop do
    return if File.exists?(path.to_s)
    raise "timed out waiting for #{path.basename}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def lsp_write_queue_methods(path : Path) : Array(String)
  return [] of String unless File.exists?(path.to_s)
  File.read(path.to_s).lines.map(&.strip).reject(&.empty?)
end

private def assert_no_lsp_write_queue_failure(channel : Channel(String), duration : Time::Span = 100.milliseconds) : Nil
  select
  when reason = channel.receive
    raise "unexpected duplicate LSP transport failure callback: #{reason}"
  when timeout(duration)
    nil
  end
end

private def wait_for_lsp_write_queue_pending(client : LspWriteQueueProbe, timeout_span : Time::Span = 2.seconds) : Nil
  deadline = Time.instant + timeout_span
  loop do
    return if client.pending_size > 0
    raise "timed out waiting for a pending LSP request" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

describe "bounded asynchronous LSP outgoing writes" do
  it "keeps a caller fiber moving while the server stops reading" do
    with_lsp_write_queue_workspace do |root|
      server = root / "fake_lsp"
      ready = root / "ready"
      release = root / "release"
      write_lsp_write_queue_server(server)

      client = Adamantine::Lsp::Client.new(server.to_s, root, [ready.to_s, release.to_s])
      send_started = Channel(Nil).new(1)
      allow_send = Channel(Nil).new(1)
      send_finished = Channel(Exception?).new(1)
      payload = "x" * (2 * 1024 * 1024)
      did_change_returned = false

      begin
        raise "client should initialize" unless client.start
        wait_for_lsp_write_queue_file(ready)

        spawn do
          send_started.send(nil)
          allow_send.receive
          begin
            client.text_change("file:///main.cr", 2, payload)
            send_finished.send(nil)
          rescue ex
            send_finished.send(ex)
          end
        end

        send_started.receive
        allow_send.send(nil)
        select
        when error = send_finished.receive
          raise "full didChange caller failed before release: #{error}" if error
          did_change_returned = true
        when timeout(500.milliseconds)
          raise "full didChange caller remained blocked on the stopped server"
        end

        marker_result = Channel(Exception?).new(1)
        spawn do
          begin
            client.request_notification("test/marker")
            marker_result.send(nil)
          rescue ex
            marker_result.send(ex)
          end
        end
        select
        when error = marker_result.receive
          raise "marker enqueue failed before release: #{error}" if error
        when timeout(500.milliseconds)
          raise "marker caller remained blocked while the server stopped reading"
        end
      ensure
        File.write(release.to_s, "release")
        client.stop
      end

      raise "didChange caller result was not observed before release" unless did_change_returned
    end
  end

  it "preserves enqueue order and completes a normal request" do
    with_lsp_write_queue_workspace do |root|
      server = root / "fake_lsp"
      ready = root / "ready"
      log = root / "methods.log"
      write_lsp_write_queue_server(server)
      client = Adamantine::Lsp::Client.new(server.to_s, root, [ready.to_s, "", log.to_s])

      begin
        raise "client should initialize" unless client.start
        wait_for_lsp_write_queue_file(ready)

        result = client.request_raw("test/request")
        raise "normal request response was not successful" unless result["ok"]?.try(&.as_bool?)
        client.request_notification("test/first")
        client.request_notification("test/second")
      ensure
        client.stop
      end

      expected = ["initialize", "initialized", "test/request", "test/first", "test/second", "shutdown", "exit"]
      raise "outgoing JSON-RPC order changed: #{lsp_write_queue_methods(log).inspect}" unless lsp_write_queue_methods(log) == expected
    end
  end

  it "fails closed at bounded backpressure and reports transport failure once" do
    with_lsp_write_queue_workspace do |root|
      server = root / "fake_lsp"
      ready = root / "ready"
      release = root / "release"
      write_lsp_write_queue_server(server)

      failures = Channel(String).new(2)
      client = LspWriteQueueProbe.new(server.to_s, root, [ready.to_s, release.to_s])
      client.on_transport_failure = ->(reason : String) { failures.send(reason) }
      sender_error : Exception? = nil
      payload = "x" * (Adamantine::Lsp::Client::MAX_OUTGOING_BUFFER_BYTES // 3 + 1).to_i

      begin
        raise "client should initialize" unless client.start
        wait_for_lsp_write_queue_file(ready)

        4.times do
          begin
            client.enqueue_payload(payload)
          rescue ex
            sender_error = ex
            break
          end
          sleep 1.millisecond
        end

        raise "bounded queue accepted every write while peer stopped reading" unless sender_error
        select
        when reason = failures.receive
          raise "transport failure callback was empty" if reason.empty?
        when timeout(2.seconds)
          raise "bounded queue failure did not notify transport observer"
        end
        assert_no_lsp_write_queue_failure(failures)
        raise "full queue must detach the client" if client.connected?
      ensure
        File.write(release.to_s, "release")
        client.stop
      end
    end
  end

  it "releases pending work, reaps on stop, and allows replacement recovery" do
    with_lsp_write_queue_workspace do |root|
      server = root / "fake_lsp"
      ready = root / "ready"
      release = root / "release"
      replacement_ready = root / "replacement-ready"
      log = root / "replacement-methods.log"
      write_lsp_write_queue_server(server)

      client = LspWriteQueueProbe.new(server.to_s, root, [ready.to_s, release.to_s])
      replacement : LspWriteQueueProbe? = nil
      pending_result = Channel(Exception?).new(1)
      old_process : Process? = nil

      begin
        raise "client should initialize" unless client.start
        wait_for_lsp_write_queue_file(ready)
        old_process = client.process_public
        raise "client must own a process" unless old_process

        spawn do
          begin
            client.request_raw("test/request")
            pending_result.send(nil)
          rescue ex
            pending_result.send(ex)
          end
        end
        wait_for_lsp_write_queue_pending(client)

        client.stop
        select
        when error = pending_result.receive
          raise "pending request unexpectedly succeeded" unless error
        when timeout(2.seconds)
          raise "stop did not release the pending request"
        end

        # The fake server intentionally remains asleep after initialization;
        # stop must release the pending request without waiting for it to read
        # another frame. Release it only after the client has detached, then
        # verify the explicit reap path completes.
        File.write(release.to_s, "release")
        deadline = Time.instant + 2.seconds
        loop do
          break if old_process.not_nil!.terminated?
          raise "stop did not reap the old process" if Time.instant >= deadline
          sleep 5.milliseconds
        end

        replacement = LspWriteQueueProbe.new(server.to_s, root, [replacement_ready.to_s, "", log.to_s])
        raise "replacement client should initialize" unless replacement.not_nil!.start
        wait_for_lsp_write_queue_file(replacement_ready)
      ensure
        File.write(release.to_s, "release")
        replacement.try &.stop
        client.stop
      end
    end
  end

  it "keeps the payload cap above the admitted escaped document budget" do
    admitted_source_bytes = 16 * 1024 * 1024
    worst_case_json_bytes = admitted_source_bytes * 6
    envelope_bytes = 4096
    required_cap = worst_case_json_bytes + envelope_bytes

    raise "outgoing cap rejects an admitted 16 MiB escaped document" unless Adamantine::Lsp::Client::MAX_OUTGOING_PAYLOAD_BYTES >= required_cap
    raise "aggregate outgoing budget must cover one admitted payload" unless Adamantine::Lsp::Client::MAX_OUTGOING_BUFFER_BYTES >= required_cap
    raise "outgoing queue must remain explicitly bounded" unless Adamantine::Lsp::Client::OUTGOING_QUEUE_CAPACITY > 0 && Adamantine::Lsp::Client::OUTGOING_QUEUE_CAPACITY <= 8
  end
end
