require "crystal_tui"
require "json"

require "../adamantine/clipboard"
require "../adamantine/editable_input"
require "../adamantine/editable_input_controller"
require "../adamantine/editable_input_renderer"
require "../adamantine/lsp_client"
require "../adamantine/document_session"
require "../adamantine/session_controller"
require "../adamantine/document_types"
require "../adamantine/recovery_controller"
require "../adamantine/recovery_review"
require "../adamantine/recovery_review_controller"
require "../adamantine/recovery_review_ui_controller"
require "../adamantine/lsp_action"
require "../adamantine/document_orchestrator"
require "../adamantine/command_palette"
require "../adamantine/modal_manager"
require "../adamantine/inline_preview_renderer"
require "../adamantine/close_confirmation_controller"
require "../adamantine/external_review_controller"
require "../adamantine/input_router"
require "../adamantine/navigation_controller"
require "../adamantine/overlay_controller"
require "../adamantine/lsp_controller"
require "../adamantine/lexical_controller"
require "../adamantine/input_mode_controller"
require "../adamantine/uri_codec"
require "../adamantine/key_config"
require "../adamantine/theme"
require "../adamantine/search_state"
require "../adamantine/search_panel"
require "../adamantine/project_search"
require "../adamantine/quick_open_search"
require "../adamantine/quick_open_state"
require "../adamantine/quick_open_controller"
require "../adamantine/problems_state"
require "../adamantine/problems_controller"
require "../adamantine/lsp_popup_state"
require "../adamantine/context_menu_state"
require "../adamantine/command_palette_state"
require "../adamantine/editor_config"
require "../adamantine/settings_state"
require "../adamantine/language_registry"
require "../adamantine/lsp_registry"
require "../adamantine/semantic_tokens"
require "../adamantine/folding"
require "../adamantine/hyperclick"
require "../adamantine/box_drawing"
require "../adamantine/git_controller"
require "../adamantine/git_gutter_controller"

module Adamantine
  # Startup log entries may be added before SplitContainer assigns the log's
  # first real rect. Recompute auto-scroll once the first frame has geometry.
  private class StartupStatusLog < Tui::Log
    @first_layout_pending = true

    def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      if @first_layout_pending && !rect.empty?
        @first_layout_pending = false
        scroll_to_bottom if auto_scroll
      end

      super
    end
  end

  class App < Tui::App
    include CommandPalette
    include EditableInputController
    include InputModeController
    include OverlayController
    include SearchPanel
    include InputRouter
    include ModalManager
    include InlinePreviewRenderer
    include CloseConfirmationController
    include ExternalReviewController
    include RecoveryReviewControllerUi
    include NavigationController
    include LspController
    include LexicalController
    include QuickOpenController
    include ProblemsController
    include BoxDrawing
    include GitController
    include GitGutterController
    alias InputMode = InputModeController::InputMode

    alias SettingsMode = SettingsState::Mode

    EDITOR_TITLE = ENV["ADAMANTINE_TITLE"]? || ENV["EDITOR_TITLE"]? || "Adamantine"

    FILE_PANEL_RATIO             = 0.22
    BODY_LOG_RATIO               = 0.84
    STATUS_LOG_MAX_ENTRIES       =  200
    MIN_FILE_PANEL_WIDTH         =   18
    MIN_EDITOR_WIDTH             =   24
    MIN_SPLIT_EDITOR_WIDTH       = MIN_EDITOR_WIDTH * 2 + 3
    MIN_LOG_HEIGHT               =  6
    RECOVERY_MENU_PAGE_SIZE      =  2
    RECOVERY_MENU_LABEL_MAX      = 56
    SESSION_RESTORE_MAX_BYTES    = 64_i64 * 1024 * 1024
    LSP_RESPONSE_SETTINGS_ACTION = "setting:lsp.max_response_mib"
    EDITOR_INDENT_WIDTH_ACTION   = "setting:editor.indent_width"
    EDITOR_AUTO_INDENT_ACTION    = "setting:editor.auto_indent"
    LSP_RESPONSE_PRESETS         = [1, 4, 8, 16, 32, 64]

    COMMAND_ENTRIES = [
      CommandEntry.new("Help", "help", ["help", "?"], "Show command help", "", "app.help", true),
      CommandEntry.new("Save", "w", ["w", "write"], "Save active file", "", "app.save"),
      CommandEntry.new("Close tab", "q", ["q", "close"], "Close active tab", "", "app.close_tab"),
      CommandEntry.new("Split editor right", "splitright", ["splitright"], "Open a side-by-side editor group", "", "app.split_right"),
      CommandEntry.new("Focus next editor group", "focusnextgroup", ["focusnextgroup"], "Move focus between editor groups", "", "app.focus_next_group"),
      CommandEntry.new("Close editor split", "closesplit", ["closesplit"], "Collapse the split and keep all tabs open", "", "app.close_split"),
      CommandEntry.new("Quit editor", "quit", ["quit", "exit", "qa"], "Quit editor", "", "app.quit"),
      CommandEntry.new("Save and quit", "wq", ["wq", "wx", "writequit"], "Save and quit"),
      CommandEntry.new("Open file", "open", ["open", "e", "edit"], "Open a file by path", "<path>"),
      CommandEntry.new("Apply theme", "theme", ["theme"], "Apply a theme preset by name", "<name>"),
      CommandEntry.new("List themes", "themes", ["themes"], "List available themes"),
      CommandEntry.new("LSP status", "lsp", ["lsp"], "Show LSP status; restart reconnects the configured server", "", "lsp.status"),
      CommandEntry.new("Restart LSP", "lsp restart", [] of String, "Restart the configured language server"),
      CommandEntry.new("Format document", "format", ["format"], "Preview LSP formatting for the active document"),
      CommandEntry.new("Review external changes", "external", ["external"], "Compare editor text with external disk changes", "", "app.review_external"),
      CommandEntry.new("Git browser", "git", ["git"], "Browse repository status, history and diff (read-only)"),
      CommandEntry.new("Next tab", "tabnext", ["tabnext", "next", "bnext", "bn"], "Activate the next tab", "", "app.next_tab"),
      CommandEntry.new("Previous tab", "tabprev", ["tabprev", "prev", "bprev", "bp"], "Activate the previous tab", "", "app.previous_tab"),
      CommandEntry.new("Focus project tree", "tree", ["tree", "focus-tree", "tree-focus"], "Focus project tree", "", "app.focus_tree"),
      CommandEntry.new("Focus editor", "focus-editor", ["focus-editor", "edit-focus"], "Focus active editor", "", "app.focus_editor"),
      CommandEntry.new("Reload theme", "open-theme", ["open-theme"], "Reload the active theme file", "", "app.reload_theme"),
      CommandEntry.new("List buffers", "ls", ["ls", "buffers"], "List open buffers"),
      CommandEntry.new("Jump back", "jumpback", ["jumpback", "pop"], "Jump back in navigation history", "", "app.jump_back"),
      CommandEntry.new("Jump forward", "jumpforward", ["jumpforward", "jf"], "Jump forward in navigation history", "", "app.jump_forward"),
      CommandEntry.new("Undo", "undo", ["undo"], "Undo the last edit in the active editor", "", "app.undo"),
      CommandEntry.new("Redo", "redo", ["redo"], "Redo the last undone edit in the active editor", "", "app.redo"),
      CommandEntry.new("Settings", "settings", ["settings"], "Open settings dialog", "", "app.settings"),
      CommandEntry.new("Rename symbol", "rename", ["rename"], "Preview an LSP rename", "<new name>"),
      CommandEntry.new("Quick fix", "quickfix", ["quickfix", "quick-fix", "qf"], "Preview an applicable LSP quick fix"),
      CommandEntry.new("Select buffer", "buf", ["buf", "buffer"], "Select a buffer by index or name", "<index|name>"),
      CommandEntry.new("Find in file", "search", ["search", "find"], "Open find panel for the current file", "", "app.find"),
      CommandEntry.new("Find in project", "grep", ["grep", "rg"], "Open project search panel", "", "app.find_in_project"),
      CommandEntry.new("Recovery", "recover", ["recover"], "Open abandoned recovery checkpoints"),
      CommandEntry.new("Editor option", "set", ["set"], "Show or set editor options", "<option=value>"),
      CommandEntry.new("Change directory", "cd", ["cd"], "Change project root and file tree path", "<path>"),
      CommandEntry.new("Print directory", "pwd", ["pwd", "cwd"], "Show the current working directory"),
      CommandEntry.new("Set mark", "mark", ["mark"], "Set a local mark", "<letter>"),
      CommandEntry.new("List marks", "marks", ["marks"], "List local marks"),
      CommandEntry.new("Jump to mark", "jump", ["jump"], "Jump to a local mark", "<letter>"),
      CommandEntry.new("Replace text", "replace", ["replace", "s", "r"], "Replace text using /old/new/ flags", "<old/new>"),
    ]

    @project_root : Path
    @file_panel : Tui::FilePanel
    @editor_tabs : Tui::TabbedPanel
    @right_editor_tabs : Tui::TabbedPanel? = nil
    @editor_group_split : Tui::SplitContainer? = nil
    @active_editor_group : Int32 = 0
    @status_log : Tui::Log
    @header : Tui::Header
    @footer : Tui::Footer
    @body_split : Tui::SplitContainer
    @file_panel_split : Tui::SplitContainer
    @document_session : DocumentSession
    @document_orchestrator : DocumentOrchestrator
    @session_controller : SessionController
    @session_lifecycle_active : Bool = false
    @recovery_controller : RecoveryController
    @recovery_review_controller : RecoveryReviewController
    @recovery_menu_candidates : Array(RecoveryController::RecoveryCandidate) = [] of RecoveryController::RecoveryCandidate
    @recovery_menu_page : Int32 = 0
    @on_editor_hyperclick : Proc(Int32, Int32, Tui::Modifiers, Nil)?
    @lsp : Lsp::Client?
    @lsp_action_running : Bool = false
    @lsp_action_queued : InteractiveLspRequest? = nil
    @lsp_action_generation : UInt64 = 0_u64
    @context_menu : ContextMenuState = ContextMenuState.new
    @lsp_popup : LspPopupState = LspPopupState.new
    @git_view : GitViewState = GitViewState.new
    @git_gutter : GitGutterState = GitGutterState.new
    @key_bindings : KeyConfig::ActionMap = KeyConfig.defaults
    # The effective map drives dispatch and discovery; this sparse layer is
    # the provenance needed to persist explicit unbinds without serializing
    # inherited defaults.
    @key_overrides : KeyConfig::ActionMap = KeyConfig::ActionMap.new
    @input_mode_controller : InputModeController::ModeStack = InputModeController::ModeStack.new
    @command_palette : CommandPaletteState = CommandPaletteState.new
    @search : SearchState = SearchState.new
    @project_search_cancellation : ProjectSearch::Cancellation? = nil
    @quick_open : QuickOpenState = QuickOpenState.new
    @problems : ProblemsState = ProblemsState.new
    @buffer_search_pending : SearchPanel::BufferSearchRequest? = nil
    @buffer_search_running : SearchPanel::BufferSearchRequest? = nil
    @buffer_search_worker_active : Bool = false
    @buffer_search_generation : UInt64 = 0_u64
    @settings : SettingsState = SettingsState.new
    @keymap_path : String? = nil
    @theme_path : String? = nil
    @clipboard : Clipboard::Service
    @clipboard_paste_generation : UInt64 = 0_u64

    def initialize(
      project_root : Path,
      lsp_command : String? = nil,
      lsp_args : Array(String) = [] of String,
      keymap_path : String? = nil,
      theme_path : String? = nil,
      recovery_root : Path? = nil,
      clipboard_backend : Clipboard::Backend? = nil,
      session_root : Path? = nil,
      session_enabled : Bool? = nil,
    )
      super()

      resolved_root = project_root
      raise "Invalid project root: #{resolved_root}" unless File.directory?(resolved_root.to_s)
      @project_root = resolved_root
      @theme_path = resolve_theme_path(theme_path)
      theme_loaded = Theme.load(@theme_path)

      @file_panel = Tui::FilePanel.new(@project_root, id: "project-tree")

      @editor_tabs = Tui::TabbedPanel.new("tabs")
      @editor_tabs.show_close_button = true

      @status_log = StartupStatusLog.new("status")
      @status_log.max_entries = STATUS_LOG_MAX_ENTRIES
      if theme_loaded
        @status_log.info("Theme loaded: #{Theme.name}")
      elsif (theme_error = Theme.load_error)
        @status_log.warning("Theme load failed: #{theme_error}")
      end
      @clipboard = Clipboard::Service.new(
        clipboard_backend || Clipboard::SystemBackend.default,
        ->(result : Clipboard::Result) { report_clipboard_result(result) }
      )
      @document_session = DocumentSession.new
      @session_controller = SessionController.new(
        session_root,
        session_enabled,
        ->(message : String) { @status_log.warning(message) }
      )
      @recovery_controller = RecoveryController.new(
        project: @project_root,
        buffers: -> { @document_session.open_buffers },
        root: recovery_root,
        report: ->(message : String) { @status_log.warning(message) }
      )
      @recovery_review_controller = RecoveryReviewController.new(
        project: @project_root,
        buffers: -> { @document_session.open_buffers },
        report: ->(message : String) { @status_log.warning(message) }
      )
      @header = Tui::Header.new("header", EDITOR_TITLE)
      @header.subtitle = "No file opened"
      @header.show_clock = true
      @header.start_clock
      @document_orchestrator = build_document_orchestrator
      @on_editor_hyperclick = ->(line : Int32, col : Int32, modifiers : Tui::Modifiers) do
        hyperclick_at(line, col, modifiers)
      end
      configure_editor_group_panel(@editor_tabs)
      @document_orchestrator.configure_editor_groups(
        -> { active_editor_tabs },
        ->(path : String) { editor_tabs_for_path_internal(path) },
        ->(panel : Tui::TabbedPanel) { activate_editor_group_internal(panel) }
      )
      @document_orchestrator.on_change do |buffer, change|
        git_gutter_buffer_changed(buffer)
        clear_buffer_diagnostics(buffer)
        # Published semantic positions belong to the previous text revision.
        # Invalidate even when the server is absent or disconnected.
        buffer.semantic_overlay = SemanticOverlay.empty
        buffer.semantic_generation += 1
        lexical_buffer_changed(buffer, change)
        search_buffer_changed(buffer)
        sync_lsp_change(buffer, change)
      end
      @keymap_path = resolve_keymap_path(keymap_path)
      key_layers = load_key_layers(@keymap_path)
      @key_bindings = key_layers.effective
      @key_overrides = key_layers.overrides
      @settings.max_response_mib = SettingsConfig.load(@keymap_path, ->(message : String) { @status_log.warning(message) })
      editing_settings = SettingsConfig.load_editing(@keymap_path, ->(message : String) { @status_log.warning(message) })
      @settings.indent_width = editing_settings.indent_width
      @settings.auto_indent = editing_settings.auto_indent
      KeyConfig.duplicate_binding_warnings(@key_bindings).each do |warning|
        @status_log.warning(warning)
      end

      @status_log.info("Project: #{@project_root}")
      @status_log.info("Tip: #{key_hint("app.open_file_tree")} tree | #{key_hint("app.save")} save | #{key_hint("app.close_tab")} close | #{key_hint("app.next_tab")} / #{key_hint("app.goto_tab_1")}..9 switch")
      @status_log.info("Tip: #{key_hint("app.previous_tab")} previous tab | #{key_hint("lsp.status")} LSP status | #{key_hint("app.quit")} quit | #{key_hint("app.help")} | #{key_hint("app.settings")}")
      @status_log.info("Tip: #{key_hint("app.reload_theme")} reload theme | #{key_hint("app.jump_back")} jump back | #{key_hint("app.jump_forward")} jump forward")
      @status_log.info("Tip: #{key_hint("app.undo")} undo | #{key_hint("app.redo")} redo")
      @status_log.info("Tip: #{key_hint("app.copy")} copy | #{key_hint("app.cut")} cut | #{key_hint("app.paste")} paste")
      @status_log.info("Tip: #{key_hint("app.find")} find in file | #{key_hint("app.find_in_project")} find in project")
      @status_log.info("Tip: #{key_hint("app.command_palette")} discovers actions | Esc+Esc opens raw command mode")
      @status_log.info("Tip: #{key_hint("app.quick_actions")} quick actions | #{key_hint("lsp.goto_definition")} go to definition | #{key_hint("app.jump_back")} back | #{key_hint("app.jump_forward")} forward")
      @status_log.info("Tip: #{key_hint("lsp.hover")} hover | #{key_hint("lsp.references")} references | #{key_hint("lsp.signature")} signature | #{key_hint("lsp.context_menu")} LSP menu")
      @status_log.info("Tip: Shift+Click jumps to definition or shows usages; Shift+Alt+Click always shows references")
      @status_log.info("Tip: theme #{Theme.name}, settings: Enter to switch keymap/theme")

      @file_panel.on_activate do |entry|
        if entry && !entry.is_dir
          open_file(@file_panel.path / entry.name)
        elsif entry && entry.is_dir
          @status_log.info("Folder: #{entry.name}")
          mark_dirty!
        end
      end

      connect_lsp_if_requested(lsp_command, lsp_args)

      @file_panel_split = Tui::SplitContainer.new(
        direction: Tui::SplitContainer::Direction::Horizontal,
        ratio: FILE_PANEL_RATIO,
        id: "file-editor-split"
      )
      @file_panel_split.first = @file_panel
      @file_panel_split.second = @editor_tabs
      @file_panel_split.show_border = true
      @file_panel_split.first_title = "Project"
      @file_panel_split.second_title = "Editors"
      @file_panel_split.min_first = MIN_FILE_PANEL_WIDTH
      @file_panel_split.min_second = MIN_EDITOR_WIDTH

      @body_split = Tui::SplitContainer.new(
        direction: Tui::SplitContainer::Direction::Vertical,
        ratio: BODY_LOG_RATIO,
        id: "body-split"
      )
      @body_split.show_border = false
      @body_split.first = @file_panel_split
      @body_split.second = @status_log
      @body_split.min_second = MIN_LOG_HEIGHT

      @editor_tabs.positions = Set{Tui::TabbedPanel::TabPosition::Top}

      @footer = Tui::Footer.mc_style
      @footer.bindings = [
        Tui::Footer::Binding.new(1, "Help", :help),
        Tui::Footer::Binding.new(2, "Tree", :tree),
        Tui::Footer::Binding.new(3, "Save", :save),
        Tui::Footer::Binding.new(4, "Close", :close),
        Tui::Footer::Binding.new(5, "Reload", :reload),
        Tui::Footer::Binding.new(6, "Log", :log),
        Tui::Footer::Binding.new(7, "Prev", :prev),
        Tui::Footer::Binding.new(8, "Next", :next),
        Tui::Footer::Binding.new(9, "LSP", :lsp),
        Tui::Footer::Binding.new(10, "Quit", :quit),
      ]
      @footer.on_click do |binding|
        case binding.key
        when 1
          show_help
        when 2
          @file_panel.focus
        when 3
          save_active
        when 4
          close_active_tab
        when 5
          refresh_file_tree
        when 6
          @status_log.clear
        when 7
          switch_to_previous_tab
        when 8
          switch_to_next_tab
        when 9
          show_lsp_status
        when 10
          quit
        end
      end
      apply_theme
      update_header
    end

    def compose : Array(Tui::Widget)
      [@header, @body_split, @footer] of Tui::Widget
    end

    def run : Nil
      # Session restore is part of the real UI lifecycle, not construction;
      # restore it before recovery choices are presented.
      start_session_lifecycle
      if @recovery_controller.start
        # The startup scan is explicit and happens once.  The periodic worker
        # only writes current buffers; it never rescans abandoned sessions.
        open_recovery_menu
      end
      @document_orchestrator.start_external_file_monitor
      super
    ensure
      @lexical_shutdown = true
      close_recovery_review
      close_git_view
      git_gutter_shutdown
      shutdown_lsp
      @clipboard.close
      @document_orchestrator.stop_external_file_monitor
      @recovery_controller.stop(force: true)
      cancel_search_workers
      cancel_quick_open_search
      close_problems
    end

    def quit(force : Bool = false) : Nil
      if force
        close_external_review
        close_recovery_review
        cancel_close_confirmation
      elsif !@close_quit_committing
        request_reviewed_quit
        return
      end

      # Commit boundary: no yielding work separates the final live review
      # from retiring the monitor's in-flight observations. Session/recovery
      # I/O below may yield, but cannot reopen the reviewed decision set.
      @document_orchestrator.stop_external_file_monitor

      # Cancelled quits return above and must not publish a newer UI snapshot.
      # A successful snapshot makes this lifecycle single-shot so a repeated
      # quit/cleanup path cannot overwrite it with a later partial view.
      if @session_lifecycle_active && save_session_state(@project_root)
        @session_lifecycle_active = false
        @session_controller.deactivate
      end

      @clipboard.close
      @recovery_controller.stop(force: force)
      @lexical_shutdown = true
      close_git_view
      git_gutter_shutdown
      cancel_search_workers
      cancel_quick_open_search
      close_problems
      shutdown_lsp
      super()
    end

    # Activate persistence only when the caller has entered the application
    # lifecycle.  This hook is intentionally private; integration tests and
    # the real run loop reach it through the same lifecycle boundary.
    private def start_session_lifecycle : Bool
      return true if @session_lifecycle_active

      @session_lifecycle_active = true
      @session_controller.activate
      restore_session_state(@project_root)
      true
    rescue ex
      @status_log.warning("Session restore failed: #{ex.message || ex.class}")
      true
    end

    # Capture only bounded, canonical UI metadata.  Source text, undo history,
    # and executable/LSP settings never cross the session persistence boundary.
    private def save_session_state(root : Path? = nil) : Bool
      return false unless @session_lifecycle_active

      project_root = root || @project_root
      snapshot = session_snapshot(project_root)
      return false unless snapshot

      @session_controller.save(snapshot.not_nil!)
    rescue ex
      @status_log.warning("Session save failed: #{ex.message || ex.class}")
      false
    end

    private def session_snapshot(root : Path) : SessionStore::Snapshot?
      canonical_root = session_real_path(root)
      tabs = [] of SessionStore::TabState
      active_index : Int32? = nil
      active_id = active_editor_tabs.active_tab_id

      editor_tab_groups.each do |panel|
        panel.tabs.each do |tab|
          buffer = @document_session.open_buffers[tab.id]?
          next unless buffer

          canonical_path = session_canonical_path(buffer.not_nil!.path, canonical_root)
          next unless canonical_path

          if duplicate_index = tabs.index { |entry| entry.path == canonical_path }
            active_index = duplicate_index.to_i32 if active_id == tab.id
            next
          end
          if tabs.size >= SessionStore::MAX_TABS
            @status_log.warning("Session snapshot exceeds #{SessionStore::MAX_TABS} tabs")
            return nil
          end

          editor = buffer.not_nil!.editor
          cursor = SessionStore::Position.new(
            editor.cursor_line.clamp(0, Int32::MAX),
            editor.cursor_col.clamp(0, Int32::MAX),
          )
          scroll_line = 0
          scroll_column = 0
          if session_editor = editor.as?(EditingTextEditor)
            scroll_line = session_editor.session_scroll_y
            scroll_column = session_editor.session_scroll_x
          end
          scroll = SessionStore::Position.new(scroll_line, scroll_column)
          tabs << SessionStore::TabState.new(canonical_path, cursor, scroll)
          active_index = (tabs.size - 1).to_i32 if active_id == tab.id
        end
      end

      SessionStore::Snapshot.new(canonical_root, tabs, active_index)
    rescue ex
      @status_log.warning("Session snapshot failed: #{ex.message || ex.class}")
      nil
    end

    # Restore against the current disk snapshot through the ordinary guarded
    # opener.  A bounded cumulative source budget prevents a large persisted
    # tab list from turning startup into an unbounded read/allocation event.
    private def restore_session_state(root : Path, max_bytes : Int64 = SESSION_RESTORE_MAX_BYTES) : Nil
      result = @session_controller.load(root)
      return unless result
      snapshot = result.not_nil!.state
      return unless snapshot

      canonical_root = session_real_path(root)
      state = snapshot.not_nil!
      unless session_real_path(state.project_root) == canonical_root
        @status_log.warning("Ignoring session state for another project root")
        return
      end

      remaining = max_bytes.clamp(0_i64, SESSION_RESTORE_MAX_BYTES)
      restored_ids = [] of String?
      seen_paths = [] of String
      skipped = 0
      restored = 0

      state.tabs.each_with_index do |tab, index|
        # Restoring only bounded persisted entries still permits a user to
        # have more already-open buffers.  Yield between restore batches, but
        # do not truncate identity lookup: a late dirty alias must not become
        # a duplicate merely because it is tab 129.
        Fiber.yield if index > 0 && index % 32 == 0
        canonical_path = session_canonical_path(tab.path, canonical_root)
        unless canonical_path
          restored_ids << nil
          skipped += 1
          next
        end

        path_key = canonical_path.to_s
        if seen_paths.includes?(path_key)
          restored_ids << nil
          skipped += 1
          next
        end
        seen_paths << path_key

        existing = existing_session_buffer(canonical_path, canonical_root)
        target = existing ? existing.not_nil!.path : canonical_path
        existing_buffer = !existing.nil?
        if existing.nil?
          size = session_source_size(target)
          unless size && size.not_nil! <= remaining && size.not_nil! <= DocumentOrchestrator::MAX_FILE_BYTES.to_i64
            restored_ids << nil
            skipped += 1
            next
          end
        end

        line = tab.cursor.line.clamp(0, Int32::MAX)
        column = tab.cursor.column.clamp(0, Int32::MAX)
        opened = if existing_buffer
                   # Existing buffers may contain unsaved edits.  Reusing the
                   # identity is more important than re-reading disk text;
                   # keep its current cursor, selection, and viewport too.
                   active_editor_tabs.switch_to(target.to_s)
                   @document_orchestrator.focus_active_editor
                   true
                 else
                   @document_orchestrator.open_file(target, line, column, max_bytes: remaining)
                 end
        unless opened
          restored_ids << nil
          skipped += 1
          next
        end

        actual = @document_session.open_buffers[target.to_s]?
        unless actual
          restored_ids << nil
          skipped += 1
          next
        end

        if !existing_buffer && (editor = actual.not_nil!.editor.as?(EditingTextEditor))
          editor.restore_session_view(
            tab.scroll.line.clamp(0, Int32::MAX),
            tab.scroll.column.clamp(0, Int32::MAX),
          )
        end
        restored_ids << target.to_s
        restored += 1
        if !existing_buffer
          loaded_bytes = if editor = actual.not_nil!.editor.as?(EditingTextEditor)
                           editor.search_byte_length.to_i64
                         else
                           0_i64
                         end
          remaining -= loaded_bytes
          remaining = 0_i64 if remaining < 0
        end
      end

      if active_index = state.active_tab
        if active_index >= 0 && active_index < restored_ids.size
          if active_id = restored_ids[active_index]
            active_editor_tabs.switch_to(active_id)
            @document_orchestrator.focus_active_editor
          end
        end
      end

      git_gutter_active_file_changed

      if restored > 0 || skipped > 0
        suffix = skipped > 0 ? "; skipped #{skipped}" : ""
        @status_log.info("Session restored #{restored} tab#{restored == 1 ? "" : "s"}#{suffix}")
      end
    rescue ex
      @status_log.warning("Session restore failed: #{ex.message || ex.class}")
    end

    private def existing_session_buffer(path : Path, root : Path) : OpenBuffer?
      @document_session.open_buffers.each_value do |buffer|
        candidate = session_canonical_path(buffer.path, root)
        return buffer if candidate && candidate == path
      end
      nil
    end

    private def session_source_size(path : Path) : Int64?
      return nil unless File.file?(path.to_s)
      File.size(path.to_s)
    rescue
      nil
    end

    private def session_real_path(path : Path) : Path
      Path.new(File.realpath(path.to_s))
    rescue
      path.expand
    end

    # Resolve symlinks for existing files and for the deepest existing parent
    # of a missing path.  This keeps persisted identities canonical while
    # rejecting intermediate symlink escapes from the project root.
    private def session_canonical_path(path : Path, root : Path) : Path?
      candidate = path.absolute? ? path.expand : (root / path).expand
      canonical = if File.exists?(candidate.to_s)
                    Path.new(File.realpath(candidate.to_s))
                  else
                    ancestor = candidate
                    while !File.exists?(ancestor.to_s)
                      parent = ancestor.parent
                      break if parent == ancestor
                      ancestor = parent
                    end
                    if File.exists?(ancestor.to_s)
                      suffix = candidate.to_s[ancestor.to_s.size..-1]? || ""
                      suffix = suffix.lstrip(File::SEPARATOR)
                      Path.new(File.realpath(ancestor.to_s), suffix)
                    else
                      candidate
                    end
                  end
      root_text = root.to_s
      candidate_text = canonical.to_s
      prefix = root_text.ends_with?(File::SEPARATOR) ? root_text : "#{root_text}#{File::SEPARATOR}"
      return nil unless candidate_text == root_text || candidate_text.starts_with?(prefix)
      canonical
    rescue
      nil
    end

    private def build_document_orchestrator : DocumentOrchestrator
      orchestrator : DocumentOrchestrator? = nil
      orchestrator = DocumentOrchestrator.new(
        @document_session,
        @editor_tabs,
        @status_log,
        ->(editor : Tui::TextEditor) { editor.focus },
        ->(editor : Tui::TextEditor, buffer : OpenBuffer?) { style_editor(editor, buffer) },
        ->(editor : Tui::TextEditor, buffer : OpenBuffer) { configure_editor_lsp_styles_internal(editor, buffer) },
        ->(path : Path) { detect_language(path) },
        ->(path : Path) { path_to_uri(path) },
        ->(uri : String) { uri_to_path_internal(uri) },
        -> { update_header_internal },
        ->(buffer : OpenBuffer) { sync_lsp_open(buffer) },
        ->(buffer : OpenBuffer, change : Tui::TextEditor::TextChange) { sync_lsp_change(buffer, change) },
        ->(buffer : OpenBuffer) do
          git_gutter_buffer_saved(buffer)
          sync_lsp_save(buffer)
        end,
        ->(uri : String) { close_lsp_document(uri) },
        -> { current_lsp_context_internal },
        ->(buffer : OpenBuffer, conflict : ExternalFileConflict) do
          git_gutter_external_conflict(buffer)
          show_external_file_conflict(orchestrator.not_nil!, buffer, conflict)
        end
      )
      orchestrator.not_nil!
    end

    private def show_external_file_conflict(
      orchestrator : DocumentOrchestrator,
      buffer : OpenBuffer,
      conflict : ExternalFileConflict,
    ) : Nil
      # A monitor notification is not permission to take keyboard focus or
      # replace an existing review. The captured candidate remains unresolved
      # until the user explicitly requests review.
      @status_log.warning("External change in #{buffer.path}; #{key_hint("app.review_external")} / :external to review, or Save")
      mark_dirty!
    end

    private def layout_children : Nil
      return if @children.empty?

      if @editor_group_split && estimated_editor_width(@rect.width) < MIN_SPLIT_EDITOR_WIDTH
        collapse_editor_split
        @status_log.warning("Editor split collapsed after resize; widen the window and use :splitright to reopen")
      end

      header_h = 1
      footer_h = 1
      body_h = [@rect.height - header_h - footer_h, 1].max

      @header.rect = Tui::Rect.new(@rect.x, @rect.y, @rect.width, header_h)
      @body_split.rect = Tui::Rect.new(@rect.x, @rect.y + header_h, @rect.width, body_h)
      @footer.rect = Tui::Rect.new(@rect.x, @rect.y + header_h + body_h, @rect.width, footer_h)
    end

    def on_capture(event : Tui::Event) : Bool
      if close_confirmation_active?
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::KeyEvent
          return handle_close_confirmation_input(event)
        when Tui::PasteEvent, Tui::MouseEvent
          return true
        end
      elsif external_review_active?
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::KeyEvent
          return handle_external_review_input(event)
        when Tui::PasteEvent, Tui::MouseEvent
          return true
        end
      elsif recovery_review_active?
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::KeyEvent
          return handle_recovery_review_input(event)
        when Tui::PasteEvent, Tui::MouseEvent
          return true
        end
      elsif command_palette_active?
        # The palette is a hard modal boundary: the focused editor must not
        # receive paste or mouse input while its overlay is visible.
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::KeyEvent
          route_key_event(event)
          return true
        when Tui::PasteEvent
          return handle_editable_input_paste(
            @command_palette.input_field,
            event.text,
            -> { command_palette_input_changed }
          )
        when Tui::MouseEvent
          return true
        end
      elsif git_view_active?
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::KeyEvent
          handle_git_input(event)
          return true
        when Tui::PasteEvent, Tui::MouseEvent
          return true
        end
      elsif formatting_popup_active? || quick_fix_popup_active?
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::KeyEvent
          allowed = quick_fix_popup_active? ? quick_fix_key_event?(event) : formatting_key_event?(event)
          return true unless allowed
        when Tui::PasteEvent, Tui::MouseEvent
          return true
        end
      elsif completion_popup_active?
        case event
        when Tui::KeyEvent
          unless completion_key_event?(event)
            # Completion owns the focused editor until it is explicitly
            # accepted/cancelled. A different key is consumed without handing
            # it to the editor or invalidating the captured request: the user
            # can still choose a row after an irrelevant key. Keep the modal
            # boundary until the user explicitly cancels it; this also keeps a
            # following paste/mouse event isolated.
            return true
          end
        when Tui::MouseEvent
          # Mouse input is not a completion selection gesture. Consume it
          # while retaining the popup and its captured authority.
          return true
        when Tui::PasteEvent
          # Never let bracketed paste reach the editor under the overlay.
          return true
        end
      elsif quick_open_active?
        # Invalidate any editor paste request that was started before this
        # modal event.  The modal owns the focused surface until it closes,
        # so a late clipboard callback must not mutate the editor underneath.
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::PasteEvent
          return handle_editable_input_paste(
            @quick_open.query_input,
            event.text,
            -> { on_quick_open_query_changed },
            -> { reject_quick_open_query_limit }
          )
        when Tui::MouseEvent
          # The query modal owns mouse input; it must not reach the focused
          # editor beneath the overlay.
          return true
        when Tui::KeyEvent
          route_key_event(event)
          return true
        end
      elsif search_panel_mode_active?
        # Search is an editable hard modal. Paste updates its query, while
        # mouse input remains isolated from the focused editor underneath.
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::PasteEvent
          return handle_editable_input_paste(
            @search.query_input,
            event.text,
            -> { on_search_query_changed }
          )
        when Tui::MouseEvent
          return true
        when Tui::KeyEvent
          route_key_event(event)
          return true
        end
      elsif problems_active?
        # Problems owns the focused surface until explicit accept/cancel.
        # Invalidate pending clipboard callbacks and consume every non-key
        # event so paste/mouse input cannot mutate the editor underneath.
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::PasteEvent, Tui::MouseEvent
          return true
        when Tui::KeyEvent
          route_key_event(event)
          return true
        end
      elsif context_menu_mode_active?
        # Context menus own the focused surface until an explicit menu action
        # closes them.  Route keys first so F1/quick-open can deliberately
        # replace the menu, but consume every other key, paste, and mouse
        # event instead of allowing it to reach the editor underneath.
        @clipboard_paste_generation &+= 1_u64
        case event
        when Tui::PasteEvent, Tui::MouseEvent
          return true
        when Tui::KeyEvent
          route_key_event(event)
          return true
        end
      elsif event.is_a?(Tui::MouseEvent) && (settings_mode_active? || lsp_popup_mode_active?)
        # Settings and generic LSP popups are render overlays rather than
        # child widgets, so mouse events would otherwise reach the focused
        # editor underneath them.
        invalidate_lsp_actions
        @clipboard_paste_generation &+= 1_u64
        return true
      elsif event.is_a?(Tui::MouseEvent) && activate_editor_group_at(event.x, event.y)
        invalidate_lsp_actions
      elsif event.is_a?(Tui::KeyEvent) || event.is_a?(Tui::MouseEvent)
        invalidate_lsp_actions
      end
      if !completion_popup_active? && !problems_active? && (event.is_a?(Tui::KeyEvent) || event.is_a?(Tui::MouseEvent) || event.is_a?(Tui::PasteEvent))
        cancel_repeat_search_on_input
        @clipboard_paste_generation &+= 1_u64
      end

      if event.is_a?(Tui::PasteEvent)
        # Overlays leave the editor focused underneath them. Do not let a
        # bracketed paste mutate that editor after a modal route declined it.
        return true unless active_input_mode == InputMode::Normal
        return super
      end

      return false unless event.is_a?(Tui::KeyEvent)
      return true if route_key_event(event)
      super
    end

    # A background LSP response must never wait for room in the input queue.
    # The event loop already observes the dirty flag, so dropping a redundant
    # wakeup when the bounded queue is full is safe.
    def wakeup : Nil
      select
      when @input.events.send(Tui::WakeupEvent.new)
      else
      end
    rescue
    end

    def on_event(event : Tui::Event) : Bool
      false
    end

    private def command_palette_entries : Array(CommandEntry)
      COMMAND_ENTRIES
    end

    private def command_entry(action : String) : CommandEntry?
      COMMAND_ENTRIES.find { |entry| entry.action == action }
    end

    # Keep F1 discovery and Quick Actions on the same cheap, read-only
    # preflight.  Raw colon commands intentionally continue to use the
    # operation's authoritative guard when executed.
    private def command_disabled_reason(entry : CommandEntry) : String?
      case entry.action
      when "search", "replace"
        return "No active editor" unless current_buffer && current_editor
      when "format"
        lsp_action_disabled_reason(InteractiveLspAction::Formatting)
      when "rename"
        lsp_action_disabled_reason(InteractiveLspAction::Rename)
      when "quickfix"
        lsp_action_disabled_reason(InteractiveLspAction::QuickFix)
      when "lsp restart"
        lsp_restart_disabled_reason
      when "external"
        buffer = current_buffer
        return "No active editor" unless buffer
        buffer.external_conflict ? nil : "No external changes to review"
      else
        nil
      end
    end

    private def open_recovery_menu : Nil
      unless @recovery_controller.initialized?
        # A constructed App is also used as a headless command harness.  Do
        # not create the user's real recovery directory from :recover there;
        # App.run owns the production lifecycle.  Tests can pass recovery_root
        # and initialize the controller explicitly.
        unless @recovery_controller.root
          @status_log.info("Recovery menu is available when the editor is running")
          return
        end
        return unless @recovery_controller.initialize_session
      end

      candidates = @recovery_controller.candidates
      if candidates.empty?
        @status_log.info("No abandoned recovery checkpoints")
        return
      end

      @recovery_menu_candidates = candidates
      @recovery_menu_page = 0
      open_recovery_menu_page
    end

    private def open_recovery_menu_page : Nil
      page_count = recovery_menu_page_count
      @recovery_menu_page = @recovery_menu_page.clamp(0, page_count - 1)
      first = @recovery_menu_page * RECOVERY_MENU_PAGE_SIZE
      page_candidates = @recovery_menu_candidates[first, RECOVERY_MENU_PAGE_SIZE] || [] of RecoveryController::RecoveryCandidate
      actions = [] of LspContextAction

      page_candidates.each do |candidate|
        selected = candidate
        actions << LspContextAction.new(
          "Review draft (read-only): #{recovery_menu_label(selected)}",
          "#{actions.size + 1}",
          -> do
            open_recovery_review(selected)
            nil
          end
        )
        actions << LspContextAction.new(
          "Open recovered copy: #{recovery_menu_label(selected)}",
          "#{actions.size + 1}",
          -> do
            if path = @recovery_controller.recover(selected)
              if open_file(path)
                @status_log.info("Opened private recovery copy for #{selected.source_path}; checkpoint retained")
              else
                @status_log.warning("Could not open recovery copy for #{selected.source_path}; checkpoint retained")
              end
            end
            nil
          end
        )
        actions << LspContextAction.new(
          "Discard checkpoint: #{recovery_menu_label(selected)}",
          "#{actions.size + 1}",
          -> do
            @recovery_controller.discard(selected)
            nil
          end
        )
      end

      if @recovery_menu_page > 0
        actions << LspContextAction.new(
          "Previous page (#{@recovery_menu_page}/#{page_count})",
          "#{actions.size + 1}",
          -> do
            @recovery_menu_page -= 1
            open_recovery_menu_page
            nil
          end
        )
      end
      if @recovery_menu_page + 1 < page_count
        actions << LspContextAction.new(
          "Next page (#{@recovery_menu_page + 2}/#{page_count})",
          "#{actions.size + 1}",
          -> do
            @recovery_menu_page += 1
            open_recovery_menu_page
            nil
          end
        )
      end

      open_context_menu("Abandoned Recovery Checkpoints", actions)
    end

    private def recovery_menu_page_count : Int32
      ((@recovery_menu_candidates.size + RECOVERY_MENU_PAGE_SIZE - 1) // RECOVERY_MENU_PAGE_SIZE).clamp(1, Int32::MAX)
    end

    private def recovery_menu_label(candidate : RecoveryController::RecoveryCandidate) : String
      version = candidate.version ? candidate.version.to_s : "unknown"
      session_id = candidate.session_id
      session_id = session_id[8, 8] if session_id.starts_with?("session-") && session_id.size > 8
      session_id = session_id[0, 8] unless session_id.empty? || session_id.size <= 8
      session = session_id.empty? ? "unknown session" : "session #{session_id}"
      suffix = " (version #{version}, #{session})"
      source = candidate.source_path.to_s
      max_source = [RECOVERY_MENU_LABEL_MAX - suffix.size, 1].max
      if source.size > max_source
        source = "…#{source[-(max_source - 1), max_source - 1]}"
      end
      label = "#{source}#{suffix}"
      return label if label.size <= RECOVERY_MENU_LABEL_MAX
      "#{label[0, RECOVERY_MENU_LABEL_MAX - 1]}…"
    end

    private def handle_settings_input(event : Tui::KeyEvent) : Bool
      case @settings.mode
      when SettingsState::Mode::Browse
        handle_settings_browse_input(event)
      when SettingsState::Mode::Capture
        handle_settings_capture_input(event)
      when SettingsState::Mode::ConfirmOverwrite
        handle_settings_confirm_input(event)
      when SettingsState::Mode::ConfirmUnbind
        handle_settings_unbind_confirm_input(event)
      else
        false
      end
    end

    private def handle_settings_browse_input(event : Tui::KeyEvent) : Bool
      return false unless @settings.open && !@settings.actions.empty?

      # Delete/Backspace are physical Settings controls.  They take priority
      # over any accidental menu-close remap so clearing a binding is always
      # discoverable and reversible through the confirmation prompt.
      if event.key == Tui::Key::Delete || event.key == Tui::Key::Backspace
        if action = selected_settings_binding_action
          @settings.capture_action = action
          @settings.capture_binding = ""
          @settings.conflicting_action = nil
          @settings.conflicting_actions.clear
          @settings.mode = SettingsState::Mode::ConfirmUnbind
          mark_dirty!
          return true
        end
      end

      if event.key == Tui::Key::Escape || action_pressed?("app.menu_close", event)
        close_settings_dialog
        return true
      elsif action_pressed?("app.settings", event)
        close_settings_dialog
        return true
      elsif event.key == Tui::Key::Up || action_pressed?("app.menu_up", event)
        move_settings_selection(-1)
        return true
      elsif event.key == Tui::Key::Down || action_pressed?("app.menu_down", event)
        move_settings_selection(1)
        return true
      elsif event.key == Tui::Key::Home || action_pressed?("app.menu_first", event)
        set_settings_selection(0)
        return true
      elsif event.key == Tui::Key::End || action_pressed?("app.menu_last", event)
        set_settings_selection(@settings.actions.size - 1)
        return true
      elsif event.key == Tui::Key::Enter || action_pressed?("app.menu_select", event)
        return execute_selected_settings_action
      end

      if char = event.char
        if char >= '1' && char <= '9'
          index = char - '1'
          if index >= 0 && index < @settings.actions.size
            set_settings_selection(index)
            return execute_selected_settings_action
          end
        end
      end

      # Settings owns the modal input boundary. Unknown keys must not leak
      # through to the focused editor behind the dialog.
      true
    end

    private def handle_settings_capture_input(event : Tui::KeyEvent) : Bool
      action = @settings.capture_action
      unless action
        close_settings_dialog
        return true
      end

      if action_pressed?("app.menu_close", event) || event.key == Tui::Key::Escape
        @status_log.info("Cancelled key remap")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      binding = event_to_binding(event)
      if binding.empty?
        @status_log.warning("Unsupported key combination")
        @settings.capture_binding = ""
        mark_dirty!
        return true
      end

      normalized = KeyConfig.normalize_binding(binding)
      @settings.capture_binding = normalized

      conflicts = KeyConfig.conflicting_actions(@key_bindings, action, normalized)
      if conflicts.empty?
        assign_key_binding(action, normalized)
        @status_log.success("Mapped #{action} to #{normalized}")
        reset_settings_capture_state
        mark_dirty!
      else
        @settings.conflicting_actions = conflicts
        @settings.conflicting_action = conflicts.first?
        @settings.mode = SettingsState::Mode::ConfirmOverwrite
      end

      mark_dirty!
      true
    end

    private def handle_settings_confirm_input(event : Tui::KeyEvent) : Bool
      action = @settings.capture_action
      unless action
        close_settings_dialog
        return true
      end

      # Confirmation keys are physical safety controls. Resolve them before
      # configurable menu actions so remapping select to N (or close to Y)
      # cannot invert the user's answer.
      if event.matches?("enter") || event.matches?("return") || event.matches?("y")
        assign_key_binding(action, @settings.capture_binding, remove_from_conflict: true)
        @status_log.success("Updated #{action} to #{@settings.capture_binding} (overwrote #{actions_for_settings_conflict})")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      if event.matches?("escape") || event.matches?("esc") || event.matches?("n")
        @status_log.info("Binding not changed")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      if action_pressed?("app.menu_select", event)
        assign_key_binding(action, @settings.capture_binding, remove_from_conflict: true)
        @status_log.success("Updated #{action} to #{@settings.capture_binding} (overwrote #{actions_for_settings_conflict})")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      if action_pressed?("app.menu_close", event)
        @status_log.info("Binding not changed")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      true
    end

    private def handle_settings_unbind_confirm_input(event : Tui::KeyEvent) : Bool
      action = @settings.capture_action
      unless action
        close_settings_dialog
        return true
      end

      if event.matches?("enter") || event.matches?("return") || event.matches?("y")
        unbind_key_binding(action)
        @status_log.success("Unbound #{action}")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      if event.matches?("escape") || event.matches?("esc") || event.matches?("n")
        @status_log.info("Binding not changed")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      if action_pressed?("app.menu_select", event)
        unbind_key_binding(action)
        @status_log.success("Unbound #{action}")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      if action_pressed?("app.menu_close", event)
        @status_log.info("Binding not changed")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      true
    end

    private def actions_for_settings_conflict : String
      actions = @settings.conflicting_actions
      return @settings.conflicting_action || "another action" if actions.empty?
      actions.join(", ")
    end

    private def reset_settings_capture_state : Nil
      @settings.reset_capture
    end

    private def open_settings_dialog : Nil
      close_context_menu
      close_lsp_popup
      close_search_panel if @search.open

      if @settings.open
        mark_dirty!
        return
      end

      with_input_mode_guard(InputMode::Settings) do
        theme_actions = Theme.preset_names.sort.map do |name|
          "theme:#{name}"
        end

        key_actions = (KeyConfig.defaults.keys + @key_bindings.keys).uniq.sort.map do |action|
          "key:#{action}"
        end

        @settings.actions = theme_actions + [EDITOR_INDENT_WIDTH_ACTION, EDITOR_AUTO_INDENT_ACTION, LSP_RESPONSE_SETTINGS_ACTION] + key_actions
        @settings.selected_index = 0
        @settings.capture_action = nil
        @settings.capture_binding = ""
        @settings.conflicting_action = nil
        @settings.conflicting_actions.clear
        @settings.mode = SettingsState::Mode::Browse

        previous_overlay = @settings.overlay

        @settings.overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_settings_dialog(buffer, clip)
        }
        @settings.overlay = open_overlay(previous_overlay, @settings.overlay.not_nil!)
        @settings.open = true
        mark_dirty!
      end
    end

    private def close_settings_dialog : Nil
      close_modal(@settings, InputMode::Settings)
      @settings.reset_capture
      mark_dirty!
    end

    private def execute_selected_settings_action : Bool
      action = selected_settings_action
      return false unless action

      if theme_name = settings_theme_name(action)
        apply_theme_by_name(theme_name)
        return true
      end

      if action == LSP_RESPONSE_SETTINGS_ACTION
        apply_lsp_response_limit
        return true
      end

      if action == EDITOR_INDENT_WIDTH_ACTION
        apply_editor_indent_width
        return true
      end

      if action == EDITOR_AUTO_INDENT_ACTION
        apply_editor_auto_indent
        return true
      end

      settings_action = settings_binding_action(action)
      return false unless settings_action

      @settings.capture_action = settings_action
      start_settings_capture
      true
    end

    private def start_settings_capture : Nil
      action = @settings.capture_action
      return unless action

      @settings.capture_binding = ""
      @settings.conflicting_action = nil
      @settings.conflicting_actions.clear
      @settings.mode = SettingsState::Mode::Capture
      @status_log.info("Rebind #{action} | press any key")
      mark_dirty!
    end

    private def apply_theme_by_name(name : String) : Nil
      if Theme.load(name)
        @theme_path = name
        apply_theme
        @status_log.success("Theme applied: #{Theme.name}")
      else
        if reason = Theme.load_error
          @status_log.warning("Theme not found: #{name}; using fallback #{Theme.name} (#{reason})")
        else
          @status_log.warning("Theme not found: #{name}; using fallback #{Theme.name}")
        end
      end

      mark_dirty!
      wakeup
    end

    private def settings_binding_action(action : String) : String?
      return unless action.starts_with?("key:")
      action[4..-1]? || ""
    end

    private def apply_lsp_response_limit : Nil
      current = @settings.max_response_mib
      next_limit = LSP_RESPONSE_PRESETS.find { |preset| preset > current } || LSP_RESPONSE_PRESETS.first
      @settings.max_response_mib = next_limit

      if client = @lsp
        client.max_response_bytes = SettingsConfig.max_response_bytes(next_limit)
      end

      if save_settings
        @status_log.success("LSP response limit: #{next_limit} MiB (saved)")
      else
        @status_log.warning("LSP response limit: #{next_limit} MiB (not saved; using in memory)")
      end

      # A larger cap only affects the next response. Re-schedule the current
      # buffer once so semantic/fold requests can use it without a retry loop.
      if next_limit > current
        if buffer = current_buffer
          schedule_semantic_tokens(buffer, Time::Span.zero)
          schedule_folding_ranges(buffer, Time::Span.zero)
        end
      end

      mark_dirty!
      wakeup
    end

    private def apply_editor_indent_width : Nil
      current = @settings.indent_width
      @settings.indent_width = current >= EditingSettings::MAX_INDENT_WIDTH ? EditingSettings::MIN_INDENT_WIDTH : current + 1
      apply_editing_settings_to_open_editors

      if save_editing_settings
        @status_log.success("Editor indent width: #{@settings.indent_width} spaces (saved)")
      else
        @status_log.warning("Editor indent width: #{@settings.indent_width} spaces (not saved; using in memory)")
      end
      mark_dirty!
      wakeup
    end

    private def apply_editor_auto_indent : Nil
      @settings.auto_indent = !@settings.auto_indent
      apply_editing_settings_to_open_editors

      if save_editing_settings
        @status_log.success("Editor auto-indent: #{@settings.auto_indent ? "on" : "off"} (saved)")
      else
        @status_log.warning("Editor auto-indent: #{@settings.auto_indent ? "on" : "off"} (not saved; using in memory)")
      end
      mark_dirty!
      wakeup
    end

    private def settings_theme_name(action : String) : String?
      return unless action.starts_with?("theme:")
      action[6..-1]? || ""
    end

    private def settings_display_name(action : String) : String
      if theme = settings_theme_name(action)
        "Theme: #{theme}"
      elsif action == EDITOR_INDENT_WIDTH_ACTION
        "Editor indent width"
      elsif action == EDITOR_AUTO_INDENT_ACTION
        "Editor auto-indent"
      elsif action == LSP_RESPONSE_SETTINGS_ACTION
        "LSP response limit"
      else
        settings_binding_action(action) || action
      end
    end

    private def settings_display_value(action : String) : String
      if theme = settings_theme_name(action)
        Theme.name == theme ? "active" : "press Enter"
      elsif action == EDITOR_INDENT_WIDTH_ACTION
        "#{@settings.indent_width} spaces"
      elsif action == EDITOR_AUTO_INDENT_ACTION
        @settings.auto_indent ? "on" : "off"
      elsif action == LSP_RESPONSE_SETTINGS_ACTION
        "#{@settings.max_response_mib} MiB"
      else
        binding_action = settings_binding_action(action)
        return "" unless binding_action
        key_hint(binding_action, "unbound")
      end
    end

    private def selected_settings_binding_action : String?
      selected = selected_settings_action
      return nil unless selected
      settings_binding_action(selected.not_nil!)
    end

    private def keymap_conflicts(action : String) : Array(String)
      conflicts = KeyConfig.conflicts_for_action(@key_bindings, action)
      owners = [] of String
      conflicts.each_value do |actions|
        actions.each do |owner|
          owners << owner unless owners.includes?(owner)
        end
      end
      owners.sort!
      owners
    end

    private def move_settings_selection(delta : Int32) : Nil
      return if @settings.actions.empty?

      count = @settings.actions.size
      @settings.selected_index += delta
      if @settings.selected_index < 0
        @settings.selected_index = count - 1
      elsif @settings.selected_index >= count
        @settings.selected_index = 0
      end
      mark_dirty!
    end

    private def set_settings_selection(index : Int32) : Nil
      return if @settings.actions.empty?
      max = @settings.actions.size - 1
      return if index < 0 || index > max
      @settings.selected_index = index
      mark_dirty!
    end

    private def selected_settings_action : String?
      return nil if @settings.actions.empty?
      idx = @settings.selected_index.clamp(0, @settings.actions.size - 1)
      @settings.actions[idx]?
    end

    private def render_settings_dialog(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return if @settings.actions.empty?

      available_rows = [clip.height - 12, 1].max
      max_rows = [@settings.actions.size, available_rows].min
      max_rows = [max_rows, 1].max
      list_height = [max_rows, 18].min
      dialog_width = [clip.width - 4, 86].min
      dialog_width = [dialog_width, 64].max
      dialog_height = list_height + 10
      dialog_height = [dialog_height, clip.height - 2].min
      dialog_x = (clip.x + (clip.width - dialog_width) // 2).clamp(clip.x, [clip.right - dialog_width, clip.x].max)
      dialog_y = (clip.y + (clip.height - dialog_height) // 2).clamp(clip.y, [clip.bottom - dialog_height, clip.y].max)

      border = Tui::Style.new(fg: Theme::Popup.border, bg: Theme::Popup.text)
      active = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)
      normal = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)

      draw_box_border(buffer, clip, dialog_x, dialog_y, dialog_width, dialog_height, border, border, "Settings", title_style)

      content_top = dialog_y + 1
      content_bottom = dialog_y + dialog_height - 1

      list_start = content_top + 1
      list_end = [list_start + list_height, content_bottom - 5].min
      list_width = [dialog_width - 6, 1].max
      action_col = dialog_x + 3
      window_size = [list_end - list_start, 1].max
      max_start = [@settings.actions.size - window_size, 0].max
      window_start = @settings.selected_index - window_size / 2
      window_start = 0 if window_start < 0
      window_start = max_start if window_start > max_start

      list_index = 0

      @settings.actions.each_with_index do |action, index|
        next if index < window_start
        break if list_start + list_index >= list_end
        break if list_index >= window_size

        y = list_start + list_index
        is_active = index == @settings.selected_index
        style = is_active ? active : normal

        prefix = is_active ? ">" : " "
        name = settings_display_name(action).ljust(36)[0, 36]
        value = settings_display_value(action)
        line = "#{prefix} #{name} : #{value}"
        line = line.ljust(list_width)
        line.each_char_with_index do |char, dx|
          break if dx >= list_width
          break if action_col + dx >= dialog_x + dialog_width - 1
          buffer.set(action_col + dx, y, char, style) if clip.contains?(action_col + dx, y)
        end

        list_index += 1
      end

      hint_y = content_bottom - 3
      message = case @settings.mode
                when SettingsState::Mode::Browse
                  selected = selected_settings_action
                  if selected == EDITOR_INDENT_WIDTH_ACTION
                    "↑/↓ select, Enter for next width (1–8 spaces), Esc close"
                  elsif selected == EDITOR_AUTO_INDENT_ACTION
                    "↑/↓ select, Enter to toggle auto-indent, Esc close"
                  elsif selected == LSP_RESPONSE_SETTINGS_ACTION
                    "↑/↓ select, Enter for next limit (1–64 MiB), Esc close"
                  elsif selected && settings_theme_name(selected)
                    "↑/↓ (or 1-9) select, Enter to apply, Esc close"
                  else
                    "↑/↓ (or 1-9) select, Enter to remap, Delete/Backspace unbind, Esc close"
                  end
                when SettingsState::Mode::Capture
                  action = selected_settings_action
                  if action
                    "Press new key for #{settings_display_name(action)}, Esc to cancel"
                  else
                    "Press new key, Esc to cancel"
                  end
                when SettingsState::Mode::ConfirmOverwrite
                  "Conflict with #{actions_for_settings_conflict} -> Enter/Y accept, N/Esc cancel"
                when SettingsState::Mode::ConfirmUnbind
                  action = @settings.capture_action
                  "Unbind #{action || "this action"}? -> Enter/Y confirm, N/Esc cancel"
                else
                  "Press Esc to close"
                end

      draw_text_line(buffer, clip, dialog_x + 2, hint_y, message, normal, dialog_width - 4)
    end

    private def assign_key_binding(action : String, binding : String, remove_from_conflict : Bool = true) : Nil
      normalized = KeyConfig.normalize_binding(binding)
      return if normalized.empty?

      if remove_from_conflict
        KeyConfig.conflicting_actions(@key_bindings, action, normalized).each do |owner|
          remove_binding_from_action(owner, normalized)
        end
      end

      @key_bindings[action] = [normalized]
      @key_overrides[action] = [normalized]

      saved = save_key_bindings
      if saved
        @status_log.success("Saved keymap to #{resolve_keymap_for_output}")
      else
        @status_log.warning("Could not persist keymap; using in-memory map")
      end

      mark_dirty!
    end

    private def remove_binding_from_action(action : String, binding : String) : Nil
      bindings = (@key_bindings[action]? || [] of String).dup
      bindings.reject! { |candidate| KeyConfig.normalize_binding(candidate) == binding }
      @key_bindings[action] = bindings
      # This is an exact replacement for the owner, not a one-key mutation of
      # the inherited default.  Persisting it is what makes a conflict removal
      # survive restart and prevents the old owner from returning.
      @key_overrides[action] = bindings.dup
    end

    private def unbind_key_binding(action : String) : Nil
      @key_bindings[action] = [] of String
      @key_overrides[action] = [] of String

      saved = save_key_bindings
      if saved
        @status_log.success("Saved unbound keymap to #{resolve_keymap_for_output}")
      else
        @status_log.warning("Could not persist unbound keymap; using in-memory map")
      end
      mark_dirty!
    end

    private def save_key_bindings : Bool
      path = resolve_keymap_path_for_save
      return false unless path

      begin
        KeyConfig.save_overrides(path, @key_overrides)
        @keymap_path = path
        true
      rescue ex
        @status_log.error("Failed to save key bindings: #{ex.class}: #{ex.message}")
        false
      end
    end

    private def save_settings : Bool
      path = resolve_keymap_path_for_save
      return false unless path

      begin
        SettingsConfig.save(path, @settings.max_response_mib)
        @keymap_path = path
        true
      rescue ex
        @status_log.error("Failed to save settings: #{ex.class}: #{ex.message}")
        false
      end
    end

    private def save_editing_settings : Bool
      path = resolve_keymap_path_for_save
      return false unless path

      begin
        SettingsConfig.save_editing(path, EditingSettings.new(
          indent_width: @settings.indent_width,
          auto_indent: @settings.auto_indent,
        ))
        @keymap_path = path
        true
      rescue ex
        @status_log.error("Failed to save editor settings: #{ex.class}: #{ex.message}")
        false
      end
    end

    private def apply_editing_settings_to_open_editors : Nil
      @document_session.open_buffers.each_value do |buffer|
        if editor = buffer.editor.as?(EditingTextEditor)
          apply_editor_config(editor, buffer.path)
          editor.auto_indent = @settings.auto_indent
        else
          buffer.editor.tab_size = @settings.indent_width
        end
      end
    end

    private def resolve_keymap_path_for_save : String?
      if path = @keymap_path
        return path unless path.empty?
      end

      resolved = KeyConfig.default_save_path
      return resolved if resolved

      home = ENV["HOME"]?
      return nil unless home
      Path.new(home, ".config", "adamantine", "config.json").to_s
    end

    private def resolve_keymap_path(provided_path : String?) : String?
      return provided_path if provided_path && !provided_path.empty?
      KeyConfig.resolve_default_path
    end

    private def resolve_keymap_for_output : String
      @keymap_path || "in-memory"
    end

    private def event_to_binding(event : Tui::KeyEvent) : String
      key = key_token(event)
      return "" if key.empty?

      mods = event.modifiers
      if mods == Tui::Modifiers::None
        event_to_binding_key_override(event).try { |override| return override }
      end

      pieces = [] of String
      pieces << "ctrl" if mods.ctrl?
      pieces << "alt" if mods.alt?
      pieces << "shift" if mods.shift?
      pieces << "meta" if mods.meta?
      pieces << key
      pieces.join("+")
    end

    private def event_to_binding_key_override(event : Tui::KeyEvent) : String?
      return nil if event.modifiers.ctrl? || event.modifiers.alt? || event.modifiers.shift? || event.modifiers.meta?

      ch = event.char
      return nil unless ch

      if ch.ord >= 1 && ch.ord <= 26
        return "ctrl+#{((ch.ord - 1 + 'a'.ord).chr)}"
      end

      if ch.ord == 0
        return "ctrl+space"
      end

      if letter = Tui::KeyEvent.mac_option_key(ch)
        return "alt+#{letter}"
      end

      nil
    end

    private def key_token(event : Tui::KeyEvent) : String
      case event.key
      when Tui::Key::Enter
        "enter"
      when Tui::Key::Tab
        "tab"
      when Tui::Key::Backspace
        "backspace"
      when Tui::Key::Escape
        "escape"
      when Tui::Key::Space
        "space"
      when Tui::Key::Up
        "up"
      when Tui::Key::Down
        "down"
      when Tui::Key::Left
        "left"
      when Tui::Key::Right
        "right"
      when Tui::Key::Home
        "home"
      when Tui::Key::End
        "end"
      when Tui::Key::PageUp
        "pageup"
      when Tui::Key::PageDown
        "pagedown"
      when Tui::Key::Insert
        "insert"
      when Tui::Key::Delete
        "delete"
      when Tui::Key::F1
        "f1"
      when Tui::Key::F2
        "f2"
      when Tui::Key::F3
        "f3"
      when Tui::Key::F4
        "f4"
      when Tui::Key::F5
        "f5"
      when Tui::Key::F6
        "f6"
      when Tui::Key::F7
        "f7"
      when Tui::Key::F8
        "f8"
      when Tui::Key::F9
        "f9"
      when Tui::Key::F10
        "f10"
      when Tui::Key::F11
        "f11"
      when Tui::Key::F12
        "f12"
      else
        char = event.char
        return "" unless char
        char.to_s.downcase
      end
    end

    private def load_key_layers(path : String?) : KeyConfig::Layers
      warning_callback = ->(message : String) { @status_log.warning(message) }

      return KeyConfig.load_layers(path, warning_callback) if path && !path.empty?
      resolved = KeyConfig.resolve_default_path
      return KeyConfig.load_layers(resolved, warning_callback) if resolved
      KeyConfig.load_layers(nil, warning_callback)
    end

    private def action_pressed?(action : String, event : Tui::KeyEvent) : Bool
      keys = @key_bindings[action]?
      return false unless keys
      keys.any? { |key| event.matches?(key) }
    end

    private def key_hint(action : String, fallback : String = "") : String
      keys = @key_bindings[action]?
      return fallback unless keys
      return "unbound" if keys.empty?
      hint = keys.join(" / ")
      conflicts = keymap_conflicts(action)
      conflicts.empty? ? hint : "#{hint} (conflicts: #{conflicts.join(", ")})"
    end

    # Menu metadata must describe this app's active keymap.  Unlike status/help
    # hints, it must not resurrect a default when the user explicitly unbinds
    # an action or when a test/application supplies a sparse map.
    private def configured_key_hint(action : String, fallback : String = "") : String
      key_hint(action, fallback)
    end

    private def build_quick_actions_menu : Array(LspContextAction)
      search_entry = command_entry("search").not_nil!
      project_search_entry = command_entry("grep").not_nil!
      replace_entry = command_entry("replace").not_nil!
      actions = [
        LspContextAction.new(
          search_entry.title,
          context_command_shortcut(search_entry, "/"),
          -> { execute_context_command(search_entry) },
          -> { command_disabled_reason(search_entry) }
        ),
        LspContextAction.new(
          "Find backward",
          "command: ?",
          -> { open_search_panel(SearchState::Scope::ThisFile, forward: false) },
          -> { command_disabled_reason(search_entry) }
        ),
        LspContextAction.new(
          project_search_entry.title,
          context_command_shortcut(project_search_entry, ":grep "),
          -> { execute_context_command(project_search_entry) },
          -> { command_disabled_reason(project_search_entry) }
        ),
        LspContextAction.new(
          replace_entry.title,
          context_command_shortcut(replace_entry, ":r/"),
          -> { open_command_palette(":r/") },
          -> { command_disabled_reason(replace_entry) }
        ),
      ]

      actions.concat(build_lsp_context_menu_actions)

      ["format", "rename", "quickfix"].each do |action|
        entry = command_entry(action).not_nil!
        actions << LspContextAction.new(
          entry.title,
          context_command_shortcut(entry, "unbound"),
          -> { execute_context_command(entry) },
          -> { command_disabled_reason(entry) }
        )
      end

      external_entry = command_entry("external").not_nil!
      actions << LspContextAction.new(
        external_entry.title,
        context_command_shortcut(external_entry, "unbound"),
        -> { execute_context_command(external_entry) },
        -> { command_disabled_reason(external_entry) }
      )
      actions
    end

    private def context_command_shortcut(entry : CommandEntry, fallback : String) : String
      if entry.shortcut_action.empty?
        return fallback if fallback == "unbound"
        return "command: #{fallback}"
      end
      hint = configured_key_hint(entry.shortcut_action, "unbound")
      hint == "unbound" ? hint : "global: #{hint}"
    end

    private def execute_context_command(entry : CommandEntry) : Nil
      if entry.requires_argument?
        open_command_palette("")
        prepare_command_palette_entry(entry)
      else
        execute_command(":#{entry.action}")
      end
    end

    private def wrap_lines(value : String, max_width : Int32 = 80) : Array(String)
      return [] of String if value.empty?

      normalized = value.split('\n').flat_map do |line|
        if line.size <= max_width
          [line]
        else
          chunks = [] of String
          remainder = line
          while remainder.size > max_width
            chunks << remainder[0, max_width]
            remainder = remainder[max_width..-1]
          end
          chunks << remainder unless remainder.empty?
          chunks
        end
      end
      normalized
    end

    private def apply_theme : Nil
      @header.bg_color = Theme::Header.bg
      @header.fg_color = Theme::Header.title
      @header.title_color = Theme::Header.title
      @header.subtitle_color = Theme::Header.subtitle
      @header.clock_color = Theme::Header.clock

      @footer.key_color = Theme::Footer.key_fg
      @footer.key_bg = Theme::Footer.key_bg
      @footer.label_color = Theme::Footer.label_fg
      @footer.label_bg = Theme::Footer.label_bg

      @file_panel_split.border_color = Theme::Split.border
      @file_panel_split.splitter_color = Theme::Split.splitter
      @file_panel_split.splitter_drag_color = Theme::Split.splitter_drag
      @file_panel_split.focus_border_color = Theme::Split.focus_border
      @file_panel_split.focus_title_color = Theme::Split.focus_title
      @file_panel_split.title_color = Theme::Split.title

      @body_split.border_color = Theme::Split.border
      @body_split.splitter_color = Theme::Split.splitter
      @body_split.splitter_drag_color = Theme::Split.splitter_drag
      @body_split.focus_border_color = Theme::Split.focus_border
      @body_split.focus_title_color = Theme::Split.focus_title
      @body_split.title_color = Theme::Split.title
      @editor_group_split.try { |split| style_split_container(split) }

      @file_panel.border_color = Theme::FilePanel.border_color
      @file_panel.active_border_color = Theme::FilePanel.active_border_color
      @file_panel.title_color = Theme::FilePanel.title_color
      @file_panel.bg_color = Theme::FilePanel.bg_color
      @file_panel.dir_color = Theme::FilePanel.dir_color
      @file_panel.file_color = Theme::FilePanel.file_color
      @file_panel.cursor_color = Theme::FilePanel.cursor_color
      @file_panel.cursor_bg = Theme::FilePanel.cursor_bg
      @file_panel.selected_color = Theme::FilePanel.selected_color
      @file_panel.filter_color = Theme::FilePanel.filter_color
      @file_panel.filter_bg = Theme::FilePanel.filter_bg

      @status_log.debug_style = Tui::Style.new(fg: Theme::Status.debug, bg: Theme::Status.bg)
      @status_log.info_style = Tui::Style.new(fg: Theme::Status.info, bg: Theme::Status.bg)
      @status_log.warning_style = Tui::Style.new(fg: Theme::Status.warning, bg: Theme::Status.bg)
      @status_log.error_style = Tui::Style.new(fg: Theme::Status.error, bg: Theme::Status.bg)
      @status_log.success_style = Tui::Style.new(fg: Theme::Status.success, bg: Theme::Status.bg)
      @status_log.timestamp_style = Tui::Style.new(fg: Theme::Status.timestamp, bg: Theme::Status.bg)
      @status_log.source_style = Tui::Style.new(fg: Theme::Status.source, bg: Theme::Status.bg)

      @document_session.open_buffers.each_value do |buffer|
        style_editor(buffer.editor, buffer)
      end

      mark_dirty!
    end

    private def reload_theme : Nil
      @theme_path = resolve_theme_path(@theme_path)
      loaded = Theme.load(@theme_path)
      apply_theme

      if loaded
        @status_log.success("Loaded theme: #{Theme.name} (#{@theme_path || "default"})")
      else
        if reason = Theme.load_error
          @status_log.warning("Theme load failed: #{reason}")
        else
          @status_log.warning("Theme load failed, using fallback: #{Theme.name}")
        end
      end
      mark_dirty!
      wakeup
    end

    private def resolve_theme_path(provided_path : String?) : String?
      Theme.resolve_path(provided_path)
    end

    private def style_editor(editor : Tui::TextEditor, buffer : OpenBuffer?) : Nil
      editor.text_fg = Theme::Editor.text_fg
      editor.text_bg = Theme::Editor.text_bg
      editor.cursor_fg = Theme::Editor.cursor_fg
      editor.cursor_bg = Theme::Editor.cursor_bg
      editor.selection_fg = Theme::Editor.selection_fg
      editor.selection_bg = Theme::Editor.selection_bg
      editor.line_number_fg = Theme::Editor.line_number_fg
      editor.line_number_bg = Theme::Editor.line_number_bg
      editor.fold_gutter_fg = Theme::Editor.line_number_fg
      editor.fold_placeholder_fg = Theme::Syntax.color("comment") || Theme::Editor.line_number_fg
      editor.current_line_bg = Theme::Editor.current_line_bg
      editor.show_line_numbers = true
      editor.show_fold_gutter = true
      if editing_editor = editor.as?(EditingTextEditor)
        path = buffer.try(&.path) || editing_editor.path
        apply_editor_config(editing_editor, path)
        editing_editor.auto_indent = @settings.auto_indent
        editing_editor.line_change_added_fg = Theme::Status.success
        editing_editor.line_change_modified_fg = Theme::Status.warning
        editing_editor.line_change_deleted_fg = Theme::Status.error
      else
        editor.tab_size = @settings.indent_width
      end
      editor.word_wrap = false
      hyperclick = @on_editor_hyperclick
      editor.on_hyperclick do |line, col, modifiers|
        hyperclick.try(&.call(line, col, modifiers))
      end

      if buffer
        configure_editor_lsp_styles_internal(editor, buffer)
      end
    end

    # Resolve EditorConfig for each file at the point where its style and
    # editing policy are applied.  The resolver only contributes insertion
    # policy and visual tab width; it never changes the document's detected
    # line ending or saved/history state.
    private def apply_editor_config(editor : EditingTextEditor, path : Path?) : Nil
      unless path
        editor.apply_editor_config(@settings.indent_width, tab_width: @settings.indent_width)
        return
      end

      resolved = EditorConfig.resolve(path.not_nil!, @settings.indent_width)
      resolved.warnings.each do |warning|
        @status_log.warning("EditorConfig: #{warning}")
      end

      configured_style = resolved.indent_style
      # An omitted indent_style keeps the application's global space policy;
      # indent_size=tab is a size spelling, not an implicit style switch.
      indent_style = configured_style == "tab" ? :tab : :space
      # EditorConfig's tab_width is the display width for literal tabs.  If
      # it is omitted, indent_size is the useful per-file fallback; otherwise
      # the global indentation width supplies the default visual width.
      tab_width = resolved.tab_width || resolved.indent_size || @settings.indent_width
      indent_width = if resolved.indent_size_tab
                       resolved.tab_width || @settings.indent_width
                     else
                       resolved.indent_size || @settings.indent_width
                     end
      end_of_line = case resolved.end_of_line
                    when "lf"
                      "\n"
                    when "crlf"
                      "\r\n"
                    when "cr"
                      "\r"
                    else
                      nil
                    end
      editor.apply_editor_config(
        indent_width,
        indent_style: indent_style,
        tab_width: tab_width,
        end_of_line: end_of_line
      )
    end

    private def configure_editor_lsp_styles_internal(editor : Tui::TextEditor, buffer : OpenBuffer) : Nil
      configure_lexical_highlighting(buffer)
      editor.on_cell_style do |line, col, _char, style|
        lexical = lexical_token_at(buffer, line, col)
        token = buffer.semantic_overlay.name_at(line, col) || lexical
        styled = Theme::Syntax.apply(style, token)
        lsp_diagnostic_style(buffer.diagnostics, line, col, styled)
      end
    end

    private def refresh_file_tree : Nil
      @file_panel.refresh
    end

    private def toggle_diagnostics : Nil
      if buffer = current_buffer
        if buffer.diagnostics.empty?
          @status_log.info("No diagnostics for #{buffer.path.basename}")
        else
          buffer.diagnostics.each do |diag|
            source = diag.source ? " [#{diag.source}]" : ""
            @status_log.warning("#{buffer.path.basename}:#{diag.line + 1}:#{diag.character + 1}#{source} #{diag.message}")
          end
        end
      else
        @status_log.warning("No active buffer")
      end
    end

    private def show_help : Nil
      @status_log.info("#{key_hint("app.copy")} copy | #{key_hint("app.cut")} cut | #{key_hint("app.paste")} paste")
      @status_log.info("#{key_hint("app.open_file_tree")} tree | #{key_hint("app.save")} save | #{key_hint("app.close_tab")} close | #{key_hint("lsp.status")} LSP status")
      @status_log.info("#{key_hint("app.next_tab")} next tab | #{key_hint("app.previous_tab")} prev tab | #{key_hint("app.goto_tab_1")}..#{key_hint("app.goto_tab_9")} jump to tab")
      @status_log.info("Command palette: #{key_hint("app.command_palette")} discovers actions; Esc Esc opens raw mode; type :w :q :wq :open :theme ...")
      COMMAND_ENTRIES.each do |entry|
        argument = entry.argument_hint.empty? ? "" : " #{entry.argument_hint}"
        @status_log.info(":#{entry.action}#{argument} — #{entry.description}")
      end
      @status_log.info("Quick actions: #{key_hint("app.quick_actions")} (Find/Replace/LSP actions)")
      @status_log.info("Text replace: :r /old/new/ [gic] or :s/old/new/gic (c = preview)")
      @status_log.info("#{key_hint("lsp.goto_definition")} definition | #{key_hint("app.jump_back")} back")
      @status_log.info("#{key_hint("app.jump_forward")} forward | #{key_hint("app.settings")} settings")
      @status_log.info("#{key_hint("app.undo")} undo | #{key_hint("app.redo")} redo")
      @status_log.info("#{key_hint("app.find")} find in file | #{key_hint("app.find_in_project")} find in project | Tab switches scope, Enter next/open")
      @status_log.info("#{key_hint("lsp.hover")} Hover | #{key_hint("lsp.references")} References | #{key_hint("lsp.signature")} Signature | #{key_hint("lsp.context_menu")} LSP menu")
      @status_log.info("Folds: click +/- in gutter or #{key_hint("lsp.toggle_fold")} at cursor")
      @status_log.info("Hyperclick: Shift+Click or middle-click definition/usages | Shift+Alt+Click references")
      @status_log.info("Context menu: #{key_hint("app.menu_select")} run | 1..9 quick | #{key_hint("app.menu_up")}/#{key_hint("app.menu_down")} navigate | #{key_hint("app.menu_close")} close")
      @status_log.info("#{key_hint("app.reload_theme")} reload theme | #{key_hint("app.help")} help | #{key_hint("app.settings")} settings | #{key_hint("app.quit")} quit")
      @status_log.info("Settings: reopen any key binding to remap or choose a theme preset")
      @status_log.info("Use --lsp COMMAND and --theme PATH|preset to connect to LSP and load theme")
    end

    private def report_clipboard_result(result : Clipboard::Result) : Nil
      case result.status
      when Clipboard::Status::Unsupported
        @status_log.warning("System clipboard unavailable; using internal clipboard")
      when Clipboard::Status::TooLarge
        @status_log.warning("Clipboard data exceeds the 16 MiB limit")
      when Clipboard::Status::InvalidEncoding
        @status_log.warning("Clipboard data is not valid UTF-8")
      when Clipboard::Status::Timeout
        @status_log.warning("System clipboard helper timed out; using internal clipboard")
      when Clipboard::Status::Failed
        @status_log.warning("System clipboard helper failed; using internal clipboard")
      when Clipboard::Status::Success
      end
    end

    private def update_header : Nil
      update_header_internal
    end

    private def update_header_internal : Nil
      subtitle = "No file opened"

      if buffer = active_buffer_internal
        lang = buffer.language_id || "plaintext"
        dirty = buffer.editor.modified? ? " *" : ""
        external = buffer.external_conflict ? " ! external change" : ""
        subtitle = "#{buffer.path}#{dirty}#{external}  (#{lang})"
        rename_tab_internal(buffer)
      elsif !@document_session.open_buffers.empty?
        subtitle = "#{@document_session.open_buffers.size} buffers"
      end

      # Keep connection health ahead of long paths, including with no open file.
      review_hint = active_buffer_internal.try(&.external_conflict) ? "[External: #{key_hint("app.review_external")} review] " : ""
      group_hint = @right_editor_tabs ? "[Pane #{@active_editor_group + 1}] " : ""
      @header.subtitle = "#{group_hint}#{review_hint}[LSP #{lsp_health_label}] #{subtitle}"
      mark_dirty!
    end

    private def editor_tab_groups : Array(Tui::TabbedPanel)
      groups = [@editor_tabs] of Tui::TabbedPanel
      groups << @right_editor_tabs.not_nil! if @right_editor_tabs
      groups
    end

    private def active_editor_tabs : Tui::TabbedPanel
      if @active_editor_group == 1
        @right_editor_tabs || @editor_tabs
      else
        @editor_tabs
      end
    end

    private def editor_tabs_for_path_internal(path : String) : Tui::TabbedPanel?
      editor_tab_groups.find { |panel| panel.tabs.any? { |tab| tab.id == path } }
    end

    private def estimated_editor_width(width : Int32) : Int32
      width = 120 if width <= 0
      total = width - 3
      return 0 if total < MIN_FILE_PANEL_WIDTH + MIN_EDITOR_WIDTH

      first = (total * FILE_PANEL_RATIO).to_i.clamp(MIN_FILE_PANEL_WIDTH, total - MIN_EDITOR_WIDTH)
      total - first
    end

    private def configure_editor_group_panel(panel : Tui::TabbedPanel) : Nil
      panel.positions = Set{Tui::TabbedPanel::TabPosition::Top}
      panel.show_close_button = true
      panel.on_tab_switch do |_id|
        git_gutter_tab_switched
        close_external_review
        close_recovery_review
        close_problems
        search_tab_switched
        invalidate_lsp_actions
        @clipboard_paste_generation &+= 1_u64
        update_header
      end
      panel.on_before_tab_close do |tab_id|
        allowed = before_close_tab(tab_id)
        git_gutter_tab_closing(tab_id) if allowed
        allowed
      end
      panel.on_tab_close do |tab_id|
        git_gutter_tab_closed(tab_id)
        close_external_review
        close_recovery_review
        if buffer = @document_session.open_buffers[tab_id]?
          close_problems_for_buffer(buffer)
        end
        search_tab_closed(tab_id)
        close_tab(tab_id)
      end
    end

    private def activate_editor_group_internal(panel : Tui::TabbedPanel) : Nil
      group = panel.same?(@right_editor_tabs) && @right_editor_tabs ? 1 : 0
      return if group == @active_editor_group

      @active_editor_group = group
      invalidate_lsp_actions
      @clipboard_paste_generation &+= 1_u64
      close_external_review
      close_recovery_review
      close_problems
      search_tab_switched
      git_gutter_tab_switched
      update_editor_group_titles
      if id = panel.active_tab_id
        @document_session.open_buffers[id]?.try { |buffer| buffer.editor.focus }
      else
        panel.focus
      end
      update_header
    end

    private def activate_editor_group_at(x : Int32, y : Int32) : Bool
      return false unless @right_editor_tabs

      if @right_editor_tabs.not_nil!.rect.contains?(x, y)
        activate_editor_group_internal(@right_editor_tabs.not_nil!)
        true
      elsif @editor_tabs.rect.contains?(x, y)
        activate_editor_group_internal(@editor_tabs)
        true
      else
        false
      end
    end

    private def style_split_container(split : Tui::SplitContainer) : Nil
      split.border_color = Theme::Split.border
      split.splitter_color = Theme::Split.splitter
      split.splitter_drag_color = Theme::Split.splitter_drag
      split.focus_border_color = Theme::Split.focus_border
      split.focus_title_color = Theme::Split.focus_title
      split.title_color = Theme::Split.title
    end

    private def update_editor_group_titles : Nil
      return unless split = @editor_group_split

      split.first_title = @active_editor_group == 0 ? "Group 1 *" : "Group 1"
      split.second_title = @active_editor_group == 1 ? "Group 2 *" : "Group 2"
    end

    private def split_editor_right : Bool
      if right = @right_editor_tabs
        activate_editor_group_internal(right)
        if id = right.active_tab_id
          @document_session.open_buffers[id]?.try { |buffer| buffer.editor.focus }
        else
          right.focus
        end
        return true
      end

      editor_width = estimated_editor_width(@rect.width)
      if editor_width < MIN_SPLIT_EDITOR_WIDTH
        @status_log.warning("Cannot split editor: widen the window to at least #{MIN_SPLIT_EDITOR_WIDTH + MIN_FILE_PANEL_WIDTH + 3} columns")
        mark_dirty!
        return true
      end

      right = Tui::TabbedPanel.new("tabs-right")
      configure_editor_group_panel(right)
      nested = Tui::SplitContainer.new(
        direction: Tui::SplitContainer::Direction::Horizontal,
        ratio: 0.5,
        id: "editor-groups-split"
      )
      nested.show_border = true
      nested.min_first = MIN_EDITOR_WIDTH
      nested.min_second = MIN_EDITOR_WIDTH
      nested.first_title = "Group 1"
      nested.second_title = "Group 2"
      style_split_container(nested)

      # Detach the left panel before reparenting it under the nested split.
      @file_panel_split.second = nil
      nested.first = @editor_tabs
      nested.second = right
      @right_editor_tabs = right
      @editor_group_split = nested
      @file_panel_split.second = nested
      update_editor_group_titles
      activate_editor_group_internal(right)
      mark_dirty!
      true
    end

    private def close_editor_split : Bool
      unless @right_editor_tabs
        @status_log.warning("No editor split is open")
        return true
      end

      collapse_editor_split
      true
    end

    private def collapse_editor_split : Nil
      right = @right_editor_tabs
      split = @editor_group_split
      return unless right && split

      # Keep the currently selected document, regardless of which pane owns
      # focus. All right-side tabs remain open, but collapse is not a pane
      # switch unless the right pane was active.
      active_id = active_editor_tabs.active_tab_id
      # Transfer tab values and their existing widgets directly. Calling any
      # close API here would retire the buffer, stop its file watch, and close
      # its LSP document, which a layout change must never do.
      until right.tabs.empty?
        tab = right.tabs[0]
        right.remove_child(tab.content.not_nil!) if tab.content
        right.tabs.delete_at(0)
        @editor_tabs.add_tab(tab)
      end
      @editor_tabs.switch_to(active_id.not_nil!) if active_id

      @file_panel_split.second = nil
      split.first = nil
      split.second = nil
      @file_panel_split.second = @editor_tabs
      @right_editor_tabs = nil
      @editor_group_split = nil
      activate_editor_group_internal(@editor_tabs)
      @active_editor_group = 0
      if id = active_editor_tabs.active_tab_id
        @document_session.open_buffers[id]?.try { |buffer| buffer.editor.focus }
      end
      update_header
    end

    private def focus_next_editor_group : Bool
      unless right = @right_editor_tabs
        @status_log.warning("No editor split is open")
        return true
      end

      target = @active_editor_group == 0 ? right : @editor_tabs
      activate_editor_group_internal(target)
      if id = target.active_tab_id
        @document_session.open_buffers[id]?.try { |buffer| buffer.editor.focus }
      else
        target.focus
      end
      true
    end

    private def current_lsp_context_internal : NamedTuple(uri: String, line: Int32, character: Int32)?
      buffer = active_buffer_internal
      editor = active_editor_internal
      return nil if buffer.nil? || editor.nil?
      {uri: buffer.uri, line: editor.cursor_line, character: editor.cursor_col}
    end

    private def active_editor_internal : Tui::TextEditor?
      if active = active_editor_tabs.active_tab_id
        @document_session.open_buffers[active]?.try(&.editor)
      end
    end

    private def active_buffer_internal : OpenBuffer?
      if active = active_editor_tabs.active_tab_id
        @document_session.open_buffers[active]?
      end
    end

    private def rename_tab_internal(buffer : OpenBuffer) : Nil
      modified = buffer.editor.modified? ? "*" : ""
      external = buffer.external_conflict ? "!" : ""
      editor_tabs_for_path_internal(buffer.path.to_s).try(&.rename_tab(buffer.path.to_s, "#{buffer.path.basename}#{modified}#{external}"))
    end

    private def detect_language(path : Path) : String
      LanguageRegistry.detect(path)
    end

    private def path_to_uri(path : Path) : String
      UriCodec.path_to_uri(path)
    end

    private def uri_to_path_internal(uri : String) : Path?
      UriCodec.uri_to_path(uri)
    end
  end
end
