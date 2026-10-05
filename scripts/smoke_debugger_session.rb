#!/usr/bin/env ruby
require "digest"
require "fileutils"
require "io/console"
require "json"
require "optparse"
require "pty"
require "rbconfig"
require "tmpdir"
require "timeout"
require_relative "lib/pty_screen"

# Bounded end-to-end debugger UI smoke. The adapter is a deterministic local
# DAP fixture; /usr/bin/true is only the profile's inert program placeholder.
# No real target, compiler, debugger, user state, or external service is used.

options = {fake_adapter: false, editor_bin: nil, timeout: 45.0, self_check: false,
           dock: "left", dock_explicit: false}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/smoke_debugger_session.rb --fake-adapter --editor-bin PATH [--dock left|bottom]"
  parser.on("--fake-adapter", "Use the in-repository scripted DAP peer (required)") { options[:fake_adapter] = true }
  parser.on("--editor-bin PATH", "Path to a privately built Adamantine executable") { |path| options[:editor_bin] = path }
  parser.on("--dock POSITION", "Debug inspector position: left (default) or bottom") do |position|
    options[:dock] = position
    options[:dock_explicit] = true
  end
  parser.on("--timeout SECONDS", Float, "Overall smoke deadline (default: 45)") { |seconds| options[:timeout] = seconds }
  parser.on("--self-check", "Run only the bounded VT screen-model and dock-oracle checks") { options[:self_check] = true }
  parser.on("-h", "--help") { puts parser; exit 0 }
end.parse!

abort "--fake-adapter is required; real adapters are not supported by this smoke" unless options[:fake_adapter] || options[:self_check]
abort "--editor-bin is required" unless options[:editor_bin] || options[:self_check]
abort "--dock must be left or bottom" unless %w[left bottom].include?(options[:dock])
abort "--timeout must be between 10 and 120 seconds" unless options[:timeout].between?(10.0, 120.0)

binary = options[:self_check] ? nil : File.realpath(options[:editor_bin])
abort "editor binary is not executable: #{binary}" if !options[:self_check] && !(File.file?(binary) && File.executable?(binary))
repo = File.realpath(File.expand_path("..", __dir__))
fixture = File.realpath(File.join(repo, "spec/fixtures/debugger/dap_controller_adapter.rb"))
true_program = File.realpath("/usr/bin/true")

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def validate_drained_output_state!(state)
  state[:mutex].synchronize do
    raise "PTY output drain did not reach EOF" unless state[:drain_eof]
    raise "PTY output drain did not complete" unless state[:drain_complete]
    if state[:drain_error]
      raise "PTY output drain failed: #{state[:drain_error]}"
    end
    if state[:screen_error]
      raise "PTY screen tracker failed closed: #{state[:screen_error]}"
    end
  end
end

def await_drained_output!(drain, state, seconds: 1.0)
  unless drain && drain.join(seconds)
    raise "PTY output drain did not complete within #{seconds} seconds"
  end
  validate_drained_output_state!(state)
end

def pty_screen_self_check!
  prefix = "record = Record (Record)"
  loading = "#{prefix} · Loading"

  whole_row = PtyScreen.new(48, 3)
  whole_row.feed("\e[2J\e[1;1H#{loading}")
  whole_row.feed("\e[1;1H#{prefix}                ")
  row = whole_row.row_containing(prefix)
  raise "VT self-check failed: whole-row repaint" unless row && !row.include?("Loading")

  suffix_row = PtyScreen.new(48, 3)
  suffix_row.feed("\e[2J\e[1;1H#{loading}")
  suffix_row.watch_row(prefix)
  loading_revision = suffix_row.revision
  suffix_row.feed("\e[1;#{prefix.length + 1}H                ")
  row = suffix_row.row_containing(prefix)
  raise "VT self-check failed: suffix repaint" unless row && !row.include?("Loading")
  history = suffix_row.watched_history.select { |revision, _row| revision > loading_revision }
  raise "VT self-check failed: observed Loading-removal transition" unless
    history.any? { |_revision, observed| observed.include?("Loading") } &&
    history.any? { |_revision, observed| !observed.include?("Loading") }

  cursor = PtyScreen.new(12, 2)
  cursor.feed("abcDEF\e[1;4HZ")
  raise "VT self-check failed: cursor addressing" unless cursor.row_containing("abcZEF")
  cursor.feed("\e[1;4H\e[K")
  raise "VT self-check failed: erase-line" unless cursor.row_containing("abc") && !cursor.include?("ZEF")

  resized = PtyScreen.new(12, 2)
  resized.feed("\e[1;1Hbefore-resize")
  resized.resize(6, 2)
  resized.feed("\e[1;1Hafter")
  raise "VT self-check failed: resize reset" unless resized.include?("after") && !resized.include?("before-resize")

  unicode = PtyScreen.new(12, 2)
  unicode.feed("\e[1;1H\xce")
  unicode.feed("\xbb lambda")
  raise "VT self-check failed: split UTF-8 glyph" unless unicode.include?("λ lambda")

  wide = PtyScreen.new(12, 2)
  wide.feed("\e[1;1HA雪Z\e[1;4H!")
  raise "VT self-check failed: wide-glyph suffix repaint" unless wide.row_containing("A雪!") == "A雪!        "

  wide_emoji = PtyScreen.new(12, 2)
  wide_emoji.feed("\e[1;1HA😀Z\e[1;4H!")
  raise "VT self-check failed: wide-emoji suffix repaint" unless wide_emoji.row_containing("A😀!") == "A😀!        "

  combining = PtyScreen.new(12, 2)
  combining.feed("e\xcc\x81x")
  raise "VT self-check failed: combining mark width" unless combining.row_containing("e\u0301x") == "e\u0301x          "

  unsupported_width = PtyScreen.new(12, 2)
  begin
    unsupported_width.feed("\u200d")
    raise "VT self-check failed: unsupported Unicode width was accepted"
  rescue PtyScreen::UnsupportedSequence
    # Unknown width/cluster behavior is outside this deliberately small model.
  end

  truncated_utf8 = PtyScreen.new(12, 2)
  truncated_utf8.feed("\xce")
  begin
    truncated_utf8.finish!
    raise "VT self-check failed: truncated UTF-8 was accepted at EOF"
  rescue PtyScreen::UnsupportedSequence
    # A trailing partial code point at EOF is malformed output, unlike a
    # read chunk split that is completed by a later feed call.
  end

  truncated_terminal = PtyScreen.new(12, 2)
  truncated_terminal.feed("\e[")
  truncated_final_state = {
    mutex: Mutex.new,
    drain_eof: true,
    drain_complete: true,
    drain_error: nil,
    screen_error: nil,
  }
  begin
    truncated_terminal.finish!
  rescue PtyScreen::UnsupportedSequence => error
    truncated_final_state[:screen_error] = error.message
  end
  begin
    validate_drained_output_state!(truncated_final_state)
    raise "VT self-check failed: truncated final terminal sequence was accepted"
  rescue RuntimeError => error
    raise unless error.message.include?("screen tracker failed closed")
  end

  fragmented = PtyScreen.new(12, 2)
  raise "VT self-check failed: alternate screen initially active" if fragmented.alternate_screen?
  raise "VT self-check failed: Kitty keyboard initially enabled" if fragmented.kitty_keyboard_enabled?
  fragmented.feed("\e[?1049h")
  raise "VT self-check failed: alternate-screen enter" unless fragmented.alternate_screen?
  fragmented.feed("\e[>5u")
  raise "VT self-check failed: Kitty keyboard enable" unless fragmented.kitty_keyboard_enabled?
  fragmented.feed("\e[<u")
  raise "VT self-check failed: Kitty keyboard disable" if fragmented.kitty_keyboard_enabled?
  fragmented.feed("\e[?1049l")
  raise "VT self-check failed: alternate-screen leave" if fragmented.alternate_screen?
  fragmented.feed("\e[")
  fragmented.feed("1;1Hfresh")
  raise "VT self-check failed: chunked CSI" unless fragmented.include?("fresh")

  begin
    fragmented.feed("\e[?9999h")
    raise "VT self-check failed: unsupported sequence was accepted"
  rescue PtyScreen::UnsupportedSequence
    # Fail-closed behavior is intentional.
  end
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

def palette(writer, text)
  key(writer, "\e[112;6u") # Ctrl+Shift+P is an alternate F1 palette route.
  type_text(writer, text)
end

def command(writer, text)
  palette(writer, ":#{text}")
  key(writer, "\e[13u")
end

def terminal_text(output)
  output.dup.force_encoding(Encoding::UTF_8).scrub
        .gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
        .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "")
        .gsub("\r", "")
end

def output_snapshot(state)
  state[:mutex].synchronize { state[:output].dup }
end

def output_cursor(state)
  state[:mutex].synchronize { state[:total_bytes] }
end

def output_since(state, cursor)
  state[:mutex].synchronize do
    first_byte = state[:total_bytes] - state[:output].bytesize
    offset = [[cursor - first_byte, 0].max, state[:output].bytesize].min
    # A cursor can land inside a multibyte character when PTY reads split one.
    while offset < state[:output].bytesize && (state[:output].getbyte(offset) & 0xc0) == 0x80
      offset += 1
    end
    state[:output].byteslice(offset..-1) || +""
  end
end

def terminal_output_since(state, cursor)
  terminal_text(output_since(state, cursor))
end

def screen_snapshot(state)
  state[:mutex].synchronize do
    raise "PTY screen tracker failed closed: #{state[:screen_error]}" if state[:screen_error]

    {
      revision: state[:screen].revision,
      alternate_screen: state[:screen].alternate_screen?,
      kitty_keyboard: state[:screen].kitty_keyboard_enabled?,
      rows: state[:screen].rows,
      watched_history: state[:screen].watched_history,
    }
  end
end

def screen_watch_row(state, fragment)
  state[:mutex].synchronize do
    raise "PTY screen tracker failed closed: #{state[:screen_error]}" if state[:screen_error]
    state[:screen].watch_row(fragment)
  end
end

def screen_row(snapshot, fragment)
  snapshot[:rows].reverse.find { |row| row.include?(fragment) }
end

def screen_row_loaded_after?(state, baseline_revision, prefix, status, current_row: nil, row_matcher: nil)
  snapshot = screen_snapshot(state)
  transitions = snapshot[:watched_history].select do |revision, row|
    revision > baseline_revision && row.include?(prefix)
  end
  loading = transitions.find do |_revision, row|
    row.include?(status) && (!row_matcher || row_matcher.call(row))
  end
  current = current_row || screen_row(snapshot, prefix)
  loading && current && snapshot[:revision] > loading[0] && !current.include?(status)
end

def screen_includes?(state, fragment)
  screen_snapshot(state)[:rows].any? { |row| row.include?(fragment) }
end

def screen_row_includes?(state, row_fragment, fragment)
  row = screen_row(screen_snapshot(state), row_fragment)
  row && row.include?(fragment)
end

def screen_revision(state)
  screen_snapshot(state)[:revision]
end

def terminal_cells(row)
  cells = []
  row.scan(/\X/).each do |grapheme|
    cells << grapheme
    cells << "" if PtyScreen::WIDE_CODEPOINTS.include?(grapheme.codepoints.first)
  end
  cells
end

def terminal_cell(cells, column)
  cells.fetch(column, "")
end

def terminal_cell_slice(cells, start, length)
  (cells[start, length] || []).join
end

def editor_viewport_source_row(snapshot, marker)
  rows = snapshot[:rows] || []
  grid = rows.map { |row| terminal_cells(row) }
  return if grid.empty?

  width = grid.map(&:length).max || 0
  status_divider_y = grid.each_index.find do |y|
    horizontal = (2...width).count do |column|
      ["─", "┴", "┼"].include?(terminal_cell(grid[y], column))
    end
    junction = (3...width).any? do |column|
      ["┴", "┼"].include?(terminal_cell(grid[y], column))
    end
    horizontal >= (width * 0.70).to_i && junction
  end
  return unless status_divider_y && status_divider_y.positive?

  # The first shared vertical junction after the activity rail is the Files
  # inspector edge; source text must be to its right, in the editor viewport.
  editor_left = (3...width).find do |column|
    ["┴", "┼"].include?(terminal_cell(grid[status_divider_y], column))
  end
  return unless editor_left

  marker_cells = terminal_cells(marker)
  (1...status_divider_y).reverse_each do |y|
    cells = grid[y]
    marker_start = (editor_left + 1...cells.length).find do |column|
      cells[column, marker_cells.length] == marker_cells
    end
    return rows[y] if marker_start
  end
  nil
end

def rail_label_start?(grid, label, first_letter:)
  letters = label.chars
  grid.each_index.any? do |start|
    letters.each_with_index.all? do |letter, offset|
      expected = offset.zero? ? first_letter : letter.downcase
      cells = grid[start + offset]
      cells && terminal_cell(cells, 0) == expected && terminal_cell(cells, 1) == "│"
    end
  end
end

def active_debug_rail?(grid)
  # The tall activity rail spells Files and Debug vertically. When Debug is
  # selected, Files remains independently present but lowercase/inactive.
  rail_label_start?(grid, "Files", first_letter: "f") &&
    rail_label_start?(grid, "Debug", first_letter: "D")
end

def sidebar_debug_body_rows(snapshot, pane, source_fragment:)
  rows = snapshot[:rows] || []
  grid = rows.map { |row| terminal_cells(row) }
  return if grid.empty? || !active_debug_rail?(grid)

  token = "[#{pane}]"
  header_y = grid.each_index.find do |y|
    next false if y.zero?
    terminal_cell_slice(grid[y], 3, token.length) == token &&
      terminal_cell_slice(grid[y - 1], 2, 5) == "DEBUG" &&
      terminal_cell(grid[y], 1) == "│" && terminal_cell(grid[y - 1], 1) == "│"
  end
  return unless header_y

  title_y = header_y - 1
  width = grid.map(&:length).max || 0
  right_separator = (2...width).find do |column|
    terminal_cell(grid[title_y], column) == "│" && terminal_cell(grid[header_y], column) == "│"
  end
  return unless right_separator

  body_start = header_y + 1
  body_end = body_start
  while body_end < grid.length &&
        terminal_cell(grid[body_end], 1) == "│" &&
        terminal_cell(grid[body_end], right_separator) == "│"
    body_end += 1
  end
  return if body_end == body_start

  body = (body_start...body_end).map do |y|
    left = terminal_cell_slice(grid[y], 2, right_separator - 2).strip
    right = terminal_cell_slice(grid[y], right_separator + 1, width - right_separator - 1)
    {left: left, right: right}
  end
  # Certify a real side-by-side frame: the marker must be in the editor half
  # on a row where the selected Debug inspector also renders content.
  return unless body.any? do |line|
    !line[:left].empty? && line[:right].include?(source_fragment)
  end

  body.map { |line| line[:left] }
end

def bottom_debug_body_rows(snapshot, pane, source_fragment:)
  rows = snapshot[:rows] || []
  grid = rows.map { |row| terminal_cells(row) }
  return if grid.empty? || !active_debug_rail?(grid)

  width = grid.map(&:length).max || 0
  separator_y = grid.each_index.find do |y|
    next false unless terminal_cell(grid[y], 1) == "┼"
    horizontal = (2...width).count do |column|
      ["─", "┴"].include?(terminal_cell(grid[y], column))
    end
    horizontal >= (width * 0.70).to_i
  end
  return unless separator_y && separator_y.positive?

  source_above = (0...separator_y).any? do |y|
    terminal_cell_slice(grid[y], 2, width - 2).include?(source_fragment)
  end
  return unless source_above

  title_y = separator_y + 1
  title_x = (0...width).find do |column|
    terminal_cell_slice(grid[title_y], column, 5) == "DEBUG"
  end
  return unless title_x
  header_y = title_y + 1
  pane_headers = {
    "STACK"       => {label: "STACK",       offset: 1},
    "THREADS"     => {label: "THREADS",     offset: 7},
    "VARIABLES"   => {label: "VARS",        offset: 15},
    "WATCH"       => {label: "WATCH",       offset: 20},
    "BREAKPOINTS" => {label: "BP",          offset: 26},
    "OUTPUT"      => {label: "OUTPUT",      offset: 29},
    "SOURCES"     => {label: "SOURCES",     offset: 36},
  }
  pane_headers.each_value do |entry|
    label_x = title_x + entry[:offset]
    return unless terminal_cell_slice(grid[header_y], label_x, entry[:label].length) == entry[:label]
  end
  selected = pane_headers[pane]
  return unless selected
  marker_x = title_x + selected[:offset] - 1
  return unless terminal_cell(grid[header_y], marker_x) == "▶"

  body_start = header_y + 1
  body_end = body_start
  while body_end < grid.length && terminal_cell(grid[body_end], 1) == "│"
    body_end += 1
  end
  return if body_end == body_start

  (body_start...body_end).map do |y|
    terminal_cell_slice(grid[y], 2, width - 2).strip
  end
end

def debug_dock_body_rows(snapshot, dock, pane, source_fragment:)
  case dock
  when "left"
    sidebar_debug_body_rows(snapshot, pane, source_fragment: source_fragment)
  when "bottom"
    bottom_debug_body_rows(snapshot, pane, source_fragment: source_fragment)
  else
    raise ArgumentError, "unsupported debug dock #{dock.inspect}"
  end
end

def debug_dock_config_json(dock)
  JSON.generate(debug: {dock: dock}) + "\n"
end

def debug_dock_contains_snapshot?(snapshot, dock, pane, fragments, source_fragment:)
  body = debug_dock_body_rows(snapshot, dock, pane, source_fragment: source_fragment)
  return false unless body

  # Preserve the legacy full-screen content assertion for Bottom, while
  # requiring that the match also lies inside the dock bounded by its divider.
  if dock == "bottom"
    fragments.each do |fragment|
      return false unless snapshot[:rows].any? { |row| row.include?(fragment) }
    end
  end
  fragments.all? { |fragment| body.any? { |row| row.include?(fragment) } }
end

def debug_dock_row_contains_snapshot?(snapshot, dock, pane, fragments, source_fragment:)
  body = debug_dock_body_rows(snapshot, dock, pane, source_fragment: source_fragment)
  return false unless body
  return false if dock == "bottom" && fragments.any? do |fragment|
    !snapshot[:rows].any? { |row| row.include?(fragment) }
  end

  body.any? { |row| fragments.all? { |fragment| row.include?(fragment) } }
end

def debug_dock_contains?(state, dock, pane, fragments, source_fragment:)
  debug_dock_contains_snapshot?(screen_snapshot(state), dock, pane, fragments,
    source_fragment: source_fragment)
end

def debug_dock_row_contains?(state, dock, pane, fragments, source_fragment:)
  debug_dock_row_contains_snapshot?(screen_snapshot(state), dock, pane, fragments,
    source_fragment: source_fragment)
end

def record_variable_prefix(dock)
  case dock
  when "left" then "record = Record"
  when "bottom" then "record = Record (Record)"
  else raise ArgumentError, "unsupported debug dock #{dock.inspect}"
  end
end

def record_variable_row_matches?(row, dock)
  prefix = Regexp.escape(record_variable_prefix(dock))
  row.match?(/(?:\A|[^[:alnum:]_])#{prefix}(?=\s|\z)/)
end

def debug_dock_record_row_contains_snapshot?(snapshot, dock, source_fragment:)
  body = debug_dock_body_rows(snapshot, dock, "VARIABLES", source_fragment: source_fragment)
  return false unless body

  if dock == "bottom"
    return false unless snapshot[:rows].any? do |row|
      row.include?(record_variable_prefix(dock))
    end
  end
  body.any? { |row| record_variable_row_matches?(row, dock) }
end

def debug_dock_record_row_contains?(state, dock, source_fragment:)
  debug_dock_record_row_contains_snapshot?(screen_snapshot(state), dock,
    source_fragment: source_fragment)
end

def debug_dock_frame_row_contains_snapshot?(snapshot, dock, pane, frame_name, source_location,
                                            source_fragment:)
  body = debug_dock_body_rows(snapshot, dock, pane, source_fragment: source_fragment)
  return false unless body

  location = Regexp.new("(?:\\A|\\s)#{Regexp.escape(source_location)}(?:\\z|[^0-9])")
  body.any? { |row| row.include?(frame_name) && row.match?(location) }
end

def debug_dock_frame_row_contains_any_location?(state, dock, pane, frame_name, source_locations,
                                                source_fragment:)
  snapshot = screen_snapshot(state)
  source_locations.any? do |location|
    debug_dock_frame_row_contains_snapshot?(snapshot, dock, pane, frame_name, location,
      source_fragment: source_fragment)
  end
end

def synthetic_screen_snapshot(width, height, assignments)
  screen = PtyScreen.new(width, height)
  screen.feed("\e[2J")
  assignments.each do |(row, column), text|
    screen.feed("\e[#{row + 1};#{column + 1}H#{text}")
  end
  {rows: screen.rows}
end

def debug_dock_oracle_self_check!(dock:, dock_explicit:)
  raise "debug dock self-check failed: default route is not Left" unless dock_explicit || dock == "left"
  %w[left bottom].each do |dock|
    parsed = JSON.parse(debug_dock_config_json(dock))
    raise "debug dock self-check failed: private config route" unless parsed.dig("debug", "dock") == dock
  end

  side = {}
  12.times do |row|
    side[[row, 1]] = "│"
    side[[row, 36]] = "│"
    side[[row, 75]] = "│" # A later editor split must not replace the inspector edge.
  end
  "files".chars.each_with_index { |letter, row| side[[row, 0]] = letter }
  "Debug".chars.each_with_index { |letter, offset| side[[offset + 6, 0]] = offset.zero? ? "D" : letter }
  side[[0, 2]] = "DEBUG"
  side[[1, 3]] = "[VARIABLES]"
  side[[2, 2]] = "Locals"
  side[[3, 2]] = "sentinel = 271828"
  side[[3, 37]] = "puts 2"
  side[[4, 2]] = "record = Record (Record)"
  side[[4, 37]] = "puts 3"
  side[[8, 2]] = "value = 31"
  side[[8, 37]] = "puts 4"
  side_snapshot = synthetic_screen_snapshot(112, 14, side)
  raise "debug dock self-check failed: left sidebar" unless
    debug_dock_contains_snapshot?(side_snapshot, "left", "VARIABLES", ["sentinel = 271828"],
      source_fragment: "puts 2")
  raise "debug dock self-check failed: shortened Left Record row" unless
    debug_dock_record_row_contains_snapshot?(side_snapshot, "left", source_fragment: "puts 2")

  ["record = Record2 (Record)", "record = RecordWrong"].each do |wrong_record|
    wrong_left_record = side.dup
    wrong_left_record[[4, 2]] = wrong_record
    wrong_left_record_snapshot = synthetic_screen_snapshot(112, 14, wrong_left_record)
    raise "debug dock self-check failed: Left accepted wrong Record value #{wrong_record.inspect}" if
      debug_dock_record_row_contains_snapshot?(wrong_left_record_snapshot, "left",
        source_fragment: "puts 2")
  end

  wrong_left_pane = side.dup
  wrong_left_pane[[1, 3]] = "[OUTPUT]"
  wrong_left_pane_snapshot = synthetic_screen_snapshot(112, 14, wrong_left_pane)
  raise "debug dock self-check failed: Left accepted Record from the wrong pane" if
    debug_dock_record_row_contains_snapshot?(wrong_left_pane_snapshot, "left",
      source_fragment: "puts 2")

  source_record_decoy = side.dup
  source_record_decoy[[4, 2]] = "other = value"
  source_record_decoy[[4, 37]] = "# SOURCE_MARKER record = Record (Record)"
  source_record_decoy_snapshot = synthetic_screen_snapshot(112, 14, source_record_decoy)
  raise "debug dock self-check failed: source-only Record passed as Variables content" if
    debug_dock_record_row_contains_snapshot?(source_record_decoy_snapshot, "left",
      source_fragment: "puts 2")

  source_only = side.dup
  source_only[[3, 2]] = "Locals"
  source_only[[3, 37]] = "sentinel = 271828; puts 2"
  source_only_snapshot = synthetic_screen_snapshot(112, 14, source_only)
  raise "debug dock self-check failed: source-only value passed" if
    debug_dock_contains_snapshot?(source_only_snapshot, "left", "VARIABLES", ["sentinel = 271828"],
      source_fragment: "puts 2")
  raise "debug dock self-check failed: global source decoy was not present" unless
    source_only_snapshot[:rows].any? { |row| row.include?("sentinel = 271828") }

  no_debug_rail = side.dup
  no_debug_rail.delete([6, 0])
  no_debug_snapshot = synthetic_screen_snapshot(112, 14, no_debug_rail)
  raise "debug dock self-check failed: inactive Debug rail passed" if
    debug_dock_contains_snapshot?(no_debug_snapshot, "left", "VARIABLES", ["sentinel = 271828"],
      source_fragment: "puts 2")

  bottom = {}
  14.times { |row| bottom[[row, 1]] = "│" }
  "files".chars.each_with_index { |letter, row| bottom[[row, 0]] = letter }
  "Debug".chars.each_with_index { |letter, offset| bottom[[offset + 6, 0]] = offset.zero? ? "D" : letter }
  bottom[[2, 2]] = "SOURCE_MARKER"
  bottom[[5, 1]] = "┼"
  110.times { |offset| bottom[[5, offset + 2]] = "─" }
  bottom[[6, 2]] = "DEBUG"
  bottom[[7, 3]] = "STACK THREADS VARS WATCH BP OUTPUT SOURCES"
  bottom[[7, 16]] = "▶" # The wide header identifies the active Variables pane in text.
  bottom[[8, 2]] = "sentinel = 271828"
  bottom[[9, 2]] = "record = Record (Record)"
  bottom_snapshot = synthetic_screen_snapshot(112, 14, bottom)
  raise "debug dock self-check failed: explicit Bottom" unless
    debug_dock_contains_snapshot?(bottom_snapshot, "bottom", "VARIABLES", ["sentinel = 271828"],
      source_fragment: "SOURCE_MARKER")
  raise "debug dock self-check failed: typed Bottom Record row" unless
    debug_dock_record_row_contains_snapshot?(bottom_snapshot, "bottom",
      source_fragment: "SOURCE_MARKER")

  wrong_bottom_record = bottom.dup
  wrong_bottom_record[[9, 2]] = "record = RecordWrong (Record)"
  wrong_bottom_record_snapshot = synthetic_screen_snapshot(112, 14, wrong_bottom_record)
  raise "debug dock self-check failed: Bottom accepted wrong Record value" if
    debug_dock_record_row_contains_snapshot?(wrong_bottom_record_snapshot, "bottom",
      source_fragment: "SOURCE_MARKER")
  raise "debug dock self-check failed: source above bottom panel passed as dock content" if
    debug_dock_contains_snapshot?(bottom_snapshot, "bottom", "VARIABLES", ["SOURCE_MARKER"],
      source_fragment: "SOURCE_MARKER")
  raise "debug dock self-check failed: Bottom accepted as a sidebar" if
    debug_dock_body_rows(bottom_snapshot, "left", "VARIABLES", source_fragment: "SOURCE_MARKER")

  wrong_bottom_pane = bottom.dup
  wrong_bottom_pane[[7, 16]] = " "
  wrong_bottom_pane[[7, 30]] = "▶" # Output is selected, while the payload is a Stack/Variables decoy.
  wrong_bottom_pane[[8, 2]] = "fixture_main · main.cr:12"
  wrong_bottom_pane[[9, 2]] = "sentinel = 271828"
  wrong_bottom_snapshot = synthetic_screen_snapshot(112, 14, wrong_bottom_pane)
  raise "debug dock self-check failed: Bottom accepted Stack text from Output" if
    debug_dock_frame_row_contains_snapshot?(wrong_bottom_snapshot, "bottom", "STACK",
      "fixture_main", "main.cr:12", source_fragment: "SOURCE_MARKER")
  raise "debug dock self-check failed: Bottom accepted Variables text from Output" if
    debug_dock_contains_snapshot?(wrong_bottom_snapshot, "bottom", "VARIABLES", ["sentinel = 271828"],
      source_fragment: "SOURCE_MARKER")
  raise "debug dock self-check failed: Bottom accepted Record from the wrong pane" if
    debug_dock_record_row_contains_snapshot?(wrong_bottom_snapshot, "bottom",
      source_fragment: "SOURCE_MARKER")

  bottom_footer = bottom.dup
  (10...14).each { |row| bottom_footer.delete([row, 1]) }
  bottom_footer[[10, 2]] = "sentinel = 999999"
  bottom_footer_snapshot = synthetic_screen_snapshot(112, 14, bottom_footer)
  raise "debug dock self-check failed: unbounded Bottom footer row passed" if
    debug_dock_contains_snapshot?(bottom_footer_snapshot, "bottom", "VARIABLES", ["sentinel = 999999"],
      source_fragment: "SOURCE_MARKER")

  footer = side.dup
  footer.delete([11, 36])
  footer[[11, 2]] = "sentinel = 999999"
  footer_snapshot = synthetic_screen_snapshot(112, 14, footer)
  raise "debug dock self-check failed: unbounded footer row passed" if
    debug_dock_contains_snapshot?(footer_snapshot, "left", "VARIABLES", ["sentinel = 999999"],
      source_fragment: "puts 2")

  wrong_row = side.dup
  wrong_row[[1, 3]] = "[STACK]"
  wrong_row[[3, 2]] = "fixture_main · main.cr:4"
  wrong_row[[3, 37]] = "main.cr:5 SOURCE_MARKER puts 2"
  wrong_row_snapshot = synthetic_screen_snapshot(112, 14, wrong_row)
  raise "debug dock self-check failed: Stack location from editor passed as inspector content" if
    debug_dock_frame_row_contains_snapshot?(wrong_row_snapshot, "left", "STACK", "fixture_main",
      "main.cr:5", source_fragment: "SOURCE_MARKER")

  matching_stack = wrong_row.dup
  matching_stack[[3, 2]] = "fixture_main · main.cr:5"
  matching_stack[[3, 37]] = "SOURCE_MARKER puts 2"
  matching_stack_snapshot = synthetic_screen_snapshot(112, 14, matching_stack)
  raise "debug dock self-check failed: matching selected Stack row" unless
    debug_dock_frame_row_contains_snapshot?(matching_stack_snapshot, "left", "STACK", "fixture_main",
      "main.cr:5", source_fragment: "SOURCE_MARKER")

  longer_stack_line = matching_stack.dup
  longer_stack_line[[3, 2]] = "fixture_main · main.cr:50"
  longer_stack_snapshot = synthetic_screen_snapshot(112, 14, longer_stack_line)
  raise "debug dock self-check failed: Stack line 50 matched expected line 5" if
    debug_dock_frame_row_contains_snapshot?(longer_stack_snapshot, "left", "STACK", "fixture_main",
      "main.cr:5", source_fragment: "SOURCE_MARKER")

  editor_area = {}
  (1...10).each do |row|
    editor_area[[row, 2]] = "│"
    editor_area[[row, 18]] = "│"
  end
  editor_area[[4, 20]] = "# λ smoke — 雪"
  (2...38).each { |column| editor_area[[10, column]] = "─" }
  editor_area[[10, 2]] = "┴"
  editor_area[[10, 18]] = "┴"
  editor_snapshot = synthetic_screen_snapshot(38, 14, editor_area)
  raise "debug dock self-check failed: bounded editor source marker" unless
    editor_viewport_source_row(editor_snapshot, "# λ smoke — 雪")

  footer_only_source = editor_area.dup
  footer_only_source.delete([4, 20])
  footer_only_source[[13, 20]] = "# λ smoke — 雪"
  footer_only_snapshot = synthetic_screen_snapshot(38, 14, footer_only_source)
  raise "debug dock self-check failed: footer-only Unicode marker passed as source" if
    editor_viewport_source_row(footer_only_snapshot, "# λ smoke — 雪")

  sidebar_only_source = editor_area.dup
  sidebar_only_source.delete([4, 20])
  sidebar_only_source[[4, 4]] = "# λ smoke — 雪"
  sidebar_only_snapshot = synthetic_screen_snapshot(38, 14, sidebar_only_source)
  raise "debug dock self-check failed: sidebar-only Unicode marker passed as source" if
    editor_viewport_source_row(sidebar_only_snapshot, "# λ smoke — 雪")
end

def resize_pty(reader, state, child:, width:, height:)
  state[:mutex].synchronize do
    reader.winsize = [height, width]
    state[:screen].resize(width, height)
  end
  # PTY.open + Process.spawn does not necessarily give the child a controlling
  # terminal/foreground process group, so TIOCSWINSZ alone may not deliver
  # SIGWINCH. Notify only the editor child this smoke spawned.
  Process.kill("WINCH", child[:pid]) if editor_alive?(child)
end

def fixture_records(path)
  return [] unless File.file?(path)
  File.readlines(path, chomp: true).each_with_object([]) do |line, records|
    begin
      records << JSON.parse(line)
    rescue JSON::ParserError
      # The adapter may be writing a record while the smoke polls its log.
    end
  end
end

def adapter_requests(path, command_name = nil)
  fixture_records(path).select do |record|
    record["type"] == "request" && (!command_name || record["command"] == command_name)
  end
end

def fixture_markers(path)
  fixture_records(path).each_with_object([]) do |record, markers|
    markers << record["name"] if record["type"] == "fixture" && record["name"]
  end
end

def fixture_process_pids(path, marker_name)
  fixture_records(path).each_with_object([]) do |record, pids|
    next unless record["type"] == "fixture" && record["name"] == marker_name
    pid = record["pid"]
    pids << pid if pid.is_a?(Integer) && pid.positive?
  end
end

def wait_for(label, seconds: 8.0, child: nil)
  deadline = monotonic + seconds
  until yield
    raise "editor exited before #{label}" if child && !editor_alive?(child)
    raise "timeout waiting for #{label}" if monotonic >= deadline
    sleep 0.02
  end
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

def signal_owned_child(child, signal)
  Process.kill(signal, child[:pid]) if child && !child[:reaped]
rescue Errno::ESRCH
  nil
end

def wait_for_fixture_exits(path, expected_count, seconds: 4.0, child: nil)
  wait_for("fixture process exit markers (#{expected_count})", seconds: seconds, child: child) do
    started = fixture_process_pids(path, "smoke_process_started")
    exited = fixture_process_pids(path, "smoke_process_exited")
    started.size == expected_count && exited.size == expected_count && started == exited
  end
end

def reopen_saved_profile_after_cleanup(writer, output_state, child:, seconds: 8.0)
  deadline = monotonic + seconds
  loop do
    remaining = deadline - monotonic
    raise "timeout waiting for saved launch profile after adapter cleanup" if remaining <= 0

    cursor = output_cursor(output_state)
    key(writer, "\e[15~") # F5 may be refused until Controller cleanup completes.
    begin
      wait_for("saved launch profile", seconds: [remaining, 0.5].min, child: child) do
        terminal_output_since(output_state, cursor).include?("Debug launch profile")
      end
      return
    rescue RuntimeError => error
      raise unless error.message.start_with?("timeout waiting for saved launch profile")
      # While cleanup is pending, F5 only reports the wait; after it clears,
      # the same key opens Review (never Starts) and Enter remains explicit.
    end
  end
end

def send_quit(writer, child)
  return unless editor_alive?(child)
  3.times { key(writer, "\e[27u"); sleep 0.03 }
  command(writer, "quit")
  sleep 0.15
  key(writer, "\e[13u") if editor_alive?(child) # approve the visible Stop transition
end

pty_screen_self_check!
debug_dock_oracle_self_check!(dock: options[:dock], dock_explicit: options[:dock_explicit])
if options[:self_check]
  puts "PTY screen-model self-checks: PASS"
  exit 0
end

tmp_root = Dir.mktmpdir("adamantine-debug-smoke-")
root = File.realpath(tmp_root)
project = File.join(root, "project")
state_home = File.join(root, "state")
config_path = File.join(root, "config.json")
source_path = File.join(project, "main.cr")
adapter_log = File.join(root, "adapter.jsonl")
release_path = File.join(root, "release-disconnect")
FileUtils.mkdir_p(project, mode: 0o700)
Dir.mkdir(state_home, 0o700)
File.write(config_path, debug_dock_config_json(options[:dock]))
source_text = <<~CRYSTAL
  # SOURCE_MARKER sentinel = 271828
  # SOURCE_MARKER record = Record (Record); value = 31
  # SOURCE_MARKER editor-only content
  # λ smoke — 雪 😀
  puts "λ smoke — 雪 😀"
  puts 2
  puts 3
  puts 4
  puts 5
  puts 6
  puts 7
  puts 8
  puts 9
  puts 10
  # λ smoke — 雪 😀
  puts 12
  puts 13
  puts 14
CRYSTAL
source_text << (15..80).map { |number| "puts #{number}\n" }.join
File.write(source_path, source_text)

adapter_mode = "source_checksum,hold_disconnect,process_self_pid,terminate_capability,smoke_process"
adapter_argv = [File.realpath(RbConfig.ruby), fixture, adapter_log, adapter_mode, source_path, release_path]
launch_profile_json = JSON.generate(adapter_argv)
env = {
  "TERM" => "xterm-256color",
  "ADAMANTINE_SESSION" => "0",
  "ADAMANTINE_RECOVERY" => "0",
  "ADAMANTINE_STATE_HOME" => state_home,
  "XDG_STATE_HOME" => state_home,
}

pid = nil
child = nil
reader = nil
slave = nil
drain = nil
output_state = {
  mutex: Mutex.new,
  output: +"".b,
  total_bytes: 0,
  screen: PtyScreen.new(112, 26),
  screen_error: nil,
  drain_eof: false,
  drain_complete: false,
  drain_error: nil,
}
passed = false

begin
  Timeout.timeout(options[:timeout]) do
    reader, slave = PTY.open
    reader.winsize = [26, 112]
    pid = Process.spawn(env, binary, project, "--config", config_path, "--no-lsp",
                       in: slave, out: slave, err: slave)
    child = {pid: pid, reaped: false, status: nil}
    drain = Thread.new do
      begin
        loop do
          chunk = reader.readpartial(65_536)
          output_state[:mutex].synchronize do
            output_state[:output] << chunk.b
            output_state[:total_bytes] += chunk.bytesize
            unless output_state[:screen_error]
              begin
                output_state[:screen].feed(chunk)
              rescue PtyScreen::UnsupportedSequence => error
                output_state[:screen_error] = error.message
              end
            end
            overflow = output_state[:output].bytesize - 1_048_576
            if overflow > 0
              # Do not leave a UTF-8 continuation byte at the ring's start.
              while overflow < output_state[:output].bytesize &&
                    (output_state[:output].getbyte(overflow) & 0xc0) == 0x80
                overflow += 1
              end
              output_state[:output].slice!(0, overflow)
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

    wait_for("raw-terminal editor readiness", seconds: 8, child: child) do
      current = screen_snapshot(output_state)
      current[:revision].positive? && current[:alternate_screen] &&
        current[:kitty_keyboard] &&
        current[:rows].any? { |row| row.include?("Adamantine") } && !slave.echo?
    end
    # Keep the slave open until both the current alternate-screen frame and
    # the no-echo raw-mode handoff are observed. Closing our duplicate does
    # not change the editor's terminal state; it only avoids retaining an
    # extra descriptor during the rest of the smoke.
    slave.close
    slave = nil
    command(reader, "open #{source_path}")
    wait_for("Unicode source opened", child: child) do
      terminal_text(output_snapshot(output_state)).include?("λ smoke")
    end

    # First-use launch review must not start the adapter. The modal also owns
    # F9, so no pre-launch breakpoint may leak into the reviewed session.
    key(reader, "\e[15~") # F5: open launch profile
    wait_for("launch profile modal", child: child) do
      terminal_text(output_snapshot(output_state)).include?("Debug launch profile")
    end
    wait_for("adapter argv field focus", child: child) do
      terminal_text(output_snapshot(output_state)).include?("> Adapter argv JSON")
    end
    key(reader, "\e[20~") # F9 is captured by the modal.
    key(reader, "\e[97;5u") # Ctrl+A replaces the default JSON [] field.
    paste_cursor = output_cursor(output_state)
    paste_text(reader, launch_profile_json)
    wait_for("adapter argv paste processed", child: child) { output_cursor(output_state) > paste_cursor }
    key(reader, "\e[13u")
    wait_for("program field focus", child: child) do
      terminal_text(output_snapshot(output_state)).include?("> Program path")
    end
    paste_text(reader, true_program)
    key(reader, "\e[13u") # cwd is prefilled with the canonical project root.
    wait_for("working directory field focus", child: child) do
      terminal_text(output_snapshot(output_state)).include?("> Working directory")
    end
    key(reader, "\e[13u") # target argv remains the default empty array.
    wait_for("target argv field focus", child: child) do
      terminal_text(output_snapshot(output_state)).include?("> Target argv JSON")
    end
    key(reader, "\e[13u") # advance to the explicit Generic/Stock-Crystal Values selector.
    wait_for("Values selector focus", child: child) do
      terminal_text(output_snapshot(output_state)).include?("> Values: Adapter (default)")
    end
    raise "Values selection started the adapter before review" unless fixture_records(adapter_log).empty?
    key(reader, "\e[13u") # continue from the selector to the explicit launch review.
    wait_for("explicit launch review", child: child) do
      terminal_text(output_snapshot(output_state)).include?("Review launch; Enter starts explicitly")
    end
    raise "adapter started before explicit review confirmation" unless fixture_records(adapter_log).empty?
    key(reader, "\e[20~") # F9 remains captured by the Review modal.
    raise "review modal input started the adapter" unless fixture_records(adapter_log).empty?
    key(reader, "\e[13u") # explicit Start

    wait_for("initialized fake adapter", seconds: 10, child: child) do
      adapter_requests(adapter_log, "initialize").any? &&
        adapter_requests(adapter_log, "configurationDone").any? &&
        adapter_requests(adapter_log, "stackTrace").any?
    end
    requests_before_breakpoint = adapter_requests(adapter_log, "setBreakpoints")
    unless requests_before_breakpoint.all? { |request| request.dig("arguments", "breakpoints") == [] }
      raise "F9 from a launch modal leaked a breakpoint into the started session"
    end
    # Now F9 is a real editor action. Its source/line must reach the adapter.
    key(reader, "\e[20~")
    wait_for("post-launch breakpoint request", child: child) do
      adapter_requests(adapter_log, "setBreakpoints").any? do |request|
        args = request["arguments"] || {}
        source = args["source"] || {}
        source["path"] == File.realpath(source_path) &&
          (args["breakpoints"] || []).any? { |bp| bp["line"] == 1 }
      end
    end

    # Show the actual dock through the modified-key palette path.
    dock_show_revision = screen_revision(output_state)
    command(reader, "debug-panel")
    wait_for("Debug dock and Stack projection", child: child) do
      revision = screen_revision(output_state)
      revision > dock_show_revision && debug_dock_frame_row_contains_any_location?(output_state,
        options[:dock], "STACK", "fixture_main", ["main.cr:12", "main.cr:13"],
        source_fragment: "SOURCE_MARKER")
    end
    # Exercise the focused dock's advertised pane traversal, not only the
    # alternate palette action. Stack -> Threads -> Variables.
    variables_pane_revision = screen_revision(output_state)
    2.times { key(reader, "\t") }
    wait_for("Variables pane focus by Tab", child: child) do
      screen_revision(output_state) > variables_pane_revision &&
        debug_dock_contains?(output_state, options[:dock], "VARIABLES",
          ["Press Enter to load scopes"], source_fragment: "SOURCE_MARKER")
    end
    scopes_screen_revision = screen_revision(output_state)
    key(reader, "\e[13u")
    wait_for("real locals scope and sentinel", seconds: 10, child: child) do
      requests = adapter_requests(adapter_log)
      saw_scopes = requests.any? { |request| request["command"] == "scopes" }
      saw_variables = requests.any? { |request| request["command"] == "variables" }
      screen_revision(output_state) > scopes_screen_revision &&
        saw_scopes && saw_variables && debug_dock_row_contains?(output_state, options[:dock], "VARIABLES",
          ["sentinel", "271828"], source_fragment: "SOURCE_MARKER")
    end
    2.times { key(reader, "\e[B") } # Skip the Locals scope and sentinel to select record.
    record_prefix = record_variable_prefix(options[:dock])
    wait_for("record row in the current Variables inspector", child: child) do
      debug_dock_record_row_contains?(output_state, options[:dock],
        source_fragment: "SOURCE_MARKER")
    end
    screen_watch_row(output_state, record_prefix)
    child_page_baseline = screen_revision(output_state)
    key(reader, "\e[13u")
    wait_for("record child request", seconds: 8, child: child) do
      adapter_requests(adapter_log, "variables").any? do |request|
        request.dig("arguments", "variablesReference") == 701
      end
    end
    wait_for("Loading status cleared from current record row", seconds: 8, child: child) do
      current_rows = debug_dock_body_rows(screen_snapshot(output_state), options[:dock], "VARIABLES",
        source_fragment: "SOURCE_MARKER")
      record_row = current_rows && current_rows.find do |row|
        record_variable_row_matches?(row, options[:dock])
      end
      screen_row_loaded_after?(output_state, child_page_baseline,
        record_prefix, "Loading", current_row: record_row,
        row_matcher: ->(row) { record_variable_row_matches?(row, options[:dock]) }) &&
        record_row && !record_row.include?("Loading")
    end
    # The child can extend just below the visible page at this terminal size;
    # move selection into the returned child row so the smoke proves it is
    # actually projected, not merely present in an adapter response.
    value_revision = screen_revision(output_state)
    key(reader, "\e[B")
    wait_for("record child value", seconds: 8, child: child) do
      screen_revision(output_state) > value_revision &&
        debug_dock_contains?(output_state, options[:dock], "VARIABLES", ["value = 31"],
          source_fragment: "SOURCE_MARKER")
    end

    # Esc hides the dock and leaves the editor/source view visible. The grid
    # does not model cursor styling, so this proves visual return only—not
    # cursor selection or keyboard focus. Neither it nor a narrow resize should
    # stop or disconnect the still-live session.
    disconnect_baseline = fixture_markers(adapter_log).count("disconnect_received")
    editor_return_revision = screen_revision(output_state)
    key(reader, "\e[27u")
    wait_for("editor return with Unicode source visible", child: child) do
      screen_revision(output_state) > editor_return_revision &&
        screen_row_includes?(output_state, "# λ smoke", "λ smoke") &&
        !screen_includes?(output_state, "DEBUG") && !screen_includes?(output_state, "STACK")
    end
    sleep 0.1
    raise "Escape from the dock stopped the target" unless fixture_markers(adapter_log).count("disconnect_received") == disconnect_baseline
    raise "Escape from the dock exited the editor" unless editor_alive?(child)
    resize_cursor = output_cursor(output_state)
    resize_pty(reader, output_state, child: child, width: 38, height: 14)
    wait_for("narrow resize redraw", seconds: 3, child: child) do
      output_cursor(output_state) > resize_cursor &&
        editor_viewport_source_row(screen_snapshot(output_state), "# λ smoke — 雪") &&
        !screen_includes?(output_state, "DEBUG") && !screen_includes?(output_state, "STACK")
    end
    narrow_output = output_since(output_state, resize_cursor)
    File.binwrite(File.join(root, "narrow.raw"), narrow_output)
    narrow_screen = screen_snapshot(output_state)
    narrow_source_row = editor_viewport_source_row(narrow_screen, "# λ smoke — 雪")
    raise "narrow resize lost the visible Unicode source marker" unless narrow_source_row
    raise "narrow resize stopped the editor" unless editor_alive?(child)
    restored_cursor = output_cursor(output_state)
    resize_pty(reader, output_state, child: child, width: 112, height: 26)
    wait_for("wide resize restored Unicode source", child: child) do
      output_cursor(output_state) > restored_cursor &&
        screen_row_includes?(output_state, "# λ smoke", "λ smoke — 雪 😀")
    end

    # Re-show using the same palette fallback, hide again, then use the real
    # Shift+F5 Stop binding. The fixture deliberately withholds disconnect ACK.
    dock_reshow_revision = screen_revision(output_state)
    command(reader, "debug-panel")
    wait_for("dock re-show", child: child) do
      screen_revision(output_state) > dock_reshow_revision &&
        debug_dock_contains?(output_state, options[:dock], "VARIABLES", ["value = 31"],
          source_fragment: "SOURCE_MARKER")
    end
    disconnect_baseline = fixture_markers(adapter_log).count("disconnect_received")
    key(reader, "\e[27u")
    key(reader, "\e[15;2~") # Shift+F5
    wait_for("direct Stop request", child: child) do
      fixture_markers(adapter_log).count("disconnect_received") == disconnect_baseline + 1
    end
    raise "editor exited while adapter disconnect was held" unless editor_alive?(child)
    File.write(release_path, "release\n")
    wait_for("direct Stop cleanup marker", seconds: 7, child: child) do
      fixture_markers(adapter_log).count("disconnect_released") == disconnect_baseline + 1
    end
    wait_for_fixture_exits(adapter_log, 1, child: child)
    FileUtils.rm_f(release_path)

    # Start the saved profile again to exercise Quit's explicit Stop approval
    # and cleanup barrier. This second disconnect is held until the script
    # releases only its own fixture sentinel.
    initialize_baseline = adapter_requests(adapter_log, "initialize").size
    reopen_saved_profile_after_cleanup(reader, output_state, child: child)
    review_cursor = output_cursor(output_state)
    4.times { key(reader, "\e[13u") }
    wait_for("saved Values selector focus", child: child) do
      terminal_output_since(output_state, review_cursor).include?("> Values: Adapter (default)")
    end
    raise "saved Values selection spawned an adapter early" unless adapter_requests(adapter_log, "initialize").size == initialize_baseline
    key(reader, "\e[13u") # Values is the fifth explicit setup step, not Start.
    wait_for("saved profile review", child: child) do
      terminal_output_since(output_state, review_cursor).include?("Review launch; Enter starts explicitly")
    end
    raise "second launch review spawned an adapter early" unless adapter_requests(adapter_log, "initialize").size == initialize_baseline
    key(reader, "\e[13u")
    wait_for("second fake session active", seconds: 10, child: child) do
      adapter_requests(adapter_log, "initialize").size == initialize_baseline + 1 &&
        adapter_requests(adapter_log, "stackTrace").size >= initialize_baseline + 1
    end
    disconnect_baseline = fixture_markers(adapter_log).count("disconnect_received")
    quit_cursor = output_cursor(output_state)
    command(reader, "quit")
    wait_for("Quit Stop-approval modal", child: child) do
      terminal_output_since(output_state, quit_cursor).include?("Stop the active debug target before quit?")
    end
    request_count_before_approval = adapter_requests(adapter_log).size
    key(reader, "\e[20~") # F9 must not escape the transition modal.
    raise "Quit modal leaked F9 into the active target" unless adapter_requests(adapter_log).size == request_count_before_approval
    raise "Quit Stop was requested before explicit approval" unless fixture_markers(adapter_log).count("disconnect_received") == disconnect_baseline
    key(reader, "\e[13u") # approve Stop, do not commit Quit yet
    wait_for("held Quit disconnect", child: child) do
      fixture_markers(adapter_log).count("disconnect_received") == disconnect_baseline + 1
    end
    raise "Quit committed before adapter cleanup completed" unless editor_alive?(child)
    File.write(release_path, "release\n")
    wait_for("Quit disconnect release", seconds: 7, child: child) do
      fixture_markers(adapter_log).count("disconnect_released") == disconnect_baseline + 1
    end
    wait_for("orderly editor Quit", seconds: 8) { !editor_alive?(child) }
    raise "editor exited unsuccessfully: #{child[:status].inspect}" unless child[:status]&.success?
    pid = nil
    child = nil
    wait_for_fixture_exits(adapter_log, 2)
    raise "adapter initialize count did not match the two explicit Starts" unless adapter_requests(adapter_log, "initialize").size == initialize_baseline + 1
    await_drained_output!(drain, output_state, seconds: 1.0)

    passed = true
  end
  puts JSON.generate(
    result: "PASS",
    fake_adapter: true,
    debug_dock: options[:dock],
    explicit_review_start: true,
    modal_input_capture: true,
    breakpoint_route: true,
    stack_and_variables: true,
    stop_and_quit_cleanup: true,
    narrow_unicode_resize: true,
    adapter_cleanup: true
  )
rescue Exception => error
  warn "debugger PTY smoke failed: #{error.class}: #{error.message}"
  warn "debugger PTY smoke artifacts: #{root}"
  File.binwrite(File.join(root, "terminal.raw"), output_snapshot(output_state)) if output_state[:mutex]
  if output_state[:mutex]
    screen_text = output_state[:mutex].synchronize do
      ["revision=#{output_state[:screen].revision}", "error=#{output_state[:screen_error]}", *output_state[:screen].rows].join("\n")
    end
    File.write(File.join(root, "terminal.screen"), screen_text + "\n")
    warn screen_text.lines.last(12).join
  end
  warn terminal_text(output_snapshot(output_state))[-4_000, 4_000] if output_state[:mutex]
  exit 1
ensure
  if child && editor_alive?(child)
    begin
      File.write(release_path, "release\n")
      send_quit(reader, child) if reader
      deadline = monotonic + 3.0
      sleep 0.02 while editor_alive?(child) && monotonic < deadline
    rescue Errno::EIO, IOError
    end
    if editor_alive?(child)
      signal_owned_child(child, "TERM")
      deadline = monotonic + 1.5
      sleep 0.02 while editor_alive?(child) && monotonic < deadline
    end
    if editor_alive?(child)
      signal_owned_child(child, "KILL")
      deadline = monotonic + 1.5
      sleep 0.02 while editor_alive?(child) && monotonic < deadline
    end
  end
  if adapter_log && File.exist?(adapter_log)
    started = fixture_process_pids(adapter_log, "smoke_process_started").size
    exited = fixture_process_pids(adapter_log, "smoke_process_exited").size
    if started > exited
      begin
        wait_for_fixture_exits(adapter_log, started, seconds: 4.0)
      rescue RuntimeError => error
        warn "could not verify fixture cleanup: #{error.message}"
      end
    end
  end
  drain&.join(1)
  reader&.close rescue nil
  slave&.close rescue nil
  FileUtils.remove_entry(root) if passed && File.directory?(root)
end
