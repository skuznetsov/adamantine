require "crystal_tui"
require "json"

require "../editor/replace_utils"
require "../editor/lsp_client"
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

  alias ReplaceFlags = ReplaceUtils::ReplaceFlags

  class App < Tui::App
    enum CommandMode
      Inactive
      Palette
    end

    enum SettingsMode
      Browse
      Capture
      ConfirmOverwrite
    end

    COMMAND_PALETTE_DOUBLE_ESCAPE_MS = 320

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
    @command_mode : CommandMode = CommandMode::Inactive
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

      if event.key != Tui::Key::Escape
        @command_last_escape_ms = 0
      end

      if @command_mode != CommandMode::Inactive
        return true if handle_command_palette_input(event)
      end

      if action_pressed?("app.command_palette", event) || command_palette_double_escape?(event)
        open_command_palette
        return true
      end

      if @settings_open
        return true if handle_settings_input(event)
      end

      if @context_menu_open
        return true if handle_context_menu_input(event)
      end

      if @lsp_popup_open
        return true if handle_lsp_popup_input(event)
      end

      if action_pressed?("app.open_file_tree", event)
        @file_panel.focus
        return true
      elsif action_pressed?("app.next_tab", event)
        switch_to_next_tab
        return true
      elsif action_pressed?("app.previous_tab", event)
        switch_to_previous_tab
        return true
      elsif action_pressed?("app.goto_tab_1", event)
        switch_to_tab_by_position(0)
        return true
      elsif action_pressed?("app.goto_tab_2", event)
        switch_to_tab_by_position(1)
        return true
      elsif action_pressed?("app.goto_tab_3", event)
        switch_to_tab_by_position(2)
        return true
      elsif action_pressed?("app.goto_tab_4", event)
        switch_to_tab_by_position(3)
        return true
      elsif action_pressed?("app.goto_tab_5", event)
        switch_to_tab_by_position(4)
        return true
      elsif action_pressed?("app.goto_tab_6", event)
        switch_to_tab_by_position(5)
        return true
      elsif action_pressed?("app.goto_tab_7", event)
        switch_to_tab_by_position(6)
        return true
      elsif action_pressed?("app.goto_tab_8", event)
        switch_to_tab_by_position(7)
        return true
      elsif action_pressed?("app.goto_tab_9", event)
        switch_to_tab_by_position(8)
        return true
      elsif action_pressed?("app.quick_actions", event)
        open_quick_actions_menu
        return true
      elsif action_pressed?("lsp.goto_definition", event)
        goto_definition
        return true
      elsif action_pressed?("lsp.hover", event)
        show_hover_hint
        return true
      elsif action_pressed?("lsp.references", event)
        show_references_hint
        return true
      elsif action_pressed?("lsp.signature", event)
        show_signature_hint
        return true
      elsif action_pressed?("lsp.context_menu", event)
        open_lsp_context_menu
        return true
      elsif action_pressed?("app.settings", event)
        open_settings_dialog
        return true
      elsif action_pressed?("app.save", event)
        save_active
        return true
      elsif action_pressed?("app.close_tab", event)
        close_active_tab
        return true
      elsif action_pressed?("lsp.status", event)
        show_lsp_status
        return true
      elsif action_pressed?("app.focus_tree", event)
        @file_panel.focus
        return true
      elsif action_pressed?("app.focus_editor", event)
        if @editor_tabs.active_tab_id
          focus_active_editor
        else
          @file_panel.focus
        end
        return true
      elsif action_pressed?("app.refresh_tree", event)
        refresh_file_tree
        return true
      elsif action_pressed?("app.reload_theme", event)
        reload_theme
        return true
      elsif action_pressed?("app.help", event)
        show_help
        return true
      elsif action_pressed?("app.quit", event)
        quit
        return true
      elsif action_pressed?("app.jump_back", event)
        jump_back
        return true
      elsif action_pressed?("app.jump_forward", event)
        jump_forward
        return true
      end

      super
    end

    def on_event(event : Tui::Event) : Bool
      false
    end

    private def handle_command_palette_input(event : Tui::KeyEvent) : Bool
      if action_pressed?("app.menu_close", event) || event.key == Tui::Key::Escape
        close_command_palette
        return true
      end

      if action_pressed?("app.menu_select", event) || event.matches?("enter") || event.matches?("return")
        execute_command(@command_input)
        return true
      end

      if action_pressed?("app.menu_up", event)
        command_palette_history_prev
        return true
      end

      if action_pressed?("app.menu_down", event)
        command_palette_history_next
        return true
      end

      if event.matches?("tab")
        command_palette_complete
        return true
      end

      if event.matches?("backspace")
        if @command_input.size > 1
          @command_input = @command_input[0...-1]
          update_command_palette_candidates
          mark_dirty!
        else
          close_command_palette
        end
        return true
      end

      if char = event.char
        return false if char.ord < 32

        @command_input = @command_input + char.to_s
        @command_history_index = -1
        update_command_palette_candidates
        mark_dirty!
        return true
      end

      true
    end

    private def command_palette_double_escape?(event : Tui::KeyEvent) : Bool
      return false unless event.key == Tui::Key::Escape

      now = Time.utc.to_unix_ms
      last = @command_last_escape_ms
      @command_last_escape_ms = now

      return false if last == 0
      (now - last) <= COMMAND_PALETTE_DOUBLE_ESCAPE_MS
    end

    private def open_command_palette(initial_input : String = ":") : Nil
      close_context_menu
      close_lsp_popup
      close_settings_dialog if @settings_open

      return if @command_open

      @command_open = true
      @command_mode = CommandMode::Palette
      @command_history_index = -1
      @command_input = normalize_command_palette_input(initial_input)
      update_command_palette_candidates

      if overlay = @command_overlay
        App.remove_overlay(overlay)
      end

      @command_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
        render_command_palette(buffer, clip)
      }
      App.add_overlay(@command_overlay.not_nil!)
      mark_dirty!
    end

    private def normalize_command_palette_input(raw_input : String) : String
      text = raw_input.empty? ? ":" : raw_input
      return text if text.starts_with?('/') || text.starts_with?('?') || text.starts_with?(':')
      ":#{text}"
    end

    private def close_command_palette : Nil
      return unless @command_open

      if overlay = @command_overlay
        App.remove_overlay(overlay)
      end

      @command_overlay = nil
      @command_mode = CommandMode::Inactive
      @command_open = false
      @command_input = ":"
      @command_candidates = [] of CommandEntry
      @command_history_index = -1
      mark_dirty!
    end

    private def command_palette_complete : Nil
      return if @command_candidates.empty?

      first = @command_candidates[0]
      suggestion = first.aliases.first?
      return unless suggestion

      text = clean_command_text(@command_input)
      parsed = parse_command_parts(text)
      return if parsed.size > 1

      @command_input = ":#{suggestion} "
      @command_history_index = -1
      update_command_palette_candidates
      mark_dirty!
    end

    private def execute_command(raw_input : String) : Nil
      command_text = clean_command_text(raw_input)
      if command_text.empty?
        close_command_palette
        return
      end

      parts = parse_command_parts(command_text)
      return if parts.empty?

      raw_command = parts[0]
      arguments = parts[1..]
      if raw_command == "n"
        executed = execute_search_command_repeat(@last_search_forward)
      elsif raw_command == "N"
        executed = execute_search_command_repeat(!@last_search_forward)
      elsif command_text.starts_with?("/") || command_text.starts_with?("?")
        executed = execute_search_command(command_text)
      else
        if raw_command.starts_with?("s/")
          command = "s"
          argument_text = raw_command[1..]
          unless arguments.empty?
            argument_text += " #{arguments.join(" ")}"
          end
        elsif raw_command.starts_with?("r/")
          command = "r"
          argument_text = raw_command[1..]
          unless arguments.empty?
            argument_text += " #{arguments.join(" ")}"
          end
        else
          command = raw_command.downcase
          argument_text = arguments.join(" ")
        end

        executed = case command
                   when "w", "write"
                     save_active
                     true
                   when "q", "close"
                     close_active_tab
                     true
                   when "quit", "exit", "qa", "q!"
                     quit
                     true
                   when "wq", "wx", "writequit"
                     save_active
                     quit
                     true
                   when "e", "open", "edit"
                     open_file_by_command_argument(argument_text)
                     true
                   when "theme"
                     apply_theme_command(argument_text)
                     true
                   when "themes"
                     list_theme_presets
                     true
                   when "lsp"
                     show_lsp_status
                     true
                   when "tabnext", "next"
                     switch_to_next_tab
                     true
                   when "tabprev", "prev"
                     switch_to_previous_tab
                     true
                   when "bnext", "bn"
                     switch_to_next_tab
                     true
                   when "bprev", "bp"
                     switch_to_previous_tab
                     true
                   when "buf", "buffer"
                     open_buffer_by_argument(argument_text)
                     true
                   when "help", "?"
                     show_help
                     true
                   when "tree", "focus-tree", "tree-focus"
                     @file_panel.focus
                     true
                   when "focus-editor", "edit-focus"
                     if @editor_tabs.active_tab_id
                       focus_active_editor
                     else
                       @status_log.warning("No active editor")
                     end
                     true
                   when "open-theme"
                     reload_theme
                     true
                   when "ls", "buffers"
                     list_open_buffers
                     true
                   when "jumpback", "pop"
                     jump_back
                     true
                   when "jumpforward", "jf"
                     jump_forward
                     true
                   when "settings"
                     open_settings_dialog
                     true
                   when "set"
                     apply_set_command(argument_text)
                     true
                   when "cd"
                     change_project_root(argument_text)
                     true
                   when "pwd", "cwd"
                     show_current_directory
                     true
                   when "mark"
                     set_mark_command(argument_text)
                     true
                   when "marks"
                     list_marks
                     true
                   when "jump"
                     jump_to_mark(argument_text)
                     true
                   when "search", "find"
                     execute_search_command("/#{argument_text}")
                   when "replace", "s", "r"
                     execute_replace_command(argument_text)
                     true
                   else
                     @status_log.warning("Unknown command: #{command}")
                     false
                   end
      end

      if executed
        remember_command(command_text)
        close_command_palette
      else
        status = "Type :help for commands"
        @status_log.info(status)
        mark_dirty!
      end
    end

    private def execute_search_command(raw_command : String) : Bool
      return false if raw_command.size < 2
      return false unless raw_command[0] == '/' || raw_command[0] == '?'

      query = raw_command[1..-1].strip
      if query.empty?
        previous = @last_search_query
        if previous.nil? || previous.empty?
          @status_log.warning("No previous search pattern")
          return false
        end
        query = previous
      else
        @last_search_query = query
      end

      direction = raw_command[0] == '/'
      @last_search_forward = direction
      search_in_active_editor(query, direction)
    end

    private def execute_search_command_repeat(forward : Bool) : Bool
      query = @last_search_query
      if query.nil? || query.empty?
        @status_log.warning("No previous search pattern")
        return false
      end

      search_in_active_editor(query, forward)
    end

    private def search_in_active_editor(query : String, forward : Bool) : Bool
      editor = current_editor
      if editor.nil?
        @status_log.warning("No active editor")
        return false
      end

      lines = editor.text.split('\n')
      if lines.empty?
        @status_log.warning("No content in active editor")
        return false
      end

      max_line = lines.size - 1
      start_line = editor.cursor_line
      start_line = 0 if start_line < 0
      start_line = max_line if start_line > max_line

      start_col = editor.cursor_col
      start_col = 0 if start_col < 0

      match = if forward
                search_forward(lines, start_line, start_col, query)
              else
                search_backward(lines, start_line, start_col, query)
              end

      return false unless match

      line, col, wrapped = match
      move_editor_cursor(editor, line, col)
      @status_log.success("Search #{forward ? "/" : "?"}#{query.inspect}#{wrapped ? " (wrapped)" : ""} -> #{line + 1}:#{col + 1}")
      mark_dirty!
      true
    end

    private def search_forward(lines : Array(String), start_line : Int32, start_col : Int32, needle : String) : Tuple(Int32, Int32, Bool)?
      return nil if needle.empty?
      max_line = lines.size - 1
      start_column = [start_col + 1, 0].max

      first_line = lines[start_line]? || ""
      if (col = first_line.index(needle, start_column))
        return {start_line, col, false}
      end

      (start_line + 1).upto(max_line) do |line_index|
        line_text = lines[line_index]? || ""
        if (col = line_text.index(needle))
          return {line_index, col, false}
        end
      end

      0.upto(start_line - 1) do |line_index|
        line_text = lines[line_index]? || ""
        if (col = line_text.index(needle))
          return {line_index, col, true}
        end
      end

      nil
    end

    private def search_backward(lines : Array(String), start_line : Int32, start_col : Int32, needle : String) : Tuple(Int32, Int32, Bool)?
      return nil if needle.empty?
      start_column = start_col.clamp(0, lines[start_line]?.try(&.size) || 0)
      cursor_line = lines[start_line]?
      if cursor_line
        if (col = cursor_line[0, start_column].rindex(needle))
          return {start_line, col, false}
        end
      end

      (start_line - 1).downto(0) do |line_index|
        line_text = lines[line_index]? || ""
        if (col = line_text.rindex(needle))
          return {line_index, col, false}
        end
      end

      (lines.size - 1).downto(start_line + 1) do |line_index|
        line_text = lines[line_index]? || ""
        if (col = line_text.rindex(needle))
          return {line_index, col, true}
        end
      end

      nil
    end

    private def clean_command_text(raw_input : String) : String
      text = raw_input.strip
      return "" if text.empty?
      return text[1..-1].strip if text.starts_with?(":")
      text
    end

    private def parse_command_parts(raw_text : String) : Array(String)
      tokens = [] of String
      current = String.new
      in_quotes = false
      quote_char = '\0'
      escaped = false

      raw_text.each_char do |ch|
        if escaped
          current += ch
          escaped = false
          next
        end

        if ch == '\\'
          escaped = true
          next
        end

        if in_quotes
          if ch == quote_char
            in_quotes = false
          else
            current += ch
          end
          next
        end

        if ch == '"' || ch == '\''
          in_quotes = true
          quote_char = ch
          next
        end

        if ch.whitespace?
          unless current.empty?
            tokens << current
            current = ""
          end
        else
          current += ch
        end
      end

      tokens << current unless current.empty?
      tokens
    end

    private def command_prefix_token : String
      text = clean_command_text(@command_input)
      return "" if text.empty?
      tokens = parse_command_parts(text)
      return "" if tokens.empty?
      tokens[0]
    end

    private def update_command_palette_candidates : Nil
      token = command_prefix_token
      if token.empty?
        @command_candidates = COMMAND_ENTRIES.dup
      else
        lower = token.downcase
        @command_candidates = COMMAND_ENTRIES.select do |entry|
          entry.aliases.any? { |alias_name| alias_name.starts_with?(lower) }
        end
      end
    end

    private def remember_command(command_text : String) : Nil
      command = clean_command_text(command_text)
      return if command.empty?
      history = @command_history
      if !history.empty? && history[-1] == command
        return
      end
      history << command
      history.shift if history.size > 200
    end

    private def command_palette_history_prev : Nil
      return if @command_history.empty?
      if @command_history_index < 0
        @command_history_index = @command_history.size - 1
      elsif @command_history_index > 0
        @command_history_index -= 1
      end

      if @command_history_index >= 0
        @command_input = ":" + @command_history[@command_history_index]
        update_command_palette_candidates
        mark_dirty!
      end
    end

    private def command_palette_history_next : Nil
      return if @command_history.empty?
      if @command_history_index < 0
        @command_input = ":"
        update_command_palette_candidates
        mark_dirty!
        return
      end

      if @command_history_index < @command_history.size - 1
        @command_history_index += 1
        @command_input = ":" + @command_history[@command_history_index]
      else
        @command_history_index = -1
        @command_input = ":"
      end

      update_command_palette_candidates
      mark_dirty!
    end

    private def apply_theme_command(theme_name : String) : Nil
      name = theme_name.strip
      if name.empty?
        @status_log.info("Theme command: use ':theme <name>' or ':themes'")
        list_theme_presets
        return
      end

      if Theme.load(name)
        apply_theme
        @status_log.success("Theme applied: #{Theme.name}")
      else
        @status_log.warning("Theme not found: #{name}")
      end
    end

    private def list_theme_presets : Nil
      presets = Theme.preset_names.sort
      if presets.empty?
        @status_log.info("No theme presets available")
      else
        @status_log.info("Theme presets: #{presets.join(", ")}")
      end
    end

    private def open_file_by_command_argument(arg : String) : Nil
      path_value = arg.strip
      if path_value.empty?
        @status_log.warning("Usage: :open <path>")
        return
      end

      normalized = resolve_command_path(path_value)
      if File.directory?(normalized.to_s)
        @status_log.warning("Not a file: #{normalized}")
        return
      end

      if open_file(normalized)
        @status_log.success("Opened #{normalized}")
      else
        @status_log.error("File not found: #{normalized}")
      end
    end

    private def resolve_command_path(value : String) : Path
      raw = value
      home = ENV["HOME"]?
      if raw == "~"
        raw = home || raw
      elsif raw.starts_with?("~/") && home
        raw = File.join(home, raw[2..])
      elsif raw.starts_with?("~\\") && home
        raw = File.join(home, raw[2..])
      end

      candidate = Path.new(raw)
      candidate.absolute? ? candidate : (@project_root / candidate)
    end

    private def list_open_buffers : Nil
      if @open_buffers.empty?
        @status_log.info("No open buffers")
        return
      end

      opened = @open_buffers.each_value.to_a.sort_by do |buffer|
        buffer.path.to_s
      end.map do |buffer|
        path = buffer.path.to_s
        marker = @editor_tabs.active_tab_id == path ? "*" : " "
        "#{marker} #{path}"
      end

      @status_log.info("Open buffers:")
      opened.each { |entry| @status_log.info("  #{entry}") }
    end

    private def open_buffer_by_argument(argument_text : String) : Nil
      argument = argument_text.strip
      if argument.empty?
        list_open_buffers
        return
      end

      if index = argument.to_i?
        if index <= 0
          @status_log.warning("Buffer index must be positive")
          return
        end

        open_buffer_by_index(index - 1)
        return
      end

      matching = @open_buffers.select do |path_str, _|
        path = Path.new(path_str)
        path.basename.to_s == argument || path.to_s.includes?(argument)
      end

      if matching.empty?
        @status_log.warning("No matching buffer: #{argument}")
        return
      end

      if matching.size > 1
        @status_log.info("Multiple buffers match. Use a longer name or number:")
        matching.each_with_index do |pair, index|
          name = pair[0]
          @status_log.info("  #{index + 1}) #{name}")
        end
        return
      end

      path = matching.keys.first
      return unless path
      switch_to_tab_by_position_buffer(path.to_s)
    end

    private def open_buffer_by_index(index : Int32) : Nil
      entries = @open_buffers.keys.sort
      return @status_log.warning("No buffer at index #{index + 1}") if index < 0 || index >= entries.size
      switch_to_tab_by_position_buffer(entries[index])
    end

    private def switch_to_tab_by_position_buffer(path_str : String) : Nil
      return if @open_buffers.empty?
      return unless @open_buffers[path_str]?

      @editor_tabs.switch_to(path_str)
      focus_active_editor
      update_header
    end

    private def apply_set_command(argument_text : String) : Nil
      argument = argument_text.strip
      if argument.empty?
        @status_log.info("set options: theme=<name>")
        @status_log.info("theme: #{Theme.name}")
        return
      end

      if argument.includes?("=")
        key, value = argument.split("=", 2)
        case key.strip.downcase
        when "theme", "color_theme", "colorscheme"
          apply_theme_command(value.strip)
        else
          @status_log.warning("Unknown option: #{key}")
        end
      else
        @status_log.warning("Unsupported set command format. Use :set theme=<name>")
      end
    end

    private def change_project_root(argument_text : String) : Nil
      path_value = argument_text.strip
      if path_value.empty?
        @status_log.warning("Usage: :cd <path>")
        return
      end

      resolved = resolve_command_path(path_value)
      if !File.directory?(resolved.to_s)
        @status_log.warning("Not a directory: #{resolved}")
        return
      end

      @project_root = resolved
      @file_panel.path = resolved
      refresh_file_tree
      @status_log.success("Project root: #{resolved}")
      mark_dirty!
    end

    private def show_current_directory : Nil
      @status_log.info("Current root: #{@project_root}")
    end

    private def set_mark_command(argument_text : String) : Nil
      if argument_text.empty?
        list_marks
        return
      end

      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active position to mark")
        return
      end

      name = parse_command_parts(argument_text).first?.try(&.strip) || ""
      if name.empty?
        @status_log.warning("Usage: :mark <name>")
        return
      end

      @command_marks[name] = CommandMark.new(context[:uri], context[:line], context[:character])
      @status_log.success("Marked #{name} at #{context[:uri]}:#{context[:line] + 1}:#{context[:character] + 1}")
    end

    private def list_marks : Nil
      if @command_marks.empty?
        @status_log.info("No marks")
        return
      end

      @status_log.info("Marks:")
      @command_marks.each do |name, location|
        @status_log.info("  #{name}: #{location.uri}:#{location.line + 1}:#{location.character + 1}")
      end
    end

    private def jump_to_mark(argument_text : String) : Nil
      target = argument_text.strip
      if target.empty?
        @status_log.warning("Usage: :jump <name>")
        return
      end

      mark = @command_marks[target]?
      unless mark
        @status_log.warning("Unknown mark: #{target}")
        return
      end

      path = uri_to_path(mark.uri)
      if path.nil?
        @status_log.warning("Cannot resolve URI #{mark.uri}")
        return
      end

      if open_file(path, mark.line, mark.character)
        @status_log.success("Jumped to #{target}")
      else
        @status_log.error("Failed to jump to mark #{target}")
      end
    end

    private def execute_replace_command(argument_text : String) : Nil
      buffer = current_buffer
      if buffer.nil?
        @status_log.warning("No active buffer for replace")
        return
      end

      parsed = ReplaceUtils.parse_replace_arguments(argument_text)
      if parsed.nil?
        @status_log.warning("Usage: :r /old/new/ [gic] or :s/old/new/[gic]")
        return
      end

      old_text, new_text, flags = parsed
      if old_text.empty?
        @status_log.warning("Replace pattern must not be empty")
        return
      end

      editor = buffer.editor
      previous_line = editor.cursor_line
      previous_col = editor.cursor_col
      match_count = ReplaceUtils.replace_match_count(editor.text, old_text, flags)
      if match_count == 0
        @status_log.info("No matches for '#{old_text}'")
        return
      end

      if flags.preview
        sample = [match_count, 5].min
        preview = ReplaceUtils.make_replace_previews(editor.text, old_text, new_text, sample, flags)
        @status_log.info("Replace preview #{ReplaceUtils.flags_to_label(flags)} for '#{old_text}' => '#{new_text}'")
        if preview.empty?
          @status_log.info("No preview content")
        else
          preview.each_with_index do |line, index|
            @status_log.info("  #{index + 1}. #{line}")
          end
        end
        return
      end

      replaced = ReplaceUtils.replace_text_content(editor.text, old_text, new_text, flags)
      if replaced == editor.text
        @status_log.info("No matches for '#{old_text}'")
        return
      end

      editor.text = replaced
      editor.set_cursor(previous_line, previous_col)
      buffer.version += 1
      rename_tab(buffer)
      sync_lsp_change(buffer)
      update_header
      mark_dirty! if @command_open
      @status_log.success("Replaced #{flags.global ? "all" : "first"} occurrence#{flags.ignore_case ? " (ignore case)" : ""} of '#{old_text}' with '#{new_text}'")
    end

    private def render_command_palette(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless @command_open

      width = [clip.width - 6, 90].min
      width = [width, 56].max
      height = 14
      height = [height, clip.height - 2].min
      x = (clip.x + (clip.width - width) // 2).clamp(clip.x, [clip.right - width, clip.x].max)
      y = [clip.y + 2, clip.bottom - height - 1].max
      popup_bg = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      popup_border = Tui::Style.new(fg: Theme::Popup.border, bg: Theme::Popup.text)
      popup_title = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)
      popup_active = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)

      # top
      buffer.set(x, y, '┌', popup_border) if clip.contains?(x, y)
      (1...width - 1).each do |dx|
        buffer.set(x + dx, y, '─', popup_border) if clip.contains?(x + dx, y)
      end
      buffer.set(x + width - 1, y, '┐', popup_border) if clip.contains?(x + width - 1, y)

      title = " Command "
      title.each_char_with_index do |char, idx|
        break if idx >= width - 2
        buffer.set(x + 1 + idx, y, char, popup_title) if clip.contains?(x + 1 + idx, y)
      end

      body_top = y + 1
      (body_top...y + height - 1).each do |line_y|
        break if line_y >= clip.bottom
        buffer.set(x, line_y, '│', popup_border) if clip.contains?(x, line_y)
        buffer.set(x + width - 1, line_y, '│', popup_border) if clip.contains?(x + width - 1, line_y)
        (1...width - 1).each do |dx|
          buffer.set(x + dx, line_y, ' ', popup_bg) if clip.contains?(x + dx, line_y)
        end
      end

      input_prompt = ">"
      input_x = x + 2
      input_y = y + 1
      buffer.set(input_x, input_y, input_prompt, popup_active) if clip.contains?(input_x, input_y)
      input_area = width - 6
      input_value = @command_input.ljust(input_area)[0, input_area]
      input_value.each_char_with_index do |char, idx|
        buffer.set(input_x + 2 + idx, input_y, char, popup_bg) if clip.contains?(input_x + 2 + idx, input_y)
      end

      list_start = y + 3
      list_end = y + height - 3
      list_width = width - 4
      list_rows = [list_end - list_start, 0].max
      if list_rows > 0
        @command_candidates[0, list_rows].each_with_index do |entry, index|
          y_pos = list_start + index
          break if y_pos > list_end
          row_style = index == 0 ? popup_active : popup_bg
          command = entry.aliases.first? || ""
          line = "#{command.ljust(12)} - #{entry.description}"
          line = line.ljust(list_width)[0, list_width]
          line.each_char_with_index do |char, idx|
            break if idx >= list_width
            buffer.set(x + 2 + idx, y_pos, char, row_style) if clip.contains?(x + 2 + idx, y_pos)
          end
        end
      end

      hint = "[Enter] run | Esc closes | ↑/↓ history | Tab complete"
      hint = hint.ljust(width - 2)
      hint_y = y + height - 2
      hint.each_char_with_index do |char, idx|
        break if idx >= width - 2
        buffer.set(x + 1 + idx, hint_y, char, popup_border) if clip.contains?(x + 1 + idx, hint_y)
      end

      bottom = y + height - 1
      buffer.set(x, bottom, '└', popup_border) if clip.contains?(x, bottom)
      (1...width - 1).each do |dx|
        buffer.set(x + dx, bottom, '─', popup_border) if clip.contains?(x + dx, bottom)
      end
      buffer.set(x + width - 1, bottom, '┘', popup_border) if clip.contains?(x + width - 1, bottom)
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
      @settings_open = true

      if overlay = @settings_overlay
        App.remove_overlay(overlay)
      end

      @settings_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
        render_settings_dialog(buffer, clip)
      }
      App.add_overlay(@settings_overlay.not_nil!)
      mark_dirty!
    end

    private def close_settings_dialog : Nil
      return unless @settings_open

      if overlay = @settings_overlay
        App.remove_overlay(overlay)
      end

      @settings_open = false
      @settings_overlay = nil
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

      @context_menu_title = title
      @context_menu_index = 0
      close_lsp_popup

      overlay = @context_menu_overlay
      if overlay
        App.remove_overlay(overlay)
      end

      @context_menu_open = true
      @context_menu_actions = actions
      @context_menu_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
        render_lsp_context_menu(buffer, clip)
      }
      App.add_overlay(@context_menu_overlay.not_nil!)
      mark_dirty!
    end

    private def close_context_menu : Nil
      return unless @context_menu_open

      if overlay = @context_menu_overlay
        App.remove_overlay(overlay)
      end

      @context_menu_open = false
      @context_menu_overlay = nil
      @context_menu_actions = [] of LspContextAction
      @context_menu_index = 0
      @context_menu_title = "Actions"
    end

    private def open_lsp_popup(title : String, lines : Array(String), max_lines : Int32 = 16) : Nil
      close_context_menu
      @lsp_popup_title = title
      @lsp_popup_lines = lines

      @lsp_popup_open = true
      overlay = @lsp_popup_overlay
      if overlay
        App.remove_overlay(overlay)
      end
      @lsp_popup_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
        render_lsp_popup(buffer, clip, max_lines)
      }
      App.add_overlay(@lsp_popup_overlay.not_nil!)
      mark_dirty!
    end

    private def close_lsp_popup : Nil
      return unless @lsp_popup_open

      if overlay = @lsp_popup_overlay
        App.remove_overlay(overlay)
      end

      @lsp_popup_open = false
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

    private def focus_active_editor : Nil
      if editor = current_editor
        editor.focus
      end
    end

    private def move_editor_cursor(editor : Tui::TextEditor, line : Int32, character : Int32) : Nil
      editor.set_cursor(line, character)
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

    private def goto_definition : Nil
      goto_lsp_location("definition") do |client, context|
        client.goto_definition(context[:uri], context[:line], context[:character])
      end
    end

    private def goto_declaration : Nil
      goto_lsp_location("declaration") do |client, context|
        client.declaration(context[:uri], context[:line], context[:character])
      end
    end

    private def goto_type_definition : Nil
      goto_lsp_location("type definition") do |client, context|
        client.type_definition(context[:uri], context[:line], context[:character])
      end
    end

    private def goto_implementation : Nil
      goto_lsp_location("implementation") do |client, context|
        client.implementation(context[:uri], context[:line], context[:character])
      end
    end

    private def goto_lsp_location(
      label : String,
      &block : (Lsp::Client, NamedTuple(uri: String, line: Int32, character: Int32) -> Array(Lsp::Location))
    ) : Nil
      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active editor position for #{label}")
        return
      end

      client = @lsp
      if client.nil?
        @status_log.warning("LSP is not connected")
        return
      end

      locations = block.call(client, context)
      if locations.empty?
        @status_log.warning("No #{label} found")
        return
      end

      @navigation_forward_history.clear

      @navigation_history << NavigationLocation.new(context[:uri], context[:line], context[:character])
      prune_navigation_history

      location = locations.first
      uri_to_path(location.uri).try do |path|
        if !open_file(path, location.line, location.character)
          @navigation_history.pop?
          @status_log.error("Failed to jump to #{path}")
        else
          @status_log.success("Jump to #{path.basename}:#{location.line + 1}:#{location.character + 1}")
        end
      end
    end

    private def show_hover_hint : Nil
      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active editor")
        return
      end

      client = @lsp
      if client.nil?
        @status_log.warning("LSP is not connected")
        return
      end

      hover = client.hover(context[:uri], context[:line], context[:character])
      if hover.nil?
        @status_log.warning("No hover information")
        close_lsp_popup
        return
      end

      open_lsp_popup("Hover", wrap_lines(hover.text), 14)
    end

    private def show_references_hint : Nil
      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active editor")
        return
      end

      client = @lsp
      if client.nil?
        @status_log.warning("LSP is not connected")
        return
      end

      references = client.references(context[:uri], context[:line], context[:character])
      if references.empty?
        @status_log.warning("No references")
        close_lsp_popup
        return
      end

      lines = references.map_with_index do |location, index|
        if path = uri_to_path(location.uri)
          filename = path.to_s
          "#{index + 1}. #{filename}:#{location.line + 1}:#{location.character + 1}"
        else
          "#{index + 1}. #{location.uri}:#{location.line + 1}:#{location.character + 1}"
        end
      end

      open_lsp_popup("References", lines, 18)
    end

    private def show_signature_hint : Nil
      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active editor")
        return
      end

      client = @lsp
      if client.nil?
        @status_log.warning("LSP is not connected")
        return
      end

      signature = client.signature_help(context[:uri], context[:line], context[:character])
      if signature.nil? || signature.signatures.empty?
        @status_log.warning("No signature help")
        close_lsp_popup
        return
      end

      lines = signature.signatures.each_with_index.to_a.map do |signature_text, index|
        marker = index == signature.active_signature ? "▶" : " "
        "#{marker} #{signature_text}"
      end
      open_lsp_popup("Signature", lines, 14)
    end

    private def show_completion_hint : Nil
      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active editor")
        return
      end

      client = @lsp
      if client.nil?
        @status_log.warning("LSP is not connected")
        return
      end

      completions = client.completion(context[:uri], context[:line], context[:character])
      if completions.empty?
        @status_log.warning("No completion items")
        close_lsp_popup
        return
      end

      lines = completions.each_with_index.to_a.map do |item, index|
        detail = item.detail ? " - #{item.detail}" : ""
        "#{index + 1}. #{item.label}#{detail}"
      end
      open_lsp_popup("Completion", lines, 20)
    end

    private def show_diagnostics_hint : Nil
      buffer = current_buffer
      editor = current_editor
      if buffer.nil? || editor.nil?
        @status_log.warning("No active editor")
        return
      end

      diagnostics = buffer.diagnostics.select do |diagnostic|
        diagnostic.line == editor.cursor_line
      end
      if diagnostics.empty?
        @status_log.info("No diagnostics on current line")
        close_lsp_popup
        return
      end

      lines = diagnostics.map do |diagnostic|
        source = diagnostic.source ? " [#{diagnostic.source}]" : ""
        "ln #{diagnostic.line + 1}:#{diagnostic.character + 1}#{source} #{diagnostic.message}"
      end
      open_lsp_popup("Diagnostics", lines, 12)
    end

    private def execute_code_action_hint : Nil
      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active editor")
        return
      end

      client = @lsp
      if client.nil?
        @status_log.warning("LSP is not connected")
        return
      end

      actions = client.code_action(context[:uri], context[:line], context[:character])
      if actions.empty?
        @status_log.warning("No code actions")
        close_lsp_popup
        return
      end

      lines = actions.each_with_index.to_a.map do |action, index|
        title = action["title"]?.try(&.as_s) || "action #{index + 1}"
        "#{index + 1}. #{title}"
      end
      open_lsp_popup("Code actions", lines, 18)
    end

    private def current_lsp_context : NamedTuple(uri: String, line: Int32, character: Int32)?
      buffer = current_buffer
      editor = current_editor
      return nil if buffer.nil? || editor.nil?
      {uri: buffer.uri, line: editor.cursor_line, character: editor.cursor_col}
    end

    private def jump_back : Nil
      if @navigation_history.empty?
        @status_log.warning("No navigation history")
        return
      end

      current = current_lsp_context
      if current
        @navigation_forward_history << NavigationLocation.new(current[:uri], current[:line], current[:character])
      end

      last = @navigation_history.pop
      uri_to_path(last.uri).try do |path|
        if !open_file(path, last.line, last.character)
          @navigation_forward_history.pop?
          @status_log.error("Failed to restore #{path}")
        end
      end

      prune_navigation_forward_history
    end

    private def jump_forward : Nil
      if @navigation_forward_history.empty?
        @status_log.warning("No navigation forward history")
        return
      end

      current = current_lsp_context
      if current
        @navigation_history << NavigationLocation.new(current[:uri], current[:line], current[:character])
      end

      next_location = @navigation_forward_history.pop
      uri_to_path(next_location.uri).try do |path|
        if !open_file(path, next_location.line, next_location.character)
          @navigation_history.pop?
          @status_log.error("Failed to restore #{path}")
        end
      end

      prune_navigation_history
      prune_navigation_forward_history
    end

    private def prune_navigation_forward_history : Nil
      return if @navigation_forward_history.size <= @navigation_history_limit
      overflow = @navigation_forward_history.size - @navigation_history_limit
      overflow.times { @navigation_forward_history.shift }
    end

    private def prune_navigation_history : Nil
      return if @navigation_history.size <= @navigation_history_limit
      overflow = @navigation_history.size - @navigation_history_limit
      overflow.times { @navigation_history.shift }
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

    private def build_lsp_context_menu_actions : Array(LspContextAction)
      return [] of LspContextAction unless @lsp

      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active cursor for LSP actions")
        return [] of LspContextAction
      end

      _ = context # explicit capture to avoid unused variable warnings on older compilers
      [
        LspContextAction.new("Go to definition", key_hint("lsp.menu_definition"), -> { goto_definition }),
        LspContextAction.new("Go to declaration", key_hint("lsp.menu_declaration"), -> { goto_declaration }),
        LspContextAction.new("Go to type definition", key_hint("lsp.menu_type_definition"), -> { goto_type_definition }),
        LspContextAction.new("Go to implementation", key_hint("lsp.menu_implementation"), -> { goto_implementation }),
        LspContextAction.new("Show hover", key_hint("lsp.menu_hover"), -> { show_hover_hint }),
        LspContextAction.new("Show references", key_hint("lsp.menu_references"), -> { show_references_hint }),
        LspContextAction.new("Show signature", key_hint("lsp.menu_signature"), -> { show_signature_hint }),
        LspContextAction.new("Show completion", key_hint("lsp.menu_completion"), -> { show_completion_hint }),
        LspContextAction.new("Show diagnostics", key_hint("lsp.menu_diagnostics"), -> { show_diagnostics_hint }),
        LspContextAction.new("Code actions", key_hint("lsp.menu_code_actions"), -> { execute_code_action_hint }),
      ]
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

    private def uri_to_path(uri : String) : Path?
      return unless uri.starts_with?("file://")
      raw_path = uri[7..]
      begin
        Path.new(raw_path.gsub("%20", " "))
      rescue
        nil
      end
    end

    private def current_editor : Tui::TextEditor?
      if active = @editor_tabs.active_tab_id
        @open_buffers[active]?.try(&.editor)
      end
    end

    private def current_buffer : OpenBuffer?
      if active = @editor_tabs.active_tab_id
        @open_buffers[active]?
      end
    end

    private def open_file(path : Path, cursor_line : Int32? = nil, cursor_character : Int32? = nil) : Bool
      path_str = path.to_s
      return false unless File.file?(path.to_s)

      if existing = @open_buffers[path_str]?
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
      @open_buffers[path_str] = buffer

      editor.on_change do
        if local_buffer = @open_buffers[path_str]?
          local_buffer.version += 1
          rename_tab(local_buffer)
          sync_lsp_change(local_buffer)
          update_header
        end
      end

      editor.on_save do |saved_path|
        if local_buffer = @open_buffers[path_str]?
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

    private def lsp_diagnostic_style(diagnostics : Array(Lsp::Diagnostic), line : Int32, col : Int32, base_style : Tui::Style) : Tui::Style
      selected : Lsp::Diagnostic? = nil
      selected_rank = 99
      diagnostics.each do |diagnostic|
        next unless diagnostic_in_range?(diagnostic, line, col)
        rank = severity_rank(diagnostic.severity)
        if selected.nil? || rank < selected_rank
          selected = diagnostic
          selected_rank = rank
        end
      end

      return base_style unless selected

      Theme::Lsp.diagnostic_style(base_style, selected.severity)
    end

    private def severity_rank(severity : Int32?) : Int32
      case severity
      when 1 then 0
      when 2 then 1
      when 3 then 2
      when 4 then 3
      else        4
      end
    end

    private def diagnostic_in_range?(diagnostic : Lsp::Diagnostic, line : Int32, col : Int32) : Bool
      return false if line < diagnostic.line
      return false if line > diagnostic.end_line

      if diagnostic.line == diagnostic.end_line
        return col >= diagnostic.character && col < diagnostic.end_character
      end

      if line == diagnostic.line
        col >= diagnostic.character
      elsif line == diagnostic.end_line
        col < diagnostic.end_character
      else
        true
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
      if buffer = @open_buffers.delete(tab_id)
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

      update_header if @open_buffers.empty?
    end

    private def save_active : Nil
      if editor = current_editor
        editor.save
      else
        @status_log.warning("No active editor")
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

    private def show_lsp_status : Nil
      if @lsp
        @status_log.success("LSP connected")
      else
        @status_log.warning("LSP not connected")
      end
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

    private def connect_lsp_if_requested(command : String?, args : Array(String)) : Nil
      if command.nil? || command.empty?
        if resolved = resolve_default_lsp_command
          connect_lsp(resolved, [] of String)
        else
          @status_log.warning("LSP disabled: pass --lsp COMMAND or set EDITOR_LSP / CRYSTAL_EDITOR_LSP")
          @status_log.warning("Hint: put your local LSP at ../crystal_lsp, ../crystal-lsp, ../crystal_v2_repo/bin/crystal_v2_lsp, or ../crystal")
        end
        return
      end

      connect_lsp(command, args)
    end

    private def resolve_default_lsp_command : String?
      env_command = ENV["EDITOR_LSP"]?
      return env_command if env_command && !env_command.empty?
      editor_env = ENV["CRYSTAL_EDITOR_LSP"]?
      return editor_env if editor_env && !editor_env.empty?

      base_dirs = [
        Path.new(Dir.current).parent,
        @project_root.parent,
      ].uniq

      base_dirs.each do |base_dir|
        ["crystal_lsp", "crystal-lsp", "crystal_v2_repo"].each do |dir_name|
          candidate_dir = base_dir / dir_name
          if command = resolve_local_lsp_command(candidate_dir)
            return command
          end
        end

        candidate_root = base_dir / "crystal"
        if command = resolve_local_lsp_command(candidate_root)
          return command
        end
      end

      nil
    end

    private def resolve_local_lsp_command(base_dir : Path) : String?
      return base_dir.to_s if local_executable?(base_dir.to_s)
      return unless File.directory?(base_dir.to_s)

      candidate_bins = [
        base_dir / "bin" / "crystalline",
        base_dir / "bin" / "crystal-lsp",
        base_dir / "crystalline",
        base_dir / "crystal-lsp",
        base_dir / "bin" / "crystal",
        base_dir / "crystal",
        base_dir / "bin" / "crystal_v2_lsp",
        base_dir / "crystal_v2_lsp",
        base_dir / "bin" / "lsp",
        base_dir / "bin" / "crystal-lsp-server",
        base_dir / "lsp",
        base_dir / "build" / "crystal",
      ]

      candidate_bins.each do |bin_path|
        if local_executable?(bin_path.to_s)
          return bin_path.to_s
        end
      end

      nil
    end

    private def local_executable?(path : String) : Bool
      info = File.info(path)
      info.file? && File::Info.executable?(path)
    rescue
      false
    end

    private def connect_lsp(command : String, args : Array(String)) : Nil
      @lsp = Lsp::Client.new(command, @project_root, args)
      @lsp.try do |client|
        client.on_diagnostics = ->(uri : String, diagnostics : Array(Lsp::Diagnostic)) {
          updated = false
          @open_buffers.each_value do |buffer|
            if buffer.uri == uri
              buffer.diagnostics = diagnostics
              updated = true
            end
          end
          if updated
            mark_dirty!
            wakeup
          end
        }
      end

      if @lsp.try(&.start)
        @status_log.success("LSP connected: #{command}")
      else
        @status_log.error("LSP failed: #{command}")
        @lsp = nil
      end
    end

    private def sync_lsp_open(buffer : OpenBuffer) : Nil
      return unless client = @lsp
      client.open_text_document(
        uri: buffer.uri,
        language_id: buffer.language_id || "plaintext",
        version: buffer.version,
        text: buffer.editor.text
      )
    end

    private def sync_lsp_change(buffer : OpenBuffer) : Nil
      @lsp.try do |client|
        client.text_change(
          uri: buffer.uri,
          version: buffer.version,
          text: buffer.editor.text
        )
      end
    end

    private def sync_lsp_save(buffer : OpenBuffer) : Nil
      @lsp.try(&.save_text_document(buffer.uri))
    end

    private def close_lsp_document(uri : String) : Nil
      @lsp.try(&.close_text_document(uri))
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
      "file://#{path.expand.to_s.gsub(" ", "%20")}".gsub("\\", "/")
    end
  end
end
