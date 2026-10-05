#!/usr/bin/env ruby
# Joined real-Crystal + LLDB-DAP + Adamantine App/PTY acceptance gate.
# All tools are explicit; only the checked-in fixture copied into a private
# temporary project is compiled or launched.

require "digest"
require "fileutils"
require "io/console"
require "json"
require "open3"
require "optparse"
require "pty"
require "rbconfig"
require "timeout"
require "tmpdir"
require_relative "lib/crystal_debug_smoke"
require_relative "lib/pty_screen"

options = {editor_bin: nil, compiler: nil, adapter: nil, debugserver: nil, timeout: 180.0}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/smoke_debugger_crystal.rb --editor-bin PATH --compiler PATH --adapter PATH --debugserver PATH"
  parser.on("--editor-bin PATH", "Explicit privately built Adamantine executable") { |path| options[:editor_bin] = path }
  parser.on("--compiler PATH", "Explicit existing Crystal compiler executable") { |path| options[:compiler] = path }
  parser.on("--adapter PATH", "Explicit existing LLDB-DAP executable") { |path| options[:adapter] = path }
  parser.on("--debugserver PATH", "Explicit existing debugserver executable") { |path| options[:debugserver] = path }
  parser.on("--timeout SECONDS", Float, "App/PTY workflow deadline, 45..300 seconds (default: 180)") { |seconds| options[:timeout] = seconds }
  parser.on("-h", "--help") { puts parser; exit 0 }
end.parse!

abort "--timeout must be between 45 and 300 seconds" unless options[:timeout].between?(45.0, 300.0)
begin
  tools = CrystalDebugSmoke.resolve_tool_paths!(options)
rescue CrystalDebugSmoke::Error => error
  abort "FAIL: #{error.message}"
end
begin
  CrystalDebugSmoke.process_table!
rescue CrystalDebugSmoke::Error => error
  abort "FAIL: process-ownership preflight: #{error.message}"
end

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def key(writer, sequence)
  writer.write(sequence)
  writer.flush
end

def type_text(writer, text)
  text.each_codepoint { |codepoint| key(writer, "\e[#{codepoint}u") }
end

def paste_text(writer, text)
  key(writer, "\e[200~#{text}\e[201~")
end

def command(writer, text)
  key(writer, "\e[112;6u")
  type_text(writer, ":#{text}")
  key(writer, "\e[13u")
end

def editor_alive?(child)
  return false unless child && !child[:reaped]
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

def wait_until(label, seconds:, child: nil)
  deadline = monotonic + seconds
  until yield
    raise "editor exited before #{label}" if child && !editor_alive?(child)
    raise "timeout waiting for #{label}" if monotonic >= deadline
    sleep 0.025
  end
end

def screen_snapshot(state)
  CrystalDebugSmoke.screen_snapshot!(state)
end

def wait_for_screen(label, state, seconds:, child: nil, &predicate)
  wait_until(label, seconds: seconds, child: child) do
    predicate.call(screen_snapshot(state))
  end
end

EDITOR_SOURCE_PROBE = CrystalDebugSmoke::EDITOR_SOURCE_PROBE

def debug_frame_row(snapshot, source_line)
  CrystalDebugSmoke.require_debug_frame_row!(
    snapshot, source_line, source_fragment: EDITOR_SOURCE_PROBE
  )
rescue CrystalDebugSmoke::OracleError
  nil
end

def require_debug_side_geometry!(snapshot)
  CrystalDebugSmoke.require_inspector_rows!(
    snapshot, "VARIABLES", [], source_fragment: EDITOR_SOURCE_PROBE
  )
  true
end

def inspector_has_rows?(snapshot, pane, fragments)
  CrystalDebugSmoke.require_inspector_rows!(
    snapshot, pane, fragments, source_fragment: EDITOR_SOURCE_PROBE
  )
  true
rescue CrystalDebugSmoke::OracleError
  false
end

def inspector_contains?(snapshot, pane, fragment)
  panel_rows = CrystalDebugSmoke.require_inspector_rows!(
    snapshot, pane, [], source_fragment: EDITOR_SOURCE_PROBE
  )
  panel_rows.any? { |entry| entry[:content].downcase.include?(fragment.downcase) }
rescue CrystalDebugSmoke::OracleError
  false
end

def load_scopes_if_prompted(writer, state, child)
  snapshot = screen_snapshot(state)
  panel_rows = CrystalDebugSmoke.require_inspector_rows!(
    snapshot, "VARIABLES", [], source_fragment: EDITOR_SOURCE_PROBE
  )
  prompt_visible = panel_rows.any? { |entry| entry[:content].match?(/load scopes/i) }
  if prompt_visible
    revision = snapshot[:revision]
    key(writer, "\e[13u")
    wait_for_screen("Variables scope load", state, seconds: 20, child: child) do |current|
      current[:revision] > revision && inspector_has_rows?(current, "VARIABLES", ["native_scalar"])
    end
  end
  current = screen_snapshot(state)
  CrystalDebugSmoke.require_inspector_rows!(
    current, "VARIABLES", ["native_scalar"], source_fragment: EDITOR_SOURCE_PROBE
  )
end

def select_variable_from_locals!(writer, state, child, name)
  key(writer, "\e[H")
  offset = nil
  wait_for_screen("first-page Variables row for #{name}", state, seconds: 8, child: child) do |snapshot|
    begin
      offset = CrystalDebugSmoke.variable_selection_offset!(
        snapshot, name, source_fragment: EDITOR_SOURCE_PROBE
      )
      true
    rescue CrystalDebugSmoke::OracleError
      false
    end
  end
  offset.times { key(writer, "\e[B") }
  true
end

def inspect_variable(writer, state, child, name, expected_value, expected_type: nil)
  select_variable_from_locals!(writer, state, child, name)
  revision = screen_snapshot(state)[:revision]
  key(writer, "d") # Read-only Value Detail; value text is tested at full modal width.
  wait_for_screen("#{name} value detail", state, seconds: 12, child: child) do |current|
    current[:revision] > revision && begin
      CrystalDebugSmoke.require_value_detail!(current, name, expected_value, expected_type: expected_type)
    rescue CrystalDebugSmoke::OracleError
      false
    end
  end
  current = screen_snapshot(state)
  CrystalDebugSmoke.require_value_detail!(current, name, expected_value, expected_type: expected_type)
  key(writer, "\e[13u")
  true
end

def process_snapshot
  CrystalDebugSmoke.process_table!
end

def process_group_paths(processes, paths)
  paths.each_with_object({}) do |(label, path), found|
    found[label] = CrystalDebugSmoke.processes_for_path(processes, path)
  end
end

def processes_for_executable_name(processes, path)
  basename = File.basename(path)
  processes.select do |process|
    executable = process[:command].split(/\s+/, 2).first.to_s
    File.basename(executable) == basename
  end
end

def append_process_identities!(destination, additions)
  additions.each do |process|
    next if destination.any? do |captured|
      captured[:pid] == process[:pid] && captured[:command] == process[:command]
    end
    destination << process
  end
end

def capture_processes!(captured_owned, captured_group, table, editor_pid, editor_group)
  append_process_identities!(captured_owned, CrystalDebugSmoke.owned_processes(table, editor_pid))
  append_process_identities!(captured_group, CrystalDebugSmoke.process_group_members(table, editor_group))
end

def wait_for_process_group_empty!(pgid, label, timeout_seconds: 1.5)
  deadline = monotonic + timeout_seconds
  last_members = []
  loop do
    last_members = CrystalDebugSmoke.process_group_members(process_snapshot, pgid)
    return true if last_members.empty?
    break if monotonic >= deadline
    sleep 0.1
  end
  raise "#{label} process group still has survivors after bounded observation: #{last_members.inspect}"
end

def run_compiler!(compiler, argv, env, stdout_path, stderr_path, timeout_seconds: 90)
  pid = Process.spawn(env, compiler, *argv, in: File::NULL,
                      out: stdout_path, err: stderr_path, pgroup: true)
  deadline = monotonic + timeout_seconds
  status = nil
  loop do
    waited = Process.waitpid2(pid, Process::WNOHANG)
    if waited
      status = waited[1]
      break
    end
    if monotonic >= deadline
      cleanup_error = nil
      begin
        CrystalDebugSmoke.terminate_spawned_child!(pid, term_grace: 1.0, kill_grace: 1.0)
      rescue CrystalDebugSmoke::Error => error
        cleanup_error = error.message
      end
      begin
        wait_for_process_group_empty!(pid, "timed-out Crystal compiler")
      rescue StandardError => error
        cleanup_error = [cleanup_error, error.message].compact.join("; ")
      end
      suffix = cleanup_error ? "; cleanup audit: #{cleanup_error}" : "; directly spawned compiler PID reaped"
      raise "Crystal fixture compilation exceeded #{timeout_seconds} seconds#{suffix}"
    end
    sleep 0.025
  end
  wait_for_process_group_empty!(pid, "Crystal compiler")
  unless status.success?
    detail = File.read(stderr_path) rescue ""
    detail = File.read(stdout_path) + detail if detail.empty?
    raise "Crystal fixture compilation failed (#{status.exitstatus}): #{detail[-3000, 3000]}"
  end
end

def raise_with_screen(error, state)
  warn "FAIL: #{error.class}: #{error.message}"
  begin
    snapshot = screen_snapshot(state)
    warn "Current-screen rows (bounded PTY model):"
    snapshot[:rows].each { |row| warn row.rstrip unless row.strip.empty? }
  rescue StandardError => screen_error
    warn "Current-screen snapshot unavailable: #{screen_error.message}"
    diagnostic_rows = state[:mutex].synchronize { state[:diagnostic_rows] }
    if diagnostic_rows
      warn "Last bounded screen before parser failure (diagnostic only):"
      diagnostic_rows.each { |row| warn row.rstrip unless row.strip.empty? }
    end
  end
end

repo = File.realpath(File.expand_path("..", __dir__))
fixture_source = File.realpath(File.join(repo, "scripts/fixtures/debugger_crystal_values.cr"))
fixture_lines = File.readlines(fixture_source, chomp: true)
breakpoint_source_line = fixture_lines.index { |line| line.include?("DAP_BREAKPOINT: joined Crystal/App gate") }
raise "fixture has no unique breakpoint marker" unless breakpoint_source_line &&
  fixture_lines.count { |line| line.include?("DAP_BREAKPOINT: joined Crystal/App gate") } == 1
breakpoint_line = breakpoint_source_line + 1 # Crystal source gutter line numbers are one-based.

root = nil
begin
  root = File.realpath(Dir.mktmpdir("adcr-", "/private/tmp"))
  FileUtils.chmod(0o700, root)
  project = File.join(root, "p")
  state_home = File.join(root, "state")
  config_home = File.join(root, "config-home")
  cache = File.join(root, "crystal-cache")
  config_path = File.join(root, "config.json")
  source_path = File.join(project, "main.cr")
  program_path = File.join(project, "g")
  build_stdout = File.join(root, "crystal-build.stdout")
  build_stderr = File.join(root, "crystal-build.stderr")
  compiler_version_stdout = File.join(root, "compiler-version.stdout")
  compiler_version_stderr = File.join(root, "compiler-version.stderr")
  FileUtils.mkdir_p([project, state_home, config_home, cache], mode: 0o700)
  project = File.realpath(project)
  source_path = File.join(project, "main.cr")
  program_path = File.join(project, "g")
  File.write(config_path, "{}\n", mode: "w", perm: 0o600)
  FileUtils.cp(fixture_source, source_path)
  FileUtils.chmod(0o600, source_path)

  tool_identity = tools.each_with_object({}) do |(name, path), identities|
    identities[name] = {path: path, sha256: Digest::SHA256.file(path).hexdigest}
  end
  version_env = {"HOME" => root, "TMPDIR" => root}
  run_compiler!(tools[:compiler], ["--version"], version_env,
                compiler_version_stdout, compiler_version_stderr, timeout_seconds: 10)
  version_out = File.read(compiler_version_stdout)
  compiler_version = version_out.lines.first.to_s.strip
  raise "compiler did not report a version" if compiler_version.empty?

  compile_argv = ["build", "--debug", "-O", "0", "-o", program_path]
  compile_argv << "--link-flags=-fuse-ld=/usr/bin/ld" if RbConfig::CONFIG["host_os"].include?("darwin")
  compile_argv << source_path
  compiler_env = {"CRYSTAL_CACHE_DIR" => cache, "HOME" => root, "TMPDIR" => root}
  run_compiler!(tools[:compiler], compile_argv, compiler_env, build_stdout, build_stderr)
  program_path = File.realpath(program_path)
  raise "compiled fixture is not executable" unless File.file?(program_path) && File.executable?(program_path)
rescue StandardError => error
  warn "FAIL: Crystal fixture setup/build: #{error.class}: #{error.message}"
  warn "Temporary build/project files retained at #{root}" if root && File.directory?(root)
  exit 1
end

width = 180
height = 45
reader = nil
slave = nil
drain = nil
child = nil
passed = false
captured_owned = []
captured_group = []
debuggee_pids_before_stop = []
adapter_pids_before_stop = []
editor_group = nil
state = {
  mutex: Mutex.new,
  screen: PtyScreen.new(width, height),
  total_bytes: 0,
  screen_error: nil,
  diagnostic_rows: nil,
  drain_error: nil,
  drain_eof: false,
  drain_complete: false,
}
result = nil
launch_observation = nil

begin
  Timeout.timeout(options[:timeout]) do
    reader, slave = PTY.open
    reader.winsize = [height, width]
    app_env = {
      "TERM" => "xterm-256color",
      "HOME" => root,
      "TMPDIR" => root,
      "XDG_CONFIG_HOME" => config_home,
      "XDG_STATE_HOME" => state_home,
      "ADAMANTINE_STATE_HOME" => state_home,
      "ADAMANTINE_SESSION" => "0",
      "ADAMANTINE_RECOVERY" => "0",
      "LLDB_DEBUGSERVER_PATH" => tools[:debugserver],
      "CRYSTAL_CACHE_DIR" => cache,
    }
    pid = Process.spawn(app_env, tools[:editor_bin], project, "--config", config_path, "--no-lsp",
                        in: slave, out: slave, err: slave, pgroup: true)
    child = {pid: pid, reaped: false, status: nil}
    editor_group = pid
    initial_process_table = process_snapshot
    editor_record = initial_process_table[pid]
    raise "editor process was not observable immediately after launch" unless editor_record
    raise "editor process did not enter its owned process group" unless editor_record[:pgid] == editor_group
    capture_processes!(captured_owned, captured_group, initial_process_table, pid, editor_group)
    drain = Thread.new do
      begin
        loop do
          chunk = reader.readpartial(65_536)
          state[:mutex].synchronize do
            state[:total_bytes] += chunk.bytesize
            unless state[:screen_error]
              begin
                state[:screen].feed(chunk)
              rescue PtyScreen::UnsupportedSequence => error
                state[:screen_error] = error.message
                state[:diagnostic_rows] = state[:screen].rows
              end
            end
          end
        end
      rescue EOFError, Errno::EIO
        state[:mutex].synchronize do
          begin
            state[:screen].finish!
          rescue PtyScreen::UnsupportedSequence => error
            state[:screen_error] ||= error.message
          rescue StandardError => error
            state[:drain_error] ||= "#{error.class}: #{error.message}"
          ensure
            state[:drain_eof] = true
          end
        end
      rescue StandardError => error
        state[:mutex].synchronize { state[:drain_error] ||= "#{error.class}: #{error.message}" }
      ensure
        state[:mutex].synchronize { state[:drain_complete] = true }
      end
    end

    wait_for_screen("raw-terminal editor readiness", state, seconds: 10, child: child) do |snapshot|
      snapshot[:revision].positive? && snapshot[:alternate_screen] && snapshot[:kitty_keyboard] &&
  snapshot[:rows].any? { |row| row.include?("Adamantine") } && !slave.echo?
    end
    slave.close
    slave = nil

    command(reader, "open #{source_path}")
    wait_for_screen("temporary Crystal source open", state, seconds: 10, child: child) do |snapshot|
      snapshot[:rows].any? { |row| row.include?("native_breakpoint = native_scalar") }
    end
    4.times { key(reader, "\e[B") }
    source_before_breakpoint = screen_snapshot(state)
    raise "source cursor did not reach the breakpoint statement" unless
      source_before_breakpoint[:rows].any? { |row| row.include?("native_breakpoint = native_scalar") }
    key(reader, "\e[20~") # F9 sets a source breakpoint at the cursor.

    # Fill every launch field, explicitly select Stock Crystal, then require
    # the visible review modal before allowing the first real adapter launch.
    key(reader, "\e[15~") # F5 opens profile setup; it never starts directly.
    wait_for_screen("profile form", state, seconds: 8, child: child) do |snapshot|
      snapshot[:rows].any? { |row| row.include?("Debug launch profile") } &&
        snapshot[:rows].any? { |row| row.include?("> Adapter argv JSON") }
    end
    adapter_json = JSON.generate([tools[:adapter], "--no-lldbinit"])
    key(reader, "\e[97;5u")
    paste_text(reader, adapter_json)
    key(reader, "\e[13u")
    key(reader, "\e[97;5u")
    paste_text(reader, program_path)
    key(reader, "\e[13u")
    key(reader, "\e[97;5u")
    paste_text(reader, project)
    key(reader, "\e[13u")
    key(reader, "\e[97;5u")
    paste_text(reader, "[]")
    key(reader, "\e[13u")
    wait_for_screen("Stock Crystal values selector", state, seconds: 8, child: child) do |snapshot|
      snapshot[:rows].any? { |row| row.include?("> Values: Adapter (default)") }
    end
    key(reader, "\e[C") # Right explicitly selects Stock Crystal (LLDB).
    wait_for_screen("Stock Crystal selector value", state, seconds: 5, child: child) do |snapshot|
      snapshot[:rows].any? { |row| row.include?("Values: Stock Crystal (LLDB)") }
    end
    key(reader, "\e[13u") # Enter constructs the review; still no launch.
    wait_for_screen("reviewed launch confirmation", state, seconds: 8, child: child) do |snapshot|
      snapshot[:rows].any? { |row| row.include?("Review launch; Enter starts explicitly") } &&
        snapshot[:rows].any? { |row| row.include?("Values: Stock Crystal (LLDB)") } &&
        snapshot[:rows].any? { |row| row.include?("--no-lldbinit") } &&
        snapshot[:rows].any? { |row| row.include?(program_path) }
    end
    current_processes = process_snapshot
    capture_processes!(captured_owned, captured_group, current_processes, child[:pid], editor_group)
    raise "editor process group is unavailable" unless current_processes[child[:pid]]&.fetch(:pgid) == child[:pid]
    raise "adapter started before explicit review approval" unless
      CrystalDebugSmoke.process_group_members(current_processes, editor_group).size == 1

    key(reader, "\e[13u") # Explicit approval is the sole launch action.
    begin
      wait_until("owned adapter and Crystal target processes", seconds: 30, child: child) do
        table = process_snapshot
        capture_processes!(captured_owned, captured_group, table, child[:pid], editor_group)
        owned = CrystalDebugSmoke.owned_processes(table, child[:pid])
        group = CrystalDebugSmoke.process_group_members(table, editor_group)
        adapter_processes = CrystalDebugSmoke.processes_for_path(owned, tools[:adapter])
        debuggee_processes = CrystalDebugSmoke.processes_for_path(owned, program_path)
        launch_observation = {
          owned: owned.map { |process| [process[:pid], process[:ppid], process[:pgid], process[:command]] },
          group: group.map { |process| [process[:pid], process[:ppid], process[:pgid], process[:command]] },
          adapter_mentions: processes_for_executable_name(table.values, tools[:adapter]).map { |process| [process[:pid], process[:ppid], process[:pgid], process[:command]] },
          target_mentions: processes_for_executable_name(table.values, program_path).map { |process| [process[:pid], process[:ppid], process[:pgid], process[:command]] },
        }
        !adapter_processes.empty? && !debuggee_processes.empty?
      end
    rescue RuntimeError => error
      raise "#{error.message}; last process evidence: #{launch_observation.inspect}"
    end
    command(reader, "debug-panel")
    wait_for_screen("real breakpoint stop in current Stack pane", state, seconds: 20, child: child) do |snapshot|
      debug_frame_row(snapshot, breakpoint_line)
    end
    initial_snapshot = screen_snapshot(state)
    initial_frame = debug_frame_row(initial_snapshot, breakpoint_line)
    raise "frame row is not at the fixture source breakpoint" unless initial_frame
    current_processes = process_snapshot
    capture_processes!(captured_owned, captured_group, current_processes, child[:pid], editor_group)
    owned = CrystalDebugSmoke.owned_processes(current_processes, child[:pid])
    adapter_pids_before_stop = CrystalDebugSmoke.processes_for_path(owned, tools[:adapter]).map { |process| process[:pid] }
    debuggee_pids_before_stop = CrystalDebugSmoke.processes_for_path(owned, program_path).map { |process| process[:pid] }
    raise "real LLDB-DAP process was not a captured editor descendant" if adapter_pids_before_stop.empty?
    raise "real Crystal target process was not a captured editor descendant" if debuggee_pids_before_stop.empty?

    # Select the Debug side inspector through its production command and make
    # the accepted left-rail geometry part of the real workflow, not a fake UI.
    command(reader, "debug-variables")
    wait_for_screen("side Variables inspector", state, seconds: 10, child: child) do |snapshot|
      inspector_contains?(snapshot, "VARIABLES", "load scopes")
    end
    require_debug_side_geometry!(screen_snapshot(state))
    load_scopes_if_prompted(reader, state, child)
    wait_for_screen("real Crystal locals projected in current screen", state, seconds: 20, child: child) do |snapshot|
      inspector_has_rows?(snapshot, "VARIABLES", ["native_scalar", "native_string", "native_array"])
    end
    require_debug_side_geometry!(screen_snapshot(state))

    # Value goldens come from fixture literals and the existing Stock-Crystal
    # controller evidence. String/Array Type labels are opaque LLDB-DAP names
    # already asserted by the native probe; scalar Type is deliberately not
    # goldenized because no existing probe certifies its adapter label.
    inspect_variable(reader, state, child, "native_scalar", "314159")
    inspect_variable(reader, state, child, "native_string", '"Crystal gate" (12 bytes)', expected_type: "String *")
    inspect_variable(reader, state, child, "native_array", "[22, 44] (size=2)", expected_type: "Array(Int32) *")
    select_variable_from_locals!(reader, state, child, "native_array")
    key(reader, "\e[C") # Expand the selected native_array.
    wait_for_screen("native Array indexed children in current Variables screen", state, seconds: 15, child: child) do |snapshot|
      inspector_has_rows?(snapshot, "VARIABLES", ["[0] = 22 (int)", "[1] = 44 (int)"])
    end
    require_debug_side_geometry!(screen_snapshot(state))

    # Step over the executable breakpoint statement, then over the scalar
    # mutation. Each transition must move the live stack frame and final
    # native detail must change from 314159 to 314160.
    2.times { key(reader, "\e[9;2u") } # Variables -> Threads -> Stack.
    wait_for_screen("Stack pane focused before Step", state, seconds: 8, child: child) do |snapshot|
      debug_frame_row(snapshot, breakpoint_line)
    end
    key(reader, "\e[21~") # F10 Step Over to the next source statement.
    wait_for_screen("first changed stack location after Step", state, seconds: 15, child: child) do |snapshot|
      debug_frame_row(snapshot, breakpoint_line + 1)
    end
    first_step_frame = debug_frame_row(screen_snapshot(state), breakpoint_line + 1)
    raise "first Step did not change stack location" unless first_step_frame
    key(reader, "\e[21~")
    wait_for_screen("second changed stack location after Step", state, seconds: 15, child: child) do |snapshot|
      debug_frame_row(snapshot, breakpoint_line + 2)
    end

    command(reader, "debug-variables")
    wait_for_screen("post-Step Variables inspector", state, seconds: 10, child: child) do |snapshot|
      inspector_has_rows?(snapshot, "VARIABLES", [])
    end
    require_debug_side_geometry!(screen_snapshot(state))
    load_scopes_if_prompted(reader, state, child)
    inspect_variable(reader, state, child, "native_scalar", "314160")
    inspect_variable(reader, state, child, "native_string", '"Crystal gate" (12 bytes)', expected_type: "String *")
    inspect_variable(reader, state, child, "native_array", "[22, 44] (size=2)", expected_type: "Array(Int32) *")
    select_variable_from_locals!(reader, state, child, "native_array")
    key(reader, "\e[C")
    wait_for_screen("post-Step native Array children", state, seconds: 15, child: child) do |snapshot|
      inspector_has_rows?(snapshot, "VARIABLES", ["[0] = 22 (int)", "[1] = 44 (int)"])
    end

    # Stop is explicit and occurs through the real App binding. Prove the
    # captured fixture and adapter processes disappear before asking to Quit.
    capture_processes!(captured_owned, captured_group, process_snapshot, child[:pid], editor_group)
    key(reader, "\e[15;2~") # Shift+F5 Stop.
    wait_until("Stop cleanup of target and adapter", seconds: 20, child: child) do
      table = process_snapshot
      owned = CrystalDebugSmoke.owned_processes(table, child[:pid])
      no_target = CrystalDebugSmoke.processes_for_path(owned, program_path).empty?
      no_adapter = CrystalDebugSmoke.processes_for_path(owned, tools[:adapter]).empty?
      no_target && no_adapter
    end
    wait_for_screen("visible ended debugger state after Stop", state, seconds: 10, child: child) do |snapshot|
      snapshot[:rows].any? { |row| row.match?(/\bEnded\b/i) }
    end
    raise "editor exited during explicit Stop" unless editor_alive?(child)
    table_after_stop = process_snapshot
    remaining_targets = debuggee_pids_before_stop.select do |target_pid|
      captured = captured_owned.find { |process| process[:pid] == target_pid }
      captured && CrystalDebugSmoke.process_still_matches?(table_after_stop, captured)
    end
    raise "captured Crystal target process survived Stop: #{remaining_targets.inspect}" unless remaining_targets.empty?
    remaining_adapters = adapter_pids_before_stop.select do |adapter_pid|
      captured = captured_owned.find { |process| process[:pid] == adapter_pid }
      captured && CrystalDebugSmoke.process_still_matches?(table_after_stop, captured)
    end
    raise "captured LLDB-DAP process survived Stop: #{remaining_adapters.inspect}" unless remaining_adapters.empty?

    command(reader, "quit")
    wait_until("orderly App Quit", seconds: 12) { !editor_alive?(child) }
    raise "editor exited unsuccessfully: #{child[:status].inspect}" unless child[:status] && child[:status].success?
    table_after_quit = process_snapshot
    leftovers = CrystalDebugSmoke.remaining_processes(captured_owned, table_after_quit)
    raise "captured owned process identities survived Quit: #{leftovers.inspect}" unless leftovers.empty?
    captured_group_leftovers = CrystalDebugSmoke.remaining_processes(captured_group, table_after_quit)
    raise "captured original-group process identities survived Quit: #{captured_group_leftovers.inspect}" unless captured_group_leftovers.empty?
    group_leftovers = CrystalDebugSmoke.process_group_members(table_after_quit, editor_group)
    raise "owned editor process group is not empty after Quit: #{group_leftovers.inspect}" unless group_leftovers.empty?

    unless drain.join(3)
      raise "PTY terminal drain did not reach final EOF"
    end
    final_screen = screen_snapshot(state)
    state[:mutex].synchronize do
      raise "PTY drain did not report EOF" unless state[:drain_eof]
      raise "PTY drain did not complete" unless state[:drain_complete]
      raise "PTY drain error: #{state[:drain_error]}" if state[:drain_error]
    end
    raise "alternate terminal screen remained active at EOF" if final_screen[:alternate_screen]
    raise "Kitty keyboard protocol remained enabled at EOF" if final_screen[:kitty_keyboard]
    raise "final terminal emitted no bytes" unless final_screen[:total_bytes].positive?

    result = {
      result: "PASS",
      joined_real_crystal_lldb_dap_app_pty: true,
      compiler: compiler_version,
      tools: tool_identity,
      breakpoint_source_line: breakpoint_line,
      initial_scalar: "314159",
      string_summary: '"Crystal gate" (12 bytes)',
      array_summary: "[22, 44] (size=2)",
      array_children: {"[0]" => "22", "[1]" => "44"},
      step_locations: [breakpoint_line + 1, breakpoint_line + 2],
      scalar_after_step: "314160",
      stop_cleanup: true,
      quit_owned_process_cleanup: true,
      final_terminal_eof: true,
      terminal_bytes_drained: final_screen[:total_bytes],
      temp_project_removed_after_pass: true,
    }
    passed = true
  end
rescue StandardError, Timeout::Error => error
  raise_with_screen(error, state)
  warn "Temporary owned fixture retained for diagnosis: #{root}"
  exit 1
ensure
  if child && editor_alive?(child)
    begin
      3.times { key(reader, "\e[27u") if reader }
      key(reader, "\e[15;2~") if reader # Best-effort visible Stop; never signal the target PID.
      sleep 0.2
      command(reader, "quit") if reader && editor_alive?(child)
      key(reader, "\e[13u") if reader && editor_alive?(child) # Approve the visible Quit/Stop transition.
      deadline = monotonic + 5
      sleep 0.025 while editor_alive?(child) && monotonic < deadline
    rescue Errno::EIO, IOError, Errno::EBADF
    end
    if editor_alive?(child)
      begin
        child[:status] = CrystalDebugSmoke.terminate_spawned_child!(
          child[:pid], term_grace: 1.0, kill_grace: 1.0
        )
        child[:reaped] = true
      rescue CrystalDebugSmoke::Error => error
        warn "Editor cleanup failed: #{error.message}"
      end
    end
  end
  if !passed && child
    editor_group ||= child[:pid]
    begin
      audit_table = process_snapshot
      remaining_identities = CrystalDebugSmoke.remaining_processes(captured_owned, audit_table)
      remaining_group_identities = CrystalDebugSmoke.remaining_processes(captured_group, audit_table)
      remaining_group = CrystalDebugSmoke.process_group_members(audit_table, editor_group)
      if remaining_identities.empty? && remaining_group_identities.empty? && remaining_group.empty?
        warn "Failure cleanup audit: no captured process identities or original editor-group members remain."
      else
        warn "FAIL: failure cleanup audit found captured process identities still live: #{remaining_identities.inspect}" unless remaining_identities.empty?
        warn "FAIL: failure cleanup audit found captured original-group identities still live: #{remaining_group_identities.inspect}" unless remaining_group_identities.empty?
        warn "FAIL: failure cleanup audit found original editor-group members still live: #{remaining_group.inspect}" unless remaining_group.empty?
      end
    rescue StandardError => error
      warn "FAIL: failure cleanup audit is inconclusive; process snapshot failed: #{error.message}"
    end
  end
  drain&.join(2)
  reader&.close rescue nil
  slave&.close rescue nil
  if passed
    FileUtils.remove_entry(root) if File.directory?(root)
  else
    warn "Temporary build/project files retained at #{root}" if File.directory?(root)
  end
end

puts JSON.generate(result) if result
