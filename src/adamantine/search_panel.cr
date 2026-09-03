require "crystal_tui"

module Adamantine
  module SearchPanel
    FILE_MATCH_CAP          = 200
    PROJECT_PANEL_WIDTH_MIN =  36
    PROJECT_PANEL_WIDTH_MAX =  56
    FILE_PANEL_WIDTH        =  44
    FILE_PANEL_HEIGHT       =   4
    PROJECT_PANEL_HEIGHT    =  16

    private def handle_search_panel_input(event : Tui::KeyEvent) : Bool
      return false unless @search.open

      if action_pressed?("app.menu_close", event) || event.key == Tui::Key::Escape
        close_search_panel
        return true
      end

      if action_pressed?("app.find", event)
        open_search_panel(SearchState::Scope::ThisFile)
        return true
      end

      if action_pressed?("app.find_in_project", event)
        open_search_panel(SearchState::Scope::Project)
        return true
      end

      if event.matches?("shift+tab")
        @search.ignore_case = !@search.ignore_case
        on_search_query_changed
        return true
      end

      if event.matches?("tab")
        next_scope = @search.scope.this_file? ? SearchState::Scope::Project : SearchState::Scope::ThisFile
        open_search_panel(next_scope)
        return true
      end

      if event.matches?("shift+enter") || event.matches?("shift+return")
        move_search_selection(-1)
        jump_to_selected_match
        return true
      end

      if event.matches?("enter") || event.matches?("return") || action_pressed?("app.menu_select", event)
        if @search.scope.this_file?
          move_search_selection(1)
        else
          @search.focus = SearchState::Focus::Results
        end
        jump_to_selected_match
        return true
      end

      if event.matches?("up")
        handle_search_vertical(-1)
        return true
      end

      if event.matches?("down")
        handle_search_vertical(1)
        return true
      end

      if event.matches?("pageup")
        move_search_selection(-search_results_window)
        jump_to_selected_match if @search.scope.this_file?
        return true
      end

      if event.matches?("pagedown")
        move_search_selection(search_results_window)
        jump_to_selected_match if @search.scope.this_file?
        return true
      end

      if event.matches?("left")
        @search.focus = SearchState::Focus::Query
        @search.query_cursor = [@search.query_cursor - 1, 0].max
        mark_dirty!
        return true
      end

      if event.matches?("right")
        @search.focus = SearchState::Focus::Query
        @search.query_cursor = [@search.query_cursor + 1, @search.query.size].min
        mark_dirty!
        return true
      end

      if event.matches?("home")
        @search.focus = SearchState::Focus::Query
        @search.query_cursor = 0
        mark_dirty!
        return true
      end

      if event.matches?("end")
        @search.focus = SearchState::Focus::Query
        @search.query_cursor = @search.query.size
        mark_dirty!
        return true
      end

      if event.matches?("backspace")
        delete_search_query_char(behind: true)
        return true
      end

      if event.matches?("delete")
        delete_search_query_char(behind: false)
        return true
      end

      if char = event.char
        return false if char.ord < 32
        insert_search_query_char(char)
        return true
      end

      false
    end

    private def open_search_panel(scope : SearchState::Scope, query : String? = nil, *, ignore_case : Bool? = nil, jump : Bool = false, forward : Bool = true) : Nil
      close_context_menu
      close_lsp_popup
      close_settings_dialog if @settings.open
      close_command_palette if @command_palette.open

      @search.scope = scope
      @search.forward = forward
      @search.focus = SearchState::Focus::Query
      unless query.nil?
        @search.query = query
        @search.query_cursor = query.size
      end
      @search.ignore_case = ignore_case unless ignore_case.nil?

      if @search.open
        refresh_search_matches
        select_match_near_cursor(forward) if jump || scope.this_file?
        jump_to_selected_match if jump || (scope.this_file? && !@search.query.empty?)
        mark_dirty!
        return
      end

      with_input_mode_guard(InputModeController::InputMode::SearchPanel) do
        previous_overlay = @search.overlay
        @search.overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_search_panel(buffer, clip)
        }
        @search.overlay = open_overlay(previous_overlay, @search.overlay.not_nil!)
        @search.open = true
        refresh_search_matches
        select_match_near_cursor(forward) if jump || scope.this_file?
        jump_to_selected_match if jump || (scope.this_file? && !@search.query.empty?)
        mark_dirty!
      end
    end

    private def close_search_panel : Nil
      return unless @search.open

      if editor = current_editor
        editor.set_cursor(editor.cursor_line, editor.cursor_col)
      end

      close_modal(@search, InputModeController::InputMode::SearchPanel)
      @search.focus = SearchState::Focus::Query
      mark_dirty!
    end

    private def on_search_query_changed : Nil
      refresh_search_matches
      if @search.scope.this_file?
        select_match_near_cursor(@search.forward)
        jump_to_selected_match
      end
      mark_dirty!
    end

    private def insert_search_query_char(char : Char) : Nil
      @search.focus = SearchState::Focus::Query
      query = @search.query
      index = @search.query_cursor.clamp(0, query.size)
      @search.query = query[0, index] + char.to_s + query[index..]
      @search.query_cursor = index + 1
      on_search_query_changed
    end

    private def delete_search_query_char(behind : Bool) : Nil
      @search.focus = SearchState::Focus::Query
      query = @search.query
      index = @search.query_cursor.clamp(0, query.size)
      if behind
        return if index <= 0
        @search.query = query[0, index - 1] + query[index..]
        @search.query_cursor = index - 1
      else
        return if index >= query.size
        @search.query = query[0, index] + query[index + 1..]
      end
      on_search_query_changed
    end

    private def handle_search_vertical(delta : Int32) : Nil
      if @search.scope.project?
        if delta > 0 && @search.focus.query?
          @search.focus = SearchState::Focus::Results
          mark_dirty!
          return
        end
        if delta < 0 && @search.focus.results? && @search.selected_index == 0
          @search.focus = SearchState::Focus::Query
          mark_dirty!
          return
        end
        @search.focus = SearchState::Focus::Results
        move_search_selection(delta)
        return
      end

      move_search_selection(delta)
      jump_to_selected_match
    end

    private def move_search_selection(delta : Int32) : Nil
      return if @search.matches.empty?

      count = @search.matches.size
      @search.selected_index = (@search.selected_index + delta) % count
      @search.selected_index += count if @search.selected_index < 0
      ensure_search_scroll_visible
      mark_dirty!
    end

    private def search_results_window : Int32
      8
    end

    private def ensure_search_scroll_visible : Nil
      window = search_results_window
      return if window <= 0 || @search.matches.empty?

      if @search.selected_index < @search.scroll
        @search.scroll = @search.selected_index
      elsif @search.selected_index >= @search.scroll + window
        @search.scroll = @search.selected_index - window + 1
      end
      @search.scroll = @search.scroll.clamp(0, [@search.matches.size - 1, 0].max)
    end

    private def refresh_search_matches : Nil
      query = @search.query
      previous = @search.matches[@search.selected_index]?

      if query.empty?
        @search.matches = [] of ProjectSearch::Match
        @search.truncated = false
        @search.selected_index = 0
        @search.scroll = 0
        return
      end

      case @search.scope
      when SearchState::Scope::ThisFile
        if editor = current_editor
          path = editor.path || Path.new("")
          @search.matches = ProjectSearch.search_text(
            editor.text,
            query,
            ignore_case: @search.ignore_case,
            path: path,
            max_matches: FILE_MATCH_CAP
          )
          @search.truncated = @search.matches.size >= FILE_MATCH_CAP
        else
          @search.matches = [] of ProjectSearch::Match
          @search.truncated = false
        end
      when SearchState::Scope::Project
        result = ProjectSearch.search(@project_root, query, ignore_case: @search.ignore_case)
        @search.matches = result.matches
        @search.truncated = result.truncated
      end

      if previous
        found = @search.matches.index { |match| match.line == previous.line && match.col == previous.col && match.path == previous.path }
        @search.selected_index = found || 0
      else
        @search.selected_index = 0
      end

      unless @search.matches.empty?
        @search.selected_index = @search.selected_index.clamp(0, @search.matches.size - 1)
      else
        @search.selected_index = 0
      end
      ensure_search_scroll_visible
    end

    private def select_match_near_cursor(forward : Bool) : Nil
      return if @search.matches.empty?

      editor = current_editor
      unless editor
        @search.selected_index = forward ? 0 : @search.matches.size - 1
        return
      end

      line = editor.cursor_line
      col = editor.cursor_col
      index = if forward
                @search.matches.index { |match| match.line > line || (match.line == line && match.col >= col) }
              else
                @search.matches.rindex { |match| match.line < line || (match.line == line && match.col < col) }
              end
      @search.selected_index = index || (forward ? 0 : @search.matches.size - 1)
      ensure_search_scroll_visible
    end

    private def jump_to_selected_match : Nil
      match = @search.matches[@search.selected_index]?
      if match.nil?
        unless @search.query.empty?
          @status_log.warning("No matches for #{@search.query.inspect}")
        end
        return
      end

      if @search.scope.project?
        unless open_file(match.path, match.line, match.col)
          @status_log.warning("Failed to open search match #{match.path}")
          return
        end
      end

      editor = current_editor
      unless editor && editor.path == match.path
        @status_log.warning("Search results are stale for the active file")
        refresh_search_matches
        return
      end

      end_col = match.col + @search.query.size
      editor.select_range(match.line, match.col, match.line, end_col, cursor_at_end: false)
      mark_dirty!
    end

    private def render_search_panel(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      editor = current_editor
      base = editor ? editor.rect : @body_split.rect

      project = @search.scope.project?
      panel_width = if project
                      [PROJECT_PANEL_WIDTH_MAX, [PROJECT_PANEL_WIDTH_MIN, clip.width - 2].min].min
                    else
                      [FILE_PANEL_WIDTH, clip.width - 2].min
                    end
      panel_width = [panel_width, 24].max

      panel_height = if project
                       [PROJECT_PANEL_HEIGHT, clip.height - 2].min
                     else
                       FILE_PANEL_HEIGHT
                     end
      panel_height = [panel_height, 4].max

      panel_x = (base.x + base.width - panel_width - 1).clamp(clip.x, [clip.right - panel_width, clip.x].max)
      panel_y = (base.y + 1).clamp(clip.y, [clip.bottom - panel_height, clip.y].max)

      border = Tui::Style.new(fg: Theme::Popup.border, bg: Theme::Popup.active_bg)
      normal = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      active = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)
      cursor_style = Tui::Style.new(fg: Theme::Popup.active_bg, bg: Theme::Popup.title)

      draw_box_border(buffer, clip, panel_x, panel_y, panel_width, panel_height, border, normal, search_panel_title, title_style)

      inner_width = [panel_width - 2, 1].max
      query_y = panel_y + 1
      draw_search_query_line(buffer, clip, panel_x + 1, query_y, inner_width, normal, cursor_style)

      if project
        list_top = panel_y + 2
        list_bottom = panel_y + panel_height - 2
        window = [list_bottom - list_top, 1].max
        if @search.selected_index < @search.scroll
          @search.scroll = @search.selected_index
        elsif @search.selected_index >= @search.scroll + window
          @search.scroll = @search.selected_index - window + 1
        end
        max_scroll = [@search.matches.size - window, 0].max
        @search.scroll = @search.scroll.clamp(0, max_scroll)

        if @search.matches.empty?
          message = @search.query.empty? ? "Type to search the project" : "No matches"
          draw_text_line(buffer, clip, panel_x + 1, list_top, message, normal, inner_width)
        else
          @search.matches.each_with_index do |match, index|
            next if index < @search.scroll
            row = list_top + (index - @search.scroll)
            break if row >= list_bottom

            selected = index == @search.selected_index && @search.focus.results?
            style = selected ? active : normal
            draw_text_line(buffer, clip, panel_x + 1, row, search_match_label(match), style, inner_width)
          end
        end
      end

      hint_y = panel_y + panel_height - 2
      draw_text_line(buffer, clip, panel_x + 1, hint_y, search_panel_hint, normal, inner_width)
    end

    private def search_panel_title : String
      count = if @search.matches.empty?
                @search.query.empty? ? "" : " 0"
              elsif @search.scope.this_file?
                extra = @search.truncated ? "+" : ""
                " #{@search.selected_index + 1}/#{@search.matches.size}#{extra}"
              else
                extra = @search.truncated ? "+" : ""
                " #{@search.matches.size}#{extra}"
              end
      case_mark = @search.ignore_case ? "  aa" : "  Aa"
      scope_name = @search.scope.this_file? ? "Find" : "Search"
      "#{scope_name}#{count}#{case_mark}"
    end

    private def search_panel_hint : String
      if @search.scope.this_file?
        "Enter next  S-Enter prev  Tab project  Esc"
      else
        "Enter open  Tab file  S-Tab case  Esc"
      end
    end

    private def search_match_label(match : ProjectSearch::Match) : String
      rel = begin
        match.path.relative_to(@project_root).to_s
      rescue
        match.path.to_s
      end
      rel = match.path.basename.to_s if rel.empty?
      "#{rel}:#{match.line + 1}: #{match.snippet}"
    end

    private def draw_search_query_line(buffer : Tui::Buffer, clip : Tui::Rect, x : Int32, y : Int32, width : Int32, style : Tui::Style, cursor_style : Tui::Style) : Nil
      query = @search.query
      cursor = @search.query_cursor.clamp(0, query.size)
      return if width <= 0

      graphemes = [] of String
      widths = [] of Int32
      query.each_grapheme do |grapheme|
        glyph = grapheme.to_s
        graphemes << glyph
        widths << Tui::Unicode.grapheme_width(glyph)
      end

      cursor_grapheme = graphemes.size
      char_offset = 0
      graphemes.each_with_index do |glyph, index|
        next_offset = char_offset + glyph.size
        if cursor < next_offset
          cursor_grapheme = index
          break
        end
        char_offset = next_offset
      end

      available_before_cursor = [width - 1, 0].max
      start = cursor_grapheme
      cursor_offset = 0
      index = cursor_grapheme - 1
      while index >= 0
        glyph_width = widths[index]
        break if cursor_offset + glyph_width > available_before_cursor

        cursor_offset += glyph_width
        start = index
        index -= 1
      end

      visible = String.build do |builder|
        index = start
        while index < graphemes.size
          builder << graphemes[index]
          index += 1
        end
      end
      draw_text_line(buffer, clip, x, y, visible, style, width)

      cursor_x = x + cursor_offset
      return unless cursor_x < x + width && clip.contains?(cursor_x, y)

      if cursor_grapheme < graphemes.size && widths[cursor_grapheme] > 0 && cursor_x + widths[cursor_grapheme] <= x + width
        buffer.set(cursor_x, y, graphemes[cursor_grapheme], cursor_style)
      else
        buffer.set(cursor_x, y, ' ', cursor_style)
      end
    end
  end
end
