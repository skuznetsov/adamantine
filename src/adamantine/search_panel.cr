require "crystal_tui"

require "./buffer_search"

module Adamantine
  module SearchPanel
    FILE_MATCH_CAP          = 200
    FILE_SEARCH_SYNC_BYTES  = 64 * 1024
    PROJECT_PANEL_WIDTH_MIN = 36
    PROJECT_PANEL_WIDTH_MAX = 56
    FILE_PANEL_WIDTH        = 44
    FILE_PANEL_HEIGHT       =  4
    PROJECT_PANEL_HEIGHT    = 16
    PROJECT_SEARCH_DEBOUNCE = 60.milliseconds

    # A request keeps only the identity and scalar state needed to validate a
    # result.  The persistent buffer source is captured by the worker only
    # after the debounce has elapsed, so each superseded keystroke does not
    # retain another document root.
    class BufferSearchRequest
      enum Kind
        Live
        Repeat
      end

      getter kind : Kind
      getter buffer_identity : UInt64
      getter editor_identity : UInt64
      getter path : Path
      getter version : Int32
      getter query : String
      getter ignore_case : Bool
      getter cursor_line : Int32
      getter cursor_col : Int32
      getter forward : Bool
      getter generation : UInt64
      getter ready_at : Time::Instant
      getter previous : ProjectSearch::Match?
      property cancelled : Bool = false

      def initialize(
        @kind : Kind,
        @buffer_identity : UInt64,
        @editor_identity : UInt64,
        @path : Path,
        @version : Int32,
        @query : String,
        @ignore_case : Bool,
        @cursor_line : Int32,
        @cursor_col : Int32,
        @forward : Bool,
        @generation : UInt64,
        @ready_at : Time::Instant,
        @previous : ProjectSearch::Match?,
      )
      end

      def live? : Bool
        @kind.live?
      end

      def repeat? : Bool
        @kind.repeat?
      end

      def cancel : Nil
        @cancelled = true
      end
    end

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

      @search.focus = SearchState::Focus::Query
      return true if handle_editable_input_key(
                       @search.query_input,
                       event,
                       -> { on_search_query_changed }
                     )

      false
    end

    private def open_search_panel(scope : SearchState::Scope, query : String? = nil, *, ignore_case : Bool? = nil, jump : Bool = false, forward : Bool = true) : Nil
      close_context_menu
      close_lsp_popup
      close_settings_dialog if @settings.open
      close_command_palette if @command_palette.open
      @clipboard_paste_generation &+= 1_u64

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
      @clipboard_paste_generation &+= 1_u64

      cancel_project_search
      cancel_buffer_search

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
      before = @search.query_input.revision
      @search.query_input.insert(char.to_s)
      on_search_query_changed if @search.query_input.revision != before
    end

    private def delete_search_query_char(behind : Bool) : Nil
      @search.focus = SearchState::Focus::Query
      before = @search.query_input.revision
      behind ? @search.query_input.delete_backward : @search.query_input.delete_forward
      on_search_query_changed if @search.query_input.revision != before
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
      cancel_project_search
      cancel_buffer_search

      if query.empty?
        clear_search_matches
        return
      end

      case @search.scope
      when SearchState::Scope::ThisFile
        refresh_buffer_search(query, previous)
      when SearchState::Scope::Project
        start_project_search(query, previous)
        return
      end

      restore_search_selection(previous)
    end

    private def refresh_buffer_search(query : String, previous : ProjectSearch::Match?) : Nil
      editor = current_editor
      buffer = current_buffer
      editing_editor = editor.try(&.as?(EditingTextEditor))
      unless editor && buffer && editing_editor
        clear_search_matches
        @search.searching = false
        return
      end

      path = editor.not_nil!.path || Path.new("")
      cursor_line = editor.not_nil!.cursor_line
      cursor_col = editor.not_nil!.cursor_col
      request = BufferSearchRequest.new(
        BufferSearchRequest::Kind::Live,
        buffer.not_nil!.object_id,
        editor.not_nil!.object_id,
        path,
        buffer.not_nil!.version,
        query,
        @search.ignore_case,
        cursor_line,
        cursor_col,
        @search.forward,
        @buffer_search_generation,
        Time.instant + PROJECT_SEARCH_DEBOUNCE,
        previous
      )

      clear_search_matches
      if editing_editor.not_nil!.search_byte_length <= FILE_SEARCH_SYNC_BYTES
        source = search_source_for(editing_editor)
        result = BufferSearch.scan(
          source,
          query,
          ignore_case: request.ignore_case,
          path: request.path,
          max_matches: FILE_MATCH_CAP
        )
        unless result.cancelled?
          @search.matches = result.matches
          @search.truncated = result.truncated?
          @search.searching = false
          restore_search_selection(previous)
        end
        return
      end

      @search.searching = true
      enqueue_buffer_search(request)
    rescue ex
      report_buffer_search_error(request, ex) if request
    end

    protected def search_source_for(editor : EditingTextEditor) : BufferSearch::Source
      editor.search_source
    end

    private def start_project_search(query : String, previous : ProjectSearch::Match?) : Nil
      root = @project_root
      ignore_case = @search.ignore_case
      generation = @search.generation
      cancellation = ProjectSearch::Cancellation.new

      clear_search_matches
      @search.searching = true
      @project_search_cancellation = cancellation

      spawn(name: "project-search") do
        sleep PROJECT_SEARCH_DEBOUNCE
        next if cancellation.cancelled?

        result = ProjectSearch.search(root, query, ignore_case: ignore_case, cancellation: cancellation)
        next if result.cancelled? || cancellation.cancelled?
        next unless current_project_search?(cancellation, generation, root, query, ignore_case)

        @project_search_cancellation = nil
        @search.searching = false
        @search.matches = result.matches
        @search.truncated = result.truncated
        restore_search_selection(previous)
        mark_dirty!
      rescue ex
        next unless current_project_search?(cancellation, generation, root, query, ignore_case)

        @project_search_cancellation = nil
        @search.searching = false
        @status_log.warning("Project search failed: #{ex.message}")
        mark_dirty!
      end
    end

    private def current_project_search?(cancellation : ProjectSearch::Cancellation, generation : UInt64, root : Path, query : String, ignore_case : Bool) : Bool
      @project_search_cancellation.same?(cancellation) &&
        @search.generation == generation &&
        @search.open &&
        @search.scope.project? &&
        @search.query == query &&
        @search.ignore_case == ignore_case &&
        @project_root == root
    end

    # Repeats share the same bounded worker as live queries.  This keeps the
    # scheduler at one running request plus one replaceable pending request,
    # regardless of how quickly the user types or repeats a search.
    private def enqueue_buffer_search(request : BufferSearchRequest) : Nil
      @buffer_search_pending.try(&.cancel)
      @buffer_search_pending = request
      schedule_buffer_search_worker
    end

    private def schedule_buffer_search_worker : Nil
      return if @buffer_search_worker_active

      @buffer_search_worker_active = true
      spawn(name: "buffer-search") do
        begin
          loop do
            request = @buffer_search_pending
            break unless request

            wait = request.ready_at - Time.instant
            sleep wait if wait > Time::Span.zero
            next unless @buffer_search_pending.same?(request)

            @buffer_search_pending = nil
            run_buffer_search(request)
          end
        ensure
          @buffer_search_worker_active = false
          mark_dirty!
          wakeup
          schedule_buffer_search_worker unless @buffer_search_pending.nil?
        end
      end
    end

    private def run_buffer_search(request : BufferSearchRequest) : Nil
      return unless current_buffer_search?(request, check_cursor: true)

      editor = current_editor
      editing_editor = editor.try(&.as?(EditingTextEditor))
      return unless editor && editing_editor
      return unless current_buffer_search?(request, check_cursor: true)

      @buffer_search_running = request
      source = search_source_for(editing_editor)
      checkpoint = -> do
        current_buffer_search?(request, check_cursor: true)
      end

      if request.live?
        result = BufferSearch.scan(
          source,
          request.query,
          ignore_case: request.ignore_case,
          path: request.path,
          max_matches: FILE_MATCH_CAP,
          checkpoint: checkpoint
        )
        publish_buffer_scan(request, result)
      else
        result = BufferSearch.find_next(
          source,
          request.query,
          request.cursor_line,
          request.cursor_col,
          forward: request.forward,
          ignore_case: request.ignore_case,
          path: request.path,
          checkpoint: checkpoint
        )
        publish_buffer_repeat(request, result)
      end
    rescue ex
      report_buffer_search_error(request, ex)
    ensure
      @buffer_search_running = nil if @buffer_search_running.same?(request)
      # A request can become stale during debounce, before it owns `running`.
      # Release its loading state too, but never that of a newer generation.
      if @buffer_search_pending.nil? && @buffer_search_generation == request.generation
        if @search.searching && request.live? && @search.open && @search.scope.this_file?
          # A cursor/version guard rejected the scan, not the query. An empty
          # unpublished result must not become an exhaustive "No matches".
          clear_search_matches
          @search.truncated = true
        end
        @search.searching = false
      end
    end

    private def report_buffer_search_error(request : BufferSearchRequest, error : Exception) : Nil
      return unless current_buffer_search?(request, check_cursor: false)

      @search.searching = false
      if request.live?
        clear_search_matches
        @search.truncated = true
      end
      @status_log.warning("In-file search failed: #{error.message || error.class}")
      mark_dirty!
      wakeup
    end

    private def current_buffer_search?(request : BufferSearchRequest, *, check_cursor : Bool) : Bool
      return false if request.cancelled
      return false unless @buffer_search_generation == request.generation

      buffer = current_buffer
      editor = current_editor
      return false unless buffer && editor
      return false unless buffer.object_id == request.buffer_identity
      return false unless editor.object_id == request.editor_identity
      return false unless buffer.version == request.version
      return false unless @search.query == request.query
      return false unless @search.ignore_case == request.ignore_case
      if request.live?
        return false unless @search.open && @search.scope.this_file?
      end
      return false if check_cursor && (editor.cursor_line != request.cursor_line || editor.cursor_col != request.cursor_col)
      true
    end

    private def publish_buffer_scan(request : BufferSearchRequest, result : BufferSearch::ScanResult) : Nil
      return if result.cancelled?
      return unless current_buffer_search?(request, check_cursor: true)

      @search.matches = result.matches
      @search.truncated = result.truncated?
      @search.searching = false
      restore_search_selection(request.previous)
      select_match_near_cursor(@search.forward)
      jump_to_selected_match unless @search.matches.empty?
      mark_dirty!
      wakeup
    end

    private def publish_buffer_repeat(request : BufferSearchRequest, result : BufferSearch::RepeatResult) : Nil
      return if result.cancelled?
      return unless current_buffer_search?(request, check_cursor: true)

      @search.searching = false
      if match = result.match
        editor = current_editor
        unless editor
          return
        end
        end_col = match.end_col || match.col + request.query.size
        editor.select_range(match.line, match.col, match.line, end_col, cursor_at_end: false)
        @status_log.success("Search #{request.forward ? "/" : "?"}#{request.query.inspect}#{result.wrapped? ? " (wrapped)" : ""} -> #{match.line + 1}:#{match.col + 1}")
      else
        @status_log.warning("No matches for #{request.query.inspect}")
      end
      mark_dirty!
      wakeup
    end

    # Command-palette n/N repeats use the same source and worker, but are not
    # limited by the live panel's 200-result list.  A large-buffer repeat is
    # accepted immediately and reports its result only after the bounded
    # cooperative scan completes.
    private def schedule_repeat_search(query : String, forward : Bool) : Bool
      editor = current_editor
      buffer = current_buffer
      editing_editor = editor.try(&.as?(EditingTextEditor))
      unless editor && buffer && editing_editor
        @status_log.warning("No active editor")
        return false
      end

      cancel_project_search
      cancel_buffer_search

      path = editor.not_nil!.path || Path.new("")
      request = BufferSearchRequest.new(
        BufferSearchRequest::Kind::Repeat,
        buffer.not_nil!.object_id,
        editor.not_nil!.object_id,
        path,
        buffer.not_nil!.version,
        query,
        @search.ignore_case,
        editor.not_nil!.cursor_line,
        editor.not_nil!.cursor_col,
        forward,
        @buffer_search_generation,
        Time.instant,
        nil
      )

      if editing_editor.not_nil!.search_byte_length <= FILE_SEARCH_SYNC_BYTES
        source = search_source_for(editing_editor)
        result = BufferSearch.find_next(
          source,
          query,
          request.cursor_line,
          request.cursor_col,
          forward: forward,
          ignore_case: request.ignore_case,
          path: request.path
        )
        publish_buffer_repeat(request, result)
        return true
      end

      @search.searching = true
      enqueue_buffer_search(request)
      mark_dirty!
      wakeup
      true
    rescue ex
      report_buffer_search_error(request, ex) if request
      true
    end

    private def cancel_buffer_search : Nil
      had_request = @buffer_search_pending.try { |request| !request.cancelled } || @buffer_search_running.try { |request| !request.cancelled }
      @buffer_search_pending.try(&.cancel)
      @buffer_search_running.try(&.cancel)
      @buffer_search_pending = nil
      if had_request
        @buffer_search_generation &+= 1_u64
        @search.searching = false
      end
    end

    private def cancel_repeat_search_on_input : Nil
      pending_repeat = @buffer_search_pending.try(&.repeat?)
      running_repeat = @buffer_search_running.try(&.repeat?)
      cancel_buffer_search if pending_repeat || running_repeat
    end

    private def search_buffer_changed(buffer : OpenBuffer) : Nil
      request = @buffer_search_running || @buffer_search_pending
      if @search.open && @search.scope.this_file? && !@search.query.empty? && current_buffer.try(&.same?(buffer))
        refresh_search_matches
      elsif request && request.buffer_identity == buffer.object_id
        cancel_buffer_search
      end
    end

    private def search_tab_switched : Nil
      had_live_panel = @search.open && @search.scope.this_file? && !@search.query.empty?
      cancel_buffer_search
      return unless had_live_panel

      refresh_search_matches
      mark_dirty!
    end

    private def search_tab_closed(tab_id : String) : Nil
      request = @buffer_search_running || @buffer_search_pending
      return unless request
      return unless request.path.to_s == tab_id

      cancel_buffer_search
    end

    private def cancel_search_workers : Nil
      cancel_project_search
      cancel_buffer_search
    end

    private def cancel_project_search : Nil
      @project_search_cancellation.try(&.cancel)
      @project_search_cancellation = nil
      @search.generation &+= 1_u64
      @search.searching = false
    end

    private def clear_search_matches : Nil
      @search.matches = [] of ProjectSearch::Match
      @search.truncated = false
      @search.selected_index = 0
      @search.scroll = 0
    end

    private def restore_search_selection(previous : ProjectSearch::Match?) : Nil
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
        return if @search.searching
        unless @search.query.empty?
          if @search.truncated
            @status_log.warning("Partial search; no matches confirmed for #{@search.query.inspect}")
          else
            @status_log.warning("No matches for #{@search.query.inspect}")
          end
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

      end_col = match.end_col || match.col + @search.query.size
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
      EditableInputRenderer.render(
        buffer,
        Tui::Rect.new(panel_x + 1, query_y, inner_width, 1),
        @search.query_input,
        normal,
        cursor_style,
        cursor_style,
        clip,
      )

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
          draw_text_line(buffer, clip, panel_x + 1, list_top, search_panel_empty_message, normal, inner_width)
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
      count = if @search.searching
                " ..."
              elsif @search.matches.empty?
                @search.query.empty? ? "" : " 0#{search_result_incomplete_marker}"
              elsif @search.scope.this_file?
                " #{@search.selected_index + 1}/#{@search.matches.size}#{search_result_incomplete_marker}"
              else
                " #{@search.matches.size}#{search_result_incomplete_marker}"
              end
      case_mark = @search.ignore_case ? "  aa" : "  Aa"
      scope_name = @search.scope.this_file? ? "Find" : "Search"
      "#{scope_name}#{count}#{case_mark}"
    end

    private def search_result_incomplete_marker : String
      @search.truncated ? " (partial)" : ""
    end

    private def search_panel_empty_message : String
      return "Type to search the project" if @search.query.empty?
      return "Searching..." if @search.searching
      return "No matches (partial)" if @search.truncated

      "No matches"
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

    private def draw_search_query_line(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      x : Int32,
      y : Int32,
      width : Int32,
      style : Tui::Style,
      cursor_style : Tui::Style,
    ) : Nil
      EditableInputRenderer.render(
        buffer,
        Tui::Rect.new(x, y, width, 1),
        @search.query_input,
        style,
        cursor_style,
        cursor_style,
        clip,
      )
    end
  end
end
