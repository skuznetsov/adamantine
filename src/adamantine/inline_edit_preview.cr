require "crystal_tui"
require "./piece_tree_replace"

module Adamantine
  # A read-only, lazy projection of a prepared document-edit candidate.
  #
  # The model retains only line-span metadata and the two persistent roots.
  # Rows and bounded text fragments are produced on demand, so opening a
  # preview does not materialize either document or a document-sized diff.
  module InlineEditPreview
    MAX_ROW_BYTES = 4_096
    # Keep the source window below the row budget even if every codepoint
    # expands to a visible escape plus the page-continuation marker.
    MAX_WINDOW_COLUMNS = 400
    MAX_COMPARE_CHUNK  = 64 * 1024
    TRUNCATION_MARKER  = "[truncated]"

    struct EditSpan
      getter old_start_line : Int32
      getter old_end_line : Int32
      getter new_start_line : Int32
      getter new_end_line : Int32

      def initialize(
        @old_start_line : Int32,
        @old_end_line : Int32,
        @new_start_line : Int32,
        @new_end_line : Int32,
      )
      end
    end

    class Row
      getter prefix : Char
      getter old_line : Int32?
      getter new_line : Int32?
      getter text : String
      getter line_ending : String

      def initialize(
        @prefix : Char,
        @old_line : Int32?,
        @new_line : Int32?,
        @text : String,
        @line_ending : String = "",
      )
      end

      def context? : Bool
        @prefix == ' '
      end

      def removed? : Bool
        @prefix == '-'
      end

      def added? : Bool
        @prefix == '+'
      end

      def eol_changed? : Bool
        @line_ending == "<changed>"
      end
    end

    class Model
      private struct Hunk
        getter old_start : Int32
        getter old_end : Int32
        getter new_start : Int32
        getter new_end : Int32

        def initialize(
          @old_start : Int32,
          @old_end : Int32,
          @new_start : Int32,
          @new_end : Int32,
        )
        end
      end

      getter title : String
      getter top : Int32
      getter horizontal_offset : Int32

      @hunks : Array(Hunk)
      @top : Int32 = 0
      @horizontal_offset : Int32 = 0
      @horizontal_step : Int32 = 1
      @segments = [] of Tuple(Int32, Int32, Char, Int32, Int32)
      @change_starts = [] of Int32
      @row_count : Int32 = 0

      def initialize(
        @original : Tui::PieceTreeBuffer,
        @candidate : Tui::PieceTreeBuffer,
        spans : Array(EditSpan),
        @title : String = "Proposed edit preview",
      )
        # Freeze the caller's current roots inside private fork objects. A
        # later mutation of a constructor argument must not alter the review.
        @original = @original.replace_fork
        @candidate = @candidate.replace_fork
        @hunks = build_hunks(spans)
        build_index
        @top = first_change_row.clamp(0, [row_count - 1, 0].max)
      end

      # The projection is virtual: this is a scalar count, not an allocated
      # row collection. Row text is bounded display text, not canonical bytes.
      def row_count : Int32
        @row_count
      end

      def row_at(index : Int32) : Row
        raise IndexError.new("preview row outside projection") unless index >= 0 && index < row_count

        segment, offset = segment_for_row(index)
        case segment[2]
        when '-' then removed_row(segment[3] + offset)
        when '+' then added_row(segment[4] + offset)
        else          context_row(segment[3] + offset, segment[4] + offset)
        end
      end

      # Return a bounded source-column window for rendering. Unlike Row#text,
      # this method never substitutes a head/tail sample for a long line:
      # callers can move the window and inspect every source codepoint. The
      # virtual row index and the requested offset are both checked/clamped
      # before asking the piece tree for a UTF-8-safe slice.
      def row_text_window(index : Int32, offset : Int32 = @horizontal_offset) : String
        segment, row_offset = segment_for_row(index)
        buffer, line = case segment[2]
                       when '-'
                         {@original, segment[3] + row_offset}
                       when '+'
                         {@candidate, segment[4] + row_offset}
                       else
                         {@original, segment[3] + row_offset}
                       end
        line_length = buffer.line_character_length(line)
        start_column = offset.clamp(0, line_length)
        count = Math.min(MAX_WINDOW_COLUMNS, line_length - start_column)
        # A tab's display stop depends on all preceding source cells. Do not
        # re-expand it from this window's local origin; show the source token
        # explicitly so panning cannot misrepresent its indentation.
        text = sanitize(buffer.line_slice(line, start_column, count), escape_tabs: true)
        if start_column + count < line_length
          text = "#{text} … [more] …"
        end
        bounded_text(text)
      end

      # Page size is measured in source codepoints. Renderer widths are
      # terminal cells, so the explicit one-column modifier remains the
      # lossless path for wide glyphs, tabs and escaped control characters.
      def horizontal_step=(value : Int32) : Int32
        @horizontal_step = value.clamp(1, MAX_WINDOW_COLUMNS)
      end

      def pan_horizontal(delta : Int32, fine : Bool = false) : Int32
        step = fine ? 1 : @horizontal_step
        target = @horizontal_offset.to_i64 + delta.to_i64 * step
        @horizontal_offset = target.clamp(0_i64, Int32::MAX.to_i64).to_i32
      end

      private def segment_for_row(index : Int32)
        raise IndexError.new("preview row outside projection") unless index >= 0 && index < row_count

        low = 0
        high = @segments.size
        while low < high
          middle = (low + high) // 2
          if @segments[middle][1] <= index
            low = middle + 1
          else
            high = middle
          end
        end
        segment = @segments[low]
        {segment, index - segment[0]}
      end

      private def append_segment(count : Int32, kind : Char, old_line : Int32, new_line : Int32)
        return if count == 0
        finish = @row_count.to_i64 + count
        raise ArgumentError.new("preview exceeds virtual row limit") if finish > Int32::MAX
        @segments << {@row_count, finish.to_i32, kind, old_line, new_line}
        @row_count = finish.to_i32
      end

      private def build_index
        old_cursor = 0
        new_cursor = 0
        @hunks.each do |hunk|
          append_segment(common_count(old_cursor, hunk.old_start, new_cursor, hunk.new_start), ' ', old_cursor, new_cursor)
          @change_starts << @row_count
          append_segment(hunk.old_end - hunk.old_start, '-', hunk.old_start, hunk.new_start)
          append_segment(hunk.new_end - hunk.new_start, '+', hunk.old_start, hunk.new_start)
          old_cursor = hunk.old_end
          new_cursor = hunk.new_end
        end
        append_segment(common_count(old_cursor, @original.line_count, new_cursor, @candidate.line_count), ' ', old_cursor, new_cursor)
      end

      def scroll_top=(value : Int32) : Int32
        target = value.clamp(0, [row_count - 1, 0].max)
        @top = target
      end

      def scroll_by(delta : Int32) : Int32
        self.scroll_top = @top + delta
      end

      def scroll_page(delta : Int32, page_rows : Int32) : Int32
        self.scroll_by(delta * [page_rows, 1].max)
      end

      def home : Int32
        self.scroll_top = 0
      end

      def finish : Int32
        self.scroll_top = [row_count - 1, 0].max
      end

      # Move the virtual viewport to a changed row. Wrapping keeps Tab and
      # Shift-Tab useful when the last hunk is reached without changing the
      # underlying editor cursor or scroll position.
      def next_change : Int32
        target = next_change_row(@top + 1)
        self.scroll_top = target
      end

      def previous_change : Int32
        target = previous_change_row(@top - 1)
        self.scroll_top = target
      end

      def first_change_row : Int32
        @change_starts.first? || 0
      end

      private def next_change_row(start : Int32) : Int32
        @change_starts.find { |row| row >= start } || first_change_row
      end

      private def previous_change_row(start : Int32) : Int32
        @change_starts.reverse_each.find { |row| row <= start } || last_change_row
      end

      private def last_change_row : Int32
        @change_starts.last? || 0
      end

      private def common_count(old_start : Int32, old_finish : Int32, new_start : Int32, new_finish : Int32) : Int32
        old_count = [old_finish - old_start, 0].max
        new_count = [new_finish - new_start, 0].max
        raise ArgumentError.new("inconsistent preview context span") unless old_count == new_count
        old_count
      end

      private def context_row(old_line : Int32, new_line : Int32) : Row
        old_text, old_eol = line_text(@original, old_line)
        # Context lies outside mapped edits or was byte-compared while
        # trimming a hunk. It is shared source, even with shifted numbering.
        Row.new(' ', old_line + 1, new_line + 1, old_text, old_eol)
      end

      private def removed_row(line : Int32) : Row
        text, eol = line_text(@original, line)
        Row.new('-', line + 1, nil, text, eol)
      end

      private def added_row(line : Int32) : Row
        text, eol = line_text(@candidate, line)
        Row.new('+', nil, line + 1, text, eol)
      end

      private def build_hunks(spans : Array(EditSpan)) : Array(Hunk)
        raw = [] of Hunk
        spans.each do |span|
          old_start = span.old_start_line.clamp(0, @original.line_count)
          old_end = span.old_end_line.clamp(old_start, @original.line_count)
          new_start = span.new_start_line.clamp(0, @candidate.line_count)
          new_end = span.new_end_line.clamp(new_start, @candidate.line_count)
          next if old_start == old_end && new_start == new_end

          if prior = raw.last?
            overlaps_old = old_start <= prior.old_end
            overlaps_new = new_start <= prior.new_end
            if overlaps_old && overlaps_new
              raw[-1] = Hunk.new(
                Math.min(prior.old_start, old_start),
                Math.max(prior.old_end, old_end),
                Math.min(prior.new_start, new_start),
                Math.max(prior.new_end, new_end),
              )
              next
            end
          end
          raw << Hunk.new(old_start, old_end, new_start, new_end)
        end

        trimmed = [] of Hunk
        raw.each do |hunk|
          old_start = hunk.old_start
          old_end = hunk.old_end
          new_start = hunk.new_start
          new_end = hunk.new_end

          while old_start < old_end && new_start < new_end && same_line?(@original, old_start, @candidate, new_start)
            old_start += 1
            new_start += 1
          end
          while old_start < old_end && new_start < new_end && same_line?(@original, old_end - 1, @candidate, new_end - 1)
            old_end -= 1
            new_end -= 1
          end
          next if old_start == old_end && new_start == new_end
          trimmed << Hunk.new(old_start, old_end, new_start, new_end)
        end
        trimmed
      end

      private def same_line?(left : Tui::PieceTreeBuffer, left_line : Int32, right : Tui::PieceTreeBuffer, right_line : Int32) : Bool
        left_text_start, left_text_end = line_bounds(left, left_line)
        right_text_start, right_text_end = line_bounds(right, right_line)
        return false unless left_text_end - left_text_start == right_text_end - right_text_start
        return false unless line_ending(left, left_line) == line_ending(right, right_line)

        offset = 0
        length = left_text_end - left_text_start
        while offset < length
          requested = Math.min(MAX_COMPARE_CHUNK, length - offset)
          count = safe_chunk_length(left, right, left_text_start + offset, right_text_start + offset, requested)
          return false if count == 0
          return false unless left.slice(left_text_start + offset, count) == right.slice(right_text_start + offset, count)
          offset += count
        end
        true
      end

      private def safe_chunk_length(
        left : Tui::PieceTreeBuffer,
        right : Tui::PieceTreeBuffer,
        left_start : Int32,
        right_start : Int32,
        requested : Int32,
      ) : Int32
        count = requested
        while count > 0
          left_boundary = left_start + count
          right_boundary = right_start + count
          left_ok = left_boundary == left.byte_length || !continuation?(left.byte_at_offset(left_boundary).not_nil!)
          right_ok = right_boundary == right.byte_length || !continuation?(right.byte_at_offset(right_boundary).not_nil!)
          return count if left_ok && right_ok
          count -= 1
        end
        0
      end

      private def continuation?(byte : UInt8) : Bool
        (byte & 0xc0_u8) == 0x80_u8
      end

      private def line_text(buffer : Tui::PieceTreeBuffer, line : Int32) : Tuple(String, String)
        start_byte, finish_byte = line_bounds(buffer, line)
        length = finish_byte - start_byte
        text = bounded_buffer_text(buffer, start_byte, length)
        {text, line_ending(buffer, line)}
      end

      private def line_bounds(buffer : Tui::PieceTreeBuffer, line : Int32) : Tuple(Int32, Int32)
        raise IndexError.new("line index #{line} outside preview root") unless line >= 0 && line < buffer.line_count
        start_byte = buffer.line_start_offset(line)
        if line + 1 < buffer.line_count
          next_start = buffer.line_start_offset(line + 1)
          finish_byte = next_start - 1
          finish_byte -= 1 if finish_byte > start_byte && buffer.byte_at_offset(finish_byte - 1) == '\r'.ord.to_u8
          {start_byte, finish_byte}
        else
          {start_byte, buffer.byte_length}
        end
      end

      private def line_ending(buffer : Tui::PieceTreeBuffer, line : Int32) : String
        return "" if line + 1 >= buffer.line_count
        start_byte, finish_byte = line_bounds(buffer, line)
        next_start = buffer.line_start_offset(line + 1)
        length = next_start - finish_byte
        return "\r\n" if length == 2
        return "\r" if finish_byte < next_start && buffer.byte_at_offset(finish_byte) == '\r'.ord.to_u8
        "\n"
      end

      private def bounded_buffer_text(buffer : Tui::PieceTreeBuffer, start_byte : Int32, length : Int32) : String
        return "" if length <= 0
        if length <= MAX_ROW_BYTES
          return bounded_text(sanitize(buffer.slice(start_byte, length)))
        end

        marker = " … #{TRUNCATION_MARKER} … "
        available = Math.max(MAX_ROW_BYTES - marker.bytesize, 2)
        head_length = utf8_prefix_length(buffer, start_byte, Math.min(available // 2, length))
        tail_length = Math.min(available - head_length, length - head_length)
        tail_start = start_byte + length - tail_length
        tail_length = utf8_suffix_length(buffer, tail_start, tail_length)
        head = head_length > 0 ? buffer.slice(start_byte, head_length) : ""
        tail = tail_length > 0 ? buffer.slice(start_byte + length - tail_length, tail_length) : ""
        bounded_text("#{sanitize(head)}#{marker}#{sanitize(tail)}")
      end

      private def utf8_prefix_length(buffer : Tui::PieceTreeBuffer, start_byte : Int32, length : Int32) : Int32
        length = [length, 0].max
        while length > 0 && start_byte + length < buffer.byte_length && continuation?(buffer.byte_at_offset(start_byte + length).not_nil!)
          length -= 1
        end
        length
      end

      private def utf8_suffix_length(buffer : Tui::PieceTreeBuffer, start_byte : Int32, length : Int32) : Int32
        return 0 if length <= 0
        offset = start_byte
        while offset < start_byte + length && continuation?(buffer.byte_at_offset(offset).not_nil!)
          offset += 1
        end
        start_byte + length - offset
      end

      private def sanitize(text : String, escape_tabs : Bool = false) : String
        String.build do |builder|
          text.each_char do |char|
            codepoint = char.ord
            if char == '\t'
              builder << (escape_tabs ? "\\t" : "\t")
            elsif codepoint < 0x20 || (0x7f..0x9f).includes?(codepoint) ||
                  codepoint == 0x61c || codepoint == 0x200e || codepoint == 0x200f ||
                  (0x202a..0x202e).includes?(codepoint) || (0x2066..0x2069).includes?(codepoint)
              builder << "\\u{" << codepoint.to_s(16) << "}"
            else
              builder << char
            end
          end
        end
      end

      private def bounded_text(text : String) : String
        return text if text.bytesize <= MAX_ROW_BYTES
        marker = " … #{TRUNCATION_MARKER} … "
        available = Math.max(MAX_ROW_BYTES - marker.bytesize, 2)
        head_length = utf8_prefix_length(text, available // 2)
        tail_length = [available - head_length, text.bytesize - head_length].min
        tail_start = text.bytesize - tail_length
        while tail_start < text.bytesize && continuation?(text.byte_at(tail_start))
          tail_start += 1
        end
        head = head_length > 0 ? text.byte_slice(0, head_length) : ""
        tail = tail_start < text.bytesize ? text.byte_slice(tail_start, text.bytesize - tail_start) : ""
        "#{head}#{marker}#{tail}"
      end

      private def utf8_prefix_length(text : String, length : Int32) : Int32
        length = [length, 0].max
        while length > 0 && length < text.bytesize && continuation?(text.byte_at(length))
          length -= 1
        end
        length
      end
    end
  end
end
