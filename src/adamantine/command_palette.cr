require "crystal_tui"

require "../adamantine/replace_utils"

module Adamantine
  module CommandPalette
    COMMAND_PALETTE_DOUBLE_ESCAPE_MS = 320
    COMMAND_PALETTE_DEFAULT_HEIGHT   =  14

    private def handle_command_palette_input(event : Tui::KeyEvent) : Bool
      printable = false
      if char = event.char
        printable = char.ord >= 32
      end

      # Printable remapped menu keys are text while the palette has focus.
      # Escape, Enter, and the physical arrows remain modal controls.
      if event.key == Tui::Key::Escape || (!printable && action_pressed?("app.menu_close", event))
        close_command_palette
        return true
      end

      if !printable && (action_pressed?("app.menu_select", event) || event.matches?("enter") || event.matches?("return"))
        if @command_palette.mode.discovery?
          execute_selected_command_palette_entry
        else
          unless command_palette_prepared_argument_pending?
            begin
              execute_command(@command_palette.input)
            rescue ex
              close_command_palette
              raise ex
            end
          end
        end
        return true
      end

      if !printable && (event.matches?("alt+up") || event.matches?("alt+down"))
        event.matches?("alt+up") ? command_palette_history_prev : command_palette_history_next
        return true
      end

      if !printable && (event.matches?("up") || action_pressed?("app.menu_up", event))
        if @command_palette.mode.discovery?
          move_command_palette_selection(-1)
        else
          command_palette_history_prev
        end
        return true
      end

      if !printable && (event.matches?("down") || action_pressed?("app.menu_down", event))
        if @command_palette.mode.discovery?
          move_command_palette_selection(1)
        else
          command_palette_history_next
        end
        return true
      end

      if event.matches?("tab")
        command_palette_complete
        return true
      end

      if event.matches?("backspace")
        if @command_palette.mode.discovery?
          unless @command_palette.input.empty?
            @command_palette.input = @command_palette.input[0...-1]
            @command_palette.selected_index = 0
            @command_palette.scroll = 0
            update_command_palette_candidates
            mark_dirty!
          end
        elsif @command_palette.input.size > 1
          @command_palette.input = @command_palette.input[0...-1]
          @command_palette.selected_index = 0
          @command_palette.scroll = 0
          update_command_palette_candidates
          mark_dirty!
        else
          close_command_palette
        end
        return true
      end

      if char = event.char
        return true if char.ord < 32

        @command_palette.input = @command_palette.input + char.to_s
        if @command_palette.mode.discovery? && @command_palette.input.size == 1 && command_palette_prefix?(char)
          @command_palette.mode = CommandPaletteState::Mode::Raw
          @command_palette.argument_hint = ""
        end
        @command_palette.selected_index = 0
        @command_palette.scroll = 0
        @command_palette.history_index = -1
        update_command_palette_candidates
        mark_dirty!
        return true
      end

      true
    end

    private def command_palette_double_escape?(event : Tui::KeyEvent) : Bool
      return false unless event.key == Tui::Key::Escape

      now = Time.utc.to_unix_ms
      last = @command_palette.last_escape_ms
      @command_palette.last_escape_ms = now

      return false if last == 0
      (now - last) <= COMMAND_PALETTE_DOUBLE_ESCAPE_MS
    end

    private def open_command_palette(initial_input : String = ":") : Nil
      close_context_menu
      close_lsp_popup
      close_settings_dialog if @settings.open
      close_search_panel if @search.open

      return if @command_palette.open

      with_input_mode_guard(InputModeController::InputMode::CommandPalette) do
        @command_palette.history_index = -1
        @command_palette.input = normalize_command_palette_input(initial_input)
        @command_palette.mode = command_palette_mode_for(@command_palette.input)
        @command_palette.selected_index = 0
        @command_palette.scroll = 0
        @command_palette.argument_hint = ""
        @command_palette.prepared_action = nil
        update_command_palette_candidates
        previous_overlay = @command_palette.overlay
        @command_palette.overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_command_palette(buffer, clip)
        }
        @command_palette.overlay = open_overlay(previous_overlay, @command_palette.overlay.not_nil!)
        @command_palette.open = true
        mark_dirty!
      end
    end

    private def normalize_command_palette_input(raw_input : String) : String
      raw_input
    end

    private def command_palette_mode_for(input : String) : CommandPaletteState::Mode
      if input.empty?
        CommandPaletteState::Mode::Discovery
      elsif command_palette_prefix?(input[0])
        CommandPaletteState::Mode::Raw
      else
        CommandPaletteState::Mode::Discovery
      end
    end

    private def command_palette_prefix?(char : Char) : Bool
      char == ':' || char == '/' || char == '?'
    end

    private def close_command_palette : Nil
      return unless @command_palette.open

      close_overlay(@command_palette.overlay)

      @command_palette.overlay = nil
      set_command_palette_inactive_mode
      @command_palette.open = false
      @command_palette.input = ":"
      @command_palette.mode = CommandPaletteState::Mode::Raw
      @command_palette.candidates = [] of CommandEntry
      @command_palette.selected_index = 0
      @command_palette.scroll = 0
      @command_palette.argument_hint = ""
      @command_palette.prepared_action = nil
      @command_palette.history_index = -1
      mark_dirty!
    end

    private def command_palette_complete : Nil
      return if @command_palette.candidates.empty?

      if @command_palette.mode.discovery?
        entry = @command_palette.candidates[@command_palette.selected_index]?
        return unless entry
        prepare_command_palette_entry(entry)
        return
      end

      first = @command_palette.candidates[0]
      suggestion = first.aliases.first?
      return unless suggestion

      text = clean_command_text(@command_palette.input)
      parsed = parse_command_parts(text)
      return if parsed.size > 1

      @command_palette.input = ":#{suggestion} "
      @command_palette.argument_hint = first.requires_argument? ? first.argument_hint : ""
      @command_palette.prepared_action = first.requires_argument? ? first.action : nil
      @command_palette.history_index = -1
      update_command_palette_candidates
      mark_dirty!
    end

    private def execute_selected_command_palette_entry : Nil
      entry = @command_palette.candidates[@command_palette.selected_index]?
      return unless entry

      if entry.requires_argument?
        prepare_command_palette_entry(entry)
        return
      end

      execute_command(":#{entry.action}")
    end

    private def command_palette_prepared_argument_pending? : Bool
      return false unless @command_palette.mode.raw?
      prepared_action = @command_palette.prepared_action
      return false if prepared_action.nil?
      hint = @command_palette.argument_hint
      return false if hint.empty?

      entry = command_palette_entries.find { |candidate| candidate.action == prepared_action }
      return false unless entry && entry.requires_argument? && entry.argument_hint == hint

      parts = parse_command_parts(clean_command_text(@command_palette.input))
      return false unless parts.size <= 1
      command = parts.first?
      return false if command.nil? || command.empty?

      ([entry.action] + entry.aliases).any? { |alias_name| alias_name.downcase == command.downcase }
    end

    private def prepare_command_palette_entry(entry : CommandEntry) : Nil
      @command_palette.mode = CommandPaletteState::Mode::Raw
      @command_palette.input = ":#{entry.action}"
      @command_palette.argument_hint = entry.argument_hint
      @command_palette.prepared_action = entry.action
      @command_palette.input += " " if entry.requires_argument?
      @command_palette.selected_index = 0
      @command_palette.scroll = 0
      @command_palette.history_index = -1
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
        executed = execute_search_command_repeat(@search.forward)
      elsif raw_command == "N"
        executed = execute_search_command_repeat(!@search.forward)
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
                   when "external"
                     open_external_review
                     true
                   when "q", "close"
                     close_active_tab
                     true
                   when "quit", "exit", "qa"
                     quit
                     true
                   when "q!"
                     quit(true)
                     true
                   when "wq", "wx", "writequit"
                     if save_active
                       quit
                       true
                     else
                       false
                     end
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
                     case argument_text.strip.downcase
                     when ""
                       show_lsp_status
                     when "restart"
                       restart_lsp
                     else
                       @status_log.warning("Usage: :lsp [restart]")
                     end
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
                   when "undo"
                     undo_active
                     true
                   when "redo"
                     redo_active
                     true
                   when "settings"
                     open_settings_dialog
                     true
                   when "format"
                     format_document
                     true
                   when "rename"
                     rename_document(argument_text)
                   when "quickfix", "quick-fix", "qf"
                     quick_fix_document
                     true
                   when "git"
                     open_git_view
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
                     if argument_text.strip.empty?
                       open_search_panel(SearchState::Scope::ThisFile)
                       true
                     else
                       execute_search_command("/#{argument_text}")
                     end
                   when "grep", "rg"
                     execute_project_search(argument_text)
                   when "recover"
                     open_recovery_menu
                     true
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
        previous = @search.query
        if previous.empty?
          @status_log.warning("No previous search pattern")
          return false
        end
        query = previous
      else
        @search.query = query
      end

      if current_editor.nil?
        @status_log.warning("No active editor")
        return false
      end

      direction = raw_command[0] == '/'
      open_search_panel(SearchState::Scope::ThisFile, query, jump: true, forward: direction)
      true
    end

    private def execute_search_command_repeat(forward : Bool) : Bool
      query = @search.query
      if query.empty?
        @status_log.warning("No previous search pattern")
        return false
      end

      search_in_active_editor(query, forward)
    end

    private def execute_project_search(raw : String) : Bool
      ignore_case = false
      needle = raw.strip
      if needle == "-i" || needle.starts_with?("-i ")
        ignore_case = true
        needle = needle[2..].strip
      end

      open_search_panel(SearchState::Scope::Project, needle.empty? ? nil : needle, ignore_case: ignore_case)
      true
    end

    private def search_in_active_editor(query : String, forward : Bool) : Bool
      schedule_repeat_search(query, forward)
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
      text = clean_command_text(@command_palette.input)
      return "" if text.empty?
      tokens = parse_command_parts(text)
      return "" if tokens.empty?
      tokens[0]
    end

    private def update_command_palette_candidates : Nil
      if @command_palette.mode.discovery?
        query = @command_palette.input.strip
        if query.empty?
          @command_palette.candidates = command_palette_entries.dup
        else
          @command_palette.candidates = command_palette_entries
            .select { |entry| !command_palette_discovery_match_score(query, entry).nil? }
            .sort_by { |entry| command_palette_discovery_match_score(query, entry) || Int32::MAX }
        end
      else
        token = command_prefix_token
        if token.empty?
          @command_palette.candidates = command_palette_entries.dup
        else
          lower = token.downcase
          @command_palette.candidates = command_palette_entries.select do |entry|
            entry.aliases.any? { |alias_name| alias_name.starts_with?(lower) }
          end
        end
      end

      @command_palette.selected_index = 0 if @command_palette.candidates.empty?
      if !@command_palette.candidates.empty? && @command_palette.selected_index >= @command_palette.candidates.size
        @command_palette.selected_index = @command_palette.candidates.size - 1
      end
      command_palette_ensure_selection_visible
    end

    private def command_palette_discovery_match_score(query : String, entry : CommandEntry) : Int32?
      fields = [entry.title, entry.action] + entry.aliases
      normalized_fields = fields.map(&.downcase)
      description = entry.description.downcase
      score = 0
      query.downcase.split(/\s+/).each do |token|
        return nil if token.empty?

        if normalized_fields.any? { |field| field == token }
          score += 0
        elsif normalized_fields.any? { |field| field.starts_with?(token) }
          score += 1
        elsif normalized_fields.any? { |field| field.includes?(token) }
          score += 2
        elsif description.includes?(token)
          score += 3
        else
          return nil
        end
      end
      score
    end

    private def move_command_palette_selection(delta : Int32) : Nil
      count = @command_palette.candidates.size
      return if count == 0

      selected = @command_palette.selected_index + delta
      selected = count - 1 if selected < 0
      selected = 0 if selected >= count
      @command_palette.selected_index = selected
      command_palette_ensure_selection_visible
      mark_dirty!
    end

    private def command_palette_visible_rows(height : Int32 = COMMAND_PALETTE_DEFAULT_HEIGHT) : Int32
      [height - 5, 1].max
    end

    private def command_palette_ensure_selection_visible(height : Int32 = COMMAND_PALETTE_DEFAULT_HEIGHT) : Nil
      rows = command_palette_visible_rows(height)
      return if rows <= 0

      max_scroll = [@command_palette.candidates.size - rows, 0].max
      @command_palette.scroll = @command_palette.scroll.clamp(0, max_scroll)
      if @command_palette.selected_index < @command_palette.scroll
        @command_palette.scroll = @command_palette.selected_index
      elsif @command_palette.selected_index >= @command_palette.scroll + rows
        @command_palette.scroll = @command_palette.selected_index - rows + 1
      end
      @command_palette.scroll = @command_palette.scroll.clamp(0, max_scroll)
    end

    private def remember_command(command_text : String) : Nil
      command = clean_command_text(command_text)
      return if command.empty?
      history = @command_palette.history
      if !history.empty? && history[-1] == command
        return
      end
      history << command
      history.shift if history.size > 200
    end

    private def command_palette_history_prev : Nil
      return if @command_palette.history.empty?
      if @command_palette.history_index < 0
        @command_palette.history_index = @command_palette.history.size - 1
      elsif @command_palette.history_index > 0
        @command_palette.history_index -= 1
      end

      if @command_palette.history_index >= 0
        @command_palette.input = ":" + @command_palette.history[@command_palette.history_index]
        @command_palette.mode = CommandPaletteState::Mode::Raw
        @command_palette.argument_hint = ""
        @command_palette.prepared_action = nil
        update_command_palette_candidates
        mark_dirty!
      end
    end

    private def command_palette_history_next : Nil
      return if @command_palette.history.empty?
      if @command_palette.history_index < 0
        @command_palette.input = ":"
        @command_palette.mode = CommandPaletteState::Mode::Raw
        @command_palette.argument_hint = ""
        @command_palette.prepared_action = nil
        update_command_palette_candidates
        mark_dirty!
        return
      end

      if @command_palette.history_index < @command_palette.history.size - 1
        @command_palette.history_index += 1
        @command_palette.input = ":" + @command_palette.history[@command_palette.history_index]
      else
        @command_palette.history_index = -1
        @command_palette.input = ":"
      end

      @command_palette.mode = CommandPaletteState::Mode::Raw
      @command_palette.argument_hint = ""
      @command_palette.prepared_action = nil
      update_command_palette_candidates
      mark_dirty!
    end

    private def command_palette_shortcut(entry : CommandEntry) : String
      action = entry.shortcut_action
      return "unbound" if action.empty?

      if keys = @key_bindings[action]?
        return "unbound" if keys.empty?
        return keys.join(" / ")
      end
      "unbound"
    end

    private def apply_theme_command(theme_name : String) : Nil
      name = theme_name.strip
      if name.empty?
        @status_log.info("Theme command: use ':theme <name>' or ':themes'")
        list_theme_presets
        return
      end

      if Theme.load(name)
        @theme_path = name
        apply_theme
        @status_log.success("Theme applied: #{Theme.name}")
      else
        if reason = Theme.load_error
          @status_log.warning("Theme not found: #{name}; #{reason}")
        else
          @status_log.warning("Theme not found: #{name}")
        end
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

      normalized = begin
        resolve_command_path(path_value)
      rescue ex
        @status_log.warning("Invalid path: #{ex.message}")
        return
      end
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
      resolve_path_within_project_root(candidate)
    end

    private def resolve_project_root_path(value : String) : Path
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
      candidate.absolute? ? candidate.expand : (@project_root / candidate).expand
    end

    private def resolve_path_within_project_root(candidate : Path) : Path
      resolved = Path.new(candidate.absolute? ? candidate.expand : (@project_root / candidate).expand)
      root_real = File.realpath(@project_root.to_s) rescue @project_root.expand.to_s
      normalized_root = root_real.ends_with?(File::SEPARATOR) ? root_real : "#{root_real}#{File::SEPARATOR}"

      if File.exists?(resolved.to_s)
        real_candidate = File.realpath(resolved.to_s)
        return Path.new(real_candidate) if real_candidate == root_real || real_candidate.starts_with?(normalized_root)
        raise "path escapes project root (#{@project_root})"
      end

      if max_existing = deepest_existing_ancestor(resolved)
        ancestor_real = File.realpath(max_existing.to_s)
        suffix = residual_path_suffix(resolved.to_s, max_existing.to_s)
        candidate_real = Path.new(ancestor_real, suffix).to_s
        unless candidate_real == root_real || candidate_real.starts_with?(normalized_root)
          raise "path escapes project root (#{@project_root})"
        end
        return Path.new(candidate_real)
      end

      raise "path escapes project root (#{@project_root})"
    end

    private def deepest_existing_ancestor(path : Path) : Path?
      current = path
      while true
        return current if File.exists?(current.to_s)
        parent = current.parent
        return nil if parent == current
        current = parent
      end
    end

    private def residual_path_suffix(target : String, ancestor : String) : String
      return "" if target == ancestor
      return "" unless target.starts_with?(ancestor)
      suffix = target[ancestor.size..-1]? || ""
      suffix.lstrip(File::SEPARATOR)
    end

    private def list_open_buffers : Nil
      if @document_session.open_buffers.empty?
        @status_log.info("No open buffers")
        return
      end

      opened = @document_session.open_buffers.each_value.to_a.sort_by do |buffer|
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

      matching = @document_session.open_buffers.select do |path_str, _|
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
      entries = @document_session.open_buffers.keys.sort
      return @status_log.warning("No buffer at index #{index + 1}") if index < 0 || index >= entries.size
      switch_to_tab_by_position_buffer(entries[index])
    end

    private def switch_to_tab_by_position_buffer(path_str : String) : Nil
      @document_orchestrator.switch_to_tab_by_position_buffer(path_str)
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

      resolved = begin
        resolve_project_root_path(path_value)
      rescue ex
        @status_log.warning("Invalid path: #{ex.message}")
        return
      end
      if !File.directory?(resolved.to_s)
        @status_log.warning("Not a directory: #{resolved}")
        return
      end

      previous_root = @project_root
      save_session_state(previous_root)
      quick_open_root_changed
      close_git_view
      cancel_project_search
      @project_root = resolved
      lsp_project_root_changed
      @file_panel.path = resolved
      refresh_file_tree
      restore_session_state(@project_root)
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

      @document_session.command_marks[name] = CommandMark.new(context[:uri], context[:line], context[:character])
      @status_log.success("Marked #{name} at #{context[:uri]}:#{context[:line] + 1}:#{context[:character] + 1}")
    end

    private def list_marks : Nil
      if @document_session.command_marks.empty?
        @status_log.info("No marks")
        return
      end

      @status_log.info("Marks:")
      @document_session.command_marks.each do |name, location|
        @status_log.info("  #{name}: #{location.uri}:#{location.line + 1}:#{location.character + 1}")
      end
    end

    private def jump_to_mark(argument_text : String) : Nil
      target = argument_text.strip
      if target.empty?
        @status_log.warning("Usage: :jump <name>")
        return
      end

      mark = @document_session.command_marks[target]?
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

      editor = buffer.editor.as?(EditingTextEditor)
      unless editor
        @status_log.warning("Active buffer does not support bounded replacement")
        return
      end

      if flags.preview
        begin
          preview = editor.replace_previews(old_text, new_text, flags)
        rescue ex : ArgumentError | IndexError | Regex::Error
          @status_log.warning("Replace refused: #{replace_status_excerpt(ex.message || "invalid arguments")}")
          return
        end

        if preview.empty?
          @status_log.info("No matches for '#{replace_status_excerpt(old_text)}'")
          return
        end

        @status_log.info("Replace preview #{ReplaceUtils.flags_to_label(flags)} for '#{replace_status_excerpt(old_text)}' => '#{replace_status_excerpt(new_text)}'")
        preview.each_with_index do |line, index|
          @status_log.info("  #{index + 1}. #{line}")
        end
        return
      end

      begin
        replaced = editor.replace_literal(old_text, new_text, flags)
      rescue ex : ArgumentError | IndexError | Regex::Error
        @status_log.warning("Replace refused: #{replace_status_excerpt(ex.message || "invalid arguments")}")
        return
      end

      unless replaced
        @status_log.info("No matches for '#{replace_status_excerpt(old_text)}'")
        return
      end
      mark_dirty! if @command_palette.open
      @status_log.success("Replaced #{flags.global ? "all" : "first"} occurrence#{flags.ignore_case ? " (ignore case)" : ""} of '#{replace_status_excerpt(old_text)}' with '#{replace_status_excerpt(new_text)}'")
    end

    private def replace_status_excerpt(value : String, max_codepoints : Int32 = 80) : String
      return value if value.size <= max_codepoints

      "#{value[0, max_codepoints]}…"
    end

    private def render_command_palette(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless @command_palette.open
      return if clip.width < 2 || clip.height < 2

      width = [[clip.width - 2, 4].max, 90].min
      width = [width, clip.width].min
      height = [[COMMAND_PALETTE_DEFAULT_HEIGHT, clip.height].min, 2].max
      x = (clip.x + (clip.width - width) // 2).clamp(clip.x, [clip.right - width, clip.x].max)
      y = (clip.y + 1).clamp(clip.y, [clip.bottom - height, clip.y].max)
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

      title = @command_palette.mode.discovery? ? " Actions " : " Command "
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
      input_area = [width - 6, 0].max
      input_value = @command_palette.input
      show_argument_hint = command_palette_prepared_argument_pending?
      if show_argument_hint
        input_value += "#{input_value.empty? ? "" : " "}#{@command_palette.argument_hint}"
      end
      draw_text_line(buffer, clip, input_x + 2, input_y, input_value, popup_bg, input_area)

      list_start = y + 3
      list_width = [width - 4, 0].max
      list_rows = [height - 5, 0].max
      command_palette_ensure_selection_visible(height)
      if list_rows > 0 && list_width > 0 && !@command_palette.candidates.empty?
        start = @command_palette.scroll.clamp(0, [@command_palette.candidates.size - list_rows, 0].max)
        @command_palette.candidates[start, list_rows].each_with_index do |entry, index|
          absolute_index = start + index
          y_pos = list_start + index
          row_style = absolute_index == @command_palette.selected_index ? popup_active : popup_bg
          shortcut = command_palette_shortcut(entry)
          command = entry.aliases.first? || entry.action
          line = "#{absolute_index == @command_palette.selected_index ? ">" : " "} #{entry.title} (#{command}) [#{shortcut}] - #{entry.description}"
          draw_text_line(buffer, clip, x + 2, y_pos, line, row_style, list_width)
        end
      elsif list_rows > 0 && list_width > 0
        line = "  No matching actions"
        draw_text_line(buffer, clip, x + 2, list_start, line, popup_bg, list_width)
      end

      hint = if @command_palette.mode.discovery?
               "[Enter] run | [Tab] prepare | ↑/↓ select | Esc close"
             else
               "[Enter] run | Esc close | ↑/↓ history | Tab complete"
             end
      hint_y = y + height - 2
      draw_text_line(buffer, clip, x + 1, hint_y, hint, popup_border, [width - 2, 0].max)

      bottom = y + height - 1
      buffer.set(x, bottom, '└', popup_border) if clip.contains?(x, bottom)
      (1...width - 1).each do |dx|
        buffer.set(x + dx, bottom, '─', popup_border) if clip.contains?(x + dx, bottom)
      end
      buffer.set(x + width - 1, bottom, '┘', popup_border) if clip.contains?(x + width - 1, bottom)
    end
  end
end
