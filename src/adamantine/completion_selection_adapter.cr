require "./editing_text_editor_unicode"
require "./text_coordinates"

module Adamantine
  # Completion authority checks need only whether a selection exists. Keep
  # that scalar adapter separate from the editor rendering implementation so
  # completion never materializes selected document text.
  class EditingTextEditor
    include TextCoordinates::SelectionProvider
    include TextCoordinates::CompletionEditProvider

    def selection_present? : Bool
      selection_active?
    end

    def apply_completion_edit(
      start_line : Int32,
      start_col : Int32,
      end_line : Int32,
      end_col : Int32,
      original_line : Int32,
      original_col : Int32,
      text : String,
    ) : Nil
      select_range(start_line, start_col, end_line, end_col, cursor_at_end: true)
      # TextEditor#insert_text snapshots the cursor in begin_edit. Restore the
      # request cursor after installing the replacement selection so undo
      # returns the user to the exact pre-acceptance position.
      @cursor.line = original_line
      @cursor.col = original_col
      insert_text(text)
    end
  end
end
