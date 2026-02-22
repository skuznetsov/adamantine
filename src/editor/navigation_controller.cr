require "crystal_tui"

module CrystalEditor
  module NavigationController
    private def focus_active_editor : Nil
      if editor = current_editor
        editor.focus
      end
    end

    private def move_editor_cursor(editor : Tui::TextEditor, line : Int32, character : Int32) : Nil
      editor.set_cursor(line, character)
    end

    private def current_editor : Tui::TextEditor?
      if active = @editor_tabs.active_tab_id
        @document_session.open_buffers[active]?.try(&.editor)
      end
    end

    private def current_buffer : OpenBuffer?
      if active = @editor_tabs.active_tab_id
        @document_session.open_buffers[active]?
      end
    end

    private def switch_to_next_tab : Nil
      tab_count = @editor_tabs.tabs.size
      if tab_count < 1
        @status_log.warning("No open tabs")
        return
      end

      next_tab = (@editor_tabs.active_tab + 1) % tab_count
      @editor_tabs.active_tab = next_tab
      focus_active_editor
      update_header
    end

    private def switch_to_previous_tab : Nil
      tab_count = @editor_tabs.tabs.size
      if tab_count < 1
        @status_log.warning("No open tabs")
        return
      end

      prev_tab = @editor_tabs.active_tab - 1
      prev_tab = tab_count - 1 if prev_tab < 0
      @editor_tabs.active_tab = prev_tab
      focus_active_editor
      update_header
    end

    private def switch_to_tab_by_position(position : Int32) : Nil
      tab_count = @editor_tabs.tabs.size
      if position < 0 || position >= tab_count
        if tab_count > 0
          @status_log.warning("No tab at position #{position + 1}")
        else
          @status_log.warning("No open tabs")
        end
        return
      end

      @editor_tabs.active_tab = position
      focus_active_editor
      update_header
    end

    private def open_file(path : Path, cursor_line : Int32? = nil, cursor_character : Int32? = nil) : Bool
      path_str = path.to_s
      return false unless File.file?(path.to_s)

      if existing = @document_session.open_buffers[path_str]?
        style_editor(existing.editor, existing)
        @editor_tabs.switch_to(path_str)
        if cursor_line && cursor_character
          move_editor_cursor(existing.editor, cursor_line, cursor_character)
        end
        update_header
        focus_active_editor
        return true
      end

      editor = Tui::TextEditor.new(path_str)
      loaded = editor.load_file(path)
      unless loaded
        @status_log.error("Failed to open #{path}")
        return false
      end
      style_editor(editor, nil)

      language = detect_language(path)
      uri = path_to_uri(path)

      buffer = OpenBuffer.new(path, editor, language, uri)
      configure_editor_lsp_styles(editor, buffer)
      @document_session.open_buffers[path_str] = buffer

      editor.on_change do
        if local_buffer = @document_session.open_buffers[path_str]?
          local_buffer.version += 1
          rename_tab(local_buffer)
          sync_lsp_change(local_buffer)
          update_header
        end
      end

      editor.on_save do |saved_path|
        if local_buffer = @document_session.open_buffers[path_str]?
          sync_lsp_save(local_buffer)
          @status_log.success("Saved #{saved_path.basename}")
          rename_tab(local_buffer)
          update_header
        end
      end

      @editor_tabs.add_tab(path_str, file_tab_label(buffer)) { editor }
      @editor_tabs.switch_to(path_str)

      sync_lsp_open(buffer)
      if cursor_line && cursor_character
        move_editor_cursor(editor, cursor_line, cursor_character)
      end
      editor.focus
      update_header
      return true
    end

    private def configure_editor_lsp_styles(editor : Tui::TextEditor, buffer : OpenBuffer) : Nil
      editor.on_cell_style do |line, col, _char, style|
        lsp_diagnostic_style(buffer.diagnostics, line, col, style)
      end
    end

    private def file_tab_label(buffer : OpenBuffer?) : String
      return "unnamed" unless buffer
      modified = buffer.editor.modified? ? "*" : ""
      "#{buffer.path.basename}#{modified}"
    end

    private def rename_tab(buffer : OpenBuffer) : Nil
      @editor_tabs.rename_tab(buffer.path.to_s, file_tab_label(buffer))
    end

    private def close_tab(tab_id : String) : Nil
      if buffer = @document_session.open_buffers.delete(tab_id)
        close_lsp_document(buffer.uri)
        @status_log.info("Closed: #{buffer.path.basename}")
      end
      update_header
    end

    private def close_active_tab : Nil
      if @editor_tabs.active_tab_id
        @editor_tabs.close_active_tab
      else
        @status_log.warning("No active editor")
      end

      update_header if @document_session.open_buffers.empty?
    end

    private def save_active : Nil
      if editor = current_editor
        editor.save
      else
        @status_log.warning("No active editor")
      end
    end

    private def jump_back : Nil
      if @document_session.navigation_history.empty?
        @status_log.warning("No navigation history")
        return
      end

      current = current_lsp_context
      if current
        @document_session.navigation_forward_history << NavigationLocation.new(current[:uri], current[:line], current[:character])
      end

      last = @document_session.navigation_history.pop
      uri_to_path(last.uri).try do |path|
        if !open_file(path, last.line, last.character)
          @document_session.navigation_forward_history.pop?
          @status_log.error("Failed to restore #{path}")
        end
      end

      prune_navigation_forward_history
    end

    private def jump_forward : Nil
      if @document_session.navigation_forward_history.empty?
        @status_log.warning("No navigation forward history")
        return
      end

      current = current_lsp_context
      if current
        @document_session.navigation_history << NavigationLocation.new(current[:uri], current[:line], current[:character])
      end

      next_location = @document_session.navigation_forward_history.pop
      uri_to_path(next_location.uri).try do |path|
        if !open_file(path, next_location.line, next_location.character)
          @document_session.navigation_history.pop?
          @status_log.error("Failed to restore #{path}")
        end
      end

      prune_navigation_history
      prune_navigation_forward_history
    end

    private def uri_to_path(uri : String) : Path?
      UriCodec.uri_to_path(uri)
    end

    private def prune_navigation_forward_history : Nil
      return if @document_session.navigation_forward_history.size <= @document_session.navigation_history_limit
      overflow = @document_session.navigation_forward_history.size - @document_session.navigation_history_limit
      overflow.times { @document_session.navigation_forward_history.shift }
    end

    private def prune_navigation_history : Nil
      return if @document_session.navigation_history.size <= @document_session.navigation_history_limit
      overflow = @document_session.navigation_history.size - @document_session.navigation_history_limit
      overflow.times { @document_session.navigation_history.shift }
    end
  end
end
