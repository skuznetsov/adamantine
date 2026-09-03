require "crystal_tui"
require "json"

require "../adamantine/lsp_client"
require "../adamantine/document_session"
require "../adamantine/document_types"
require "../adamantine/document_orchestrator"
require "../adamantine/command_palette"
require "../adamantine/modal_manager"
require "../adamantine/input_router"
require "../adamantine/navigation_controller"
require "../adamantine/overlay_controller"
require "../adamantine/lsp_controller"
require "../adamantine/input_mode_controller"
require "../adamantine/uri_codec"
require "../adamantine/key_config"
require "../adamantine/theme"
require "../adamantine/search_state"
require "../adamantine/search_panel"
require "../adamantine/project_search"
require "../adamantine/lsp_popup_state"
require "../adamantine/context_menu_state"
require "../adamantine/command_palette_state"
require "../adamantine/settings_state"
require "../adamantine/language_registry"
require "../adamantine/lsp_registry"
require "../adamantine/semantic_tokens"
require "../adamantine/folding"
require "../adamantine/hyperclick"
require "../adamantine/box_drawing"

module Adamantine
  class App < Tui::App
    include CommandPalette
    include InputModeController
    include OverlayController
    include SearchPanel
    include InputRouter
    include ModalManager
    include NavigationController
    include LspController
    include BoxDrawing
    alias InputMode = InputModeController::InputMode

    alias SettingsMode = SettingsState::Mode

    EDITOR_TITLE = ENV["ADAMANTINE_TITLE"]? || ENV["EDITOR_TITLE"]? || "Adamantine"

    FILE_PANEL_RATIO       = 0.22
    BODY_LOG_RATIO         = 0.84
    STATUS_LOG_MAX_ENTRIES =  200
    MIN_FILE_PANEL_WIDTH   =   18
    MIN_EDITOR_WIDTH       =   24
    MIN_LOG_HEIGHT         =    6

    COMMAND_ENTRIES = [
      CommandEntry.new(["w", "write"], "Save active file"),
      CommandEntry.new(["q", "close"], "Close active tab"),
      CommandEntry.new(["quit", "exit", "qa", "q!"], "Quit editor"),
      CommandEntry.new(["wq", "wx", "writequit"], "Save and quit"),
      CommandEntry.new(["e", "open", "edit"], "Open file path"),
      CommandEntry.new(["theme"], "Apply theme preset by name"),
      CommandEntry.new(["themes"], "List available themes"),
      CommandEntry.new(["lsp"], "Show LSP connection status"),
      CommandEntry.new(["tabnext", "next"], "Activate next tab"),
      CommandEntry.new(["tabprev", "prev"], "Activate previous tab"),
      CommandEntry.new(["help", "?"], "Show command list"),
      CommandEntry.new(["tree"], "Focus project tree"),
      CommandEntry.new(["focus-tree", "tree-focus"], "Focus project tree"),
      CommandEntry.new(["focus-editor", "edit-focus"], "Focus active editor"),
      CommandEntry.new(["open-theme"], "Reload active theme file"),
      CommandEntry.new(["ls", "buffers"], "List open buffers"),
      CommandEntry.new(["jumpback", "pop"], "Jump back in navigation history"),
      CommandEntry.new(["jumpforward", "jf"], "Jump forward in navigation history"),
      CommandEntry.new(["undo"], "Undo last edit in the active editor"),
      CommandEntry.new(["redo"], "Redo last undone edit in the active editor"),
      CommandEntry.new(["settings"], "Open settings dialog"),
      CommandEntry.new(["bnext", "bn"], "Go to next tab"),
      CommandEntry.new(["bprev", "bp"], "Go to previous tab"),
      CommandEntry.new(["buf", "buffer"], "Select buffer by index, index starts at 1"),
      CommandEntry.new(["search", "find"], "Open find panel for the current file (also /pattern)"),
      CommandEntry.new(["grep", "rg"], "Open project search panel"),
      CommandEntry.new(["set"], "Show or set editor options"),
      CommandEntry.new(["cd"], "Change project root and file tree path"),
      CommandEntry.new(["pwd", "cwd"], "Show current working directory"),
      CommandEntry.new(["mark"], "Set local mark"),
      CommandEntry.new(["marks"], "List marks"),
      CommandEntry.new(["jump"], "Jump to mark"),
      CommandEntry.new(["replace", "s", "r"], "Replace text: :r /old/new/ [gic] or :s/old/new/[gic]"),
    ]

    @project_root : Path
    @file_panel : Tui::FilePanel
    @editor_tabs : Tui::TabbedPanel
    @status_log : Tui::Log
    @header : Tui::Header
    @footer : Tui::Footer
    @body_split : Tui::SplitContainer
    @file_panel_split : Tui::SplitContainer
    @document_session : DocumentSession
    @document_orchestrator : DocumentOrchestrator
    @on_editor_hyperclick : Proc(Int32, Int32, Tui::Modifiers, Nil)?
    @lsp : Lsp::Client?
    @context_menu : ContextMenuState = ContextMenuState.new
    @lsp_popup : LspPopupState = LspPopupState.new
    @key_bindings : KeyConfig::ActionMap = KeyConfig.defaults
    @input_mode_controller : InputModeController::ModeStack = InputModeController::ModeStack.new
    @command_palette : CommandPaletteState = CommandPaletteState.new
    @search : SearchState = SearchState.new
    @settings : SettingsState = SettingsState.new
    @keymap_path : String? = nil
    @theme_path : String? = nil

    def initialize(project_root : Path, lsp_command : String? = nil, lsp_args : Array(String) = [] of String, keymap_path : String? = nil, theme_path : String? = nil)
      super()

      resolved_root = project_root
      raise "Invalid project root: #{resolved_root}" unless File.directory?(resolved_root.to_s)
      @project_root = resolved_root
      @theme_path = resolve_theme_path(theme_path)
      theme_loaded = Theme.load(@theme_path)

      @file_panel = Tui::FilePanel.new(@project_root, id: "project-tree")

      @editor_tabs = Tui::TabbedPanel.new("tabs")
      @editor_tabs.show_close_button = true
      @editor_tabs.on_tab_switch do |_id|
        update_header
      end

      @status_log = Tui::Log.new("status")
      @status_log.max_entries = STATUS_LOG_MAX_ENTRIES
      if theme_loaded
        @status_log.info("Theme loaded: #{Theme.name}")
      elsif (theme_error = Theme.load_error)
        @status_log.warning("Theme load failed: #{theme_error}")
      end
      @document_session = DocumentSession.new
      @header = Tui::Header.new("header", EDITOR_TITLE)
      @header.subtitle = "No file opened"
      @header.show_clock = true
      @header.start_clock
      @document_orchestrator = build_document_orchestrator
      @on_editor_hyperclick = ->(line : Int32, col : Int32, modifiers : Tui::Modifiers) do
        hyperclick_at(line, col, modifiers)
      end
      @editor_tabs.on_before_tab_close do |tab_id|
        @document_orchestrator.can_close_tab?(tab_id)
      end
      @editor_tabs.on_tab_close do |tab_id|
        close_tab(tab_id)
      end
      @keymap_path = resolve_keymap_path(keymap_path)
      @key_bindings = load_key_bindings(@keymap_path)
      KeyConfig.duplicate_binding_warnings(@key_bindings).each do |warning|
        @status_log.warning(warning)
      end

      @status_log.info("Project: #{@project_root}")
      @status_log.info("Tip: #{key_hint("app.open_file_tree")} tree | #{key_hint("app.save")} save | #{key_hint("app.close_tab")} close | #{key_hint("app.next_tab")} / #{key_hint("app.goto_tab_1")}..9 switch")
      @status_log.info("Tip: #{key_hint("app.previous_tab")} previous tab | #{key_hint("lsp.status")} LSP status | #{key_hint("app.quit")} quit | #{key_hint("app.help")} | #{key_hint("app.settings")}")
      @status_log.info("Tip: #{key_hint("app.reload_theme")} reload theme | #{key_hint("app.jump_back")} jump back | #{key_hint("app.jump_forward")} jump forward")
      @status_log.info("Tip: #{key_hint("app.undo")} undo | #{key_hint("app.redo")} redo")
      @status_log.info("Tip: #{key_hint("app.find")} find in file | #{key_hint("app.find_in_project")} find in project")
      @status_log.info("Tip: Esc+Esc opens command palette | #{key_hint("app.command_palette")} command palette")
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

    def quit(force : Bool = false) : Nil
      unless force
        dirty = @document_session.open_buffers.each_value.select(&.editor.modified?)
        unless dirty.empty?
          paths = dirty.map { |buffer| buffer.path.basename.to_s }.join(", ")
          @status_log.warning("Unsaved changes: #{paths}; use :q! to force quit")
          return
        end
      end

      shutdown_lsp
      super()
    end

    private def build_document_orchestrator : DocumentOrchestrator
      DocumentOrchestrator.new(
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
        ->(buffer : OpenBuffer) { sync_lsp_change(buffer) },
        ->(buffer : OpenBuffer) { sync_lsp_save(buffer) },
        ->(uri : String) { close_lsp_document(uri) },
        -> { current_lsp_context_internal }
      )
    end

    private def layout_children : Nil
      return if @children.empty?

      header_h = 1
      footer_h = 1
      body_h = [@rect.height - header_h - footer_h, 1].max

      @header.rect = Tui::Rect.new(@rect.x, @rect.y, @rect.width, header_h)
      @body_split.rect = Tui::Rect.new(@rect.x, @rect.y + header_h, @rect.width, body_h)
      @footer.rect = Tui::Rect.new(@rect.x, @rect.y + header_h + body_h, @rect.width, footer_h)
    end

    def on_capture(event : Tui::Event) : Bool
      return false unless event.is_a?(Tui::KeyEvent)
      return true if route_key_event(event)
      super
    end

    def on_event(event : Tui::Event) : Bool
      false
    end

    private def command_palette_entries : Array(CommandEntry)
      COMMAND_ENTRIES
    end

    private def handle_settings_input(event : Tui::KeyEvent) : Bool
      case @settings.mode
      when SettingsState::Mode::Browse
        handle_settings_browse_input(event)
      when SettingsState::Mode::Capture
        handle_settings_capture_input(event)
      when SettingsState::Mode::ConfirmOverwrite
        handle_settings_confirm_input(event)
      else
        false
      end
    end

    private def handle_settings_browse_input(event : Tui::KeyEvent) : Bool
      return false unless @settings.open && !@settings.actions.empty?

      if action_pressed?("app.menu_close", event)
        close_settings_dialog
        return true
      elsif action_pressed?("app.settings", event)
        close_settings_dialog
        return true
      elsif action_pressed?("app.menu_up", event)
        move_settings_selection(-1)
        return true
      elsif action_pressed?("app.menu_down", event)
        move_settings_selection(1)
        return true
      elsif action_pressed?("app.menu_first", event)
        set_settings_selection(0)
        return true
      elsif action_pressed?("app.menu_last", event)
        set_settings_selection(@settings.actions.size - 1)
        return true
      elsif action_pressed?("app.menu_select", event)
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

      false
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

      current = KeyConfig.find_action_for_binding(@key_bindings, normalized)
      if current == action || current.nil?
        assign_key_binding(action, normalized)
        @status_log.success("Mapped #{action} to #{normalized}")
        reset_settings_capture_state
        mark_dirty!
      else
        @settings.conflicting_action = current
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

      if action_pressed?("app.menu_select", event) || event.matches?("enter") || event.matches?("return") || event.matches?("y")
        assign_key_binding(action, @settings.capture_binding, remove_from_conflict: true)
        @status_log.success("Updated #{action} to #{@settings.capture_binding} (overwrote #{action_for_settings_conflict})")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      if action_pressed?("app.menu_close", event) || event.matches?("escape") || event.matches?("n")
        @status_log.info("Binding not changed")
        reset_settings_capture_state
        mark_dirty!
        return true
      end

      false
    end

    private def action_for_settings_conflict : String
      @settings.conflicting_action || "another action"
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

        @settings.actions = theme_actions + key_actions
        @settings.selected_index = 0
        @settings.capture_action = nil
        @settings.capture_binding = ""
        @settings.conflicting_action = nil
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

    private def settings_theme_name(action : String) : String?
      return unless action.starts_with?("theme:")
      action[6..-1]? || ""
    end

    private def settings_display_name(action : String) : String
      if theme = settings_theme_name(action)
        "Theme: #{theme}"
      else
        settings_binding_action(action) || action
      end
    end

    private def settings_display_value(action : String) : String
      if theme = settings_theme_name(action)
        Theme.name == theme ? "active" : "press Enter"
      else
        key_hint(settings_binding_action(action) || "", "")
      end
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
                  if selected && settings_theme_name(selected)
                    "↑/↓ (or 1-9) select, Enter to apply, Esc close"
                  else
                    "↑/↓ (or 1-9) select, Enter to remap, Esc close"
                  end
                when SettingsState::Mode::Capture
                  action = selected_settings_action
                  if action
                    "Press new key for #{settings_display_name(action)}, Esc to cancel"
                  else
                    "Press new key, Esc to cancel"
                  end
                when SettingsState::Mode::ConfirmOverwrite
                  "Conflict with #{@settings.conflicting_action || "another action"} -> Enter/Y accept, N/Esc cancel"
                else
                  "Press Esc to close"
                end

      draw_text_line(buffer, clip, dialog_x + 2, hint_y, message, normal, dialog_width - 4)
    end

    private def assign_key_binding(action : String, binding : String, remove_from_conflict : Bool = true) : Nil
      normalized = KeyConfig.normalize_binding(binding)
      return if normalized.empty?

      if remove_from_conflict
        @key_bindings.each_value do |bindings|
          bindings.delete(normalized)
        end
      end

      @key_bindings[action] = [normalized]

      saved = save_key_bindings
      if saved
        @status_log.success("Saved keymap to #{resolve_keymap_for_output}")
      else
        @status_log.warning("Could not persist keymap; using in-memory map")
      end

      mark_dirty!
    end

    private def save_key_bindings : Bool
      path = resolve_keymap_path_for_save
      return false unless path

      begin
        KeyConfig.save(path, @key_bindings)
        @keymap_path = path
        true
      rescue ex
        @status_log.error("Failed to save key bindings: #{ex.class}: #{ex.message}")
        false
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

    private def load_key_bindings(path : String?) : KeyConfig::ActionMap
      warning_callback = ->(message : String) { @status_log.warning(message) }

      return KeyConfig.load(path, warning_callback) if path && !path.empty?
      resolved = KeyConfig.resolve_default_path
      return KeyConfig.load(resolved, warning_callback) if resolved
      KeyConfig.defaults
    end

    private def action_pressed?(action : String, event : Tui::KeyEvent) : Bool
      keys = @key_bindings[action]?
      return false unless keys
      keys.any? { |key| event.matches?(key) }
    end

    private def key_hint(action : String, fallback : String = "") : String
      keys = @key_bindings[action]?
      keys = KeyConfig.defaults[action]? if keys.nil? || keys.empty?
      return fallback if keys.nil? || keys.empty?
      keys.join(" / ")
    end

    private def build_quick_actions_menu : Array(LspContextAction)
      actions = [
        LspContextAction.new("Find in file", "/", -> { open_search_panel(SearchState::Scope::ThisFile) }),
        LspContextAction.new("Find backward", "?", -> { open_search_panel(SearchState::Scope::ThisFile, forward: false) }),
        LspContextAction.new("Find in project", ":grep ", -> { open_search_panel(SearchState::Scope::Project) }),
        LspContextAction.new("Find/Replace", ":r/", -> { open_command_palette(":r/") }),
      ]

      actions.concat(build_lsp_context_menu_actions)
      actions
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
      editor.tab_size = 2
      editor.word_wrap = false
      hyperclick = @on_editor_hyperclick
      editor.on_hyperclick do |line, col, modifiers|
        hyperclick.try(&.call(line, col, modifiers))
      end

      if buffer
        configure_editor_lsp_styles_internal(editor, buffer)
      end
    end

    private def configure_editor_lsp_styles_internal(editor : Tui::TextEditor, buffer : OpenBuffer) : Nil
      seed_syntax_overlay(buffer)
      editor.on_cell_style do |line, col, _char, style|
        token = buffer.semantic_overlay.name_at(line, col)
        styled = Theme::Syntax.apply(style, token)
        lsp_diagnostic_style(buffer.diagnostics, line, col, styled)
      end
    end

    private def seed_syntax_overlay(buffer : OpenBuffer) : Nil
      return unless buffer.crystal_family?
      return if buffer.semantic_overlay.any_tokens?

      overlay = SemanticOverlay.build([] of Int32, buffer.editor.lines, buffer.semantic_overlay.legend)
      overlay.apply_hash_comments(buffer.editor.lines)
      buffer.semantic_overlay = overlay
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
      @status_log.info("#{key_hint("app.open_file_tree")} tree | #{key_hint("app.save")} save | #{key_hint("app.close_tab")} close | #{key_hint("lsp.status")} LSP status")
      @status_log.info("#{key_hint("app.next_tab")} next tab | #{key_hint("app.previous_tab")} prev tab | #{key_hint("app.goto_tab_1")}..#{key_hint("app.goto_tab_9")} jump to tab")
      @status_log.info("Command palette: #{key_hint("app.command_palette")} or Esc Esc, then :w :q :wq :open :theme ...")
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

    private def update_header : Nil
      update_header_internal
    end

    private def update_header_internal : Nil
      subtitle = "No file opened"

      if buffer = active_buffer_internal
        lang = buffer.language_id || "plaintext"
        dirty = buffer.editor.modified? ? " *" : ""
        lsp_mark = if @lsp.nil?
                     "  · no LSP"
                   elsif @lsp.try(&.semantic_tokens_supported?)
                     "  · LSP"
                   else
                     "  · LSP no tokens"
                   end
        subtitle = "#{buffer.path}#{dirty}  (#{lang})#{lsp_mark}"
        rename_tab_internal(buffer)
      elsif !@document_session.open_buffers.empty?
        subtitle = "#{@document_session.open_buffers.size} buffers"
      end

      @header.subtitle = subtitle
      mark_dirty!
    end

    private def current_lsp_context_internal : NamedTuple(uri: String, line: Int32, character: Int32)?
      buffer = active_buffer_internal
      editor = active_editor_internal
      return nil if buffer.nil? || editor.nil?
      {uri: buffer.uri, line: editor.cursor_line, character: editor.cursor_col}
    end

    private def active_editor_internal : Tui::TextEditor?
      if active = @editor_tabs.active_tab_id
        @document_session.open_buffers[active]?.try(&.editor)
      end
    end

    private def active_buffer_internal : OpenBuffer?
      if active = @editor_tabs.active_tab_id
        @document_session.open_buffers[active]?
      end
    end

    private def rename_tab_internal(buffer : OpenBuffer) : Nil
      modified = buffer.editor.modified? ? "*" : ""
      @editor_tabs.rename_tab(buffer.path.to_s, "#{buffer.path.basename}#{modified}")
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
