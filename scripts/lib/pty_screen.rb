# A deliberately bounded VT screen model for the app's redraw path. It models
# ASCII plus the exact Unicode glyphs observed in this fixture/UI, including
# known wide glyphs, the emitted replacement scalar, and common combining
# diacritics. Other Unicode width cases fail closed; this is not a general
# terminal emulator. Any unrecognized
# screen-affecting sequence also fails closed.
class PtyScreen
  class UnsupportedSequence < StandardError; end

  WIDE_CONTINUATION = Object.new.freeze
  WIDE_CODEPOINTS = [0x96ea, 0x1f600].freeze # 雪, 😀
  SINGLE_CODEPOINTS = [
    0x00b7, 0x03bb, 0x2014, 0x2026, 0x2191, 0x2193,
    0x2500, 0x2502, 0x250c, 0x2510, 0x2514, 0x2518,
    0x251c, 0x2524, 0x252c, 0x2534, 0x253c, 0x2588, 0x25b6, 0x25b8,
    0x25be, 0x25cf, 0xfffd,
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
