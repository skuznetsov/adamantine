require "crystal_tui"
require "./snippet_parser"

module Adamantine
  # Tracks one bounded snippet expansion in one editor. All coordinates remain
  # in the editor's codepoint-based line/column space.
  class TemplateSession
    MAX_SPANS = 64

    private struct Position
      include Comparable(Position)

      getter line : Int32
      getter column : Int32

      def initialize(@line : Int32, @column : Int32)
      end

      def <=>(other : Position) : Int32
        return @line <=> other.line unless @line == other.line
        @column <=> other.column
      end
    end

    private struct Span
      getter index : Int32
      getter start_position : Position
      getter end_position : Position

      def initialize(@index : Int32, @start_position : Position, @end_position : Position)
      end

      def empty? : Bool
        @start_position == @end_position
      end
    end

    getter editor : Tui::TextEditor

    @spans : Array(Span)
    @selected_index : Int32?
    @active : Bool

    def initialize(
      @editor : Tui::TextEditor,
      insertion_line : Int32,
      insertion_col : Int32,
      parsed : Snippet::ParseResult,
    )
      raise ArgumentError.new("template insertion position must be nonnegative") if insertion_line < 0 || insertion_col < 0
      raise ArgumentError.new("template contains more than #{MAX_SPANS} tabstops") if parsed.tabstops.size > MAX_SPANS
      raise ArgumentError.new("template must contain a final cursor stop") unless parsed.tabstops.any? { |stop| stop.index == 0 }

      tabstops = parsed.tabstops.dup
      tabstops.sort_by! { |stop| stop.index == 0 ? Int32::MAX : stop.index }
      positions = positions_for_offsets(parsed.text, tabstops, insertion_line, insertion_col)
      @spans = [] of Span
      tabstops.each do |stop|
        start_position = positions[stop.start_offset]?
        end_position = positions[stop.end_offset]?
        unless start_position && end_position && start_position <= end_position
          raise ArgumentError.new("template tabstop range is invalid")
        end
        @spans << Span.new(stop.index, start_position.not_nil!, end_position.not_nil!)
      end

      @selected_index = nil
      @active = true
    end

    def active? : Bool
      @active
    end

    # Select the first numbered stop. A final-only template simply positions
    # the cursor and completes immediately.
    def select_first : Bool
      return false unless @active
      return false if @spans.empty?

      select_or_finish(0)
    end

    def next : Bool
      return false unless @active
      return select_first unless current_index = @selected_index

      next_index = current_index + 1
      return false if next_index >= @spans.size

      select_or_finish(next_index)
    end

    def previous : Bool
      return false unless @active
      return select_first unless current_index = @selected_index
      return false if current_index <= 0

      select_or_finish(current_index - 1)
    end

    # Apply one editor-reported edit to the tracked ranges. Any full-document
    # change or edit that escapes/overlaps the current placeholder ends the
    # session because the remaining coordinates can no longer be trusted.
    def apply_change(change : Tui::TextEditor::TextChange) : Bool
      return false unless @active

      start_position = change.start
      finish_position = change.finish
      unless change.incremental? && start_position && finish_position && change.text.valid_encoding?
        cancel
        return false
      end

      start_position = Position.new(start_position.not_nil!.line, start_position.not_nil!.column)
      finish_position = Position.new(finish_position.not_nil!.line, finish_position.not_nil!.column)
      current_index = @selected_index
      unless current_index && start_position <= finish_position
        cancel
        return false
      end

      current = @spans[current_index.not_nil!]
      unless current.start_position <= start_position && finish_position <= current.end_position
        cancel
        return false
      end

      inserted_end = advance_position(start_position, change.text)
      unless inserted_end
        cancel
        return false
      end

      # Nested or intersecting spans cannot be updated safely. Adjacent stops
      # are allowed; their side of the active field determines edit affinity.
      @spans.each_with_index do |span, index|
        next if index == current_index
        if overlaps_active_span?(span, current)
          cancel
          return false
        end
        if overlaps_change?(span, start_position, finish_position)
          cancel
          return false
        end
      end

      updated = [] of Span
      @spans.each_with_index do |span, index|
        if index == current_index
          end_position = transform_position(span.end_position, start_position, finish_position, inserted_end, after: true)
          unless end_position
            cancel
            return false
          end
          updated << Span.new(span.index, span.start_position, end_position.not_nil!)
          next
        end

        after = after_active_span?(span, index, current, current_index.not_nil!)
        new_start = transform_position(span.start_position, start_position, finish_position, inserted_end, after: after)
        new_end = transform_position(span.end_position, start_position, finish_position, inserted_end, after: after)
        unless new_start && new_end && new_start.not_nil! <= new_end.not_nil!
          cancel
          return false
        end
        updated << Span.new(span.index, new_start.not_nil!, new_end.not_nil!)
      end

      @spans = updated
      true
    end

    def contains_cursor? : Bool
      return false unless @active
      return false unless current_index = @selected_index

      current = @spans[current_index]
      cursor = Position.new(@editor.cursor_line, @editor.cursor_col)
      current.start_position <= cursor && cursor <= current.end_position
    end

    def cancel : Nil
      @active = false
      @selected_index = nil
    end

    private def select_or_finish(index : Int32) : Bool
      span = @spans[index]?
      return false unless span

      if span.index == 0
        @editor.set_cursor(span.start_position.line, span.start_position.column)
        cancel
        return true
      end

      @selected_index = index
      @editor.select_range(
        span.start_position.line,
        span.start_position.column,
        span.end_position.line,
        span.end_position.column
      )
      true
    end

    private def positions_for_offsets(
      text : String,
      tabstops : Array(Snippet::Tabstop),
      base_line : Int32,
      base_column : Int32,
    ) : Hash(Int32, Position)
      offsets = [] of Int32
      tabstops.each do |stop|
        raise ArgumentError.new("template tabstop range is invalid") if stop.start_offset < 0 || stop.end_offset < stop.start_offset
        offsets << stop.start_offset
        offsets << stop.end_offset
      end
      offsets.sort!.uniq!
      raise ArgumentError.new("template tabstop range is invalid") if offsets.empty?

      positions = {} of Int32 => Position
      line = base_line
      column = base_column
      codepoint_offset = 0
      request_index = 0
      while request_index < offsets.size && offsets[request_index] == 0
        positions[0] = Position.new(line, column)
        request_index += 1
      end

      previous_was_cr = false
      text.each_char do |char|
        if char == '\r'
          line, column = advance_line(line)
          previous_was_cr = true
        elsif char == '\n'
          unless previous_was_cr
            line, column = advance_line(line)
          end
          previous_was_cr = false
        else
          column = increment(column)
          previous_was_cr = false
        end

        codepoint_offset += 1
        while request_index < offsets.size && offsets[request_index] == codepoint_offset
          positions[codepoint_offset] = Position.new(line, column)
          request_index += 1
        end
      end

      raise ArgumentError.new("template tabstop offset exceeds expanded text") unless request_index == offsets.size
      positions
    end

    private def advance_position(start_position : Position, text : String) : Position?
      line = start_position.line
      column = start_position.column
      previous_was_cr = false

      text.each_char do |char|
        if char == '\r'
          next_position = advance_line?(line)
          return nil unless next_position
          line, column = next_position.not_nil!
          previous_was_cr = true
        elsif char == '\n'
          unless previous_was_cr
            next_position = advance_line?(line)
            return nil unless next_position
            line, column = next_position.not_nil!
          end
          previous_was_cr = false
        else
          column = increment?(column)
          return nil unless column
          previous_was_cr = false
        end
      end

      Position.new(line, column)
    end

    private def advance_line(line : Int32) : Tuple(Int32, Int32)
      next_line = line.to_i64 + 1
      raise ArgumentError.new("template position exceeds editor coordinate range") if next_line > Int32::MAX
      {next_line.to_i32, 0}
    end

    private def advance_line?(line : Int32) : Tuple(Int32, Int32)?
      next_line = line.to_i64 + 1
      return nil if next_line > Int32::MAX
      {next_line.to_i32, 0}
    end

    private def increment(value : Int32) : Int32
      next_value = value.to_i64 + 1
      raise ArgumentError.new("template position exceeds editor coordinate range") if next_value > Int32::MAX
      next_value.to_i32
    end

    private def increment?(value : Int32) : Int32?
      next_value = value.to_i64 + 1
      return nil if next_value > Int32::MAX
      next_value.to_i32
    end

    private def transform_position(
      position : Position,
      start_position : Position,
      finish_position : Position,
      inserted_end : Position,
      *,
      after : Bool,
    ) : Position?
      return position if position < start_position
      return translate_after(position, finish_position, inserted_end) if position > finish_position

      after ? inserted_end : position
    end

    private def translate_after(position : Position, finish_position : Position, inserted_end : Position) : Position?
      if position.line == finish_position.line
        column_delta = position.column - finish_position.column
        column = inserted_end.column.to_i64 + column_delta
        return nil if column < 0 || column > Int32::MAX
        Position.new(inserted_end.line, column.to_i32)
      else
        line_delta = inserted_end.line.to_i64 - finish_position.line
        line = position.line.to_i64 + line_delta
        return nil if line < 0 || line > Int32::MAX
        Position.new(line.to_i32, position.column)
      end
    end

    private def overlaps_active_span?(span : Span, active : Span) : Bool
      if active.empty?
        point = active.start_position
        return span.start_position < point && point < span.end_position
      end

      return true if span.start_position < active.end_position && active.start_position < span.end_position
      if span.empty?
        point = span.start_position
        return active.start_position < point && point < active.end_position
      end
      false
    end

    private def overlaps_change?(span : Span, start_position : Position, finish_position : Position) : Bool
      if start_position == finish_position
        point = start_position
        return span.start_position < point && point < span.end_position
      end

      return true if span.start_position < finish_position && start_position < span.end_position
      span.empty? && start_position < span.start_position && span.start_position < finish_position
    end

    private def after_active_span?(span : Span, index : Int32, active : Span, active_index : Int32) : Bool
      if active.start_position < active.end_position
        return true if span.start_position >= active.end_position
        return false if span.end_position <= active.start_position
      else
        point = active.start_position
        return true if span.start_position == point && span.end_position > point
        return false if span.end_position == point && span.start_position < point
        return true if span.start_position > point
        return false if span.end_position < point
        return index > active_index
      end

      span.start_position >= active.end_position
    end
  end
end
