require "crystal_tui"

module Adamantine
  module NavigationController
    private def focus_active_editor : Nil
      @document_orchestrator.focus_active_editor
    end

    private def move_editor_cursor(editor : Tui::TextEditor, line : Int32, character : Int32) : Nil
      @document_orchestrator.move_editor_cursor(editor, line, character)
    end

    private def current_editor : Tui::TextEditor?
      @document_orchestrator.current_editor
    end

    private def current_buffer : OpenBuffer?
      @document_orchestrator.current_buffer
    end

    private def switch_to_next_tab : Nil
      @document_orchestrator.switch_to_next_tab
    end

    private def switch_to_previous_tab : Nil
      @document_orchestrator.switch_to_previous_tab
    end

    private def switch_to_tab_by_position(position : Int32) : Nil
      @document_orchestrator.switch_to_tab_by_position(position)
    end

    private def open_file(path : Path, cursor_line : Int32? = nil, cursor_character : Int32? = nil) : Bool
      @document_orchestrator.open_file(path, cursor_line, cursor_character)
    end

    private def configure_editor_lsp_styles(editor : Tui::TextEditor, buffer : OpenBuffer) : Nil
      @document_orchestrator.configure_editor_lsp_styles(editor, buffer)
    end

    private def file_tab_label(buffer : OpenBuffer?) : String
      @document_orchestrator.file_tab_label(buffer)
    end

    private def rename_tab(buffer : OpenBuffer) : Nil
      @document_orchestrator.rename_tab(buffer)
    end

    private def close_tab(tab_id : String) : Nil
      @document_orchestrator.close_tab(tab_id)
    end

    private def close_active_tab : Nil
      @document_orchestrator.close_active_tab
    end

    private def save_active : Nil
      @document_orchestrator.save_active
    end

    private def jump_back : Nil
      @document_orchestrator.jump_back
    end

    private def jump_forward : Nil
      @document_orchestrator.jump_forward
    end

    private def prune_navigation_history : Nil
      @document_orchestrator.prune_navigation_history
    end

    private def prune_navigation_forward_history : Nil
      @document_orchestrator.prune_navigation_forward_history
    end

    private def uri_to_path(uri : String) : Path?
      @document_orchestrator.uri_to_path(uri)
    end
  end
end
