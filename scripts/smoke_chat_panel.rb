#!/usr/bin/env ruby
require "digest"
require "fileutils"
require "io/console"
require "json"
require "optparse"
require "pty"
require "tmpdir"
require "timeout"
require_relative "lib/pty_screen"

# Bounded local App/PTY chat-panel smoke. `--editor-bin` proves the default
# unavailable-transport UX; `--fixture-bin` runs a separately built local
# fixture App with an injected transport. Neither path uses a model/provider.
options = {editor_bin: nil, fixture_bin: nil, timeout: 45.0, self_check: false}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/smoke_chat_panel.rb (--editor-bin PATH | --fixture-bin PATH) [--timeout SECONDS]"
  parser.on("--editor-bin PATH", "Privately built production editor executable (no transport)") { |path| options[:editor_bin] = path }
  parser.on("--fixture-bin PATH", "Prebuilt local fixture App with injected transport") { |path| options[:fixture_bin] = path }
  parser.on("--timeout SECONDS", Float, "Overall smoke deadline (default: 45)") { |seconds| options[:timeout] = seconds }
  parser.on("--self-check", "Run only the bounded VT screen-oracle checks") { options[:self_check] = true }
  parser.on("-h", "--help") { puts parser; exit 0 }
end.parse!

abort "choose exactly one of --editor-bin or --fixture-bin" unless
  options[:self_check] || [options[:editor_bin], options[:fixture_bin]].compact.size == 1
abort "--timeout must be between 10 and 120 seconds" unless options[:timeout].between?(10.0, 120.0)

binary_option = options[:fixture_bin] || options[:editor_bin]
binary = options[:self_check] ? nil : File.realpath(binary_option)
abort "editor binary is not executable: #{binary}" if !options[:self_check] && !(File.file?(binary) && File.executable?(binary))
fixture_mode = !options[:fixture_bin].nil?

WIDTH = 112
HEIGHT = 30
F1 = "\eOP".freeze
F3 = "\eOR".freeze
ESCAPE = "\e[27u".freeze
ENTER = "\e[13u".freeze
SHIFT_ENTER = "\e[13;2u".freeze
ALT_ENTER = "\e\r".freeze
SHIFT_TAB = "\e[Z".freeze
CTRL_SHIFT_G = "\e[103;6u".freeze
CTRL_G = "\x07".freeze
CTRL_S = "\x13".freeze
CTRL_W = "\x17".freeze
CURSOR_UP = "\e[A".freeze
CURSOR_DOWN = "\e[B".freeze

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def key(writer, sequence)
  writer.write(sequence)
  writer.flush
end

def move_cursor(writer, sequence, count)
  count.times { key(writer, sequence) }
end

def type_text(writer, text)
  text.each_codepoint { |codepoint| key(writer, "\e[#{codepoint}u") }
end

def paste_text(writer, text)
  key(writer, "\e[200~#{text}\e[201~")
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

def screen_contains?(snapshot, fragment)
  snapshot[:rows].any? { |row| row.include?(fragment) }
end

def bottom_rows(snapshot)
  rows = snapshot[:rows]
  start = chat_separator_index(snapshot)
  return [] unless start

  # App lays out a one-row footer after the body split. The chat panel owns
  # only the body rows after its divider; do not let footer text satisfy a
  # current-panel assertion.
  finish = rows.size - 1
  rows[(start + 1)...finish] || []
end

def horizontal_separator?(row, width)
  row.count("─") >= (width * 0.55).floor
end

def chat_separator_index(snapshot)
  snapshot[:rows].each_index.find do |index|
    row = snapshot[:rows][index]
    next false unless (row.include?("┴") || row.include?("┼")) && horizontal_separator?(row, snapshot[:width])

    header = snapshot[:rows][index + 1] || ""
    header.include?("Chat") && header.include?("Log")
  end
end

def bottom_contains?(snapshot, fragment)
  bottom_rows(snapshot).any? { |row| row.include?(fragment) }
end

def screen_rows_for(snapshot, fragment, bottom: false)
  rows = bottom ? bottom_rows(snapshot) : snapshot[:rows]
  rows.each_index.select { |index| rows[index].include?(fragment) }
end

def require_screen!(snapshot, fragments, label, bottom: false)
  missing = fragments.reject do |fragment|
    bottom ? bottom_contains?(snapshot, fragment) : screen_contains?(snapshot, fragment)
  end
  raise "#{label}: missing current-screen text #{missing.inspect}" unless missing.empty?
end

def close_review_visible?(snapshot)
  return false unless screen_contains?(snapshot, "main.cr")

  normal_form = screen_contains?(snapshot, "Close file") &&
    screen_contains?(snapshot, "Save changes before closing?") &&
    screen_contains?(snapshot, "Tab/Arrows: select") &&
    screen_contains?(snapshot, "Esc: Cancel")
  compact_form = ["[Save] Enter", "[Discard] Enter", "[Cancel] Enter"].any? do |choice|
    screen_contains?(snapshot, choice)
  end && screen_contains?(snapshot, "Esc:Cancel")

  normal_form || compact_form
end

def require_close_review!(snapshot, label)
  raise "#{label}: no active current-screen close review for main.cr" unless close_review_visible?(snapshot)
  selected = ["[Save]", "[Discard]", "[Cancel]"].any? do |choice|
    screen_contains?(snapshot, choice)
  end
  raise "#{label}: close review has no visible selected choice" unless selected
end

def require_distinct_screen_rows!(snapshot, fragments, label, bottom: false)
  rows = bottom ? bottom_rows(snapshot) : snapshot[:rows]
  indexes = fragments.map do |fragment|
    index = rows.index { |row| row.include?(fragment) }
    raise "#{label}: missing current-screen line #{fragment.inspect}" unless index
    index
  end
  raise "#{label}: multiline content was flattened into one screen row" unless indexes.uniq.size == fragments.size
end

def require_full_width_sentinel!(snapshot, label)
  row = bottom_rows(snapshot).find { |line| line.include?("WIDTH_BEGIN") }
  raise "#{label}: full-width sentinels are not on one current screen row" unless row&.include?("WIDTH_END")
  end_column = row.index("WIDTH_END") + "WIDTH_END".length
  raise "#{label}: composer did not reach near the right terminal edge" if end_column < snapshot[:width] - 12
end

def screen_snapshot_text(snapshot)
  snapshot[:rows].each_with_index.map { |row, index| format("%02d %s", index + 1, row.rstrip) }.join("\n")
end

def wait_for_screen(label, state, child, seconds: 8.0)
  deadline = monotonic + seconds
  loop do
    snapshot = current_screen(state)
    return snapshot if yield(snapshot)
    raise "editor exited before #{label}" if child && !child_alive?(child)
    raise "timeout waiting for #{label}" if monotonic >= deadline
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

def resize_pty(reader, state, child, width:, height:)
  state[:mutex].synchronize do
    reader.winsize = [height, width]
    state[:width] = width
    state[:height] = height
    state[:screen].resize(width, height)
  end
  Process.kill("WINCH", child[:pid]) if child_alive?(child)
end

def send_mouse(writer, button, x, y, terminator)
  key(writer, "\e[<#{button};#{x + 1};#{y + 1}#{terminator}")
end

def expand_chat_panel(writer, state, child)
  before = wait_for_screen("Chat pane divider", state, child) do |snapshot|
    !chat_separator_index(snapshot).nil?
  end
  original = chat_separator_index(before) || raise("Chat divider vanished before drag")
  target = [original - 8, 2].max
  return before if target >= original

  x = [[before[:width] / 2, 4].max, before[:width] - 1].min
  send_mouse(writer, 0, x, original, "M")
  sleep 0.05
  send_mouse(writer, 32, x, target, "M")
  sleep 0.05
  send_mouse(writer, 0, x, target, "m")
  wait_for_screen("enlarged Chat pane", state, child) do |snapshot|
    (current = chat_separator_index(snapshot)) && current <= target + 1
  end
end

def open_palette(writer)
  key(writer, F1)
  sleep 0.04
end

def run_command(writer, command)
  open_palette(writer)
  type_text(writer, ":#{command}")
  key(writer, ENTER)
end

def discover_action(writer, state, child, label)
  open_palette(writer)
  type_text(writer, label)
  wait_for_screen("F1 discovery result #{label.inspect}", state, child) do |snapshot|
    screen_contains?(snapshot, label)
  end
  key(writer, ENTER)
end

def wait_for_child_exit(child, seconds: 8.0)
  deadline = monotonic + seconds
  while child_alive?(child)
    raise "timeout waiting for orderly editor quit" if monotonic >= deadline
    sleep 0.02
  end
end

def orderly_quit(writer, state, child)
  run_command(writer, "quit")
  snapshot = wait_for_screen("quit transition", state, child, seconds: 3.0) do |current|
    !child_alive?(child) || screen_contains?(current, "Quit editor — review file")
  end
  return unless child_alive?(child)

  require_screen!(snapshot, ["[Cancel]"], "reviewed quit default")
  # Cancel -> Discard remains a safe fallback if the app asks despite the
  # exact-buffer save performed before orderly quit.
  key(writer, SHIFT_TAB)
  selected = wait_for_screen("explicit Discard choice", state, child) do |current|
    screen_contains?(current, "[Discard]")
  end
  require_screen!(selected, ["Quit editor — review file"], "quit review")
  key(writer, ENTER)
end

def fixture_records(path)
  return [] unless File.file?(path)
  File.readlines(path, chomp: true).map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end.compact
end

def wait_for_fixture_record(label, path, child, seconds: 8.0)
  deadline = monotonic + seconds
  loop do
    records = fixture_records(path)
    return records if yield(records)
    raise "editor exited before #{label}" if child && !child_alive?(child)
    raise "timeout waiting for fixture evidence #{label}" if monotonic >= deadline
    sleep 0.02
  end
end

def pty_oracle_self_check!
  width = 112
  height = 18
  screen = PtyScreen.new(width, height)
  screen.feed("\e[?1049h\e[>5u\e[2J\e[1;1HAdamantine\e[8;1H#{'─' * 2}┴#{'─' * (width - 3)}\e[9;1HChat  Log\e[10;1HWIDTH_BEGIN#{'x' * 85}WIDTH_END\e[18;1HFooter")
  good = {
    rows: screen.rows,
    width: width,
    height: height,
  }
  require_screen!(good, ["Adamantine"], "VT self-check header")
  require_screen!(good, ["Chat", "Log"], "VT self-check switcher", bottom: true)
  raise "VT self-check failed: footer leaked into Chat panel rows" if bottom_contains?(good, "Footer")
  wide_row = bottom_rows(good).find { |row| row.include?("WIDTH_BEGIN") }
  raise "VT self-check failed: full-width row sentinels split" unless wide_row&.include?("WIDTH_END")
  wide_end = wide_row.index("WIDTH_END") + "WIDTH_END".length
  raise "VT self-check failed: sentinel did not reach near the right edge" if wide_end < width - 12

  wrong = PtyScreen.new(width, height)
  wrong.feed("\e[?1049h\e[>5u\e[2J\e[1;1HAdamantine Chat Log WIDTH_BEGIN#{'x' * 85}WIDTH_END")
  wrong_snapshot = {rows: wrong.rows, width: width, height: height}
  begin
    require_screen!(wrong_snapshot, ["WIDTH_BEGIN", "WIDTH_END"], "seeded wrong screen", bottom: true)
    raise "VT self-check failed: top-only decoy passed the bottom-panel oracle"
  rescue RuntimeError => error
    raise unless error.message.include?("missing current-screen text")
  end

  unicode = PtyScreen.new(24, 2)
  unicode.feed("\e[1;1Hλ 雪")
  raise "VT self-check failed: supported Unicode fixture glyphs" unless unicode.include?("λ 雪")
  puts "PTY screen-oracle self-checks: PASS (seeded top-only decoy rejected)"
end

def launch_smoke(binary, fixture_mode:, timeout_seconds:)
  temp_root = Dir.mktmpdir("adamantine-chat-smoke-")
  root = File.realpath(temp_root)
  project = File.join(root, "project")
  state_home = File.join(root, "state")
  source = File.join(project, "main.cr")
  fixture_log = File.join(root, "fixture.jsonl")
  FileUtils.mkdir_p(project, mode: 0o700)
  Dir.mkdir(state_home, 0o700)
  source_lines = ["puts \"DISK_CHAT_SENTINEL\""] + (2..22).map { |line| "puts \"SOURCE_LINE_#{line}\"" } + ["puts \"EDITOR_BOTTOM_SENTINEL\""]
  original_disk_text = source_lines.join("\n") + "\n"
  File.write(source, original_disk_text)
  disk_digest = Digest::SHA256.hexdigest(original_disk_text)

  env = {
    "TERM" => "xterm-256color",
    "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"),
    "LANG" => ENV.fetch("LANG", "C.UTF-8"),
    "HOME" => state_home,
    "XDG_CONFIG_HOME" => File.join(state_home, "config"),
    "XDG_CACHE_HOME" => File.join(state_home, "cache"),
    "ADAMANTINE_SESSION" => "0",
    "ADAMANTINE_RECOVERY" => "0",
    "ADAMANTINE_STATE_HOME" => state_home,
    "XDG_STATE_HOME" => state_home,
  }
  argv = fixture_mode ? [binary, project, fixture_log] : [binary, project, "--no-lsp"]
  child = nil
  reader = nil
  slave = nil
  drain = nil
  output_state = {
    mutex: Mutex.new,
    output: +"".b,
    screen: PtyScreen.new(WIDTH, HEIGHT),
    width: WIDTH,
    height: HEIGHT,
    screen_error: nil,
    drain_error: nil,
    drain_eof: false,
    drain_complete: false,
  }
  passed = false

  begin
    Timeout.timeout(timeout_seconds) do
      reader, slave = PTY.open
      reader.winsize = [HEIGHT, WIDTH]
      child_pid = Process.spawn(env, *argv, in: slave, out: slave, err: slave, unsetenv_others: true)
      child = {pid: child_pid, reaped: false, status: nil}
      drain = Thread.new do
        begin
          loop do
            chunk = reader.readpartial(65_536)
            output_state[:mutex].synchronize do
              output_state[:output] << chunk.b
              overflow = output_state[:output].bytesize - 65_536
              output_state[:output].slice!(0, overflow) if overflow.positive?
              unless output_state[:screen_error]
                begin
                  output_state[:screen].feed(chunk)
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
              output_state[:drain_eof] = true
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

      wait_for_screen("raw terminal readiness", output_state, child) do |snapshot|
        snapshot[:revision].positive? && snapshot[:alternate_screen] && snapshot[:kitty_keyboard] &&
          screen_contains?(snapshot, "Adamantine") && !slave.echo?
      end
      raise "PTY readiness did not leave terminal echo disabled" if slave.echo?
      slave.close
      slave = nil

      run_command(reader, "open #{source}")
      wait_for_screen("source file opened", output_state, child) do |snapshot|
        screen_contains?(snapshot, "DISK_CHAT_SENTINEL")
      end

      buffer_marker = fixture_mode ? "# CHAT_UNSAVED_READ_MARKER\n" : "# CHAT_UNSAVED_BUFFER_MARKER\n"
      paste_text(reader, buffer_marker)
      wait_for_screen("unsaved fixture text in editor", output_state, child) do |snapshot|
        screen_contains?(snapshot, buffer_marker.lines.first.delete_prefix("# ").strip)
      end
      expected_buffer_text = buffer_marker + original_disk_text
      raise "opening and marking the editor buffer changed disk" unless Digest::SHA256.file(source).hexdigest == disk_digest

      # F1 is exercised as a physical key; the action name must be discoverable.
      discover_action(reader, output_state, child, "Focus Chat")
      panel = wait_for_screen("focused chat composer", output_state, child) do |snapshot|
        bottom_contains?(snapshot, "Chat") && bottom_contains?(snapshot, "Enter send")
      end
      require_screen!(panel, ["Chat", "Log"], "Chat/Log switcher", bottom: true)
      panel = expand_chat_panel(reader, output_state, child)
      original_chat_separator = chat_separator_index(panel) || raise("Chat divider missing after expansion")

      # These editor-global defaults must not escape a focused Chat composer.
      key(reader, CTRL_S)
      key(reader, CTRL_W)
      isolated = wait_for_screen("Chat-focused editor command isolation", output_state, child) do |snapshot|
        bottom_contains?(snapshot, "Chat") && screen_contains?(snapshot, "DISK_CHAT_SENTINEL")
      end
      raise "Chat-focused Ctrl+W opened the editor close review" if
        screen_contains?(isolated, "Close file") || screen_contains?(isolated, "Save changes before closing?")
      require_screen!(isolated, [buffer_marker.lines.first.delete_prefix("# ").strip],
        "unsaved editor buffer while Chat owns input")
      raise "Chat-focused Ctrl+S saved the editor buffer" unless Digest::SHA256.file(source).hexdigest == disk_digest

      if fixture_mode
        fixture_chat_flow(reader, output_state, child, fixture_log)
      else
        production_chat_flow(reader, output_state, child, source, disk_digest, original_chat_separator)
      end

      # Both paths must retain the same active editor and leave disk untouched.
      current = current_screen(output_state)
      require_screen!(current, ["CHAT_UNSAVED_READ_MARKER"], "real editor focus return") if fixture_mode
      if fixture_mode
        key(reader, F3)
        key(reader, CTRL_W)
        fixture_f3_review = wait_for_screen("fixture F3 editor-focus oracle", output_state, child) do |snapshot|
          close_review_visible?(snapshot)
        end
        require_screen!(fixture_f3_review, ["main.cr"], "fixture F3 editor-focus close review target")
        key(reader, ESCAPE)
        wait_for_screen("fixture F3 focus probe cancellation", output_state, child) do |snapshot|
          !close_review_visible?(snapshot) && screen_contains?(snapshot, "CHAT_UNSAVED_READ_MARKER")
        end
      end
      editor = wait_for_screen("final editor focus", output_state, child) do |snapshot|
        snapshot[:rows].first([snapshot[:height] - 4, 1].max).any? { |row| row.include?("DISK_CHAT_SENTINEL") }
      end
      require_screen!(editor, ["DISK_CHAT_SENTINEL"], "final editor focus")
      raise "Chat-focused commands changed the on-disk document" unless Digest::SHA256.file(source).hexdigest == disk_digest
      key(reader, CTRL_S)
      save_deadline = monotonic + 5.0
      sleep 0.02 while File.binread(source) != expected_buffer_text && monotonic < save_deadline
      raise "editor save did not match the exact seeded buffer" unless File.binread(source) == expected_buffer_text
      expected_digest = Digest::SHA256.hexdigest(expected_buffer_text)
      raise "saved source bytes do not match the exact seeded buffer" unless Digest::SHA256.file(source).hexdigest == expected_digest

      orderly_quit(reader, output_state, child)
      wait_for_child_exit(child)
      raise "editor exited unsuccessfully: #{child[:status].inspect}" unless child[:status]&.success?
      child = nil
      drain.join(1)
      raise "PTY output drain did not complete" unless output_state[:drain_complete]
      raise "PTY output drain failed: #{output_state[:drain_error]}" if output_state[:drain_error]
      raise "PTY screen tracker failed closed: #{output_state[:screen_error]}" if output_state[:screen_error]
      passed = true
    end

    result = fixture_mode ? {
      result: "PASS",
      mode: "injected-local-transport",
      real_editor_tool_session: true,
      streaming: true,
      cancellation: true,
      stale_generation_rejection: true,
      navigation_and_evaluation_denied: true,
      orderly_quit: true,
    } : {
      result: "PASS",
      mode: "production-unavailable-transport",
      f1_focus_chat_discovery: true,
      multiline_bracketed_paste: true,
      unavailable_send_retains_draft: true,
      chat_log_status_reachable: true,
      escape_editor_return_draft_retention: true,
      f3_editor_return_focus_oracle: true,
      editor_focus_handoff_draft_retention: true,
      hide_show_draft_retention: true,
      chat_focused_save_close_isolation: true,
      exact_seeded_buffer_after_editor_save: true,
      f3_editor_return_without_disk_edits: true,
      short_resize_focus_repair: true,
      unicode_narrow_short_resize: true,
      orderly_quit: true,
    }
    puts JSON.generate(result)
  rescue Exception => error
    warn "chat PTY smoke failed: #{error.class}: #{error.message}"
    warn "chat PTY smoke artifacts: #{root}"
    if output_state[:mutex]
      output_state[:mutex].synchronize do
        File.binwrite(File.join(root, "terminal.raw"), output_state[:output])
      end
      begin
        snapshot = current_screen(output_state)
        File.write(File.join(root, "terminal.screen.txt"), screen_snapshot_text(snapshot))
        warn screen_snapshot_text(snapshot).lines.last(14).join
      rescue StandardError => screen_error
        warn "current-screen snapshot unavailable: #{screen_error.message}"
      end
    end
    raise
  ensure
    if child && child_alive?(child)
      begin
        orderly_quit(reader, output_state, child) if reader
        deadline = monotonic + 2.0
        sleep 0.02 while child_alive?(child) && monotonic < deadline
      rescue StandardError
        nil
      end
      if child_alive?(child)
        signal_owned_child(child, "TERM")
        deadline = monotonic + 1.5
        sleep 0.02 while child_alive?(child) && monotonic < deadline
      end
      if child_alive?(child)
        signal_owned_child(child, "KILL")
        deadline = monotonic + 1.5
        sleep 0.02 while child_alive?(child) && monotonic < deadline
      end
    end
    drain&.join(1)
    reader&.close rescue nil
    slave&.close rescue nil
    FileUtils.remove_entry(root) if passed && File.directory?(root)
  end
end

def production_chat_flow(writer, state, child, source, disk_digest, original_chat_separator)
  # A long single-line sentinel proves the composer spans the bottom width:
  # both ends stay on one current screen row at 112 columns.
  code = "WIDTH_BEGIN#{'x' * 85}WIDTH_END\nif true\n  puts \"λ CHAT_PASTE 雪\"\nend # MULTILINE_END_SENTINEL"
  paste_text(writer, code)
  key(writer, SHIFT_ENTER)
  type_text(writer, "SHIFT_ENTER_MARKER")
  key(writer, ALT_ENTER)
  type_text(writer, "ALT_ENTER_MARKER λ雪😀e\u0301")
  draft = wait_for_screen("pasted multiline draft tail", state, child) do |snapshot|
    bottom_contains?(snapshot, "SHIFT_ENTER_MARKER") && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
  end
  draft_lines = ["WIDTH_BEGIN", "if true", "puts \"λ CHAT_PASTE 雪\"", "MULTILINE_END_SENTINEL",
    "SHIFT_ENTER_MARKER", "ALT_ENTER_MARKER"]
  if draft_lines.all? { |line| bottom_contains?(draft, line) }
    require_distinct_screen_rows!(draft, draft_lines, "full multiline draft viewport", bottom: true)
    require_full_width_sentinel!(draft, "full multiline draft viewport")
  else
    require_distinct_screen_rows!(draft, ["SHIFT_ENTER_MARKER", "ALT_ENTER_MARKER"],
      "multiline draft tail", bottom: true)

    # If the bounded composer viewport clips part of the draft, move the caret
    # through it and inspect each live screen position. The full-width sentinel
    # and every pasted line remain current-screen assertions, never scrollback.
    move_cursor(writer, CURSOR_UP, 5)
    first_lines = wait_for_screen("multiline draft first lines", state, child) do |snapshot|
      bottom_contains?(snapshot, "WIDTH_BEGIN") && bottom_contains?(snapshot, "if true")
    end
    require_full_width_sentinel!(first_lines, "multiline paste first viewport")
    require_distinct_screen_rows!(first_lines, ["WIDTH_BEGIN", "if true"],
      "multiline paste first viewport", bottom: true)

    move_cursor(writer, CURSOR_DOWN, 3)
    middle_lines = wait_for_screen("multiline draft middle lines", state, child) do |snapshot|
      bottom_contains?(snapshot, "puts \"λ CHAT_PASTE 雪\"") && bottom_contains?(snapshot, "MULTILINE_END_SENTINEL")
    end
    require_distinct_screen_rows!(middle_lines, ["puts \"λ CHAT_PASTE 雪\"", "MULTILINE_END_SENTINEL"],
      "multiline paste middle viewport", bottom: true)
    move_cursor(writer, CURSOR_DOWN, 2)
    last_lines = wait_for_screen("multiline draft final lines", state, child) do |snapshot|
      bottom_contains?(snapshot, "SHIFT_ENTER_MARKER") && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
    end
    require_distinct_screen_rows!(last_lines, ["SHIFT_ENTER_MARKER", "ALT_ENTER_MARKER"],
      "Shift+Enter and Alt+Enter fallback viewport", bottom: true)
  end

  key(writer, ENTER)
  unavailable = wait_for_screen("honest unavailable send", state, child) do |snapshot|
    screen_contains?(snapshot, "No model connected; draft retained.")
  end
  require_screen!(unavailable, ["SHIFT_ENTER_MARKER", "ALT_ENTER_MARKER"],
    "unavailable Send draft tail retention", bottom: true)
  raise "unavailable Send synthesized an assistant reply" if screen_contains?(unavailable, "CHAT_SYNTHETIC_RESPONSE")
  raise "unavailable Send presented an unsent draft as a chat message" if
    bottom_rows(unavailable).any? { |row| row.include?("You:") || row.include?("Assistant:") }
  if draft_lines.all? { |line| bottom_contains?(unavailable, line) }
    require_distinct_screen_rows!(unavailable, draft_lines,
      "unavailable Send full draft retention", bottom: true)
  else
    move_cursor(writer, CURSOR_UP, 5)
    unavailable_first = wait_for_screen("unavailable Send retained draft head", state, child) do |snapshot|
      screen_contains?(snapshot, "No model connected; draft retained.") &&
        bottom_contains?(snapshot, "WIDTH_BEGIN") && bottom_contains?(snapshot, "if true")
    end
    require_distinct_screen_rows!(unavailable_first, ["WIDTH_BEGIN", "if true"],
      "unavailable Send draft head retention", bottom: true)
    move_cursor(writer, CURSOR_DOWN, 5)
    unavailable_tail = wait_for_screen("unavailable Send retained draft tail", state, child) do |snapshot|
      screen_contains?(snapshot, "No model connected; draft retained.") &&
        bottom_contains?(snapshot, "SHIFT_ENTER_MARKER") && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
    end
    require_distinct_screen_rows!(unavailable_tail, ["SHIFT_ENTER_MARKER", "ALT_ENTER_MARKER"],
      "unavailable Send draft tail retention", bottom: true)
  end

  # Escape returns focus to the editor without hiding or clearing the draft.
  # Ctrl+W is a focus oracle here: the unsaved marker must open the real close
  # review, which Escape then cancels before the Chat workflow resumes.
  key(writer, ESCAPE)
  wait_for_screen("Escape editor handoff retains draft", state, child) do |snapshot|
    bottom_contains?(snapshot, "ALT_ENTER_MARKER") && screen_contains?(snapshot, "DISK_CHAT_SENTINEL")
  end
  key(writer, CTRL_W)
  escape_close_review = wait_for_screen("Escape handed focus to editor", state, child) do |snapshot|
    close_review_visible?(snapshot)
  end
  require_close_review!(escape_close_review, "Escape editor-focus close review")
  key(writer, ESCAPE)
  wait_for_screen("Escape closes focus probe without losing draft", state, child) do |snapshot|
    !close_review_visible?(snapshot) && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
  end
  raise "Escape focus probe changed disk" unless Digest::SHA256.file(source).hexdigest == disk_digest
  key(writer, CTRL_G)
  wait_for_screen("Chat focus reacquisition after Escape", state, child) do |snapshot|
    bottom_contains?(snapshot, "Chat") && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
  end

  # F3 is checked while Chat owns focus, not by looking for editor text that
  # remains painted behind the bottom panel.
  key(writer, F3)
  key(writer, CTRL_W)
  f3_close_review = wait_for_screen("F3 editor focus handoff", state, child) do |snapshot|
    close_review_visible?(snapshot)
  end
  require_close_review!(f3_close_review, "F3 editor-focus close review")
  key(writer, ESCAPE)
  wait_for_screen("F3 focus probe cancellation", state, child) do |snapshot|
    !close_review_visible?(snapshot) && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
  end
  raise "F3 focus probe changed disk" unless Digest::SHA256.file(source).hexdigest == disk_digest
  key(writer, CTRL_G)
  wait_for_screen("Chat focus reacquisition after F3", state, child) do |snapshot|
    bottom_contains?(snapshot, "Chat") && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
  end

  # The switcher is tested against the live status log, not scrollback bytes.
  key(writer, CTRL_SHIFT_G)
  log_view = wait_for_screen("Chat/Log switch to status log", state, child) do |snapshot|
    bottom_contains?(snapshot, "Log") && bottom_contains?(snapshot, "Tip:")
  end
  require_screen!(log_view, ["Tip:"], "reachable current status log", bottom: true)
  key(writer, CTRL_SHIFT_G)
  chat_view = wait_for_screen("Chat/Log switch back to Chat", state, child) do |snapshot|
    bottom_contains?(snapshot, "Chat") && bottom_contains?(snapshot, "SHIFT_ENTER_MARKER")
  end

  # A lower source row is below the chat viewport, but appears when the
  # bottom surface is hidden. This distinguishes actual panel visibility from
  # a focus-only round trip.
  raise "bottom editor sentinel unexpectedly visible with Chat open" if screen_contains?(chat_view, "EDITOR_BOTTOM_SENTINEL")
  discover_action(writer, state, child, "Toggle bottom panel")
  hidden = wait_for_screen("hidden bottom panel restores editor height", state, child) do |snapshot|
    screen_contains?(snapshot, "EDITOR_BOTTOM_SENTINEL") &&
      !bottom_contains?(snapshot, "Enter send")
  end
  require_screen!(hidden, ["EDITOR_BOTTOM_SENTINEL", "DISK_CHAT_SENTINEL"], "hidden panel editor viewport")

  # The direct Chat route reveals and focuses the bottom panel again. The
  # long draft must survive the actual hide/show transition.
  key(writer, CTRL_G)
  after_focus = wait_for_screen("Ctrl+G Chat focus reacquisition", state, child) do |snapshot|
    bottom_contains?(snapshot, "Chat") && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
  end
  restored_separator = chat_separator_index(after_focus)
  raise "hide/show did not preserve the dragged Chat split ratio" unless restored_separator == original_chat_separator
  require_screen!(after_focus, ["WIDTH_BEGIN", "SHIFT_ENTER_MARKER", "ALT_ENTER_MARKER"],
    "Chat draft after hide/show", bottom: true)
  raise "showing Chat did not restore its bounded editor viewport" if screen_contains?(after_focus, "EDITOR_BOTTOM_SENTINEL")

  # First isolate narrow-width Unicode rendering at a normal height. This
  # checks the full draft viewport without conflating width with clipping.
  resize_pty(writer, state, child, width: 64, height: 30)
  narrow = wait_for_screen("narrow Unicode chat resize", state, child) do |snapshot|
    bottom_contains?(snapshot, "Chat") && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
  end
  require_screen!(narrow, ["λ", "雪", "😀", "e\u0301"], "Unicode content after narrow resize", bottom: true)

  # Keep a genuinely short chat viewport as a separate reachability probe.
  # The existing end-of-draft caret must keep the final line visible as soon
  # as resize is handled; no input may be needed to repair the viewport.
  resize_pty(writer, state, child, width: 64, height: 16)
  short_tail = wait_for_screen("short narrow viewport immediately retains draft tail", state, child, seconds: 6.0) do |snapshot|
    bottom_contains?(snapshot, "Chat") && bottom_contains?(snapshot, "ALT_ENTER_MARKER")
  end
  tail_row = bottom_rows(short_tail).find { |row| row.include?("ALT_ENTER_MARKER") }
  raise "short narrow viewport split the Unicode draft tail across rows" unless
    tail_row && ["λ", "雪", "😀", "e\u0301"].all? { |glyph| tail_row.include?(glyph) }

  # A short viewport need not show all six lines simultaneously. Verify that
  # the same focused composer can scroll to earlier lines, then return to its
  # end caret, using only current-screen assertions at each position.
  move_cursor(writer, CURSOR_UP, 5)
  short_middle = wait_for_screen("short narrow viewport can reach earlier draft lines", state, child) do |snapshot|
    bottom_contains?(snapshot, "puts \"λ CHAT_PASTE 雪\"") && bottom_contains?(snapshot, "MULTILINE_END_SENTINEL")
  end
  require_distinct_screen_rows!(short_middle, ["puts \"λ CHAT_PASTE 雪\"", "MULTILINE_END_SENTINEL"],
    "short narrow intermediate draft lines", bottom: true)
  move_cursor(writer, CURSOR_DOWN, 5)
  wait_for_screen("short narrow viewport returns to draft tail", state, child) do |snapshot|
    bottom_contains?(snapshot, "ALT_ENTER_MARKER")
  end

  resize_pty(writer, state, child, width: 40, height: 10)
  short = wait_for_screen("short chat viewport repair", state, child, seconds: 6.0) do |snapshot|
    chat_separator_index(snapshot).nil? && screen_contains?(snapshot, "CHAT_UNSAVED") &&
      screen_contains?(snapshot, "main.cr*")
  end
  raise "short resize left the bottom chat separator visible" if chat_separator_index(short)
  # Ctrl+W is safe here because the expected editor focus opens the existing
  # confirmation modal; Escape cancels it, proving resize repaired focus
  # without closing a tab or touching the unsaved buffer.
  key(writer, CTRL_W)
  close_review = wait_for_screen("short-resize editor focus repair", state, child, seconds: 5.0) do |snapshot|
    close_review_visible?(snapshot)
  end
  require_close_review!(close_review, "short-resize close review")
  key(writer, ESCAPE)
  repaired = wait_for_screen("short-resize close review cancellation", state, child) do |snapshot|
    chat_separator_index(snapshot).nil? && !close_review_visible?(snapshot) &&
      screen_contains?(snapshot, "CHAT_UNSAVED") && screen_contains?(snapshot, "main.cr*")
  end
  raise "short-resize focus probe changed disk" unless Digest::SHA256.file(source).hexdigest == disk_digest

  resize_pty(writer, state, child, width: WIDTH, height: HEIGHT)
  key(writer, F3)
  editor = wait_for_screen("F3 editor return", state, child) do |snapshot|
    snapshot[:rows].first([snapshot[:height] - 4, 1].max).any? { |row| row.include?("DISK_CHAT_SENTINEL") }
  end
  require_screen!(editor, ["DISK_CHAT_SENTINEL"], "F3 editor return")
  raise "F3 or Chat input changed the source file" unless Digest::SHA256.file(source).hexdigest == disk_digest
  repaired
end

def fixture_chat_flow(writer, state, child, fixture_log)
  paste_text(writer, "READ_UNSAVED")
  key(writer, ENTER)
  stream = wait_for_screen("fixture read and streamed response", state, child) do |snapshot|
    screen_contains?(snapshot, "FIXTURE_READ_UNSAVED_OK")
  end
  require_screen!(stream, ["FIXTURE_READ_UNSAVED_OK"], "streaming fixture delta", bottom: true)

  records = wait_for_fixture_record("App-owner ReadEditor and guard results", fixture_log, child) do |items|
    items.any? { |item| item["type"] == "tool_result" && item["call_id"] == "read-unsaved" } &&
      items.any? { |item| item["type"] == "tool_result" && item["call_id"] == "navigate-guard" } &&
      items.any? { |item| item["type"] == "tool_result" && item["call_id"] == "evaluate-guard" }
  end
  first_start = records.find { |item| item["type"] == "start" && item["turn"] == 1 }
  raise "fixture transport did not receive the submitted draft" unless first_start && first_start["request"] == "READ_UNSAVED"
  read_result = records.find { |item| item["type"] == "tool_result" && item["call_id"] == "read-unsaved" }
  raise "ReadEditor did not see fixture unsaved text" unless read_result.to_json.include?("CHAT_UNSAVED_READ_MARKER")
  navigate_result = records.find { |item| item["type"] == "tool_result" && item["call_id"] == "navigate-guard" }
  raise "Navigate capability was not denied" unless navigate_result["status"] == "denied"
  evaluate_result = records.find { |item| item["type"] == "tool_result" && item["call_id"] == "evaluate-guard" }
  raise "unexpected evaluation tool was admitted" unless evaluate_result["status"] == "invalid_request"

  # Explicit cancellation is independently discoverable while Chat owns
  # focus. The old callback remains captured so the next conversation can
  # prove stale-generation fencing against a real follow-up turn.
  discover_action(writer, state, child, "Cancel chat request")
  cancelled = wait_for_screen("explicit fixture cancellation status", state, child) do |snapshot|
    bottom_contains?(snapshot, "Request cancelled.")
  end
  require_screen!(cancelled, ["FIXTURE_READ_UNSAVED_OK"], "canceled fixture partial response", bottom: true)
  cancel = wait_for_fixture_record("canceled prior fixture turn", fixture_log, child) do |items|
    items.any? { |item| item["type"] == "cancel" }
  end
  raise "fixture handle cancellation was not recorded" unless cancel.any? { |item| item["type"] == "cancel" }

  discover_action(writer, state, child, "New conversation")

  key(writer, CTRL_G)
  wait_for_screen("new-conversation composer focus", state, child) do |snapshot|
    bottom_contains?(snapshot, "Chat") && bottom_contains?(snapshot, "Enter send")
  end
  paste_text(writer, "CURRENT_GENERATION")
  key(writer, ENTER)
  current = wait_for_screen("current-generation fixture delta", state, child) do |snapshot|
    screen_contains?(snapshot, "CURRENT_GENERATION_MARKER")
  end
  raise "stale generation delta reached the current conversation" if screen_contains?(current, "STALE_GENERATION_MARKER")
  records = wait_for_fixture_record("fixture stale-event emission", fixture_log, child) do |items|
    items.any? { |item| item["type"] == "emit" && item["text"] == "STALE_GENERATION_MARKER" }
  end
  raise "fixture did not emit the stale control event" unless records.any? { |item| item["type"] == "emit" && item["text"] == "STALE_GENERATION_MARKER" }
  second_start = records.find { |item| item["type"] == "start" && item["turn"] == 2 }
  raise "new conversation did not send its current draft" unless second_start && second_start["request"] == "CURRENT_GENERATION"
end

if options[:self_check]
  pty_oracle_self_check!
  exit 0
end

launch_smoke(binary, fixture_mode: fixture_mode, timeout_seconds: options[:timeout])
