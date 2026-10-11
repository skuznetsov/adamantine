#!/usr/bin/env ruby
require "json"
require "minitest/autorun"
require "rbconfig"
require "tmpdir"

class DebuggerFixtureExitTest < Minitest::Test
  FIXTURE = File.realpath(File.join(__dir__, "..", "spec/fixtures/debugger/dap_controller_adapter.rb"))

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
