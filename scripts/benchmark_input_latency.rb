#!/usr/bin/env ruby

# Diagnostic only: measures input write to the first PTY output chunk whose
# modeled terminal grid contains the expected changed text. It does not observe
# a real terminal emulator's rasterization or display scan-out.

require "fileutils"
require "digest"
require "io/console"
require "json"
require "open3"
require "optparse"
require "pty"
require "rbconfig"
require "time"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
DEFAULT_SIZE_MIB = 15
MAX_DOCUMENT_BYTES = 16 * 1024 * 1024
DEFAULT_PAUSE_MS = 250
APP_TIMEOUT_SECONDS = 45.0

def monotonic_seconds
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def rendered_text(output)
  output.scrub
    .gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
    .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "")
    .gsub("\r", "")
end

# A deliberately small VT model for the ASCII markers emitted by this app.
# It tracks CUP/SGR/erase operations used by Tui::Buffer#flush and common
# cursor controls. Non-ASCII glyphs occupy one modeled column; all probe text
# and target markers are ASCII, and the renderer uses absolute CUP at row starts.
class PtyScreen
  def initialize(width, height)
    @width = width
    @height = height
    @cells = Array.new(height) { Array.new(width, " ") }
    @x = 0
    @y = 0
    @state = :normal
    @csi = +""
    @osc_escape = false
  end

  def feed(bytes)
    bytes.each_byte do |byte|
      case @state
      when :normal
        case byte
        when 0x1b then @state = :escape
        when 0x0d then @x = 0
        when 0x0a then @y = (@y + 1).clamp(0, @height - 1)
        when 0x08 then @x = (@x - 1).clamp(0, @width - 1)
        when 0x09 then @x = [((@x / 8) + 1) * 8, @width - 1].min
        else
          put_byte(byte) if byte >= 0x20 && byte != 0x7f
        end
      when :escape
        case byte
        when 0x5b
          @csi.clear
          @state = :csi
        when 0x5d
          @osc_escape = false
          @state = :osc
        when 0x37
          @saved_cursor = [@x, @y]
          @state = :normal
        when 0x38
          @x, @y = @saved_cursor if @saved_cursor
          @state = :normal
        when 0x44
          @y = (@y + 1).clamp(0, @height - 1)
          @state = :normal
        when 0x45
          @x = 0
          @y = (@y + 1).clamp(0, @height - 1)
          @state = :normal
        else
          @state = :normal
        end
      when :csi
        if byte >= 0x40 && byte <= 0x7e
          apply_csi(byte.chr)
          @state = :normal
        else
          @csi << byte if @csi.bytesize < 128
        end
      when :osc
        if byte == 0x07 || (@osc_escape && byte == 0x5c)
          @state = :normal
          @osc_escape = false
        else
          @osc_escape = byte == 0x1b
        end
      end
    end
  end

  def include?(fragment)
    @cells.any? { |row| row.join.include?(fragment) }
  end

  private

  def put_byte(byte)
    return if @y.negative? || @y >= @height || @x.negative? || @x >= @width

    # Mark each UTF-8 leading byte as one cell and ignore continuation bytes.
    return if byte >= 0x80 && (byte & 0xc0) == 0x80

    glyph = byte < 0x80 ? byte.chr : "?"
    @cells[@y][@x] = glyph
    @x += 1
  end

  def apply_csi(final)
    private_sequence = @csi.start_with?("?", ">", "!")
    params = @csi.sub(/\A[?>!]/, "").split(";").map { |part| part.to_i }
    first = params.fetch(0, 0)
    second = params.fetch(1, 0)
    case final
    when "H", "f"
      @y = ([first, 1].max - 1).clamp(0, @height - 1)
      @x = ([second, 1].max - 1).clamp(0, @width - 1)
    when "A" then @y = (@y - [first, 1].max).clamp(0, @height - 1)
    when "B" then @y = (@y + [first, 1].max).clamp(0, @height - 1)
    when "C" then @x = (@x + [first, 1].max).clamp(0, @width - 1)
    when "D" then @x = (@x - [first, 1].max).clamp(0, @width - 1)
    when "G" then @x = ([first, 1].max - 1).clamp(0, @width - 1)
    when "d" then @y = ([first, 1].max - 1).clamp(0, @height - 1)
    when "J" then erase_display(first)
    when "K" then erase_line(first)
    when "X" then clear_cells(@y, @x, @x + [first, 1].max)
    when "s" then @saved_cursor = [@x, @y]
    when "u" then @x, @y = @saved_cursor if @saved_cursor
    when "c" then reset if !private_sequence
    end
  end

  def erase_display(mode)
    case mode
    when 2, 3
      @cells.each { |row| row.fill(" ") }
    when 0
      clear_cells(@y, @x, @width)
      ((@y + 1)...@height).each { |row| @cells[row].fill(" ") }
    when 1
      (0...@y).each { |row| @cells[row].fill(" ") }
      clear_cells(@y, 0, @x + 1)
    end
  end

  def erase_line(mode)
    case mode
    when 0 then clear_cells(@y, @x, @width)
    when 1 then clear_cells(@y, 0, @x + 1)
    when 2 then @cells[@y].fill(" ")
    end
  end

  def clear_cells(row, from, to)
    return if row.negative? || row >= @height

    left = from.clamp(0, @width)
    right = to.clamp(left, @width)
    @cells[row][left...right] = Array.new(right - left, " ") if right > left
  end

  def reset
    @cells.each { |row| row.fill(" ") }
    @x = 0
    @y = 0
  end
end

class PtyCapture
  def initialize(reader, width:, height:)
    @reader = reader
    @mutex = Mutex.new
    @screen = PtyScreen.new(width, height)
    @watches = {}
    @bytes = 0
    @closed = false
    @thread = Thread.new do
      begin
        loop do
          chunk = @reader.readpartial(16 * 1024)
          observed_at = monotonic_seconds
          @mutex.synchronize do
            @bytes += chunk.bytesize
            @screen.feed(chunk)
            @watches.each_value do |watch|
              next if watch[:observed_at] || @bytes <= watch[:after_byte]
              watch[:observed_at] = observed_at if @screen.include?(watch[:fragment])
            end
          end
        end
      rescue EOFError, Errno::EIO, IOError
        @mutex.synchronize { @closed = true }
      end
    end
  end

  def watch(name, fragment, after_byte: byte_count)
    @mutex.synchronize do
      raise "instrument marker #{fragment.inspect} already on screen before input" if @screen.include?(fragment)

      @watches[name] = {fragment: fragment, after_byte: after_byte, observed_at: nil}
    end
  end

  def byte_count
    @mutex.synchronize { @bytes }
  end

  def observed_at(name)
    @mutex.synchronize { @watches.fetch(name)[:observed_at] }
  end

  def screen_includes?(fragment)
    @mutex.synchronize { @screen.include?(fragment) }
  end

  def close
    @reader.close unless @reader.closed?
    @thread.join(0.5)
    @thread.kill if @thread.alive?
    @thread.join
  rescue IOError
    nil
  end
end

class EditorPty
  attr_reader :pid, :capture, :root

  def initialize(binary:, root:, width:, height:, lsp: false, lsp_events: nil)
    @root = root
    @width = width
    @height = height
    FileUtils.mkdir_p(File.join(root, "home"))
    FileUtils.mkdir_p(File.join(root, "state"))
    @config = File.join(root, "config.json")
    File.write(@config, "{}")
    env = {
      "TERM" => "xterm-256color",
      "HOME" => File.join(root, "home"),
      "XDG_CONFIG_HOME" => File.join(root, "home", ".config"),
      "XDG_STATE_HOME" => File.join(root, "state"),
      "ADAMANTINE_SESSION" => "0",
      "ADAMANTINE_RECOVERY" => "0",
      "ADAMANTINE_STATE_HOME" => File.join(root, "state"),
      "ADAMANTINE_LSP" => "",
      "EDITOR_LSP" => "",
    }
    argv = [binary, root, "--config", @config]
    if lsp
      argv.concat(["--lsp", RbConfig.ruby,
                   "--lsp-arg", File.expand_path(__FILE__),
                   "--lsp-arg", "--fake-lsp",
                   "--lsp-arg", lsp_events])
    else
      argv << "--no-lsp"
    end
    @reader, @writer, @pid = PTY.spawn(env, *argv)
    @reader.winsize = [height, width]
    @capture = PtyCapture.new(@reader, width: width, height: height)
    @stopped = false
  end

  def start_file_open(path, marker)
    open_palette("open #{path}")
    send_enter("file-open", marker)
  end

  def open_palette(text)
    key("\e[112;6u") # Ctrl+Shift+P opens the command palette.
    sleep 0.12
    type(":#{text}")
    sleep 0.05
  end

  def send_enter(name, marker)
    offset = @capture.byte_count
    @capture.watch(name, marker, after_byte: offset)
    started_at = monotonic_seconds
    key("\e[13u")
    wait_for(name)
    elapsed_ms(started_at, @capture.observed_at(name))
  end

  def edit_key(name: "edit", char: "z", marker: "zoldx")
    offset = @capture.byte_count
    @capture.watch(name, marker, after_byte: offset)
    started_at = monotonic_seconds
    key("\e[#{char.ord}u")
    wait_for(name)
    elapsed_ms(started_at, @capture.observed_at(name))
  end

  def bulk_replace(name: "bulk_replace", marker: "Zx")
    open_palette("r/old/Z/g")
    send_enter(name, marker)
  end

  def controlled_pause_edit(name:, pause_ms:)
    Process.kill("STOP", @pid)
    @stopped = true
    _stopped_pid, stopped_status = Process.waitpid2(@pid, Process::WUNTRACED)
    raise "SIGSTOP control child did not report stopped state" unless stopped_status.stopped?
    offset = @capture.byte_count
    @capture.watch(name, "zoldx", after_byte: offset)
    started_at = monotonic_seconds
    key("\e[122u")
    sleep(pause_ms / 1000.0)
    still_absent = @capture.observed_at(name).nil?
    resumed_at = monotonic_seconds
    resume_child
    raise "stalled app produced target text before SIGCONT" unless still_absent

    wait_for(name)
    {
      "latency_ms" => elapsed_ms(started_at, @capture.observed_at(name)),
      "forced_pause_ms" => ((resumed_at - started_at) * 1000.0).round(3),
      "absent_while_stopped" => still_absent,
      "observed_after_resume_ms" => elapsed_ms(resumed_at, @capture.observed_at(name)),
    }
  end

  def no_input_negative_control(name:, fragment:, window_ms:)
    offset = @capture.byte_count
    @capture.watch(name, fragment, after_byte: offset)
    sleep(window_ms / 1000.0)
    observed = @capture.observed_at(name)
    raise "negative control observed a marker without input" if observed

    {
      "input_bytes_sent" => 0,
      "window_ms" => window_ms,
      "pty_output_bytes_during_window" => @capture.byte_count - offset,
      "target_text_observed" => false,
    }
  end

  def wait_for(name, timeout: APP_TIMEOUT_SECONDS)
    deadline = monotonic_seconds + timeout
    until (at = @capture.observed_at(name))
      raise "timeout waiting for PTY grid marker #{name.inspect}" if monotonic_seconds >= deadline

      sleep 0.005
    end
    at
  end

  def wait_for_screen(fragment, timeout: APP_TIMEOUT_SECONDS)
    deadline = monotonic_seconds + timeout
    until @capture.screen_includes?(fragment)
      raise "timeout waiting for startup screen marker #{fragment.inspect}" if monotonic_seconds >= deadline

      sleep 0.005
    end
  end

  def quit
    return if exited?

    begin
      open_palette("q!")
      key("\e[13u")
      deadline = monotonic_seconds + 3.0
      sleep 0.02 until exited? || monotonic_seconds >= deadline
    rescue IOError, Errno::EIO
      # Cleanup below still bounds the child even if its terminal closed.
    end
  end

  def cleanup
    resume_child if @stopped
    quit
    unless exited?
      begin
        Process.kill("TERM", @pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      sleep 0.2
      begin
        Process.kill("KILL", @pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      Process.waitpid(@pid)
    end
    @capture.close
  rescue Errno::ECHILD, Errno::ESRCH
    @capture.close
  end

  private

  def key(sequence)
    @writer.write(sequence)
    @writer.flush
  end

  def type(text)
    text.each_char { |char| key("\e[#{char.ord}u") }
  end

  def elapsed_ms(started_at, ended_at)
    ((ended_at - started_at) * 1000.0).round(3)
  end

  def resume_child
    Process.kill("CONT", @pid)
    @stopped = false
  rescue Errno::ESRCH
    @stopped = false
  end

  def exited?
    Process.waitpid(@pid, Process::WNOHANG) == @pid
  rescue Errno::ECHILD
    true
  end
end

def fake_lsp_server(events_path)
  STDIN.binmode
  STDOUT.binmode
  STDOUT.sync = true
  events_path = File.expand_path(events_path)
  loop do
    headers = {}
    line = nil
    while (line = STDIN.gets)
      break if line == "\r\n" || line == "\n"

      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip if key && value
    end
    break unless line

    length = Integer(headers.fetch("content-length"))
    body = STDIN.read(length)
    break unless body && body.bytesize == length

    method = body[/\"method\":\"([^\"]+)\"/, 1]
    raise "fake LSP saw malformed method prefix" unless method

    File.open(events_path, "a") do |file|
      file.puts(JSON.generate(method: method, body_bytes: length,
                              monotonic_seconds: monotonic_seconds))
    end

    message = JSON.parse(body) if method == "initialize"
    if method == "initialize" || body.include?("\"id\":")
      id = message ? message["id"] : body[/\"id\":(\d+)/, 1]&.to_i
      result = if method == "initialize"
                 {"capabilities" => {"textDocumentSync" => 1}}
               else
                 nil
               end
      response = JSON.generate("jsonrpc" => "2.0", "id" => id, "result" => result)
      STDOUT.write("Content-Length: #{response.bytesize}\r\n\r\n#{response}")
    end
    break if method == "exit"
  end
rescue EOFError, Errno::EPIPE
  nil
end

def percentile(values, percent)
  sorted = values.sort
  index = ((percent / 100.0) * sorted.length).ceil - 1
  sorted[[index, 0].max]
end

def summarize_samples(samples)
  values = samples.map { |sample| sample.fetch("latency_ms") }
  {
    "unit" => "milliseconds",
    "repeats" => values.length,
    "samples" => values,
    "median_ms" => percentile(values, 50),
    "p95_nearest_rank_ms" => percentile(values, 95),
    "worst_ms" => values.max,
    "spread_ms" => (values.max - values.min).round(3),
  }
end

def build_binary!(output)
  crystal = ENV.fetch("CRYSTAL", "crystal")
  args = [crystal, "build", "--release", File.join(ROOT, "src/adamantine.cr"), "-o", output]
  if RbConfig::CONFIG["host_os"].to_s.include?("darwin")
    args << "--link-flags=-fuse-ld=/usr/bin/ld"
  end
  stdout, stderr, status = Open3.capture3(*args, chdir: ROOT)
  raise "release build failed:\n#{stderr}\n#{stdout}" unless status.success?

  version, _version_stderr, version_status = Open3.capture3(crystal, "--version")
  raise "could not read Crystal version" unless version_status.success?

  [crystal, version.strip]
end

def read_events(path)
  return [] unless File.exist?(path)

  File.readlines(path).map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end.compact
end

def emit_progress(case_name, observation)
  warn "input_latency_sample #{JSON.generate("case" => case_name, "observation" => observation)}"
end

# The fake server is also launched as a child process by Adamantine. Dispatch
# this mode before parsing benchmark options so its private argument is valid.
if ARGV.first == "--fake-lsp"
  fake_lsp_server(ARGV.fetch(1))
  exit 0
end

def await_event(path, method, after_count: 0, timeout: APP_TIMEOUT_SECONDS)
  deadline = monotonic_seconds + timeout
  loop do
    matches = read_events(path).select { |event| event["method"] == method }
    return matches.fetch(after_count) if matches.length > after_count
    raise "timeout waiting for fake LSP #{method} frame" if monotonic_seconds >= deadline

    sleep 0.01
  end
end

def fixture_text(size_bytes)
  pattern = "old" + ("x" * 253)
  raise "fixture size must be a 256-byte multiple" unless (size_bytes % pattern.bytesize).zero?

  pattern * (size_bytes / pattern.bytesize)
end

def expected_content_sha256(size_bytes, kind)
  original_pattern = "old" + ("x" * 253)
  pattern = kind == :replacement ? "Z" + ("x" * 253) : original_pattern
  digest = Digest::SHA256.new
  digest.update("z") if kind == :inserted_edit
  repeats = size_bytes / 256
  block = pattern * 4096
  complete_blocks, remainder = repeats.divmod(4096)
  complete_blocks.times { digest.update(block) }
  digest.update(pattern * remainder) if remainder.positive?
  digest.hexdigest
end

def save_and_verify!(app, path, expected_bytes:, expected_sha256:)
  app.open_palette("w")
  app.send_enter("save", "Saved #{File.basename(path)}")
  actual_bytes = File.size(path)
  actual_sha256 = Digest::SHA256.file(path).hexdigest
  unless actual_bytes == expected_bytes && actual_sha256 == expected_sha256
    raise "saved content mismatch for #{File.basename(path)}: #{actual_bytes} bytes, sha256=#{actual_sha256}"
  end

  {"saved_bytes" => actual_bytes, "saved_sha256" => actual_sha256}
end

def run_app(binary:, root:, lsp: false, events: nil)
  width = 120
  height = 26
  app = EditorPty.new(binary: binary, root: root, width: width, height: height,
                      lsp: lsp, lsp_events: events)
  begin
    app.wait_for_screen("Adamantine")
    yield app
  ensure
    app.cleanup
  end
end

raw_argv = ARGV.dup
options = {binary: nil, size_mib: DEFAULT_SIZE_MIB, repeats: 3, pause_ms: DEFAULT_PAUSE_MS}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/benchmark_input_latency.rb [options]"
  parser.on("--binary PATH", "Use a prebuilt release binary instead of building") { |value| options[:binary] = value }
  parser.on("--size-mib N", Integer, "Plain-text fixture size in MiB (4..15; default 15)") { |value| options[:size_mib] = value }
  parser.on("--repeats N", Integer, "Independent app launches per measured case (default 3)") { |value| options[:repeats] = value }
  parser.on("--pause-ms N", Integer, "SIGSTOP calibration duration (default 250)") { |value| options[:pause_ms] = value }
end.parse!
abort "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
abort "--size-mib must be between 4 and 15" unless (4..15).cover?(options[:size_mib])
abort "--repeats must be between 1 and 10" unless (1..10).cover?(options[:repeats])
abort "--pause-ms must be between 100 and 2000" unless (100..2000).cover?(options[:pause_ms])

fixture_bytes = options[:size_mib] * 1024 * 1024
abort "fixture must remain below DocumentOrchestrator::MAX_FILE_BYTES" unless fixture_bytes < MAX_DOCUMENT_BYTES
workspace = Dir.mktmpdir("adamantine-input-latency-")
source = File.join(workspace, "large.txt")
events_path = File.join(workspace, "lsp-events.jsonl")
File.binwrite(source, fixture_text(fixture_bytes))
raise "fixture byte count differs" unless File.size(source) == fixture_bytes
source_sha256 = Digest::SHA256.file(source).hexdigest

begin
  binary = options[:binary]
  if binary
    binary = File.realpath(binary)
    crystal_path = nil
    crystal_version = nil
  else
    binary = File.join(workspace, "adamantine")
    crystal_path, crystal_version = build_binary!(binary)
  end
  binary_identity = {
    "path" => binary,
    "size_bytes" => File.size(binary),
    "sha256" => Digest::SHA256.file(binary).hexdigest,
    "mtime_utc" => File.mtime(binary).utc.iso8601,
    "built_by_this_run" => options[:binary].nil?,
    "source_revision_linkage" => options[:binary] ? "prebuilt binary; build checkout/revision not established by this harness" : "built from this checkout's current worktree",
  }

  cases = {
    "no_lsp_edit" => [],
    "lsp_open" => [],
    "lsp_edit_full_sync" => [],
    "no_lsp_bulk_replace" => [],
    "lsp_bulk_replace_full_sync" => [],
  }
  Array.new(options[:repeats]).each do |iteration|
    run_root = File.join(workspace, "run-no-lsp-#{iteration}")
    FileUtils.mkdir_p(run_root)
    FileUtils.cp(source, File.join(run_root, "large.txt"))
    run_app(binary: binary, root: run_root) do |app|
      opened_ms = app.start_file_open(File.join(run_root, "large.txt"), "oldx")
      latency = app.edit_key
      saved = save_and_verify!(app, File.join(run_root, "large.txt"),
                               expected_bytes: fixture_bytes + 1,
                               expected_sha256: expected_content_sha256(fixture_bytes, :inserted_edit))
      observation = {"latency_ms" => latency, "open_latency_ms" => opened_ms}.merge(saved)
      cases["no_lsp_edit"] << observation
      emit_progress("no_lsp_edit", observation)
    end
  end

  Array.new(options[:repeats]).each do |iteration|
    run_root = File.join(workspace, "run-lsp-edit-#{iteration}")
    FileUtils.mkdir_p(run_root)
    FileUtils.cp(source, File.join(run_root, "large.txt"))
    run_events = File.join(run_root, "events.jsonl")
    run_app(binary: binary, root: run_root,
            lsp: true, events: run_events) do |app|
      open_ms = app.start_file_open(File.join(run_root, "large.txt"), "oldx")
      did_open = await_event(run_events, "textDocument/didOpen")
      edit_ms = app.edit_key
      did_change = await_event(run_events, "textDocument/didChange")
      saved = save_and_verify!(app, File.join(run_root, "large.txt"),
                               expected_bytes: fixture_bytes + 1,
                               expected_sha256: expected_content_sha256(fixture_bytes, :inserted_edit))
      cases["lsp_open"] << {"latency_ms" => open_ms, "did_open_bytes" => did_open["body_bytes"]}
      emit_progress("lsp_open", cases["lsp_open"].last)
      edit_observation = {"latency_ms" => edit_ms, "did_change_bytes" => did_change["body_bytes"]}.merge(saved)
      cases["lsp_edit_full_sync"] << edit_observation
      emit_progress("lsp_edit_full_sync", edit_observation)
      expected_length = fixture_bytes + 1
      raise "full-sync didChange body is too small: #{did_change['body_bytes']}" unless did_change["body_bytes"] >= expected_length
    end
  end

  Array.new(options[:repeats]).each do |iteration|
    no_lsp_root = File.join(workspace, "run-no-lsp-replace-#{iteration}")
    FileUtils.mkdir_p(no_lsp_root)
    FileUtils.cp(source, File.join(no_lsp_root, "large.txt"))
    run_app(binary: binary, root: no_lsp_root) do |app|
      app.start_file_open(File.join(no_lsp_root, "large.txt"), "oldx")
      replace_ms = app.bulk_replace
      saved = save_and_verify!(app, File.join(no_lsp_root, "large.txt"),
                               expected_bytes: fixture_bytes - (fixture_bytes / 256) * 2,
                               expected_sha256: expected_content_sha256(fixture_bytes, :replacement))
      observation = {
        "latency_ms" => replace_ms,
        "expected_match_count" => fixture_bytes / 256,
      }.merge(saved)
      cases["no_lsp_bulk_replace"] << observation
      emit_progress("no_lsp_bulk_replace", observation)
    end

    run_root = File.join(workspace, "run-lsp-replace-#{iteration}")
    FileUtils.mkdir_p(run_root)
    FileUtils.cp(source, File.join(run_root, "large.txt"))
    run_events = File.join(run_root, "events.jsonl")
    run_app(binary: binary, root: run_root,
            lsp: true, events: run_events) do |app|
      app.start_file_open(File.join(run_root, "large.txt"), "oldx")
      await_event(run_events, "textDocument/didOpen")
      before = read_events(run_events).count { |event| event["method"] == "textDocument/didChange" }
      replace_ms = app.bulk_replace
      changed = await_event(run_events, "textDocument/didChange", after_count: before)
      saved = save_and_verify!(app, File.join(run_root, "large.txt"),
                               expected_bytes: fixture_bytes - (fixture_bytes / 256) * 2,
                               expected_sha256: expected_content_sha256(fixture_bytes, :replacement))
      observation = {
        "latency_ms" => replace_ms,
        "did_change_bytes" => changed["body_bytes"],
        "expected_match_count" => fixture_bytes / 256,
      }.merge(saved)
      cases["lsp_bulk_replace_full_sync"] << observation
      emit_progress("lsp_bulk_replace_full_sync", observation)
      minimum = fixture_bytes - (fixture_bytes / 256) * 2 + 100
      raise "bulk replace didChange body is unexpectedly small" unless changed["body_bytes"] >= minimum
    end
  end

  control_root = File.join(workspace, "run-sigstop-control")
  FileUtils.mkdir_p(control_root)
  FileUtils.cp(source, File.join(control_root, "large.txt"))
  control_events = File.join(control_root, "events.jsonl")
  pause_control = nil
  negative_control = nil
  run_app(binary: binary, root: control_root,
          lsp: false, events: control_events) do |app|
    app.start_file_open(File.join(control_root, "large.txt"), "oldx")
    negative_control = app.no_input_negative_control(
      name: "no_input_negative_control",
      fragment: "NO-INPUT-CONTROL-MUST-NOT-APPEAR",
      window_ms: 100
    )
    pause_control = app.controlled_pause_edit(name: "sigstop_control", pause_ms: options[:pause_ms])
  end
  cases["no_input_negative_control"] = negative_control
  cases["sigstop_pause_control"] = pause_control
  emit_progress("no_input_negative_control", negative_control)
  emit_progress("sigstop_pause_control", pause_control)
  unless pause_control["absent_while_stopped"] && pause_control["latency_ms"] >= options[:pause_ms] * 0.8
    raise "SIGSTOP timing control did not observe the seeded pause"
  end

  paired_replace_deltas = cases["lsp_bulk_replace_full_sync"].each_index.map do |index|
    cases["lsp_bulk_replace_full_sync"][index]["latency_ms"] - cases["no_lsp_bulk_replace"][index]["latency_ms"]
  end

  summary = {
    "schema" => "adamantine.input_latency",
    "version" => 1,
    "status" => "PASS",
    "generated_at" => Time.now.utc.iso8601,
    "invocation" => [RbConfig.ruby, File.join(ROOT, "scripts/benchmark_input_latency.rb"), *raw_argv],
    "host" => {
      "os" => RbConfig::CONFIG["host_os"],
      "cpu" => RbConfig::CONFIG["host_cpu"],
      "ruby" => RUBY_DESCRIPTION,
      "kernel_release" => Open3.capture2("uname", "-r").first.strip,
      "crystal" => crystal_version,
      "crystal_command" => crystal_path,
      "crystal_cache_dir_override" => ENV["CRYSTAL_CACHE_DIR"],
      "source_revision" => Open3.capture2("git", "rev-parse", "HEAD", chdir: ROOT).first.strip,
      "binary" => binary_identity,
    },
    "fixture" => {
      "path_kind" => "temporary single-line plain-text document",
      "bytes" => fixture_bytes,
      "document_limit_bytes" => MAX_DOCUMENT_BYTES,
      "below_limit_bytes" => MAX_DOCUMENT_BYTES - fixture_bytes,
      "replace_pattern" => "old followed by 253 x characters, repeated globally",
      "expected_global_matches" => fixture_bytes / 256,
    },
    "measurement" => {
      "unit" => "milliseconds",
      "start" => "monotonic timestamp immediately before writing the key bytes to the PTY master",
      "end" => "first PTY-read chunk after input whose modeled terminal grid contains the expected changed text",
      "pty_grid" => "VT parser for CUP, SGR, erase and cursor controls; ASCII target glyphs only",
      "not_observed" => ["real terminal emulator acknowledgment", "display scan-out", "physical pixel visibility"],
      "open_latency_caveat" => "Open action is Enter on :open; its interval also includes the application file-open path.",
      "lsp_caveat" => "Fake server advertises textDocumentSync=1 (full sync); server arrival/byte counts corroborate frames but do not time JSON serialization independently.",
      "timings_are_diagnostic_only" => true,
    },
    "cases" => cases.transform_values do |samples|
      if samples.is_a?(Array)
        {"summary" => summarize_samples(samples), "observations" => samples}
      else
        samples
      end
    end,
    "paired_bulk_replace_comparison" => {
      "pairing" => "same fixture, binary and iteration; no-LSP case runs immediately before full-sync LSP case",
      "lsp_minus_no_lsp_ms" => paired_replace_deltas,
      "median_delta_ms" => percentile(paired_replace_deltas, 50),
      "p95_nearest_rank_delta_ms" => percentile(paired_replace_deltas, 95),
      "positive_delta_means" => "full-sync LSP run took longer; this combines synchronous serialization/publication and any run-order noise",
    },
    "instrument_control" => {
      "kind" => "same application and PTY observer, target process paused after PTY input is written",
      "forced_pause_ms" => options[:pause_ms],
      "observed_latency_ms" => pause_control["latency_ms"],
      "absent_while_stopped" => pause_control["absent_while_stopped"],
      "observed_after_resume_ms" => pause_control["observed_after_resume_ms"],
      "control_pass_condition" => "no target glyph while stopped and measured latency is at least 80 percent of the forced pause",
      "negative_control" => {
        "kind" => "no input bytes are sent during a 100ms observation window",
        "observation" => negative_control,
      },
    },
    "protected_qualities" => {
      "source_file_bytes_after_runs" => File.size(source),
      "source_file_sha256_before" => source_sha256,
      "source_file_sha256_after" => Digest::SHA256.file(source).hexdigest,
      "source_file_unchanged" => File.size(source) == fixture_bytes && Digest::SHA256.file(source).hexdigest == source_sha256,
      "edit_content_evidence" => "inserted-key and bulk-replace outputs were saved after timing and checked against exact expected byte counts and SHA-256 digests",
      "rss" => {"sampled" => false, "reason" => "this PTY observer does not own a platform-independent process RSS sampler"},
    },
  }

  puts JSON.pretty_generate(summary)
ensure
  FileUtils.remove_entry(workspace) if File.directory?(workspace)
end
