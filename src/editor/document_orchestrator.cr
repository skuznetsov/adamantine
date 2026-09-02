require "crystal_tui"

module CrystalEditor
  class DocumentOrchestrator
    alias CurrentLspContext = NamedTuple(uri: String, line: Int32, character: Int32)?
    MAX_FILE_BYTES         = 16 * 1024 * 1024
    MAX_TEXT_PREVIEW_BYTES = 32 * 1024

    def initialize(
      @document_session : DocumentSession,
      @editor_tabs : Tui::TabbedPanel,
      @status_log : Tui::Log,
      @focus_editor : Proc(Tui::TextEditor, Nil),
      @style_editor : Proc(Tui::TextEditor, OpenBuffer?, Nil),
      @configure_editor_lsp_styles : Proc(Tui::TextEditor, OpenBuffer, Nil),
      @detect_language : Proc(Path, String),
      @path_to_uri : Proc(Path, String),
      @uri_to_path : Proc(String, Path?),
      @update_header : Proc(Nil),
      @sync_open : Proc(OpenBuffer, Nil),
      @sync_change : Proc(OpenBuffer, Nil),
      @sync_save : Proc(OpenBuffer, Nil),
      @close_lsp_document : Proc(String, Nil),
      @current_lsp_context : Proc(CurrentLspContext),
    )
    end

    def current_editor : Tui::TextEditor?
      if active = @editor_tabs.active_tab_id
        @document_session.open_buffers[active]?.try(&.editor)
      end
    end

    def current_buffer : OpenBuffer?
      if active = @editor_tabs.active_tab_id
        @document_session.open_buffers[active]?
      end
    end

    def move_editor_cursor(editor : Tui::TextEditor, line : Int32, character : Int32) : Nil
      editor.set_cursor(line, character)
    end

    def focus_active_editor : Nil
      if editor = current_editor
        @focus_editor.call(editor)
      end
    end

    def switch_to_next_tab : Nil
      tab_count = @editor_tabs.tabs.size
      if tab_count < 1
        @status_log.warning("No open tabs")
        return
      end

      next_tab = (@editor_tabs.active_tab + 1) % tab_count
      @editor_tabs.active_tab = next_tab
      focus_active_editor
      @update_header.call
    end

    def switch_to_previous_tab : Nil
      tab_count = @editor_tabs.tabs.size
      if tab_count < 1
        @status_log.warning("No open tabs")
        return
      end

      prev_tab = @editor_tabs.active_tab - 1
      prev_tab = tab_count - 1 if prev_tab < 0
      @editor_tabs.active_tab = prev_tab
      focus_active_editor
      @update_header.call
    end

    def switch_to_tab_by_position(position : Int32) : Nil
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
      @update_header.call
    end

    def switch_to_tab_by_position_buffer(path_str : String) : Nil
      return if @document_session.open_buffers.empty?
      return unless @document_session.open_buffers[path_str]?

      @editor_tabs.switch_to(path_str)
      focus_active_editor
      @update_header.call
    end

    def open_file(path : Path, cursor_line : Int32? = nil, cursor_character : Int32? = nil) : Bool
      path_str = path.to_s
      return false unless File.file?(path.to_s)
      begin
        file_size = File.info(path.to_s).size
        if file_size > MAX_FILE_BYTES
          @status_log.warning("Refusing to open large file #{path}: #{file_size} bytes > #{MAX_FILE_BYTES}")
          return false
        end
        return false unless text_file?(path, file_size.to_u64)
      rescue
        @status_log.warning("Failed to stat file #{path}")
        return false
      end

      if existing = @document_session.open_buffers[path_str]?
        safe_invoke("style_editor", path_str) do
          @style_editor.call(existing.editor, existing)
        end
        @editor_tabs.switch_to(path_str)
        if cursor_line && cursor_character
          move_editor_cursor(existing.editor, cursor_line, cursor_character)
        end
        @update_header.call
        focus_active_editor
        return true
      end

      editor = Tui::TextEditor.new(path_str)
      loaded = editor.load_file(path)
      unless loaded
        @status_log.error("Failed to open #{path}")
        return false
      end
      safe_invoke("style_editor", path_str) do
        @style_editor.call(editor, nil)
      end

      language = @detect_language.call(path)
      uri = @path_to_uri.call(path)

      buffer = OpenBuffer.new(path, editor, language, uri)
      safe_invoke("configure_editor_lsp_styles", path_str) do
        @configure_editor_lsp_styles.call(editor, buffer)
      end
      @document_session.open_buffers[path_str] = buffer

      editor.on_change do
        if local_buffer = @document_session.open_buffers[path_str]?
          local_buffer.version += 1
          rename_tab(local_buffer)
          safe_invoke("sync_change", path_str) do
            @sync_change.call(local_buffer)
          end
          @update_header.call
        end
      end

      editor.on_save do |saved_path|
        if local_buffer = @document_session.open_buffers[path_str]?
          safe_invoke("sync_save", path_str) do
            @sync_save.call(local_buffer)
          end
          @status_log.success("Saved #{saved_path.basename}")
          rename_tab(local_buffer)
          @update_header.call
        end
      end

      @editor_tabs.add_tab(path_str, file_tab_label(buffer)) { editor }
      @editor_tabs.switch_to(path_str)

      @sync_open.call(buffer)
      if cursor_line && cursor_character
        move_editor_cursor(editor, cursor_line, cursor_character)
      end
      @focus_editor.call(editor)
      @update_header.call
      true
    end

    private def text_file?(path : Path, file_size : UInt64) : Bool
      preview_size = [MAX_TEXT_PREVIEW_BYTES, file_size.to_i].min
      bytes = Bytes.new(preview_size)
      return true if file_size == 0_u64
      read_bytes = File.open(path, "rb") do |file|
        file.read(bytes)
      end

      sample = bytes[0, read_bytes]
      return false if sample.includes?(0_u8)

      begin
        String.new(sample).valid_encoding?
      rescue
        false
      end
    rescue
      false
    end

    def close_tab(tab_id : String) : Nil
      if buffer = @document_session.open_buffers.delete(tab_id)
        safe_invoke("close_lsp_document", buffer.uri) do
          @close_lsp_document.call(buffer.uri)
        end
        @status_log.info("Closed: #{buffer.path.basename}")
      end
      @update_header.call
    end

    def close_active_tab : Nil
      if @editor_tabs.active_tab_id
        @editor_tabs.close_active_tab
      else
        @status_log.warning("No active editor")
      end

      @update_header.call if @document_session.open_buffers.empty?
    end

    def save_active : Nil
      if editor = current_editor
        editor.save
      else
        @status_log.warning("No active editor")
      end
    end

    def jump_back : Nil
      if @document_session.navigation_history.empty?
        @status_log.warning("No navigation history")
        return
      end

      current = @current_lsp_context.call
      if current
        @document_session.navigation_forward_history << NavigationLocation.new(current[:uri], current[:line], current[:character])
      end

      last = @document_session.navigation_history.pop
      @uri_to_path.call(last.uri).try do |path|
        if !open_file(path, last.line, last.character)
          @document_session.navigation_forward_history.pop?
          @status_log.error("Failed to restore #{path}")
        end
      end

      prune_navigation_forward_history
    end

    def jump_forward : Nil
      if @document_session.navigation_forward_history.empty?
        @status_log.warning("No navigation forward history")
        return
      end

      current = @current_lsp_context.call
      if current
        @document_session.navigation_history << NavigationLocation.new(current[:uri], current[:line], current[:character])
      end

      next_location = @document_session.navigation_forward_history.pop
      @uri_to_path.call(next_location.uri).try do |path|
        if !open_file(path, next_location.line, next_location.character)
          @document_session.navigation_history.pop?
          @status_log.error("Failed to restore #{path}")
        end
      end

      prune_navigation_history
      prune_navigation_forward_history
    end

    def prune_navigation_forward_history : Nil
      history = @document_session.navigation_forward_history
      limit = @document_session.navigation_history_limit
      return if history.size <= limit
      history.shift(history.size - limit)
    end

    def prune_navigation_history : Nil
      history = @document_session.navigation_history
      limit = @document_session.navigation_history_limit
      return if history.size <= limit
      history.shift(history.size - limit)
    end

    def configure_editor_lsp_styles(editor : Tui::TextEditor, buffer : OpenBuffer) : Nil
      @configure_editor_lsp_styles.call(editor, buffer)
    end

    def uri_to_path(uri : String) : Path?
      @uri_to_path.call(uri)
    end

    def file_tab_label(buffer : OpenBuffer?) : String
      return "unnamed" unless buffer
      modified = buffer.editor.modified? ? "*" : ""
      "#{buffer.path.basename}#{modified}"
    end

    def rename_tab(buffer : OpenBuffer) : Nil
      @editor_tabs.rename_tab(buffer.path.to_s, file_tab_label(buffer))
    end

    private def safe_invoke(label : String, path : String, &)
      yield
    rescue ex
      message = ex.message || ex.class.to_s
      @status_log.warning("Orchestrator callback failed (#{label}) for #{path}: #{message}")
    end
  end
end
