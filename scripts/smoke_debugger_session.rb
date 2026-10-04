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

# Bounded end-to-end debugger UI smoke. The adapter is a deterministic local
# DAP fixture; /usr/bin/true is only the profile's inert program placeholder.
# No real target, compiler, debugger, user state, or external service is used.

options = {fake_adapter: false, editor_bin: nil, timeout: 45.0, self_check: false}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/smoke_debugger_session.rb --fake-adapter --editor-bin PATH"
  parser.on("--fake-adapter", "Use the in-repository scripted DAP peer (required)") { options[:fake_adapter] = true }
  parser.on("--editor-bin PATH", "Path to a privately built Adamantine executable") { |path| options[:editor_bin] = path }
  parser.on("--timeout SECONDS", Float, "Overall smoke deadline (default: 45)") { |seconds| options[:timeout] = seconds }
  parser.on("--self-check", "Run only the bounded VT screen-model self-checks") { options[:self_check] = true }
  parser.on("-h", "--help") { puts parser; exit 0 }
end.parse!

abort "--fake-adapter is required; real adapters are not supported by this smoke" unless options[:fake_adapter] || options[:self_check]
abort "--editor-bin is required" unless options[:editor_bin] || options[:self_check]
abort "--timeout must be between 10 and 120 seconds" unless options[:timeout].between?(10.0, 120.0)

binary = options[:self_check] ? nil : File.realpath(options[:editor_bin])
abort "editor binary is not executable: #{binary}" if !options[:self_check] && !(File.file?(binary) && File.executable?(binary))
repo = File.realpath(File.expand_path("..", __dir__))
fixture = File.realpath(File.join(repo, "spec/fixtures/debugger/dap_controller_adapter.rb"))
true_program = File.realpath("/usr/bin/true")

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# A deliberately bounded VT screen model for the app's redraw path. It models
# ASCII plus the exact Unicode glyphs observed in this fixture/UI, including
# known wide glyphs and common combining diacritics. Other Unicode width cases
# fail closed; this is not a general terminal emulator. Any unrecognized
# screen-affecting sequence also fails closed.
class PtyScreen
  class UnsupportedSequence < StandardError; end

  WIDE_CONTINUATION = Object.new.freeze
  WIDE_CODEPOINTS = [0x96ea, 0x1f600].freeze # 雪, 😀
  SINGLE_CODEPOINTS = [
    0x00b7, 0x03bb, 0x2014, 0x2026, 0x2191, 0x2193,
    0x2500, 0x2502, 0x250c, 0x2510, 0x2514, 0x2518,
    0x251c, 0x2524, 0x252c, 0x2534, 0x2588, 0x25b6,
    0x25be, 0x25cf,
  ].freeze

  attr_reader :revision

  def initialize(width, height)
    @width = width
    @height = height
    @cells = blank_grid
    @x = 0
    @y = 0
    @saved_cursor = nil
    @primary_state = nil
    @state = :normal
    @csi = +""
    @osc_escape = false
    @osc_bytes = 0
    @utf8_expected = 0
    @utf8_bytes = []
    @kitty_keyboard_enabled = false
    @revision = 0
  end

  def feed(bytes)
    bytes.each_byte do |byte|
      case @state
      when :normal
        consume_normal(byte)
      when :escape
        consume_escape(byte)
      when :csi
        consume_csi(byte)
      when :osc
        consume_osc(byte)
      end
    end
  end

  def finish!
    unless @utf8_expected.zero? && @state == :normal
      raise UnsupportedSequence, "truncated terminal output sequence"
    end
  end

  def resize(width, height)
    raise ArgumentError, "invalid PTY geometry" unless width.positive? && height.positive?

    @width = width
    @height = height
    @cells = blank_grid
    @x = 0
    @y = 0
    @saved_cursor = nil
    @primary_state = nil
    @revision += 1
    record_all_watched_rows
  end

  def rows
    @cells.map { |row| render_row(row) }
  end

  def alternate_screen?
    !@primary_state.nil?
  end

  def kitty_keyboard_enabled?
    @kitty_keyboard_enabled
  end

  def row_containing(fragment)
    @cells.reverse_each do |row|
      text = render_row(row)
      return text if text.include?(fragment)
    end
    nil
  end

  def include?(fragment)
    !row_containing(fragment).nil?
  end

  def watch_row(fragment)
    @watched_fragment = fragment
    @watched_history = []
    @cells.each_index { |row| record_watched_row(row) }
  end

  def watched_history
    (@watched_history || []).map { |revision, row| [revision, row.dup] }
  end

  private

  def blank_grid
    Array.new(@height) { Array.new(@width, " ") }
  end

  def consume_normal(byte)
    if @utf8_expected.positive?
      unless byte >= 0x80 && byte <= 0xbf
        raise UnsupportedSequence, "malformed UTF-8 in terminal output"
      end
      @utf8_bytes << byte
      @utf8_expected -= 1
      if @utf8_expected.zero?
        glyph = @utf8_bytes.pack("C*").force_encoding(Encoding::UTF_8)
        raise UnsupportedSequence, "invalid UTF-8 in terminal output" unless glyph.valid_encoding?
        put_character(glyph)
        @utf8_bytes.clear
      end
      return
    end

    case byte
    when 0x1b
      @state = :escape
    when 0x0d
      @x = 0
      @revision += 1
    when 0x0a
      line_feed
    when 0x08
      @x = (@x - 1).clamp(0, @width - 1)
      @revision += 1
    when 0x09
      @x = [((@x / 8) + 1) * 8, @width].min
      @revision += 1
    when 0x07, 0x00
      # BEL/NUL do not alter the rendered grid.
    else
      if byte >= 0xc2 && byte <= 0xdf
        @utf8_expected = 1
        @utf8_bytes = [byte]
      elsif byte >= 0xe0 && byte <= 0xef
        @utf8_expected = 2
        @utf8_bytes = [byte]
      elsif byte >= 0xf0 && byte <= 0xf4
        @utf8_expected = 3
        @utf8_bytes = [byte]
      elsif byte >= 0x80
        raise UnsupportedSequence, format("invalid UTF-8 lead byte 0x%02x", byte)
      elsif byte >= 0x20 && byte != 0x7f
        put_character(byte.chr)
      elsif byte < 0x20
        raise UnsupportedSequence, format("unhandled control byte 0x%02x", byte)
      end
    end
  end

  def consume_escape(byte)
    case byte
    when 0x5b
      @csi.clear
      @state = :csi
    when 0x5d
      @osc_escape = false
      @osc_bytes = 0
      @state = :osc
    when 0x37
      @saved_cursor = [@x, @y]
      @state = :normal
    when 0x38
      restore_cursor
      @state = :normal
    when 0x44
      line_feed
      @state = :normal
    when 0x45
      @x = 0
      line_feed
      @state = :normal
    when 0x4d
      reverse_index
      @state = :normal
    when 0x63
      reset_screen
      @state = :normal
    when 0x3d, 0x3e
      # Application/keypad mode toggles do not change visible cells.
      @state = :normal
    else
      raise UnsupportedSequence, format("unhandled ESC sequence 0x%02x", byte)
    end
  end

  def consume_csi(byte)
    if byte >= 0x40 && byte <= 0x7e
      apply_csi(byte.chr)
      @state = :normal
    elsif @csi.bytesize < 128 && byte >= 0x20 && byte <= 0x3f
      @csi << byte
    else
      raise UnsupportedSequence, "malformed or oversized CSI sequence"
    end
  end

  def consume_osc(byte)
    @osc_bytes += 1
    raise UnsupportedSequence, "oversized OSC sequence" if @osc_bytes > 4096

    if byte == 0x07 || (@osc_escape && byte == 0x5c)
      @state = :normal
      @osc_escape = false
    else
      @osc_escape = byte == 0x1b
    end
  end

  def apply_csi(final)
    private_prefix = @csi.start_with?("?", ">", "!", "<")
    prefix = private_prefix ? @csi[0] : nil
    body = private_prefix ? @csi[1..] : @csi
    params = body.empty? ? [] : body.split(";").map do |part|
      raise UnsupportedSequence, "unsupported CSI parameter" unless part.empty? || part.match?(/\A\d+\z/)
      part.empty? ? 0 : part.to_i
    end
    first = params.fetch(0, 0)
    second = params.fetch(1, 0)

    case final
    when "m", "n", "c"
      # SGR and device/status queries do not mutate the rendered grid.
      return
    when "H", "f"
      @y = ([first, 1].max - 1).clamp(0, @height - 1)
      @x = ([second, 1].max - 1).clamp(0, @width - 1)
      @revision += 1
    when "A"
      @y = (@y - [first, 1].max).clamp(0, @height - 1)
      @revision += 1
    when "B"
      @y = (@y + [first, 1].max).clamp(0, @height - 1)
      @revision += 1
    when "C"
      @x = (@x + [first, 1].max).clamp(0, @width - 1)
      @revision += 1
    when "D"
      @x = (@x - [first, 1].max).clamp(0, @width - 1)
      @revision += 1
    when "G"
      @x = ([first, 1].max - 1).clamp(0, @width - 1)
      @revision += 1
    when "d"
      @y = ([first, 1].max - 1).clamp(0, @height - 1)
      @revision += 1
    when "J"
      erase_display(first)
    when "K"
      erase_line(first)
    when "X"
      clear_cells(@y, @x, @x + [first, 1].max)
      @revision += 1
    when "s"
      @saved_cursor = [@x, @y]
    when "u"
      if prefix == ">" && params == [5]
        @kitty_keyboard_enabled = true
        return # Kitty keyboard protocol selection used by the editor.
      end
      if prefix == "<" && params.empty?
        @kitty_keyboard_enabled = false
        return # Exact Kitty keyboard protocol pop used on editor shutdown.
      end
      raise UnsupportedSequence, "unsupported CSI u sequence" if prefix
      restore_cursor
    when "h", "l"
      apply_mode(prefix, params, final)
    else
      raise UnsupportedSequence, "unhandled CSI sequence #{@csi}#{final}"
    end
  end

  def apply_mode(prefix, params, final)
    raise UnsupportedSequence, "unhandled non-private mode sequence #{@csi}#{final}" unless prefix == "?"

    modes = params.reject(&:zero?)
    allowed = [25, 1000, 1002, 1006, 1049, 2004]
    unknown = modes - allowed
    raise UnsupportedSequence, "unhandled private mode #{unknown.first}" unless unknown.empty?

    if modes.include?(1049)
      if final == "h" && !@primary_state
        @primary_state = [@cells, @x, @y]
        @cells = blank_grid
        @x = 0
        @y = 0
        @revision += 1
        record_all_watched_rows
      elsif final == "l" && @primary_state
        @cells, @x, @y = @primary_state
        @primary_state = nil
        @revision += 1
        record_all_watched_rows
      end
    end
  end

  def put_character(glyph)
    width = glyph_width(glyph)
    if width.zero?
      column = @x - 1
      column -= 1 while column >= 0 && wide_continuation?(@cells[@y][column])
      raise UnsupportedSequence, "combining mark without a base glyph" if column.negative?

      @cells[@y][column] = "#{@cells[@y][column]}#{glyph}"
      @revision += 1
      record_watched_row(@y)
      return
    end

    if @x >= @width || width > @width - @x
      @x = 0
      line_feed
    end
    return if @y.negative? || @y >= @height

    raise UnsupportedSequence, "wide glyph cannot fit terminal width" if width > @width

    clear_character_at(@y, @x)
    clear_character_at(@y, @x + width - 1) if width == 2
    @cells[@y][@x] = glyph
    @cells[@y][@x + 1] = WIDE_CONTINUATION if width == 2
    @x += width
    @revision += 1
    record_watched_row(@y)
  end

  def glyph_width(glyph)
    codepoint = glyph.ord
    return 1 if codepoint.between?(0x20, 0x7e)
    return 0 if codepoint.between?(0x0300, 0x036f)
    return 2 if WIDE_CODEPOINTS.include?(codepoint)
    return 1 if SINGLE_CODEPOINTS.include?(codepoint)

    raise UnsupportedSequence, format("unsupported Unicode width U+%04X", codepoint)
  end

  def wide_continuation?(cell)
    cell.equal?(WIDE_CONTINUATION)
  end

  def clear_character_at(row_index, column)
    return if column.negative? || column >= @width

    row = @cells[row_index]
    if wide_continuation?(row[column])
      row[column - 1] = " " if column.positive?
      row[column] = " "
    elsif row[column].is_a?(String) && WIDE_CODEPOINTS.include?(row[column].codepoints.first)
      row[column] = " "
      row[column + 1] = " " if column + 1 < @width && wide_continuation?(row[column + 1])
    else
      row[column] = " "
    end
  end

  def render_row(row)
    row.map { |cell| wide_continuation?(cell) ? "" : cell }.join
  end

  def line_feed
    if @y >= @height - 1
      @cells.shift
      @cells << Array.new(@width, " ")
      @y = @height - 1
    else
      @y += 1
    end
    @revision += 1
    record_all_watched_rows
  end

  def reverse_index
    if @y <= 0
      @cells.pop
      @cells.unshift(Array.new(@width, " "))
    else
      @y -= 1
    end
    @revision += 1
    record_all_watched_rows
  end

  def restore_cursor
    if @saved_cursor
      @x, @y = @saved_cursor
      @revision += 1
    end
  end

  def erase_display(mode)
    case mode
    when 0
      clear_cells(@y, @x, @width)
      ((@y + 1)...@height).each { |row| @cells[row].fill(" ") }
    when 1
      (0...@y).each { |row| @cells[row].fill(" ") }
      clear_cells(@y, 0, @x + 1)
    when 2, 3
      @cells.each { |row| row.fill(" ") }
    else
      raise UnsupportedSequence, "unsupported erase-display mode #{mode}"
    end
    @revision += 1
    record_all_watched_rows
  end

  def erase_line(mode)
    case mode
    when 0 then clear_cells(@y, @x, @width)
    when 1 then clear_cells(@y, 0, @x + 1)
    when 2 then @cells[@y].fill(" ")
    else raise UnsupportedSequence, "unsupported erase-line mode #{mode}"
    end
    @revision += 1
    record_watched_row(@y)
  end

  def clear_cells(row, from, to)
    return if row.negative? || row >= @height

    left = from.clamp(0, @width)
    right = to.clamp(left, @width)
    left -= 1 if left.positive? && left < @width && wide_continuation?(@cells[row][left])
    right += 1 if right < @width && wide_continuation?(@cells[row][right])
    @cells[row][left...right] = Array.new(right - left, " ") if right > left
    if right > left
      @revision += 1
      record_watched_row(row)
    end
  end

  def reset_screen
    @cells = blank_grid
    @x = 0
    @y = 0
    @saved_cursor = nil
    @primary_state = nil
    @revision += 1
    record_all_watched_rows
  end

  def record_all_watched_rows
    return unless @watched_fragment

    @cells.each_index { |row| record_watched_row(row) }
  end

  def record_watched_row(row_index)
    return unless @watched_fragment && row_index >= 0 && row_index < @height

    text = render_row(@cells[row_index])
    return unless text.include?(@watched_fragment)

    @watched_history ||= []
    return if @watched_history.last && @watched_history.last[1] == text

    @watched_history << [@revision, text]
    @watched_history.shift while @watched_history.size > 128
  end
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

pty_screen_self_check!
if options[:self_check]
  puts "PTY screen-model self-checks: PASS"
  exit 0
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

def screen_row_loaded_after?(state, baseline_revision, prefix, status)
  snapshot = screen_snapshot(state)
  transitions = snapshot[:watched_history].select do |revision, row|
    revision > baseline_revision && row.include?(prefix)
  end
  loading = transitions.find { |_revision, row| row.include?(status) }
  current = screen_row(snapshot, prefix)
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
File.write(config_path, "{}\n")
source_text = <<~CRYSTAL
  # Actual PTY smoke source; it is never executed by the fake adapter.
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
      revision > dock_show_revision && screen_includes?(output_state, "DEBUG") &&
        screen_includes?(output_state, "STACK") && screen_includes?(output_state, "fixture_main")
    end
    # Exercise the focused dock's advertised pane traversal, not only the
    # alternate palette action. Stack -> Threads -> Variables.
    variables_pane_revision = screen_revision(output_state)
    2.times { key(reader, "\t") }
    wait_for("Variables pane focus by Tab", child: child) do
      screen_revision(output_state) > variables_pane_revision &&
        screen_includes?(output_state, "Press Enter to load scopes for the stopped frame")
    end
    scopes_screen_revision = screen_revision(output_state)
    key(reader, "\e[13u")
    wait_for("real locals scope and sentinel", seconds: 10, child: child) do
      requests = adapter_requests(adapter_log)
      saw_scopes = requests.any? { |request| request["command"] == "scopes" }
      saw_variables = requests.any? { |request| request["command"] == "variables" }
      screen_revision(output_state) > scopes_screen_revision &&
        saw_scopes && saw_variables && screen_includes?(output_state, "sentinel") &&
        screen_includes?(output_state, "271828")
    end
    2.times { key(reader, "\e[B") } # Skip the Locals scope and sentinel to select record.
    screen_watch_row(output_state, "record = Record (Record)")
    child_page_baseline = screen_revision(output_state)
    key(reader, "\e[13u")
    wait_for("record child request", seconds: 8, child: child) do
      adapter_requests(adapter_log, "variables").any? do |request|
        request.dig("arguments", "variablesReference") == 701
      end
    end
    wait_for("Loading status cleared from current record row", seconds: 8, child: child) do
      screen_row_loaded_after?(output_state, child_page_baseline,
        "record = Record (Record)", "Loading")
    end
    # The child can extend just below the visible page at this terminal size;
    # move selection into the returned child row so the smoke proves it is
    # actually projected, not merely present in an adapter response.
    value_revision = screen_revision(output_state)
    key(reader, "\e[B")
    wait_for("record child value", seconds: 8, child: child) do
      screen_revision(output_state) > value_revision && screen_includes?(output_state, "value = 31")
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
        screen_row_includes?(output_state, "puts", "λ") &&
        !screen_includes?(output_state, "DEBUG") && !screen_includes?(output_state, "STACK")
    end
    narrow_output = output_since(output_state, resize_cursor)
    File.binwrite(File.join(root, "narrow.raw"), narrow_output)
    narrow_screen = screen_snapshot(output_state)
    narrow_source_row = screen_row(narrow_screen, "puts")
    raise "narrow resize lost the visible Unicode source marker" unless narrow_source_row && narrow_source_row.include?("λ")
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
        screen_includes?(output_state, "DEBUG") && screen_includes?(output_state, "STACK")
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
