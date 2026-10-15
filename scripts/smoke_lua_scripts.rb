#!/usr/bin/env ruby
require "digest"
require "fileutils"
require "io/console"
require "json"
require "open3"
require "optparse"
require "pty"
require "set"
require "tmpdir"
require "timeout"
require_relative "lib/pty_screen"

# Real App/PTY coverage for the manually launched Lua boundary. This smoke
# requires the production editor binary and an already-built private Lua 5.4
# library; it never builds, installs, or downloads either dependency.
options = {editor_bin: nil, library_path: nil, timeout: 120.0, self_check: false}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/smoke_lua_scripts.rb --editor-bin PATH --library-path PATH [--timeout SECONDS]"
  parser.on("--editor-bin PATH", "Privately built production editor executable") { |path| options[:editor_bin] = path }
  parser.on("--library-path PATH", "Absolute path to the private compatible Lua 5.4 shared library") { |path| options[:library_path] = path }
  parser.on("--timeout SECONDS", Float, "Overall smoke deadline (default: 120)") { |seconds| options[:timeout] = seconds }
  parser.on("--self-check", "Run only the bounded PTY screen-oracle check") { options[:self_check] = true }
  parser.on("-h", "--help") { puts parser; exit 0 }
end.parse!

abort "--editor-bin and --library-path are required unless --self-check is used" unless
  options[:self_check] || (options[:editor_bin] && options[:library_path])
abort "--timeout must be between 20 and 240 seconds" unless options[:timeout].between?(20.0, 240.0)

WIDTH = 112
HEIGHT = 30
F1 = "\eOP".freeze
ENTER = "\e[13u".freeze
ESCAPE = "\e[27u".freeze
CURSOR_UP = "\e[A".freeze
CURSOR_DOWN = "\e[B".freeze
CTRL_W = "\x17".freeze
CTRL_Z = "\x1a".freeze
SHIFT_TAB = "\e[Z".freeze
WORKER_FLAG = "--internal-lua-worker".freeze

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def key(writer, sequence)
  writer.write(sequence)
  writer.flush
end

def type_text(writer, text)
  encoded = text.each_codepoint.map { |codepoint| "\e[#{codepoint}u" }.join
  writer.write(encoded)
  writer.flush
end

def open_palette(writer)
  key(writer, F1)
  sleep 0.04
end

def current_screen(state)
  state[:mutex].synchronize do
    raise "PTY screen tracker failed closed: #{state[:screen_error]}" if state[:screen_error]

    {
      revision: state[:screen].revision,
      width: state[:width],
      height: state[:height],
      alternate_screen: state[:screen].alternate_screen?,
      kitty_keyboard: state[:screen].kitty_keyboard_enabled?,
      rows: state[:screen].rows,
    }
  end
end

def screen_text(snapshot)
  snapshot[:rows].map(&:rstrip).join("\n")
end

def screen_contains?(snapshot, fragment)
  snapshot[:rows].any? { |row| row.include?(fragment) }
end

def screen_matches?(snapshot, regexp)
  snapshot[:rows].any? { |row| row.match?(regexp) }
end

def run_id_for_output(snapshot, name, sentinel)
  row = snapshot[:rows].find { |candidate| candidate.include?(name) && candidate.include?(sentinel) }
  match = row && row.match(/Lua \[([[:xdigit:]]{8})\] #{Regexp.escape(name)}:/)
  raise "#{name}: output sentinel did not carry an eight-hex run ID" unless match

  match[1]
end

def review_for?(snapshot, name)
  text = screen_text(snapshot).gsub(/\s+/, " ")
  text.include?("Review Lua script: #{name}")
end

def require_review_limits!(snapshot, label)
  text = screen_text(snapshot).gsub(/\s+/, " ")
  required = [
    [/5\s*(?:s|seconds)/i, "5-second wall limit"],
    [/8\s*MiB/i, "8 MiB Lua heap limit"],
    [/16\s*KiB\s*\/\s*64/i, "16 KiB / 64-event output limit"],
  ]
  missing = required.reject { |pattern, _description| text.match?(pattern) }.map(&:last)
  raise "#{label}: review omitted limits #{missing.inspect}" unless missing.empty?
end

def wait_for_screen(label, state, child, seconds: 8.0)
  deadline = monotonic + seconds
  loop do
    snapshot = current_screen(state)
    return snapshot if yield(snapshot)
    raise "editor exited before #{label}" if child && !child_alive?(child)
    raise "timeout waiting for #{label}\n#{screen_text(snapshot)}" if monotonic >= deadline
    sleep 0.02
  end
end

def child_alive?(child)
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

def signal_owned_child(child, signal)
  Process.kill(signal, child[:pid]) if child && !child[:reaped]
rescue Errno::ESRCH
  nil
end

def discover_action(writer, state, child, label)
  open_palette(writer)
  type_text(writer, label)
  wait_for_screen("F1 discovery result #{label.inspect}", state, child) do |snapshot|
    screen_contains?(snapshot, label)
  end
  key(writer, ENTER)
end

def expected_capability_labels(capabilities)
  requested = capabilities.sub(/\ARequested capabilities:\s*/i, "").strip
  return [] if requested.casecmp("none").zero?

  labels = {
    "read_editor" => "ReadEditor",
    "read_debugger" => "ReadDebugger",
    "navigate" => "Navigate",
    "propose_edits" => "ProposeEdits",
  }
  requested.split(/\s*,\s*/).map do |name|
    labels.fetch(name) { raise "unknown expected Lua capability #{name.inspect}" }
  end
end

def review_capabilities_match?(snapshot, capabilities)
  expected = expected_capability_labels(capabilities).sort
  actual = snapshot[:rows].each_with_object([]) do |row, labels|
    row.scan(/\b(ReadEditor|ReadDebugger|Navigate|ProposeEdits):/i) do |match|
      labels << match.first
    end
  end.uniq.map(&:downcase).sort
  expected.map(&:downcase).sort == actual
end

def run_command(writer, state, child, command)
  # In the current palette, a colon command query resolves to a visible action
  # row (for example `Open file (open)`), not a literal `:open` row. Opening a
  # file is an argument-taking action, so drive the same discovered UI path as
  # a user and submit its argument separately.
  if (match = command.match(/\Aopen\s+(.+)\z/))
    discover_action(writer, state, child, "open file path")
    type_text(writer, match[1])
    key(writer, ENTER)
    return
  end

  if command == "quit"
    discover_action(writer, state, child, "Quit editor")
    key(writer, ENTER)
    return
  end

  open_palette(writer)
  type_text(writer, ":#{command}")
  wait_for_screen("command palette #{command.inspect}", state, child) do |snapshot|
    screen_contains?(snapshot, "Command") &&
      snapshot[:rows].any? { |row| row.include?(":#{command.split.first}") }
  end
  key(writer, ENTER)
end

def choose_lua_script(writer, state, child, name, catalog_index:, capabilities:)
  discover_action(writer, state, child, "Run Lua script")
  wait_for_screen("Lua script picker entry #{name.inspect}", state, child) do |snapshot|
    screen_contains?(snapshot, name) && screen_contains?(snapshot, "List buffers")
  end
  # The picker is the bounded list in LUA_FRONTIER order, initially focused at
  # row zero: three built-ins precede our manifest-controlled entries.
  (3 + catalog_index).times { key(writer, CURSOR_DOWN) }
  key(writer, ENTER)
  review = wait_for_screen("review for #{name.inspect}", state, child) do |snapshot|
    text = screen_text(snapshot).gsub(/\s+/, " ")
    review_for?(snapshot, name) && review_capabilities_match?(snapshot, capabilities) &&
      text.include?("Enter: run once") && text.include?("Esc: cancel") &&
      text.match?(/5\s*(?:s|seconds)/i) && text.match?(/8\s*MiB/i) &&
      text.match?(/16\s*KiB\s*\/\s*64/i) &&
      snapshot[:rows].any? { |row| row.match?(/SHA-256:\s*[[:xdigit:]]{64}/i) }
  end
  review_text = screen_text(review).gsub(/\s+/, " ")
  raise "#{name}: requested capabilities missing from review" unless review_capabilities_match?(review, capabilities)
  raise "#{name}: one-run/cancel consent footer missing" unless review_text.include?("Enter: run once") && review_text.include?("Esc: cancel")
  if capabilities.include?("read_editor")
    unless review_text.match?(/shared buffer/i) && review_text.match?(/not selected-buffer-only/i)
      raise "#{name}: read_editor scope disclosure did not fit visibly"
    end
  end
  require_review_limits!(review, name)
  review
end

def require_review_digest!(snapshot, digest, label)
  raise "#{label}: review did not show the frozen source digest" unless
    snapshot[:rows].any? { |row| row.include?("SHA-256:") && row.include?(digest) }
end

def open_lua_log(writer, state, child)
  discover_action(writer, state, child, "Lua script log")
  wait_for_screen("selected Lua Log view", state, child) do |snapshot|
    snapshot[:rows].any? { |row| row.include?("Log") }
  end
end

def capture_worker_children(parent_pid, binary)
  output, status = Open3.capture2("/bin/ps", "-ww", "-axo", "pid=,ppid=,stat=,command=")
  raise "could not inspect the App-owned Lua worker process list" unless status.success?

  output.lines.each_with_object([]) do |line, workers|
    fields = line.strip.split(/\s+/, 4)
    next unless fields.length == 4
    pid, ppid, state, command = fields
    next unless ppid.to_i == parent_pid && command.include?(binary)
    next unless command.match?(/(?:\A|\s)--internal-lua-worker(?:\s|\z)/)

    workers << {pid: pid.to_i, state: state, command: command}
  end
end

def matching_worker_processes(binary)
  output, status = Open3.capture2("/bin/ps", "-ww", "-axo", "pid=,ppid=,stat=,command=")
  raise "could not inspect the Lua worker process list" unless status.success?

  output.lines.select do |line|
    line.include?(binary) && line.match?(/(?:\A|\s)--internal-lua-worker(?:\s|\z)/)
  end.map(&:strip)
end

def matching_editor_processes(binary)
  output, status = Open3.capture2("/bin/ps", "-ww", "-axo", "pid=,ppid=,stat=,command=")
  raise "could not inspect the editor process list" unless status.success?

  output.lines.select { |line| line.include?(binary) }.map(&:strip)
end

def process_is_lua_worker?(pid, binary)
  output, status = Open3.capture2("/bin/ps", "-ww", "-p", pid.to_s, "-o", "command=")
  return false unless status.success?

  output.lines.any? do |line|
    line.include?(binary) && line.match?(/(?:\A|\s)--internal-lua-worker(?:\s|\z)/)
  end
end

def assert_no_worker_spawned!(parent_pid, binary, seconds: 0.3)
  deadline = monotonic + seconds
  loop do
    workers = capture_worker_children(parent_pid, binary)
    raise "Lua worker spawned before explicit consent: #{workers.inspect}" unless workers.empty?
    break if monotonic >= deadline
    sleep 0.025
  end
end

def wait_for_worker(parent_pid, binary, child, seconds: 4.0, required: true)
  deadline = monotonic + seconds
  loop do
    workers = capture_worker_children(parent_pid, binary)
    return workers if !workers.empty?
    raise "editor exited before its Lua worker appeared" if child && !child_alive?(child)
    if monotonic >= deadline
      return [] unless required
      raise "timed out waiting for the real self-exec Lua worker (expected App pid #{parent_pid}); " \
        "matching worker rows: #{matching_worker_processes(binary).inspect}; " \
        "matching editor rows: #{matching_editor_processes(binary).inspect}"
    end
    sleep 0.05
  end
end

def wait_for_worker_reap(parent_pid, binary, child, seconds: 5.0)
  deadline = monotonic + seconds
  loop do
    workers = capture_worker_children(parent_pid, binary)
    return if workers.empty?
    raise "Lua worker was not reaped (still visible as #{workers.inspect})" if monotonic >= deadline
    raise "editor exited with a Lua worker still present: #{workers.inspect}" if child && !child_alive?(child)
    sleep 0.05
  end
end

def require_worker_active!(parent_pid, binary, worker_pids, label)
  active = capture_worker_children(parent_pid, binary).map { |worker| worker[:pid] }
  raise "#{label}: worker is not still active during the UI check" if (active & worker_pids).empty?
end

def close_review_visible?(snapshot)
  screen_contains?(snapshot, "main.cr") &&
    screen_contains?(snapshot, "Close file") &&
    screen_contains?(snapshot, "Save changes before closing?") &&
    screen_contains?(snapshot, "Esc: Cancel")
end

def main_cr_tab_visible?(snapshot)
  # This smoke fixes the PTY at 112x30. Row 2 is the document tab strip;
  # searching the whole screen would mistake historical Log text for a live
  # tab after the buffer has already closed.
  tab_strip = snapshot[:rows][1].to_s
  tab_strip.match?(/(?:\A|│)\s*main\.cr\*?\s*(?:│|\z)/)
end

def assert_no_premature_finalizer_success!(state, parent_pid, binary, worker_pids, run_id:, seconds: 0.35)
  deadline = monotonic + seconds
  success_row = /Lua script complete: Fixture hanging finalizer \[run=#{Regexp.escape(run_id)}\]/i
  loop do
    snapshot = current_screen(state)
    if screen_contains?(snapshot, "Lua script proposed edits") ||
       screen_matches?(snapshot, success_row)
      raise "finalizer run published success before its worker was reaped"
    end
    require_worker_active!(parent_pid, binary, worker_pids, "finalizer shutdown window")
    break if monotonic >= deadline
    sleep 0.025
  end
end

def wait_for_finalizer_reap(state, parent_pid, binary, child, worker_pids, run_id:, seconds: 8.0)
  deadline = monotonic + seconds
  success_row = /Lua script complete: Fixture hanging finalizer \[run=#{Regexp.escape(run_id)}\]/i
  loop do
    snapshot = current_screen(state)
    if screen_contains?(snapshot, "Lua script proposed edits") || screen_matches?(snapshot, success_row)
      raise "finalizer run published success before its worker was reaped"
    end
    workers = capture_worker_children(parent_pid, binary)
    return if workers.empty?
    raise "finalizer worker remained active past its wall-time limit: #{workers.inspect}" if monotonic >= deadline
    raise "editor exited while finalizer worker remained active" if child && !child_alive?(child)
    sleep 0.05
  end
end

def write_fixture(root)
  project = File.join(root, "project")
  home = File.join(root, "home")
  state_home = File.join(root, "state")
  project_lua = File.join(project, ".adamantine", "lua")
  project_scripts = File.join(project_lua, "scripts")
  config_lua = File.join(home, ".config", "adamantine", "lua")
  config_scripts = File.join(config_lua, "scripts")
  source = File.join(project, "main.cr")

  [project_scripts, config_scripts, state_home].each { |path| FileUtils.mkdir_p(path, mode: 0o700) }
  File.chmod(0o700, root)
  File.chmod(0o700, home)
  File.chmod(0o700, state_home)

  lines = ["SMOKE_BUFFER_SENTINEL    "] + (2..32).map { |line| "line_#{line}" } + ["OUTSIDE_BOUND_SENTINEL    "]
  original = lines.join("\n") + "\n"
  File.binwrite(source, original)
  File.write(File.join(project, "README.md"), "PROJECT_README_SENTINEL\n")
  disk_digest = Digest::SHA256.hexdigest(original)

  frozen_source = "print(\"FROZEN_ORIGINAL_SENTINEL\")\n"
  denied_source = <<~LUA
    local read_result = editor.call("editor.list_buffers", {})
    local nav_result = editor.call("editor.open_file", {path="README.md"})
    print("READ_CAP=" .. read_result.status)
    print("NAV_CAP=" .. nav_result.status)
  LUA
  loop_source = "print(\"RUNAWAY_SCRIPT_STARTED_SENTINEL\")\nwhile true do end\n"
  finalizer_source = <<~LUA
    local selected = editor.context.selected_buffer
    local proposal = editor.call("editor.propose_edits", {
      buffer_id=selected.buffer_id,
      revision=selected.revision,
      edits={{start_line=1,start_column=0,end_line=1,end_column=0,new_text="FINALIZER_PROPOSAL_SENTINEL"}}
    })
    local staged = proposal.status == "ok" and proposal.data and
      proposal.data.status == "pending_review" and proposal.data.applied == false
    print("FINALIZER_PROPOSAL=" .. (staged and "pending_review" or "not_staged"))
    local doomed = setmetatable({}, {__gc=function() while true do end end})
    print("FINALIZER_SCRIPT_RETURNED_SENTINEL")
  LUA

  fixtures = [
    {id: "fixture-frozen", name: "Fixture frozen source", file: "fixture-frozen.lua", capabilities: [], source: frozen_source},
    {id: "fixture-denied", name: "Fixture denied grants", file: "fixture-denied.lua", capabilities: [], source: denied_source},
    {id: "fixture-loop", name: "Fixture runaway loop", file: "fixture-loop.lua", capabilities: [], source: loop_source},
    {id: "fixture-finalizer", name: "Fixture hanging finalizer", file: "fixture-finalizer.lua", capabilities: ["propose_edits"], source: finalizer_source},
  ]
  fixtures.each { |fixture| File.binwrite(File.join(config_scripts, fixture[:file]), fixture[:source]) }
  manifest = {version: 1, scripts: fixtures.map { |fixture| fixture.slice(:id, :name, :file, :capabilities) }}
  File.write(File.join(config_lua, "manifest.json"), JSON.generate(manifest))

  # An attractive but forbidden workspace-side autorun/catalog must remain
  # invisible; only the explicit user-configuration manifest is discoverable.
  File.write(File.join(project_lua, "manifest.json"), JSON.generate(
    version: 1,
    scripts: [{id: "project-trap", name: "Project autorun trap", file: "project-trap.lua", capabilities: []}]
  ))
  File.write(File.join(project_scripts, "project-trap.lua"), "print(\"PROJECT_AUTORUN_RAN_SENTINEL\")\n")

  {
    project: project,
    home: home,
    state_home: state_home,
    source: source,
    original: original,
    disk_digest: disk_digest,
    config_source: File.join(config_scripts, "fixture-frozen.lua"),
    frozen_source: frozen_source,
    replacement_source: "print(\"FROZEN_REPLACEMENT_SENTINEL\")\n",
    fixtures: fixtures,
  }
end

def pty_oracle_self_check!
  screen = PtyScreen.new(40, 8)
  screen.feed("\e[?1049h\e[>5u\e[2J\e[1;1HAdamantine\e[4;1HLOG_SENTINEL\e[8;1HFooter")
  snapshot = {rows: screen.rows, width: 40, height: 8}
  raise "PTY self-check: header missing" unless screen_contains?(snapshot, "Adamantine")
  raise "PTY self-check: current output row missing" unless screen_contains?(snapshot, "LOG_SENTINEL")
  raise "PTY self-check: footer decoy missing" unless screen_contains?(snapshot, "Footer")

  closed_screen = PtyScreen.new(80, 8)
  closed_screen.feed("\e[?1049h\e[>5u\e[2J\e[1;1HAdamantine\e[2;1HF │ project │ README.md\e[8;1HLua proposed edits ready for manual review in main.cr")
  closed_snapshot = {rows: closed_screen.rows, width: 80, height: 8}
  raise "PTY self-check: stale Log text looked like an open document tab" if main_cr_tab_visible?(closed_snapshot)
  closed_screen.feed("\e[2;1HF │ project │ main.cr* │ README.md")
  dirty_snapshot = {rows: closed_screen.rows, width: 80, height: 8}
  raise "PTY self-check: live dirty document tab was not detected" unless main_cr_tab_visible?(dirty_snapshot)
  puts JSON.generate(result: "PASS", pty_screen_oracle: true)
end

def run_smoke(binary, library_path, timeout_seconds:)
  temp_root = Dir.mktmpdir("adamantine-lua-smoke-")
  root = File.realpath(temp_root)
  fixture = write_fixture(root)
  env = {
    "TERM" => "xterm-256color",
    "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"),
    "LANG" => "C.UTF-8",
    "HOME" => fixture[:home],
    "XDG_CONFIG_HOME" => File.join(fixture[:home], ".config"),
    "XDG_CACHE_HOME" => File.join(fixture[:state_home], "cache"),
    "ADAMANTINE_SESSION" => "0",
    "ADAMANTINE_RECOVERY" => "0",
    "ADAMANTINE_STATE_HOME" => fixture[:state_home],
    "XDG_STATE_HOME" => fixture[:state_home],
    "ADAMANTINE_LUA_WORKER" => binary,
    "ADAMANTINE_LUA_LIBRARY" => library_path,
  }
  reader = nil
  slave = nil
  child = nil
  drain = nil
  worker_pids = Set.new
  output_state = {
    mutex: Mutex.new,
    output: +"".b,
    screen: PtyScreen.new(WIDTH, HEIGHT),
    width: WIDTH,
    height: HEIGHT,
    screen_error: nil,
    drain_error: nil,
    drain_complete: false,
  }
  passed = false
  started_at = monotonic

  begin
    Timeout.timeout(timeout_seconds) do
      reader, slave = PTY.open
      reader.winsize = [HEIGHT, WIDTH]
      pid = Process.spawn(env, binary, fixture[:project], "--no-lsp",
        in: slave, out: slave, err: slave, unsetenv_others: true)
      child = {pid: pid, reaped: false, status: nil}
      drain = Thread.new do
        begin
          loop do
            bytes = reader.readpartial(65_536)
            output_state[:mutex].synchronize do
              output_state[:output] << bytes.b
              overflow = output_state[:output].bytesize - 65_536
              output_state[:output].slice!(0, overflow) if overflow.positive?
              unless output_state[:screen_error]
                begin
                  output_state[:screen].feed(bytes)
                rescue PtyScreen::UnsupportedSequence => error
                  output_state[:screen_error] = error.message
                end
              end
            end
          end
        rescue EOFError, Errno::EIO
          output_state[:mutex].synchronize do
            begin
              output_state[:screen].finish!
            rescue PtyScreen::UnsupportedSequence => error
              output_state[:screen_error] ||= error.message
            rescue StandardError => error
              output_state[:drain_error] ||= "#{error.class}: #{error.message}"
            ensure
              output_state[:drain_complete] = true
            end
          end
        rescue StandardError => error
          output_state[:mutex].synchronize do
            output_state[:drain_error] ||= "#{error.class}: #{error.message}"
          end
        ensure
          output_state[:mutex].synchronize { output_state[:drain_complete] = true }
        end
      end

      wait_for_screen("terminal readiness", output_state, child) do |snapshot|
        snapshot[:revision].positive? && snapshot[:alternate_screen] && snapshot[:kitty_keyboard] &&
          screen_contains?(snapshot, "Adamantine") && !slave.echo?
      end
      raise "PTY readiness did not leave terminal echo disabled" if slave.echo?
      slave.close
      slave = nil

      run_command(reader, output_state, child, "open #{fixture[:source]}")
      wait_for_screen("seeded source opened", output_state, child) do |snapshot|
        screen_contains?(snapshot, "SMOKE_BUFFER_SENTINEL") && screen_contains?(snapshot, "main.cr")
      end
      raise "opening the fixture changed its exact on-disk bytes" unless Digest::SHA256.file(fixture[:source]).hexdigest == fixture[:disk_digest]

      # Discover the run command, then prove review cancellation has no side
      # effect. Project-side catalog/autorun traps must not enter discovery.
      discover_action(reader, output_state, child, "Run Lua script")
      picker = wait_for_screen("bounded Lua script catalog", output_state, child) do |snapshot|
        screen_contains?(snapshot, "List buffers") && screen_contains?(snapshot, "Fixture frozen source")
      end
      raise "workspace Lua catalog leaked into user-script discovery" if screen_contains?(picker, "Project autorun trap")
      3.times { key(reader, CURSOR_DOWN) }
      key(reader, ENTER)
      frozen_digest = Digest::SHA256.hexdigest(fixture[:frozen_source])
      review = wait_for_screen("frozen fixture review", output_state, child) do |snapshot|
        text = screen_text(snapshot).gsub(/\s+/, " ")
        review_for?(snapshot, "Fixture frozen source") &&
          text.include?("Enter: run once") && text.include?("Esc: cancel")
      end
      require_review_digest!(review, frozen_digest, "pre-consent review")
      review_text = screen_text(review).gsub(/\s+/, " ")
      no_capability_disclosed = review_text.include?("Requested capabilities: none") ||
        review_text.match?(/No capabilities requested/i)
      raise "no-capability script review did not disclose the empty grant set" unless no_capability_disclosed
      raise "one-run/cancel consent footer missing" unless review_text.include?("Enter: run once") && review_text.include?("Esc: cancel")
      require_review_limits!(review, "pre-consent review")
      key(reader, ESCAPE)
      assert_no_worker_spawned!(child[:pid], binary)
      open_lua_log(reader, output_state, child)
      assert_no_worker_spawned!(child[:pid], binary, seconds: 0.5)
      log = current_screen(output_state)
      raise "Escape-before-consent executed the Lua source" if screen_contains?(log, "FROZEN_ORIGINAL_SENTINEL")
      raise "workspace Lua autorun executed" if screen_contains?(log, "PROJECT_AUTORUN_RAN_SENTINEL")

      # Freeze-at-review adversary: mutate the config file only after its name,
      # digest and grants are visible. Approval must execute the reviewed bytes.
      choose_lua_script(reader, output_state, child, "Fixture frozen source", catalog_index: 0, capabilities: "Requested capabilities: none")
      review = current_screen(output_state)
      require_review_digest!(review, frozen_digest, "approved frozen review")
      File.binwrite(fixture[:config_source], fixture[:replacement_source])
      key(reader, ENTER)
      workers = wait_for_worker(child[:pid], binary, child, seconds: 0.25, required: false)
      worker_pids.merge(workers.map { |worker| worker[:pid] })
      open_lua_log(reader, output_state, child)
      wait_for_screen("approved frozen source output and completion", output_state, child) do |snapshot|
        screen_contains?(snapshot, "FROZEN_ORIGINAL_SENTINEL") &&
          screen_contains?(snapshot, "Lua script complete: Fixture frozen source")
      end
      raise "run reopened the script after review instead of using frozen bytes" if screen_contains?(current_screen(output_state), "FROZEN_REPLACEMENT_SENTINEL")
      wait_for_worker_reap(child[:pid], binary, child)

      # Positive navigation control: unlike the denied fixture below, this
      # built-in explicitly requests and receives the navigate capability.
      # Seeing the unique README body proves the implementation committed the
      # navigation, rather than merely returning a denial-shaped result.
      choose_lua_script(reader, output_state, child, "Open README", catalog_index: -2, capabilities: "Requested capabilities: navigate")
      key(reader, ENTER)
      navigation_workers = wait_for_worker(child[:pid], binary, child, seconds: 0.25, required: false)
      worker_pids.merge(navigation_workers.map { |worker| worker[:pid] })
      wait_for_screen("authorized navigation opened the project README", output_state, child) do |snapshot|
        screen_contains?(snapshot, "PROJECT_README_SENTINEL")
      end
      open_lua_log(reader, output_state, child)
      wait_for_screen("authorized navigation completed", output_state, child) do |snapshot|
        screen_contains?(snapshot, "Lua script complete: Open README")
      end
      wait_for_worker_reap(child[:pid], binary, child)
      run_command(reader, output_state, child, "open #{fixture[:source]}")
      wait_for_screen("source restored after authorized navigation", output_state, child) do |snapshot|
        screen_contains?(snapshot, "SMOKE_BUFFER_SENTINEL")
      end

      # Requested capabilities are not grants: both read and navigation calls
      # must be denied before the README can displace the active source buffer.
      choose_lua_script(reader, output_state, child, "Fixture denied grants", catalog_index: 1, capabilities: "Requested capabilities: none")
      key(reader, ENTER)
      denied_workers = wait_for_worker(child[:pid], binary, child, seconds: 0.25, required: false)
      worker_pids.merge(denied_workers.map { |worker| worker[:pid] })
      open_lua_log(reader, output_state, child)
      wait_for_screen("missing-capability denials", output_state, child) do |snapshot|
        screen_contains?(snapshot, "READ_CAP=denied") && screen_contains?(snapshot, "NAV_CAP=denied")
      end
      denied_screen = current_screen(output_state)
      raise "ungranted navigation opened the trap README" if screen_contains?(denied_screen, "PROJECT_README_SENTINEL")
      wait_for_worker_reap(child[:pid], binary, child)

      # An uncooperative pure-Lua loop cannot block the editor's input owner.
      choose_lua_script(reader, output_state, child, "Fixture runaway loop", catalog_index: 2, capabilities: "Requested capabilities: none")
      key(reader, ENTER)
      loop_workers = wait_for_worker(child[:pid], binary, child, seconds: 1.0)
      worker_pids.merge(loop_workers.map { |worker| worker[:pid] })
      wait_for_screen("runaway script entered its Lua loop", output_state, child) do |snapshot|
        screen_contains?(snapshot, "RUNAWAY_SCRIPT_STARTED_SENTINEL")
      end
      runaway_output = current_screen(output_state)
      runaway_run_id = run_id_for_output(runaway_output, "Fixture runaway loop", "RUNAWAY_SCRIPT_STARTED_SENTINEL")
      open_palette(reader)
      type_text(reader, "Cancel Lua script")
      wait_for_screen("runaway cancel control is visible while the worker runs", output_state, child) do |snapshot|
        screen_contains?(snapshot, "Cancel Lua script")
      end
      require_worker_active!(child[:pid], binary, loop_workers.map { |worker| worker[:pid] }, "runaway cancellation")
      key(reader, ENTER)
      wait_for_worker_reap(child[:pid], binary, child, seconds: 6.0)
      open_lua_log(reader, output_state, child)
      cancel_row = /Lua script cancelled: Fixture runaway loop \[run=#{Regexp.escape(runaway_run_id)}\]/i
      cancelled = wait_for_screen("runaway cancellation status", output_state, child) do |snapshot|
        screen_matches?(snapshot, cancel_row) && screen_contains?(snapshot, "RUNAWAY_SCRIPT_STARTED_SENTINEL")
      end
      raise "cancelled runaway did not leave the editor responsive" unless screen_contains?(cancelled, "Log")

      # Lua table finalizers run during state shutdown in this fixture. A
      # success-shaped event before worker exit would open a proposal/complete;
      # the real worker must remain active until the parent deadline kills and
      # reaps it. F1 remains responsive while the child is stuck in __gc.
      open_lua_log(reader, output_state, child)
      choose_lua_script(reader, output_state, child, "Fixture hanging finalizer", catalog_index: 3, capabilities: "Requested capabilities: propose_edits")
      key(reader, ENTER)
      open_lua_log(reader, output_state, child)
      finalizer_output = wait_for_screen("finalizer entered state shutdown", output_state, child, seconds: 2.5) do |snapshot|
        screen_contains?(snapshot, "FINALIZER_PROPOSAL=pending_review") &&
          screen_contains?(snapshot, "FINALIZER_SCRIPT_RETURNED_SENTINEL")
      end
      finalizer_workers = wait_for_worker(child[:pid], binary, child, seconds: 1.0)
      worker_pids.merge(finalizer_workers.map { |worker| worker[:pid] })
      finalizer_run_id = run_id_for_output(finalizer_output, "Fixture hanging finalizer", "FINALIZER_SCRIPT_RETURNED_SENTINEL")
      assert_no_premature_finalizer_success!(output_state, child[:pid], binary, finalizer_workers.map { |worker| worker[:pid] }, run_id: finalizer_run_id)
      open_palette(reader)
      type_text(reader, "Cancel Lua script")
      wait_for_screen("active finalizer cancel control is visible", output_state, child) do |snapshot|
        screen_contains?(snapshot, "Cancel Lua script")
      end
      require_worker_active!(child[:pid], binary, finalizer_workers.map { |worker| worker[:pid] }, "finalizer deadline")
      key(reader, ESCAPE) # Close discovery only; let the independent 5s deadline fire.
      require_worker_active!(child[:pid], binary, finalizer_workers.map { |worker| worker[:pid] }, "finalizer deadline after F1")
      open_lua_log(reader, output_state, child)
      wait_for_finalizer_reap(output_state, child[:pid], binary, child, finalizer_workers.map { |worker| worker[:pid] }, run_id: finalizer_run_id, seconds: 8.0)
      failure_row = /Lua script failed: Fixture hanging finalizer \[run=#{Regexp.escape(finalizer_run_id)}\] \(wall_time_limit\)(?:\s|:|$)/i
      success_row = /Lua script complete: Fixture hanging finalizer \[run=#{Regexp.escape(finalizer_run_id)}\](?:\s|$)/i
      finalizer_end = wait_for_screen("finalizer-specific deadline status", output_state, child, seconds: 2.0) do |snapshot|
        screen_matches?(snapshot, failure_row) &&
          screen_contains?(snapshot, "FINALIZER_PROPOSAL=pending_review") &&
          screen_contains?(snapshot, "FINALIZER_SCRIPT_RETURNED_SENTINEL")
      end
      raise "finalizer run was reported successful" if screen_matches?(finalizer_end, success_row)
      raise "success-shaped finalizer result opened a proposal preview" if screen_contains?(finalizer_end, "Lua script proposed edits")
      raise "finalizer deadline failure was not visible in Log" unless screen_matches?(finalizer_end, failure_row)
      raise "failed finalizer proposal changed the visible buffer" if screen_contains?(finalizer_end, "FINALIZER_PROPOSAL_SENTINEL")
      discover_action(reader, output_state, child, "Focus editor")
      key(reader, CTRL_W)
      finalizer_close = wait_for_screen("failed proposal left the editor buffer clean", output_state, child, seconds: 3.0) do |snapshot|
        close_review_visible?(snapshot) || !main_cr_tab_visible?(snapshot)
      end
      if close_review_visible?(finalizer_close)
        key(reader, ESCAPE)
        raise "failed finalizer proposal dirtied the buffer before successful exit"
      end
      raise "failed proposal left the main.cr tab open" if main_cr_tab_visible?(finalizer_close)
      run_command(reader, output_state, child, "open #{fixture[:source]}")
      wait_for_screen("source reopened after failed proposal", output_state, child) do |snapshot|
        screen_contains?(snapshot, "SMOKE_BUFFER_SENTINEL")
      end
      raise "failed proposal changed on-disk bytes" unless Digest::SHA256.file(fixture[:source]).hexdigest == fixture[:disk_digest]

      # The built-in is deliberately bounded to 32 lines. It sees two trailing
      # whitespace regions but can stage only the first; reject once, then
      # accept once and use exactly one Undo. No disk write is part of this flow.
      choose_lua_script(reader, output_state, child, "Trim trailing spaces — first 32 lines", catalog_index: -1, capabilities: "Requested capabilities: read_editor, propose_edits")
      trim_review = current_screen(output_state)
      raise "trim review omitted its full SHA-256 digest" unless screen_matches?(trim_review, /SHA-256:\s*[0-9a-f]{64}/i)
      key(reader, ENTER)
      preview = wait_for_screen("Lua proposal reject preview", output_state, child) do |snapshot|
        screen_contains?(snapshot, "Lua script proposed edits")
      end
      wait_for_worker_reap(child[:pid], binary, child)
      raise "preview omitted the selected-buffer edit" unless screen_contains?(preview, "SMOKE_BUFFER_SENTINEL")
      key(reader, ESCAPE)
      wait_for_screen("rejected proposal closed", output_state, child) do |snapshot|
        !screen_contains?(snapshot, "Lua script proposed edits")
      end
      raise "reject changed the on-disk source" unless Digest::SHA256.file(fixture[:source]).hexdigest == fixture[:disk_digest]

      choose_lua_script(reader, output_state, child, "Trim trailing spaces — first 32 lines", catalog_index: -1, capabilities: "Requested capabilities: read_editor, propose_edits")
      key(reader, ENTER)
      preview = wait_for_screen("Lua proposal accept preview", output_state, child) do |snapshot|
        screen_contains?(snapshot, "Lua script proposed edits")
      end
      wait_for_worker_reap(child[:pid], binary, child)
      raise "second proposal did not retain the selected-buffer sentinel" unless screen_contains?(preview, "SMOKE_BUFFER_SENTINEL")
      key(reader, ENTER)
      accepted = wait_for_screen("manual proposal acceptance", output_state, child) do |snapshot|
        screen_contains?(snapshot, "Lua proposed edits accepted; not saved · Undo to restore")
      end
      raise "accepted edit unexpectedly wrote the source file" unless Digest::SHA256.file(fixture[:source]).hexdigest == fixture[:disk_digest]

      key(reader, CTRL_W)
      dirty_review = wait_for_screen("accepted proposal is dirty before Undo", output_state, child) do |snapshot|
        close_review_visible?(snapshot)
      end
      raise "accepted proposal did not visibly create a dirty buffer" unless screen_contains?(dirty_review, "SMOKE_BUFFER_SENTINEL")
      key(reader, ESCAPE)
      wait_for_screen("close review canceled before Undo", output_state, child) do |snapshot|
        !close_review_visible?(snapshot) && screen_contains?(snapshot, "main.cr")
      end
      key(reader, CTRL_Z)
      sleep 0.15
      key(reader, CTRL_W)
      after_undo = wait_for_screen("single Undo restored a clean buffer", output_state, child, seconds: 4.0) do |snapshot|
        !close_review_visible?(snapshot) && !main_cr_tab_visible?(snapshot)
      end
      raise "one Undo did not close the clean buffer" if main_cr_tab_visible?(after_undo)
      run_command(reader, output_state, child, "open #{fixture[:source]}")
      wait_for_screen("source reopened after one Undo", output_state, child) do |snapshot|
        screen_contains?(snapshot, "SMOKE_BUFFER_SENTINEL")
      end
      raise "manual proposal flow changed on-disk bytes" unless Digest::SHA256.file(fixture[:source]).hexdigest == fixture[:disk_digest]

      # The editor remains clean and all workers have been reaped. Quit without
      # saving; a close-review prompt here would falsify the one-Undo oracle.
      run_command(reader, output_state, child, "quit")
      quit_state = wait_for_screen("clean quit transition", output_state, child, seconds: 4.0) do |snapshot|
        !child_alive?(child) || screen_contains?(snapshot, "Quit editor — review file")
      end
      if child_alive?(child)
        unless screen_contains?(quit_state, "Quit editor — review file") && Digest::SHA256.file(fixture[:source]).hexdigest == fixture[:disk_digest]
          raise "editor did not cleanly quit after the one-Undo proof\n#{screen_text(quit_state)}"
        end
        key(reader, SHIFT_TAB)
        wait_for_screen("explicit no-save discard choice", output_state, child) do |snapshot|
          screen_contains?(snapshot, "Quit editor — review file") && screen_contains?(snapshot, "[Discard]")
        end
        key(reader, ENTER)
        finish_deadline = monotonic + 4.0
        sleep 0.02 while child_alive?(child) && monotonic < finish_deadline
      end
      raise "editor did not exit after the clean smoke run" if child_alive?(child)
      raise "production editor exited unsuccessfully: #{child[:status].inspect}" unless child[:status]&.success?
      child = nil
      drain.join(1)
      raise "PTY output drain did not complete" unless output_state[:drain_complete]
      raise "PTY output drain failed: #{output_state[:drain_error]}" if output_state[:drain_error]
      raise "PTY screen tracker failed closed: #{output_state[:screen_error]}" if output_state[:screen_error]
      remaining_workers = worker_pids.select { |worker_pid| process_is_lua_worker?(worker_pid, binary) }
      raise "Lua workers remain after editor exit: #{remaining_workers.inspect}" unless remaining_workers.empty?
      passed = true
    end

    elapsed = monotonic - started_at
    puts JSON.generate(
      result: "PASS",
      mode: "production-release-with-real-lua",
      f1_catalog_and_project_autorun_denied: true,
      cancel_before_consent: true,
      source_frozen_at_review_digest: true,
      actual_lua_output_in_log: true,
      missing_read_and_navigation_grants_denied: true,
      runaway_cancel_kept_tui_responsive_and_reaped: true,
      finalizer_hang_did_not_publish_success: true,
      bounded_manual_preview_reject_accept_one_undo: true,
      disk_unchanged_without_save: true,
      observed_worker_pids: worker_pids.to_a,
      elapsed_seconds: elapsed.round(2),
    )
  rescue Exception => error
    warn "Lua App/PTY smoke failed: #{error.class}: #{error.message}"
    warn "Lua smoke artifacts: #{root}"
    if output_state[:mutex]
      output_state[:mutex].synchronize do
        File.binwrite(File.join(root, "terminal.raw"), output_state[:output])
      end
      begin
        File.write(File.join(root, "terminal.screen.txt"), screen_text(current_screen(output_state)))
      rescue StandardError => screen_error
        warn "current-screen snapshot unavailable: #{screen_error.message}"
      end
    end
    raise
  ensure
    if child && child_alive?(child)
      begin
        run_command(reader, output_state, child, "quit") if reader
        deadline = monotonic + 1.0
        sleep 0.02 while child_alive?(child) && monotonic < deadline
      rescue StandardError
        nil
      end
      if child_alive?(child)
        signal_owned_child(child, "TERM")
        deadline = monotonic + 1.0
        sleep 0.02 while child_alive?(child) && monotonic < deadline
      end
      if child_alive?(child)
        capture_worker_children(child[:pid], binary).each do |worker|
          worker_pids << worker[:pid]
          Process.kill("KILL", worker[:pid]) rescue nil
        end
        signal_owned_child(child, "KILL")
        deadline = monotonic + 1.5
        sleep 0.02 while child_alive?(child) && monotonic < deadline
      end
    end
    # A remembered PID may have been reused after its original worker exited.
    # Signal it only if the process list still identifies the exact executable
    # and worker mode; otherwise leave the unrelated process alone.
    worker_pids.each do |worker_pid|
      Process.kill("KILL", worker_pid) if process_is_lua_worker?(worker_pid, binary)
    rescue Errno::ESRCH
      nil
    end
    drain&.join(1)
    reader&.close rescue nil
    slave&.close rescue nil
    FileUtils.remove_entry(root) if passed && File.directory?(root)
  end
end

if options[:self_check]
  pty_oracle_self_check!
else
  binary = File.realpath(options[:editor_bin])
  library_path = File.realpath(options[:library_path])
  abort "editor binary is not executable: #{binary}" unless File.file?(binary) && File.executable?(binary)
  abort "Lua library path is not an absolute regular file: #{library_path}" unless library_path.start_with?(File::SEPARATOR) && File.file?(library_path)
  run_smoke(binary, library_path, timeout_seconds: options[:timeout])
end
