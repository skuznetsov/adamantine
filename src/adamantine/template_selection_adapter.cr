require "./completion_selection_adapter"

module Adamantine
  class EditingTextEditor
    # Inspect only the small span needed for an explicit template trigger.
    # In particular, this must not materialize a multi-megabyte line.
    def template_trigger_before_cursor?(trigger : String) : Bool
      characters = trigger.each_char.to_a
      return false if characters.empty? || characters.size > 64 || characters.size > cursor_col

      start = cursor_col - characters.size
      if start > 0
        preceding = @buffer.character_at(cursor_line, start - 1)
        return false if preceding && (preceding.ascii_letter? || preceding.ascii_number? || preceding == '_')
      end
      characters.each_with_index do |char, index|
        return false unless @buffer.character_at(cursor_line, start + index) == char
      end
      true
    end

    # Return nil if the indentation is unusually wide: expanding it over many
    # template lines could exceed the bounded parser's output allowance.
    def template_leading_indentation(max_chars : Int32 = 256) : String?
      String.build do |io|
        limit = @buffer.line_character_length(cursor_line)
        index = 0
        while index < limit
          return nil if index >= max_chars
          char = @buffer.character_at(cursor_line, index)
          break unless char == ' ' || char == '\t'
          io << char
          index += 1
        end
      end
    end
  end
end
