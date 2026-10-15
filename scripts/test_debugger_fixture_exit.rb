#!/usr/bin/env ruby
require "json"
require "minitest/autorun"
require "rbconfig"
require "tmpdir"

class DebuggerFixtureExitTest < Minitest::Test
  FIXTURE = File.realpath(File.join(__dir__, "..", "spec/fixtures/debugger/dap_controller_adapter.rb"))

  def test_wrong_disconnect_ack_survives_term_until_post_frame_marker
    Dir.mktmpdir("adamantine-dap-wrong-ack-") do |directory|
      log = File.join(directory, "adapter.jsonl")
      held = File.join(directory, "wrong-ack-frame-flushed")
      release = File.join(directory, "release-wrong-ack")
      child = spawn_traced_fixture(log, held, release)
      begin
        write_dap_message(child[:stdin], {
          "seq" => 23,
          "type" => "request",
          "command" => "disconnect",
          "arguments" => {},
        })
        response = read_dap_message(child[:stdout])
        assert_equal "response", response["type"]
        assert_equal "disconnect", response["command"]
        assert_equal 1023, response["request_seq"]
        assert_equal true, response["success"]
        wait_until("post-flush wrong-ACK hold") { File.file?(held) }
        assert_empty fixture_markers(log, "disconnect_wrong_ack_written")

        Process.kill("TERM", child[:pid])
        deadline = monotonic + 0.1
        loop do
          assert process_alive?(child), "TERM ended the fixture before its post-frame marker"
          assert_empty fixture_markers(log, "disconnect_wrong_ack_written"),
            "the post-frame marker was written before releasing the fixture"
          break if monotonic >= deadline
          sleep 0.005
        end

        File.write(release, "release\n")
        status = wait_for_exit(child)
        assert status.success?, "wrong-ACK fixture did not exit normally after release: #{status.inspect}"
        assert_equal 1, fixture_markers(log, "disconnect_wrong_ack_written").size
      ensure
        File.write(release, "cleanup\n") unless File.file?(release)
        close_and_reap(child)
        assert child[:stdout].closed?, "owned fixture stdout must be closed after cleanup"
      end
    end
  end

  def test_close_and_reap_closes_stdout_after_terminating_live_child
    child_stdin, parent_stdin = IO.pipe
    parent_stdout, child_stdout = IO.pipe
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30",
      in: child_stdin, out: child_stdout, err: File::NULL)
    child_stdin.close
    child_stdout.close
    child = {pid: pid, stdin: parent_stdin, stdout: parent_stdout, reaped: false, status: nil}

    close_and_reap(child)

    assert child[:reaped], "live fixture child was not reaped"
    assert child[:stdout].closed?, "owned fixture stdout must be closed after normal cleanup"
  ensure
    close_and_reap(child) if child && !child[:reaped]
    [child_stdin, parent_stdin, parent_stdout, child_stdout].compact.each do |io|
      io.close unless io.closed?
    end
  end

  def test_close_and_reap_closes_stdout_when_stdin_cleanup_raises
    stdout_reader, stdout_writer = IO.pipe
    stdin = Object.new
    stdin.define_singleton_method(:closed?) { false }
    stdin.define_singleton_method(:close) { raise IOError, "synthetic stdin close failure" }
    child = {stdin: stdin, stdout: stdout_writer, reaped: true}

    error = assert_raises(IOError) { close_and_reap(child) }

    assert_equal "synthetic stdin close failure", error.message
    assert child[:stdout].closed?, "owned fixture stdout must be closed after exceptional cleanup"
  ensure
    [stdout_reader, stdout_writer].compact.each do |io|
      io.close unless io.closed?
    end
  end

  def test_eof_alone_exits_with_the_started_pid_marker
    Dir.mktmpdir("adamantine-dap-eof-") do |directory|
      child = spawn_fixture(File.join(directory, "adapter.jsonl"))
      begin
        wait_for_started(child)
        child[:stdin].close
        status = wait_for_exit(child)

        assert status.success?, "fixture did not exit normally on stdin EOF: #{status.inspect}"
        assert_equal [child[:pid]], marker_pids(child[:log], "smoke_process_started")
        assert_equal [child[:pid]], marker_pids(child[:log], "smoke_process_exited")
      ensure
        close_and_reap(child)
      end
    end
  end

  def test_immediate_eof_then_term_repeatedly_exits_with_matching_markers
    Dir.mktmpdir("adamantine-dap-eof-term-") do |directory|
      12.times do |index|
        child = spawn_fixture(File.join(directory, "adapter-#{index}.jsonl"))
        begin
          wait_for_started(child)
          child[:stdin].close
          begin
            Process.kill("TERM", child[:pid])
          rescue Errno::ESRCH
            # EOF can complete before the immediate TERM reaches the child.
          end
          status = wait_for_exit(child)

          assert status.success?, "EOF+TERM fixture did not exit normally: #{status.inspect}"
          assert_equal [child[:pid]], marker_pids(child[:log], "smoke_process_started")
          assert_equal [child[:pid]], marker_pids(child[:log], "smoke_process_exited")
        ensure
          close_and_reap(child)
        end
      end
    end
  end

  def test_term_alone_cannot_mark_a_still_live_fixture_complete
    Dir.mktmpdir("adamantine-dap-term-held-") do |directory|
      child = spawn_fixture(File.join(directory, "adapter.jsonl"))
      begin
        wait_for_started(child)
        Process.kill("TERM", child[:pid])

        # The fixture's reader remains open. Require the child to stay live
        # without an exit marker until the owner closes that pipe.
        deadline = monotonic + 0.1
        loop do
          assert process_alive?(child), "TERM ended the fixture while stdin was still open"
          assert_empty marker_pids(child[:log], "smoke_process_exited"),
            "an exit marker was written while the fixture was still live"
          break if monotonic >= deadline
          sleep 0.005
        end

        child[:stdin].close
        status = wait_for_exit(child)
        assert status.success?, "fixture did not exit normally after the owner closed stdin: #{status.inspect}"
        assert_equal [child[:pid]], marker_pids(child[:log], "smoke_process_exited")
      ensure
        close_and_reap(child)
      end
    end
  end

  private

  def spawn_fixture(log)
    child_stdin, parent_stdin = IO.pipe
    pid = Process.spawn(RbConfig.ruby, FIXTURE, log, "smoke_process",
      in: child_stdin, out: File::NULL, err: File::NULL)
    child_stdin.close
    {pid: pid, stdin: parent_stdin, log: log, reaped: false, status: nil}
  rescue
    child_stdin&.close rescue nil
    parent_stdin&.close rescue nil
    raise
  end

  def spawn_traced_fixture(log, held, release)
    child_stdin, parent_stdin = IO.pipe
    parent_stdout, child_stdout = IO.pipe
    runner = <<~'RUBY'
      fixture, log, mode, held_path, release_path = ARGV
      ARGV.replace([log, mode])
      trace = TracePoint.new(:return) do |event|
        next unless event.defined_class == Object && event.method_id == :write_message
        message = event.binding.local_variable_get(:message)
        next unless message.is_a?(Hash) && message["type"] == "response" && message["command"] == "disconnect"
        next unless message["request_seq"] == 1023 && message["success"] == true

        File.write(held_path, "flushed\n")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
        until File.file?(release_path)
          raise "timed out waiting for wrong-ACK release" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.002
        end
      end
      trace.enable { load fixture }
    RUBY
    pid = Process.spawn(RbConfig.ruby, "-e", runner, FIXTURE, log, "disconnect_eof_wrong_ack", held, release,
      in: child_stdin, out: child_stdout, err: File::NULL)
    child_stdin.close
    child_stdout.close
    {pid: pid, stdin: parent_stdin, stdout: parent_stdout, log: log, reaped: false, status: nil}
  rescue
    child_stdin&.close rescue nil
    parent_stdin&.close rescue nil
    child_stdout&.close rescue nil
    parent_stdout&.close rescue nil
    raise
  end

  def write_dap_message(io, message)
    body = JSON.generate(message)
    io.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    io.flush
  end

  def read_dap_message(io, timeout: 2.0)
    deadline = monotonic + timeout
    header = +"".b
    until header.include?("\r\n\r\n")
      header << read_bytes(io, 1, deadline)
      raise "oversized fixture DAP header" if header.bytesize > 4096
    end
    length_match = header.match(/^Content-Length:\s*(\d+)/i)
    length = length_match && length_match[1].to_i
    raise "fixture DAP response omitted Content-Length" unless length
    JSON.parse(read_bytes(io, length, deadline))
  end

  def read_bytes(io, length, deadline)
    bytes = +"".b
    while bytes.bytesize < length
      remaining = deadline - monotonic
      raise "timeout reading fixture DAP response" unless remaining.positive?
      raise "fixture closed DAP output before response completed" unless IO.select([io], nil, nil, remaining)
      begin
        bytes << io.read_nonblock(length - bytes.bytesize)
      rescue IO::WaitReadable
        next
      end
    end
    bytes
  end

  def wait_for_started(child)
    wait_until("fixture start marker") do
      marker_pids(child[:log], "smoke_process_started") == [child[:pid]]
    end
  end

  def wait_for_exit(child)
    wait_until("owned fixture exit") { !process_alive?(child) }
    child[:status]
  end

  def process_alive?(child)
    return false if child[:reaped]
    waited = Process.waitpid(child[:pid], Process::WNOHANG)
    if waited
      child[:reaped] = true
      child[:status] = $?
      false
    else
      true
    end
  rescue Errno::ECHILD
    child[:reaped] = true
    false
  end

  def close_and_reap(child)
    child[:stdin].close unless child[:stdin].closed?
    return if child[:reaped]

    unless process_alive?(child)
      return
    end
    begin
      Process.kill("TERM", child[:pid])
    rescue Errno::ESRCH
    end
    deadline = monotonic + 1.0
    sleep 0.005 while process_alive?(child) && monotonic < deadline
    if process_alive?(child)
      begin
        Process.kill("KILL", child[:pid])
      rescue Errno::ESRCH
      end
      deadline = monotonic + 1.0
      sleep 0.005 while process_alive?(child) && monotonic < deadline
    end
    raise "could not reap owned fixture PID #{child[:pid]}" unless child[:reaped]
  ensure
    stdout = child[:stdout]
    stdout.close if stdout && !stdout.closed?
  end

  def marker_pids(path, name)
    return [] unless File.file?(path)
    File.readlines(path, chomp: true).each_with_object([]) do |line, pids|
      record = JSON.parse(line)
      next unless record["type"] == "fixture" && record["name"] == name
      pid = record["pid"]
      pids << pid if pid.is_a?(Integer) && pid.positive?
    rescue JSON::ParserError
      # The child may be in the middle of appending a record.
    end
  end

  def fixture_markers(path, name)
    return [] unless File.file?(path)
    File.readlines(path, chomp: true).each_with_object([]) do |line, records|
      record = JSON.parse(line)
      next unless record["type"] == "fixture" && record["name"] == name
      records << record
    rescue JSON::ParserError
      # The child may be in the middle of appending a record.
    end
  end

  def wait_until(label, seconds: 2.0)
    deadline = monotonic + seconds
    until yield
      raise "timeout waiting for #{label}" if monotonic >= deadline
      sleep 0.005
    end
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
