require "crystal_tui"
require "json"

require "../editor/lsp_client"
require "../editor/command_palette"
require "../editor/input_router"
require "../editor/navigation_controller"
require "../editor/overlay_controller"
require "../editor/lsp_controller"
require "../editor/input_mode_controller"
require "../editor/uri_codec"
require "../editor/key_config"
require "../editor/theme"

module CrystalEditor
  class OpenBuffer
    property path : Path
    property editor : Tui::TextEditor
    property version : Int32
    property language_id : String?
    property uri : String
    property diagnostics : Array(Lsp::Diagnostic)

    def initialize(@path : Path, @editor : Tui::TextEditor, @language_id : String?, @uri : String)
      @version = 1
      @diagnostics = [] of Lsp::Diagnostic
    end
  end

  struct NavigationLocation
    property uri : String
    property line : Int32
    property character : Int32

    def initialize(@uri : String, @line : Int32, @character : Int32)
    end
  end

  struct CommandEntry
    property aliases : Array(String)
    property description : String

    def initialize(@aliases : Array(String), @description : String)
    end
  end

  struct CommandMark
    property uri : String
    property line : Int32
    property character : Int32

    def initialize(@uri : String, @line : Int32, @character : Int32)
    end
  end

  struct LspContextAction
    property label : String
    property shortcut : String
    property action : Proc(Nil)

    def initialize(@label : String, @shortcut : String, @action : Proc(Nil))
    end
  end

  class App < Tui::App
    include CommandPalette
    include InputModeController
    include OverlayController
    include InputRouter
    include NavigationController
    include LspController
    alias InputMode = InputModeController::InputMode

    enum SettingsMode
      Browse
      Capture
      ConfirmOverwrite
    end

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
      CommandEntry.new(["settings"], "Open settings dialog"),
      CommandEntry.new(["bnext", "bn"], "Go to next tab"),
      CommandEntry.new(["bprev", "bp"], "Go to previous tab"),
      CommandEntry.new(["buf", "buffer"], "Select buffer by index, index starts at 1"),
      CommandEntry.new(["search", "find"], "Search forward from cursor (also /pattern)"),
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
    @open_buffers : Hash(String, OpenBuffer) = {} of String => OpenBuffer
    @lsp : Lsp::Client?
    @navigation_history : Array(NavigationLocation) = [] of NavigationLocation
    @navigation_forward_history : Array(NavigationLocation) = [] of NavigationLocation
    @navigation_history_limit = 128
    @context_menu_open : Bool = false
    @context_menu_title : String = "Actions"
    @context_menu_actions : Array(LspContextAction) = [] of LspContextAction
    @context_menu_index : Int32 = 0
    @context_menu_overlay : Tui::OverlayRenderer? = nil
    @lsp_popup_open : Bool = false
    @lsp_popup_title : String = ""
    @lsp_popup_lines : Array(String) = [] of String
    @lsp_popup_overlay : Tui::OverlayRenderer? = nil
    @key_bindings : KeyConfig::ActionMap = KeyConfig.defaults
    @input_mode_controller : InputModeController::ModeStack = InputModeController::ModeStack.new
    @command_overlay : Tui::OverlayRenderer? = nil
    @command_open : Bool = false
    @command_input : String = ":"
    @command_candidates : Array(CommandEntry) = [] of CommandEntry
    @command_history : Array(String) = [] of String
    @command_history_index : Int32 = -1
    @command_last_escape_ms : Int64 = 0_i64
    @last_search_query : String? = nil
    @last_search_forward : Bool = true
    @command_marks : Hash(String, CommandMark) = {} of String => CommandMark
    @settings_open : Bool = false
    @settings_mode : SettingsMode = SettingsMode::Browse
    @settings_overlay : Tui::OverlayRenderer? = nil
    @settings_actions : Array(String) = [] of String
    @settings_selected_index : Int32 = 0
    @settings_capture_action : String? = nil
    @settings_capture_binding : String = ""
    @settings_conflicting_action : String? = nil
    @keymap_path : String? = nil
    @theme_path : String? = nil

    def initialize(project_root : Path, lsp_command : String? = nil, lsp_args : Array(String) = [] of String, keymap_path : String? = nil, theme_path : String? = nil)
      super()

      @project_root = File.directory?(project_root.to_s) ? project_root : project_root.parent
      @theme_path = resolve_theme_path(theme_path)
      Theme.load(@theme_path)

      @file_panel = Tui::FilePanel.new(@project_root, id: "project-tree")

      @editor_tabs = Tui::TabbedPanel.new("tabs")
      @editor_tabs.show_close_button = true
      @editor_tabs.on_tab_close do |tab_id|
        close_tab(tab_id)
      end
      @editor_tabs.on_tab_switch do |_id|
        update_header
      end

      @status_log = Tui::Log.new("status")
      @status_log.max_entries = 200
      @keymap_path = resolve_keymap_path(keymap_path)
      @key_bindings = load_key_bindings(@keymap_path)

      @status_log.info("Project: #{@project_root}")
      @status_log.info("Tip: #{key_hint("app.open_file_tree")} tree | #{key_hint("app.save")} save | #{key_hint("app.close_tab")} close | #{key_hint("app.next_tab")} / #{key_hint("app.goto_tab_1")}..9 switch")
      @status_log.info("Tip: #{key_hint("app.previous_tab")} previous tab | #{key_hint("lsp.status")} LSP status | #{key_hint("app.quit")} quit | #{key_hint("app.help")} | #{key_hint("app.settings")}")
      @status_log.info("Tip: #{key_hint("app.reload_theme")} reload theme | #{key_hint("app.jump_back")} jump back | #{key_hint("app.jump_forward")} jump forward")
      @status_log.info("Tip: Esc+Esc opens command palette | #{key_hint("app.command_palette")} command palette")
      @status_log.info("Tip: #{key_hint("app.quick_actions")} quick actions | #{key_hint("lsp.goto_definition")} go to definition | #{key_hint("app.jump_back")} back | #{key_hint("app.jump_forward")} forward")
      @status_log.info("Tip: #{key_hint("lsp.hover")} hover | #{key_hint("lsp.references")} references | #{key_hint("lsp.signature")} signature | #{key_hint("lsp.context_menu")} LSP menu")
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
        ratio: 0.22,
        id: "file-editor-split"
      )
      @file_panel_split.first = @file_panel
      @file_panel_split.second = @editor_tabs
      @file_panel_split.show_border = true
      @file_panel_split.first_title = "Project"
      @file_panel_split.second_title = "Editors"
      @file_panel_split.min_first = 18
      @file_panel_split.min_second = 24

      @body_split = Tui::SplitContainer.new(
        direction: Tui::SplitContainer::Direction::Vertical,
        ratio: 0.84,
        id: "body-split"
      )
      @body_split.show_border = false
      @body_split.first = @file_panel_split
      @body_split.second = @status_log
      @body_split.min_second = 6

      @header = Tui::Header.new("header", "Crystal Editor")
      @header.subtitle = "No file opened"
      @header.show_clock = true
      @header.start_clock

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
      case @settings_mode
      when SettingsMode::Browse
        handle_settings_browse_input(event)
      when SettingsMode::Capture
        handle_settings_capture_input(event)
      when SettingsMode::ConfirmOverwrite
        handle_settings_confirm_input(event)
      else
        false
      end
    end

    private def handle_settings_browse_input(event : Tui::KeyEvent) : Bool
      return false unless @settings_open && !@settings_actions.empty?

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
        set_settings_selection(@settings_actions.size - 1)
        return true
      elsif action_pressed?("app.menu_select", event)
        return execute_selected_settings_action
      end

      if char = event.char
        if char >= '1' && char <= '9'
          index = char - '1'
          if index >= 0 && index < @settings_actions.size
            set_settings_selection(index)
            return execute_selected_settings_action
          end
        end
      end

      false
    end

    private def handle_settings_capture_input(event : Tui::KeyEvent) : Bool
      action = @settings_capture_action
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
        @settings_capture_binding = ""
        mark_dirty!
        return true
      end

      normalized = KeyConfig.normalize_binding(binding)
      @settings_capture_binding = normalized

      current = KeyConfig.find_action_for_binding(@key_bindings, normalized)
      if current == action || current.nil?
        assign_key_binding(action, normalized)
        @status_log.success("Mapped #{action} to #{normalized}")
        reset_settings_capture_state
        mark_dirty!
      else
        @settings_conflicting_action = current
        @settings_mode = SettingsMode::ConfirmOverwrite
      end

      mark_dirty!
      true
    end

    private def handle_settings_confirm_input(event : Tui::KeyEvent) : Bool
      action = @settings_capture_action
      unless action
        close_settings_dialog
        return true
      end

      if action_pressed?("app.menu_select", event) || event.matches?("enter") || event.matches?("return") || event.matches?("y")
        assign_key_binding(action, @settings_capture_binding, remove_from_conflict: true)
        @status_log.success("Updated #{action} to #{@settings_capture_binding} (overwrote #{action_for_settings_conflict})")
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
      @settings_conflicting_action || "another action"
    end

    private def reset_settings_capture_state : Nil
      @settings_mode = SettingsMode::Browse
      @settings_capture_action = nil
      @settings_capture_binding = ""
      @settings_conflicting_action = nil
    end

    private def open_settings_dialog : Nil
      close_context_menu
      close_lsp_popup

      if @settings_open
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

        @settings_actions = theme_actions + key_actions
        @settings_selected_index = 0
        @settings_capture_action = nil
        @settings_capture_binding = ""
        @settings_conflicting_action = nil
        @settings_mode = SettingsMode::Browse

        previous_overlay = @settings_overlay

        @settings_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_settings_dialog(buffer, clip)
        }
        @settings_overlay = open_overlay(previous_overlay, @settings_overlay.not_nil!)
        @settings_open = true
        mark_dirty!
      end
    end

    private def close_settings_dialog : Nil
      return unless @settings_open

      close_overlay(@settings_overlay)

      @settings_open = false
      @settings_overlay = nil
      exit_input_mode(InputMode::Settings)
      @settings_mode = SettingsMode::Browse
      @settings_capture_action = nil
      @settings_capture_binding = ""
      @settings_conflicting_action = nil
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

      @settings_capture_action = settings_action
      start_settings_capture
      true
    end

    private def start_settings_capture : Nil
      action = @settings_capture_action
      return unless action

      @settings_capture_binding = ""
      @settings_conflicting_action = nil
      @settings_mode = SettingsMode::Capture
      @status_log.info("Rebind #{action} | press any key")
      mark_dirty!
    end

    private def apply_theme_by_name(name : String) : Nil
      if Theme.load(name)
        @theme_path = name
        apply_theme
        @status_log.success("Theme applied: #{Theme.name}")
      else
        @status_log.warning("Theme not found: #{name}; using fallback #{Theme.name}")
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
      return if @settings_actions.empty?

      count = @settings_actions.size
      @settings_selected_index += delta
      if @settings_selected_index < 0
        @settings_selected_index = count - 1
      elsif @settings_selected_index >= count
        @settings_selected_index = 0
      end
      mark_dirty!
    end

    private def set_settings_selection(index : Int32) : Nil
      return if @settings_actions.empty?
      max = @settings_actions.size - 1
      return if index < 0 || index > max
      @settings_selected_index = index
      mark_dirty!
    end

    private def selected_settings_action : String?
      return nil if @settings_actions.empty?
      idx = @settings_selected_index.clamp(0, @settings_actions.size - 1)
      @settings_actions[idx]?
    end

    private def render_settings_dialog(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return if @settings_actions.empty?

      available_rows = [clip.height - 12, 1].max
      max_rows = [@settings_actions.size, available_rows].min
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
      title = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)

      # Top border
      buffer.set(dialog_x, dialog_y, '┌', border) if clip.contains?(dialog_x, dialog_y)
      (1...dialog_width - 1).each do |dx|
        buffer.set(dialog_x + dx, dialog_y, '─', border) if clip.contains?(dialog_x + dx, dialog_y)
      end
      buffer.set(dialog_x + dialog_width - 1, dialog_y, '┐', border) if clip.contains?(dialog_x + dialog_width - 1, dialog_y)

      header = "Settings"
      header.each_char_with_index do |char, idx|
        break if idx >= dialog_width - 2
        buffer.set(dialog_x + 1 + idx, dialog_y, char, title) if clip.contains?(dialog_x + 1 + idx, dialog_y)
      end

      content_top = dialog_y + 1
      content_bottom = dialog_y + dialog_height - 1

      (content_top...content_bottom).each do |line_y|
        break if line_y >= clip.bottom
        buffer.set(dialog_x, line_y, '│', border) if clip.contains?(dialog_x, line_y)
        buffer.set(dialog_x + dialog_width - 1, line_y, '│', border) if clip.contains?(dialog_x + dialog_width - 1, line_y)
        (1...dialog_width - 1).each do |dx|
          buffer.set(dialog_x + dx, line_y, ' ', border) if clip.contains?(dialog_x + dx, line_y)
        end
      end

      list_start = content_top + 1
      list_end = [list_start + list_height, content_bottom - 5].min
      list_width = [dialog_width - 6, 1].max
      action_col = dialog_x + 3
      window_size = [list_end - list_start, 1].max
      max_start = [@settings_actions.size - window_size, 0].max
      window_start = @settings_selected_index - window_size / 2
      window_start = 0 if window_start < 0
      window_start = max_start if window_start > max_start

      list_index = 0

      @settings_actions.each_with_index do |action, index|
        next if index < window_start
        break if list_start + list_index >= list_end
        break if list_index >= window_size

        y = list_start + list_index
        is_active = index == @settings_selected_index
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
      message = case @settings_mode
                when SettingsMode::Browse
                  selected = selected_settings_action
                  if selected && settings_theme_name(selected)
                    "↑/↓ (or 1-9) select, Enter to apply, Esc close"
                  else
                    "↑/↓ (or 1-9) select, Enter to remap, Esc close"
                  end
                when SettingsMode::Capture
                  action = selected_settings_action
                  if action
                    "Press new key for #{settings_display_name(action)}, Esc to cancel"
                  else
                    "Press new key, Esc to cancel"
                  end
                when SettingsMode::ConfirmOverwrite
                  "Conflict with #{@settings_conflicting_action || "another action"} -> Enter/Y accept, N/Esc cancel"
                else
                  "Press Esc to close"
                end

      message.each_char_with_index do |char, idx|
        break if idx >= dialog_width - 4
        buffer.set(dialog_x + 2 + idx, hint_y, char, normal) if clip.contains?(dialog_x + 2 + idx, hint_y)
      end

      (dialog_x + 1...dialog_x + dialog_width - 1).each do |x|
        buffer.set(x, content_bottom, '─', border) if clip.contains?(x, content_bottom)
      end
      buffer.set(dialog_x, content_bottom, '└', border) if clip.contains?(dialog_x, content_bottom)
      buffer.set(dialog_x + dialog_width - 1, content_bottom, '┘', border) if clip.contains?(dialog_x + dialog_width - 1, content_bottom)
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
      Path.new(home, ".config", "crystal_editor", "config.json").to_s
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

    private def handle_context_menu_input(event : Tui::KeyEvent) : Bool
      if action_pressed?("app.menu_close", event)
        close_context_menu
        return true
      end

      case
      when action_pressed?("app.menu_up", event)
        move_context_menu_selection(-1)
        mark_dirty!
        return true
      when action_pressed?("app.menu_down", event)
        move_context_menu_selection(1)
        mark_dirty!
        return true
      when action_pressed?("app.menu_select", event)
        execute_selected_context_action
        return true
      when action_pressed?("app.menu_first", event)
        @context_menu_index = 0
        mark_dirty!
        return true
      when action_pressed?("app.menu_last", event)
        @context_menu_index = @context_menu_actions.size - 1
        mark_dirty!
        return true
      end

      if char = event.char
        if char >= '1' && char <= '9'
          index = (char - '1')
          if index >= 0 && index < @context_menu_actions.size
            @context_menu_index = index
            execute_selected_context_action
            return true
          end
        end
      end

      false
    end

    private def handle_lsp_popup_input(event : Tui::KeyEvent) : Bool
      if action_pressed?("lsp.popup_close", event)
        close_lsp_popup
        return true
      end
      false
    end

    private def move_context_menu_selection(delta : Int32) : Nil
      return if @context_menu_actions.empty?

      @context_menu_index += delta
      if @context_menu_index < 0
        @context_menu_index = @context_menu_actions.size - 1
      elsif @context_menu_index >= @context_menu_actions.size
        @context_menu_index = 0
      end
    end

    private def execute_selected_context_action : Nil
      return if @context_menu_actions.empty?

      index = @context_menu_index.clamp(0, @context_menu_actions.size - 1)
      action = @context_menu_actions[index]?
      return unless action

      close_context_menu
      action.action.call
    end

    private def open_quick_actions_menu : Nil
      open_context_menu("Quick Actions", build_quick_actions_menu)
    end

    private def open_lsp_context_menu : Nil
      open_context_menu("LSP Actions", build_lsp_context_menu_actions)
    end

    private def open_context_menu(title : String, actions : Array(LspContextAction)) : Nil
      if actions.empty?
        if title == "LSP Actions"
          @status_log.warning("No LSP actions available for this cursor")
        end
        return
      end

      close_lsp_popup
      with_input_mode_guard(InputMode::ContextMenu) do
        @context_menu_title = title
        @context_menu_index = 0

        previous_overlay = @context_menu_overlay

        @context_menu_actions = actions
        @context_menu_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_lsp_context_menu(buffer, clip)
        }
        @context_menu_overlay = open_overlay(previous_overlay, @context_menu_overlay.not_nil!)
        @context_menu_open = true
        mark_dirty!
      end
    end

    private def close_context_menu : Nil
      return unless @context_menu_open

      close_overlay(@context_menu_overlay)

      @context_menu_open = false
      exit_input_mode(InputMode::ContextMenu)
      @context_menu_overlay = nil
      @context_menu_actions = [] of LspContextAction
      @context_menu_index = 0
      @context_menu_title = "Actions"
    end

    private def open_lsp_popup(title : String, lines : Array(String), max_lines : Int32 = 16) : Nil
      close_context_menu
      @lsp_popup_title = title
      @lsp_popup_lines = lines

      with_input_mode_guard(InputMode::LspPopup) do
        previous_overlay = @lsp_popup_overlay
        @lsp_popup_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_lsp_popup(buffer, clip, max_lines)
        }
        @lsp_popup_overlay = open_overlay(previous_overlay, @lsp_popup_overlay.not_nil!)
        @lsp_popup_open = true
        mark_dirty!
      end
    end

    private def close_lsp_popup : Nil
      return unless @lsp_popup_open

      close_overlay(@lsp_popup_overlay)

      @lsp_popup_open = false
      exit_input_mode(InputMode::LspPopup)
      @lsp_popup_title = ""
      @lsp_popup_lines = [] of String
      @lsp_popup_overlay = nil
    end

    private def render_lsp_context_menu(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return if @context_menu_actions.empty?

      menu_width = 60
      max_label = @context_menu_actions.map { |action| action.label.size }.max || 10
      max_shortcut = @context_menu_actions.map { |action| action.shortcut.size }.max || 0
      menu_width = [max_label + max_shortcut + 8, 12].max
      menu_height = @context_menu_actions.size + 2

      editor = current_editor
      base_rect = editor ? editor.rect : @body_split.rect
      menu_x = (base_rect.x + 2).clamp(clip.x, [clip.right - menu_width, clip.x].max)
      menu_y = (base_rect.y + 1).clamp(clip.y, [clip.bottom - menu_height, clip.y].max)

      fg_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      active_style = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)
      header_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)
      title = @context_menu_title.empty? ? "Actions" : @context_menu_title

      # Border top
      buffer.set(menu_x, menu_y, '┌', fg_style) if clip.contains?(menu_x, menu_y)
      (1...menu_width - 1).each do |dx|
        buffer.set(menu_x + dx, menu_y, '─', fg_style) if clip.contains?(menu_x + dx, menu_y)
      end
      buffer.set(menu_x + menu_width - 1, menu_y, '┐', fg_style) if clip.contains?(menu_x + menu_width - 1, menu_y)

      # Header
      title_x = menu_x + 1
      title.each_char_with_index do |char, idx|
        break if title_x + idx >= menu_x + menu_width - 1
        buffer.set(title_x + idx, menu_y, char, header_style) if clip.contains?(title_x + idx, menu_y)
      end

      @context_menu_actions.each_with_index do |action, index|
        y = menu_y + 1 + index
        is_selected = index == @context_menu_index
        row_style = is_selected ? active_style : fg_style
        line_text = "#{index + 1}) #{action.label} [#{action.shortcut}]"
        line_text = line_text.ljust(menu_width - 2)[0, menu_width - 2]

        buffer.set(menu_x, y, '│', fg_style) if clip.contains?(menu_x, y)
        (1...menu_width - 1).each do |dx|
          buffer.set(menu_x + dx, y, ' ', row_style) if clip.contains?(menu_x + dx, y)
        end
        line_text.each_char_with_index do |char, idx|
          break if idx >= menu_width - 2
          buffer.set(menu_x + 1 + idx, y, char, row_style) if clip.contains?(menu_x + 1 + idx, y)
        end
        buffer.set(menu_x + menu_width - 1, y, '│', fg_style) if clip.contains?(menu_x + menu_width - 1, y)
      end

      bottom_y = menu_y + menu_height - 1
      buffer.set(menu_x, bottom_y, '└', fg_style) if clip.contains?(menu_x, bottom_y)
      (1...menu_width - 1).each do |dx|
        buffer.set(menu_x + dx, bottom_y, '─', fg_style) if clip.contains?(menu_x + dx, bottom_y)
      end
      buffer.set(menu_x + menu_width - 1, bottom_y, '┘', fg_style) if clip.contains?(menu_x + menu_width - 1, bottom_y)
    end

    private def render_lsp_popup(buffer : Tui::Buffer, clip : Tui::Rect, max_lines : Int32) : Nil
      return if @lsp_popup_lines.empty?

      body_lines = @lsp_popup_lines
      content_lines = body_lines[0, max_lines] || [] of String
      line_width = content_lines.map(&.size).max || 1
      popup_width = [line_width + 4, 90].min
      popup_height = content_lines.size + 4

      editor = current_editor
      base_rect = editor ? editor.rect : @body_split.rect
      popup_x = (base_rect.x + base_rect.width - popup_width - 2).clamp(clip.x, [clip.right - popup_width, clip.x].max)
      popup_y = (base_rect.y + 1).clamp(clip.y, [clip.bottom - popup_height, clip.y].max)

      fg_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)

      buffer.set(popup_x, popup_y, '┌', fg_style) if clip.contains?(popup_x, popup_y)
      (1...popup_width - 1).each do |dx|
        buffer.set(popup_x + dx, popup_y, '─', fg_style) if clip.contains?(popup_x + dx, popup_y)
      end
      buffer.set(popup_x + popup_width - 1, popup_y, '┐', fg_style) if clip.contains?(popup_x + popup_width - 1, popup_y)

      header = @lsp_popup_title.empty? ? "LSP" : @lsp_popup_title
      header.each_char_with_index do |char, idx|
        break if idx >= popup_width - 2
        buffer.set(popup_x + 1 + idx, popup_y, char, title_style) if clip.contains?(popup_x + 1 + idx, popup_y)
      end

      (1..popup_height - 2).each do |row|
        y = popup_y + row
        if y >= clip.bottom
          break
        end
        buffer.set(popup_x, y, '│', fg_style) if clip.contains?(popup_x, y)
        (1...popup_width - 1).each do |dx|
          buffer.set(popup_x + dx, y, ' ', fg_style) if clip.contains?(popup_x + dx, y)
        end
        buffer.set(popup_x + popup_width - 1, y, '│', fg_style) if clip.contains?(popup_x + popup_width - 1, y)
      end

      content_lines.each_with_index do |line, index|
        y = popup_y + 1 + index
        break if y >= popup_y + popup_height - 1
        line.each_char_with_index do |char, idx|
          break if idx >= popup_width - 3
          buffer.set(popup_x + 2 + idx, y, char, fg_style) if clip.contains?(popup_x + 2 + idx, y)
        end
      end

      if content_lines.size < body_lines.size
        indicator = "… #{body_lines.size - content_lines.size} more"
        y = popup_y + popup_height - 2
        indicator.each_char_with_index do |char, idx|
          break if idx >= popup_width - 3
          buffer.set(popup_x + 2 + idx, y, char, fg_style) if clip.contains?(popup_x + 2 + idx, y)
        end
      end

      bottom = popup_y + popup_height - 1
      if bottom < clip.bottom
        buffer.set(popup_x, bottom, '└', fg_style) if clip.contains?(popup_x, bottom)
        (1...popup_width - 1).each do |dx|
          buffer.set(popup_x + dx, bottom, '─', fg_style) if clip.contains?(popup_x + dx, bottom)
        end
        buffer.set(popup_x + popup_width - 1, bottom, '┘', fg_style) if clip.contains?(popup_x + popup_width - 1, bottom)
      end
    end

    private def load_key_bindings(path : String?) : KeyConfig::ActionMap
      return KeyConfig.load(path) if path && !path.empty?
      resolved = KeyConfig.resolve_default_path
      return KeyConfig.load(resolved) if resolved
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
        LspContextAction.new("Search forward", "/", -> { open_command_palette("/") }),
        LspContextAction.new("Search backward", "?", -> { open_command_palette("?") }),
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

      @open_buffers.each_value do |buffer|
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
        @status_log.warning("Theme load failed, using fallback: #{Theme.name}")
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
      editor.current_line_bg = Theme::Editor.current_line_bg
      editor.show_line_numbers = true
      editor.tab_size = 2
      editor.word_wrap = false

      if buffer
        configure_editor_lsp_styles(editor, buffer)
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
      @status_log.info("#{key_hint("app.open_file_tree")} tree | #{key_hint("app.save")} save | #{key_hint("app.close_tab")} close | #{key_hint("lsp.status")} LSP status")
      @status_log.info("#{key_hint("app.next_tab")} next tab | #{key_hint("app.previous_tab")} prev tab | #{key_hint("app.goto_tab_1")}..#{key_hint("app.goto_tab_9")} jump to tab")
      @status_log.info("Command palette: #{key_hint("app.command_palette")} or Esc Esc, then :w :q :wq :open :theme ...")
      @status_log.info("Quick actions: #{key_hint("app.quick_actions")} (Search/Replace/LSP actions)")
      @status_log.info("Text replace: :r /old/new/ [gic] or :s/old/new/gic (c = preview)")
      @status_log.info("#{key_hint("lsp.goto_definition")} definition | #{key_hint("app.jump_back")} back")
      @status_log.info("#{key_hint("app.jump_forward")} forward | #{key_hint("app.settings")} settings")
      @status_log.info("#{key_hint("lsp.hover")} Hover | #{key_hint("lsp.references")} References | #{key_hint("lsp.signature")} Signature | #{key_hint("lsp.context_menu")} LSP menu")
      @status_log.info("Context menu: #{key_hint("app.menu_select")} run | 1..9 quick | #{key_hint("app.menu_up")}/#{key_hint("app.menu_down")} navigate | #{key_hint("app.menu_close")} close")
      @status_log.info("#{key_hint("app.reload_theme")} reload theme | #{key_hint("app.help")} help | #{key_hint("app.settings")} settings | #{key_hint("app.quit")} quit")
      @status_log.info("Settings: reopen any key binding to remap or choose a theme preset")
      @status_log.info("Use --lsp COMMAND and --theme PATH|preset to connect to LSP and load theme")
    end

    private def update_header : Nil
      subtitle = "No file opened"

      if buffer = current_buffer
        lang = buffer.language_id || "plaintext"
        dirty = buffer.editor.modified? ? " *" : ""
        subtitle = "#{buffer.path}#{dirty}  (#{lang})"
        rename_tab(buffer)
      elsif !@open_buffers.empty?
        subtitle = "#{@open_buffers.size} buffers"
      end

      @header.subtitle = subtitle
      mark_dirty!
    end

    private def detect_language(path : Path) : String?
      case path.extension
      when ".cr"
        "crystal"
      when ".rb"
        "ruby"
      when ".py"
        "python"
      when ".ts"
        "typescript"
      when ".js"
        "javascript"
      when ".json"
        "json"
      when ".md"
        "markdown"
      when ".yml", ".yaml"
        "yaml"
      when ".toml"
        "toml"
      when ".sh"
        "bash"
      when ".html"
        "html"
      when ".css"
        "css"
      else
        "plaintext"
      end
    end

    private def path_to_uri(path : Path) : String
      UriCodec.path_to_uri(path)
    end
  end
end
