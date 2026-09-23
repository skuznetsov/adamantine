require "pty"
require "io/console"
require "tmpdir"
require "json"
require "digest"
require "fileutils"

WAIT_SECONDS = 8

def await(label, seconds = WAIT_SECONDS)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  until yield
    raise "timeout: #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
end

def event_rows(path)
  return [] unless File.exist?(path)
  File.readlines(path).map { |line| JSON.parse(line) rescue nil }.compact
end

def event_count(path, method)
  event_rows(path).count { |event| event["method"] == method }
end

def plain_output(text)
  text.scrub
      .gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
      .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "")
end

class PtySession
  attr_reader :pid, :exit_status

  def initialize(binary, args, root)
    env = {"TERM" => "xterm-256color", "ADAMANTINE_SESSION" => "0",
           "ADAMANTINE_RECOVERY" => "0", "ADAMANTINE_STATE_HOME" => File.join(root, "state")}
    @reader, @writer, @pid = PTY.spawn(env, binary, *args)
    @reader.winsize = [26, 120]
    @output = +""
    @output_mutex = Mutex.new
    @reaped = false
    @reader_thread = Thread.new do
      begin
        loop do
          chunk = @reader.readpartial(65_536)
          @output_mutex.synchronize { @output << chunk }
        end
      rescue EOFError, Errno::EIO, IOError
      end
    end
  end

  def output
    @output_mutex.synchronize { @output.dup }
  end

  def output_since(offset)
    plain_output(output.byteslice(offset..) || "")
  end

  def write(sequence)
    @writer.write(sequence)
    @writer.flush
  end

  def type(text)
    text.each_codepoint { |codepoint| write("\e[#{codepoint}u") }
  end

  def palette(query)
    write("\eOP") # F1 through the real terminal input parser.
    sleep 0.15
    type(query)
  end

  def enter
    write("\e[13u")
  end

  def await_output(label, text, offset = 0)
    await(label) { output_since(offset).include?(text) }
  end

  def await_exit(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until @reaped
      pair = Process.waitpid2(@pid, Process::WNOHANG)
      if pair
        @reaped = true
        @exit_status = pair[1]
        return
      end
      raise "timeout waiting for editor exit" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
  rescue Errno::ECHILD
    @reaped = true
  end

  def alive?
    return false if @reaped
    pair = Process.waitpid2(@pid, Process::WNOHANG)
    if pair
      @reaped = true
      @exit_status = pair[1]
      false
    else
      true
    end
  rescue Errno::ECHILD
    @reaped = true
    false
  end

  def close
    terminate_editor
    @writer.close unless @writer.closed?
    @reader.close unless @reader.closed?
    @reader_thread.join(0.5)
    @reader_thread.kill if @reader_thread.alive?
    @reader_thread.join(0.5)
  rescue IOError
  end

  private

  def terminate_editor
    return if @reaped
    signal_exact_child("TERM")
    return if reap_within(0.5)
    signal_exact_child("KILL")
    reap_within(1.0)
  end

  def signal_exact_child(signal)
    Process.kill(signal, @pid)
  rescue Errno::ESRCH, Errno::ECHILD
  end

  def reap_within(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until @reaped
      pair = Process.waitpid2(@pid, Process::WNOHANG)
      if pair
        @reaped = true
        @exit_status = pair[1]
        return true
      end
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
    true
  rescue Errno::ECHILD
    @reaped = true
    true
  end

end

binary = File.realpath(ARGV.fetch(0) { abort "usage: ruby scripts/smoke_lsp_recovery.rb /path/to/current/adamantine" })
abort "binary is not executable: #{binary}" unless File.executable?(binary)
ruby = "/usr/bin/ruby"
abort "Ruby fixture runtime is unavailable: #{ruby}" unless File.executable?(ruby)
fixture = File.expand_path("../spec/fixtures/lsp_failure_probe_server.rb", __dir__)
binary_sha256 = Digest::SHA256.file(binary).hexdigest

positive_root = Dir.mktmpdir("adamantine-lsp-recovery-positive-")
positive_config = File.join(positive_root, "config.json")
positive_events = File.join(positive_root, "events.jsonl")
positive_ready = File.join(positive_root, "second-peer-ready")
File.write(positive_config, "{}")
positive = nil
begin
  positive_args = [positive_root, "--config", positive_config, "--lsp", ruby,
                   "--lsp-arg", fixture, "--lsp-arg", positive_events,
                   "--lsp-arg", positive_ready]
  positive = PtySession.new(binary, positive_args, positive_root)
  positive.await_output("initial failure header", "[LSP failed]")
  positive.await_output("initial failure hint", "Press F1 for Restart LSP")
  raise "initial peer was not the only initialized peer before user input" unless event_count(positive_events, "initialize") == 1

  positive.palette("restart")
  raise "F1 search unexpectedly restarted the peer before selection" unless event_count(positive_events, "initialize") == 1
  positive.enter
  await("manual F1 selection starts replacement peer") { event_count(positive_events, "initialize") >= 2 }
  await("replacement peer completes initialization") { event_count(positive_events, "initialized") == 1 }
  raise "expected exactly initial failed peer plus one explicit restart" unless event_count(positive_events, "initialize") == 2

  positive.palette(":q!")
  positive.enter
  positive.await_exit
  raise "editor did not exit cleanly" unless positive.exit_status&.success?
  positive.close
  positive_result = {f1_search_selected_restart: true, manual_restart: true,
                     failure_header_output: true, failure_hint_output: true, clean_quit: true,
                     initialize_count: event_count(positive_events, "initialize")}
ensure
  positive&.close
  FileUtils.remove_entry(positive_root) if File.exist?(positive_root)
end

negative_root = Dir.mktmpdir("adamantine-lsp-recovery-disabled-")
negative_config = File.join(negative_root, "config.json")
File.write(negative_config, "{}")
negative = nil
begin
  negative = PtySession.new(binary, [negative_root, "--config", negative_config, "--no-lsp"], negative_root)
  negative.await_output("disabled header", "[LSP disabled]")
  negative.palette("restart")
  negative.enter
  raise "editor exited after the no-LSP F1 input attempt" unless negative.alive?
  raise "disabled control unexpectedly showed failed health" if negative.output.include?("[LSP failed]")
  negative.write("\e[27u")
  sleep 0.1
  negative.palette(":q!")
  negative.enter
  negative.await_exit
  raise "negative-control editor did not exit cleanly" unless negative.exit_status&.success?
  negative.close
  negative_result = {editor_alive_after_no_lsp_input_attempt: true, clean_quit: true}
ensure
  negative&.close
  FileUtils.remove_entry(negative_root) if File.exist?(negative_root)
end

puts JSON.generate(result: "PASS", binary: binary, sha256: binary_sha256,
                   positive: positive_result, negative: negative_result)
