require "crystal_tui"

require "../editor/replace_utils"

module CrystalEditor
  module CommandPalette
    COMMAND_PALETTE_DOUBLE_ESCAPE_MS = 320

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

      with_input_mode_guard(InputModeController::InputMode::CommandPalette) do
        @command_history_index = -1
        @command_input = normalize_command_palette_input(initial_input)
        update_command_palette_candidates
        previous_overlay = @command_overlay
        @command_overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_command_palette(buffer, clip)
        }
        @command_overlay = open_overlay(previous_overlay, @command_overlay.not_nil!)
        @command_open = true
        mark_dirty!
      end
    end

    private def normalize_command_palette_input(raw_input : String) : String
      text = raw_input.empty? ? ":" : raw_input
      return text if text.starts_with?('/') || text.starts_with?('?') || text.starts_with?(':')
      ":#{text}"
    end

    private def close_command_palette : Nil
      return unless @command_open

      close_overlay(@command_overlay)

      @command_overlay = nil
      set_command_palette_inactive_mode
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
        @command_candidates = command_palette_entries.dup
      else
        lower = token.downcase
        @command_candidates = command_palette_entries.select do |entry|
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
  end
end
