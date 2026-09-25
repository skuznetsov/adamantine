require "json"
require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/lsp_client"

private class RecoveryTransportTestClient < Adamantine::Lsp::Client
  def process_public : Process?
    @process
  end

  def transport_state_public : Tuple(Bool, Bool, Int32)
    pending_size = @pending_mutex.synchronize { @pending.size.to_i32 }
    {@connected, @stdin.nil? && @stdout.nil?, pending_size}
  end
end

private def with_recovery_transport_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "adamantine-lsp-recovery-transport-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def write_recovery_transport_server(path : Path) : Nil
  File.write(path.to_s, <<-RUBY)
#!/usr/bin/env ruby
require "json"

mode = ARGV.fetch(0)
signal_path = ARGV[1]
pid_path = ARGV[2]
release_path = ARGV[3]
File.write(pid_path, Process.pid.to_s) if pid_path && !pid_path.empty?

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
  STDOUT.write("Content-Length: " + payload.bytesize.to_s + "\\r\\n\\r\\n" + payload)
  STDOUT.flush
end

loop do
  message = read_msg
  break unless message

  method = message["method"]
  id = message["id"]
  case method
  when "initialize"
    if mode == "init_eof"
      exit
    end

    write_msg({
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => {"capabilities" => {}},
    })

    if mode == "init_response_eof"
      STDOUT.close
      exit
    end
  when "initialized"
    case mode
    when "eof"
      File.write(signal_path, "initialized") if signal_path && !signal_path.empty?
      exit
    when "pending_eof"
      File.write(signal_path, "initialized") if signal_path && !signal_path.empty?
    when "write_failure"
      fork do
        STDIN.reopen("/dev/null")
        until release_path && !release_path.empty? && File.exists?(release_path)
          sleep 0.01
        end
      end
      STDIN.close
      File.write(signal_path, "ready") if signal_path && !signal_path.empty?
      exit!
    when "stable"
      File.write(signal_path, "ready") if signal_path && !signal_path.empty?
    end
  when "textDocument/hover"
    if mode == "pending_eof"
      File.write(signal_path, "hover") if signal_path && !signal_path.empty?
      exit
    end
  when "shutdown"
    write_msg({"jsonrpc" => "2.0", "id" => id, "result" => nil}) if mode == "stable"
  when "exit"
    exit if mode == "stable"
  end
end
RUBY
  File.chmod(path.to_s, 0o755)
end

private def wait_for_recovery_file(path : Path, expected : String? = nil, timeout_span : Time::Span = 2.seconds) : Nil
  deadline = Time.instant + timeout_span
  loop do
    if File.exists?(path.to_s)
      return if expected.nil? || File.read(path.to_s) == expected
    end
    raise "timed out waiting for #{path.basename}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def receive_recovery_failure(channel : Channel(String), timeout_span : Time::Span = 2.seconds) : String
  select
  when reason = channel.receive
    reason
  when timeout(timeout_span)
    raise "timed out waiting for LSP transport failure"
  end
end

private def assert_no_recovery_failure(channel : Channel(String), duration : Time::Span = 100.milliseconds) : Nil
  select
  when reason = channel.receive
    raise "unexpected LSP transport failure callback: #{reason}"
  when timeout(duration)
    nil
  end
end

describe "LSP recovery transport failures" do
  it "notifies once after unexpected EOF with detached transport and cleared pending work" do
    with_recovery_transport_workspace do |tmp|
      server = tmp / "fake_lsp"
      signal = tmp / "signal"
      pid_file = tmp / "pid"
      write_recovery_transport_server(server)

      client = RecoveryTransportTestClient.new(server.to_s, tmp, ["pending_eof", signal.to_s, pid_file.to_s])
      failures = Channel(String).new(2)
      client.on_transport_failure = ->(reason : String) {
        connected, detached, pending_size = client.transport_state_public
        unless !connected && detached && pending_size == 0
          raise "transport callback observed stale state: connected=#{connected}, detached=#{detached}, pending=#{pending_size}"
        end
        failures.send(reason)
        client.stop
      }

      request_finished = Channel(Exception?).new(1)
      begin
        raise "client should start" unless client.start
        spawn do
          begin
            client.request_raw("textDocument/hover", {} of String => JSON::Any)
            request_finished.send(nil)
          rescue ex
            request_finished.send(ex)
          end
        end

        wait_for_recovery_file(signal, "hover")
        reason = receive_recovery_failure(failures)
        raise "failure reason should be non-empty" if reason.empty?
        select
        when error = request_finished.receive
          raise "pending request unexpectedly succeeded" unless error
        when timeout(2.seconds)
          raise "pending request was not released"
        end
        sleep 100.milliseconds
        assert_no_recovery_failure(failures)
      ensure
        client.stop
      end
    end
  end

  it "keeps explicit stop silent and reaps the old child before replacement" do
    with_recovery_transport_workspace do |tmp|
      server = tmp / "fake_lsp"
      signal = tmp / "signal"
      pid_file = tmp / "pid"
      write_recovery_transport_server(server)

      failures = Channel(String).new(1)
      client = RecoveryTransportTestClient.new(server.to_s, tmp, ["stable", signal.to_s, pid_file.to_s])
      client.on_transport_failure = ->(reason : String) { failures.send(reason) }
      old_process : Process? = nil
      replacement : RecoveryTransportTestClient? = nil
      begin
        raise "client should start" unless client.start
        wait_for_recovery_file(signal, "ready")
        old_process = client.process_public
        raise "client must own a child process" unless old_process
        raise "child must be running before stop" unless old_process.not_nil!.exists?

        client.stop
        raise "stop must disconnect the client" if client.connected?
        raise "stop must reap the old child" unless old_process.not_nil!.terminated?
        assert_no_recovery_failure(failures)

        replacement = RecoveryTransportTestClient.new(server.to_s, tmp, ["stable", signal.to_s, pid_file.to_s])
        raise "replacement client should start" unless replacement.not_nil!.start
        replacement.not_nil!.stop
      ensure
        replacement.try &.stop
        client.stop
      end
    end
  end

  it "keeps initialization failure silent and rejects a late EOF during startup" do
    with_recovery_transport_workspace do |tmp|
      server = tmp / "fake_lsp"
      signal = tmp / "signal"
      pid_file = tmp / "pid"
      write_recovery_transport_server(server)

      failures = Channel(String).new(2)
      client = RecoveryTransportTestClient.new(server.to_s, tmp, ["init_eof", signal.to_s, pid_file.to_s])
      client.on_transport_failure = ->(reason : String) { failures.send(reason) }
      raise "initialization EOF must make start fail" if client.start
      assert_no_recovery_failure(failures)
      client.stop

      late = RecoveryTransportTestClient.new(server.to_s, tmp, ["init_response_eof", signal.to_s, pid_file.to_s])
      late.on_transport_failure = ->(reason : String) { failures.send(reason) }
      if late.start
        receive_recovery_failure(failures)
        raise "late initialization EOF must disconnect the client" if late.connected?
      else
        # The reader may observe the EOF before start's final state check; in
        # that case startup cleanup owns the failure and stays silent.
        assert_no_recovery_failure(failures)
      end
      late.stop
    end
  end

  it "notifies on a failed transport write and contains observer exceptions" do
    with_recovery_transport_workspace do |tmp|
      server = tmp / "fake_lsp"
      signal = tmp / "signal"
      pid_file = tmp / "pid"
      release = tmp / "release"
      write_recovery_transport_server(server)

      observer_started = Channel(Nil).new(1)
      client = RecoveryTransportTestClient.new(server.to_s, tmp, ["write_failure", signal.to_s, pid_file.to_s, release.to_s])
      client.on_transport_failure = ->(_reason : String) {
        observer_started.send(nil)
        raise "observer failure must be contained"
      }

      begin
        raise "client should start" unless client.start
        wait_for_recovery_file(signal, "ready")
        deadline = Time.instant + 2.seconds
        until client.process_public.try(&.terminated?)
          raise "write-failure child did not exit" if Time.instant >= deadline
          sleep 5.milliseconds
        end
        begin
          client.request_notification("test/notification")
        rescue
        end
        select
        when observer_started.receive
        when timeout(2.seconds)
          raise "write failure did not notify observer"
        end
        sleep 100.milliseconds
        raise "failed write must disconnect the client" if client.connected?
      ensure
        File.write(release.to_s, "release")
        client.stop
      end
    end
  end
end
