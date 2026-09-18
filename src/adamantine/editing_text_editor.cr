require "crystal_tui"

module Adamantine
  # The application-owned editor behavior for indentation.  The underlying
  # TextEditor keeps the piece tree and history private, so this subclass uses
  # the same local edit primitives instead of replacing the document string.
  class EditingTextEditor < Tui::TextEditor
    PREFIX_SCAN_CHUNK = 1024

    property auto_indent : Bool = true

    # Keep the setting's invariant at the editor boundary as well as in the
    # settings/configuration layer.  The inherited property is still the
    # source of truth used by the widget's tab rendering and editing code.
    def tab_size=(value : Int32) : Int32
      @tab_size = value.clamp(1, 8)
    end

    # Insert one configured indentation unit at the caret, or indent all
    # touched lines of a non-empty selection.  A command is one history entry.
    def indent : Bool
      selection = active_indentation_selection
      unless selection
        width = indentation_width
        insert_text(" " * width)
        return true
      end

      lines = indentation_lines(selection)
      return false if lines.empty?

      width = indentation_width
      changes = {} of Int32 => Int32
      begin_edit(nil)
      lines.reverse_each do |line|
        @buffer.insert(byte_offset(line, 0), " " * width)
        changes[line] = width
      end
      update_positions_after_indentation(selection, changes, adding: true)
      text_changed(TextChange.full)
      true
    end

    # Remove up to one configured indentation unit from each touched line.
    # A leading tab is one indentation unit for this command.  Work out all
    # removals before opening an undo entry so a no-op dedent has no history.
    def dedent : Bool
      selection = active_indentation_selection
      lines = indentation_lines(selection)
      removals = {} of Int32 => Int32
      lines.each do |line|
        if count = dedent_length(line)
          removals[line] = count
        end
      end
      return false if removals.empty?

      begin_edit(nil)
      removals.keys.sort.reverse_each do |line|
        count = removals[line]
        delete_buffer_range(byte_offset(line, 0), count)
      end
      update_positions_after_indentation(selection, removals, adding: false)
      text_changed(TextChange.full)
      true
    end

    # Split at the selection start (or caret) and copy only the whitespace
    # preceding that position.  This intentionally has no language-aware
    # behavior: it preserves the existing line's leading whitespace only.
    def insert_newline : Nil
      selection_start = if selection = @selection
                          normalized = selection.normalize
                          {normalized.start_line, normalized.start_col}
                        else
                          {@cursor.line, @cursor.col}
                        end
      indentation = @auto_indent ? leading_whitespace_before(selection_start[0], selection_start[1]) : ""

      # Each Enter keypress is an independent command, including repeated
      # presses on the same line; do not use the base editor's coalescing kind.
      begin_edit(nil)
      selection_change = delete_selection_content(false) if @selection
      start_position = selection_change.try(&.[0]) || current_text_position
      finish_position = selection_change.try(&.[1]) || start_position
      exact = selection_change.try(&.[2]) != false
      offset = byte_offset(@cursor.line, @cursor.col)
      logical = "\n#{indentation}"
      inserted = encode_newlines(logical, offset)
      @buffer.insert(offset, inserted)
      @cursor.line += 1
      @cursor.col = indentation.each_char.size
      text_changed(exact ? TextChange.new(start_position, finish_position, inserted) : TextChange.full)
    end

    private def indentation_width : Int32
      @tab_size.clamp(1, 8)
    end

    private def active_indentation_selection : Tui::TextEditor::Selection?
      selection = @selection
      return nil unless selection
      return nil if selection.empty?
      selection
    end

    private def indentation_lines(selection : Tui::TextEditor::Selection?) : Array(Int32)
      unless selection
        return [@cursor.line]
      end

      normalized = selection.normalize
      last_line = normalized.end_line
      if last_line > normalized.start_line && normalized.end_col == 0
        last_line -= 1
      end
      return [] of Int32 if last_line < normalized.start_line
      (normalized.start_line..last_line).to_a
    end

    private def dedent_length(line : Int32) : Int32?
      first = @buffer.character_at(line, 0)
      return 1 if first == '\t'
      return nil unless first == ' '

      spaces = 1
      while spaces < indentation_width
        break unless @buffer.character_at(line, spaces) == ' '
        spaces += 1
      end
      spaces
    end

    private def update_positions_after_indentation(selection : Tui::TextEditor::Selection?, changes : Hash(Int32, Int32), *, adding : Bool) : Nil
      if original = selection
        start_line, start_col = adjust_position(original.start_line, original.start_col, changes, adding)
        end_line, end_col = adjust_position(original.end_line, original.end_col, changes, adding)
        @selection = Tui::TextEditor::Selection.new(start_line, start_col, end_line, end_col)
      else
        @selection = nil
      end

      @cursor.line, @cursor.col = adjust_position(@cursor.line, @cursor.col, changes, adding)
      @cursor.col = @cursor.col.clamp(0, line_length(@cursor.line))
    end

    private def adjust_position(line : Int32, col : Int32, changes : Hash(Int32, Int32), adding : Bool) : Tuple(Int32, Int32)
      delta = changes[line]?
      return {line, col} unless delta

      if adding
        {line, col > 0 ? col + delta : col}
      else
        {line, [col - delta, 0].max}
      end
    end

    private def leading_whitespace_before(line : Int32, column : Int32) : String
      limit = column.clamp(0, line_length(line))
      return "" if limit == 0

      String.build do |io|
        offset = 0
        while offset < limit
          chunk = @buffer.line_slice(line, offset, Math.min(PREFIX_SCAN_CHUNK, limit - offset))
          break if chunk.empty?

          consumed = 0
          stopped = false
          chunk.each_char do |char|
            unless char == ' ' || char == '\t'
              stopped = true
              break
            end
            io << char
            consumed += 1
          end

          offset += consumed
          break if stopped || consumed < chunk.size
        end
      end
    end
  end
end
