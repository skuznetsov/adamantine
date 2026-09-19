require "crystal_tui"

module Adamantine
  # Query/list modal for bounded, path-only project navigation.
  #
  # The controller owns one index and at most one worker fiber.  Keystrokes
  # replace `pending_query`; they never enqueue an unbounded chain of scans.
  module QuickOpenController
    QUICK_OPEN_MAX_RESULTS          = 100
    QUICK_OPEN_MAX_QUERY_CODEPOINTS = 256
    QUICK_OPEN_MAX_POPUP_WIDTH      =  90
    QUICK_OPEN_DEFAULT_POPUP_HEIGHT =  16

    private def quick_open_active? : Bool
      @quick_open.open && active_input_mode == InputModeController::InputMode::QuickOpen
    end

    private def handle_quick_open_input(event : Tui::KeyEvent) : Bool
      return true unless @quick_open.open

      if action_pressed?("app.menu_close", event) || event.key == Tui::Key::Escape
        close_quick_open
        return true
      end

      if action_pressed?("app.quick_open_up", event) || event.matches?("up")
        move_quick_open_selection(-1)
        mark_dirty!
        return true
      end

      if action_pressed?("app.quick_open_down", event) || event.matches?("down")
        move_quick_open_selection(1)
        mark_dirty!
        return true
      end

      if action_pressed?("app.menu_select", event) || event.matches?("enter") || event.matches?("return")
        accept_quick_open_selection
        return true
      end

      if event.matches?("backspace")
        unless @quick_open.query.empty?
          @quick_open.query = @quick_open.query[0...-1]
          on_quick_open_query_changed
        end
        return true
      end

      # A modified character is a modal command, not query text.  Keeping it
      # consumed is important: Ctrl+Shift+P must not open the command palette
      # underneath the quick opener.
      if event.modifiers.ctrl? || event.modifiers.alt? || event.modifiers.meta?
        return true
      end

      if char = event.char
        return true if char.ord < 32 || char.ord == 127
        append_quick_open_query(char.to_s)
        return true
      end

      # Space is represented as a named key by some terminals and has no
      # `char` payload.  It is still valid in a relative path query.
      if event.matches?("space")
        append_quick_open_query(" ")
        return true
      end

      # Every key belongs to the modal boundary, including keys with no
      # quick-open meaning.  In particular, never fall through to the editor.
      true
    end

    private def open_quick_open(initial_query : String = "") : Nil
      close_context_menu
      close_lsp_popup
      close_settings_dialog if @settings.open
      close_search_panel if @search.open
      close_command_palette if @command_palette.open

      close_quick_open if @quick_open.open

      query = initial_query
      if query.size > QUICK_OPEN_MAX_QUERY_CODEPOINTS
        @status_log.warning("Quick open query exceeds #{QUICK_OPEN_MAX_QUERY_CODEPOINTS} characters")
        return
      end

      with_input_mode_guard(InputModeController::InputMode::QuickOpen) do
        @quick_open.generation &+= 1_u64
        @quick_open.root = @project_root.expand
        @quick_open.query = query
        @quick_open.matches = [] of QuickOpenSearch::FilePathMatch
        @quick_open.selected_index = 0
        @quick_open.scroll = 0
        @quick_open.searching = true
        @quick_open.partial = false
        @quick_open.status = "Loading file paths..."
        @quick_open.index = nil
        @quick_open.pending_query = query
        @quick_open.cancellation = QuickOpenSearch::Cancellation.new

        previous_overlay = @quick_open.overlay
        @quick_open.overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) {
          render_quick_open(buffer, clip)
        }
        @quick_open.overlay = open_overlay(previous_overlay, @quick_open.overlay.not_nil!)
        @quick_open.open = true
        schedule_quick_open_worker
        mark_dirty!
      end
    end

    private def close_quick_open : Nil
      return unless @quick_open.open

      # Invalidate the publication identity before detaching the overlay.
      @quick_open.open = false
      @quick_open.generation &+= 1_u64
      cancel_quick_open_search
      close_overlay(@quick_open.overlay)
      @quick_open.overlay = nil
      exit_input_mode(InputModeController::InputMode::QuickOpen)
      @quick_open.query = ""
      @quick_open.matches = [] of QuickOpenSearch::FilePathMatch
      @quick_open.selected_index = 0
      @quick_open.scroll = 0
      @quick_open.searching = false
      @quick_open.partial = false
      @quick_open.status = ""
      @quick_open.root = nil
      @quick_open.index = nil
      @quick_open.pending_query = nil
      mark_dirty!
    end

    private def append_quick_open_query(value : String) : Nil
      return if value.empty?
      if @quick_open.query.size + value.size > QUICK_OPEN_MAX_QUERY_CODEPOINTS
        # Invalidate a pass that may currently be ranking the previous query;
        # otherwise it could publish after the limit warning and replace the
        # explicit rejection with a stale result.
        @quick_open.generation &+= 1_u64
        @quick_open.cancellation.try(&.cancel)
        @quick_open.cancellation = QuickOpenSearch::Cancellation.new
        @quick_open.pending_query = nil
        @quick_open.index = nil
        @quick_open.matches = [] of QuickOpenSearch::FilePathMatch
        @quick_open.searching = false
        @quick_open.partial = false
        @quick_open.status = "Query too long (max #{QUICK_OPEN_MAX_QUERY_CODEPOINTS} characters)"
        mark_dirty!
        return
      end

      @quick_open.query += value
      on_quick_open_query_changed
    end

    private def on_quick_open_query_changed : Nil
      @quick_open.matches = [] of QuickOpenSearch::FilePathMatch
      @quick_open.selected_index = 0
      @quick_open.scroll = 0
      @quick_open.searching = true
      @quick_open.partial = false
      @quick_open.status = "Searching..."
      # Replacing, rather than appending, is the latest-query queue contract.
      @quick_open.pending_query = @quick_open.query
      schedule_quick_open_worker
      mark_dirty!
    end

    private def move_quick_open_selection(delta : Int32) : Nil
      count = @quick_open.matches.size
      return if count == 0

      index = @quick_open.selected_index + delta
      index = count - 1 if index < 0
      index = 0 if index >= count
      @quick_open.selected_index = index
      ensure_quick_open_selection_visible
    end

    private def ensure_quick_open_selection_visible(visible_rows : Int32 = 1) : Nil
      count = @quick_open.matches.size
      return if count == 0

      visible = [visible_rows, 1].max
      @quick_open.selected_index = @quick_open.selected_index.clamp(0, count - 1)
      if @quick_open.selected_index < @quick_open.scroll
        @quick_open.scroll = @quick_open.selected_index
      elsif @quick_open.selected_index >= @quick_open.scroll + visible
        @quick_open.scroll = @quick_open.selected_index - visible + 1
      end
      @quick_open.scroll = @quick_open.scroll.clamp(0, [count - visible, 0].max)
    end

    private def accept_quick_open_selection : Nil
      return unless @quick_open.open

      match = @quick_open.matches[@quick_open.selected_index]?
      unless match
        if @quick_open.searching
          @quick_open.status = "Still loading file paths..."
        else
          @quick_open.status = @quick_open.partial ? "No matching files (partial)" : "No matching files"
        end
        @status_log.warning(@quick_open.status) unless @quick_open.searching
        mark_dirty!
        return
      end

      root = @quick_open.root
      generation = @quick_open.generation
      query = @quick_open.query
      unless root && quick_open_identity_current?(root.not_nil!, generation, query)
        @quick_open.status = "Quick open result is stale"
        mark_dirty!
        return
      end

      # open_file owns the normal duplicate/unsaved/binary/oversized and
      # guarded commit lifecycle.  Keeping the popup open until it returns
      # lets failures display an error without losing the query/results.
      guard = -> { quick_open_identity_current?(root.not_nil!, generation, query) }
      opened = begin
        open_file(match.entry.path, guard: guard)
      rescue ex
        @quick_open.status = "Open failed: #{quick_open_display_excerpt(ex.message || ex.class.to_s)}"
        mark_dirty!
        false
      end

      if opened
        close_quick_open
      else
        @quick_open.status = "Could not open #{quick_open_display_excerpt(match.entry.relative_path)}"
        mark_dirty!
      end
    end

    private def quick_open_identity_current?(root : Path, generation : UInt64, query : String) : Bool
      @quick_open.open &&
        active_input_mode == InputModeController::InputMode::QuickOpen &&
        @quick_open.generation == generation &&
        @quick_open.root == root &&
        @project_root.expand == root &&
        @quick_open.query == query
    end

    private def schedule_quick_open_worker : Nil
      return unless @quick_open.open
      return if @quick_open.worker_active
      return if @quick_open.pending_query.nil?

      @quick_open.worker_active = true
      generation = @quick_open.generation
      root = @quick_open.root
      cancellation = @quick_open.cancellation
      unless root && cancellation
        # No fiber was spawned, so do not strand the ownership bit.  The
        # normal close/reopen path keeps it set until the old fiber reaches
        # `ensure`; this branch is only the pre-spawn failure case.
        @quick_open.worker_active = false
        @quick_open.searching = false
        @quick_open.status = "Quick open unavailable"
        mark_dirty!
        return
      end

      spawn(name: "quick-open") do
        begin
          loop do
            # Check the captured identity before reading or clearing mutable
            # pending state.  A close/reopen can otherwise let an old fiber
            # steal the new modal's first query.
            break unless quick_open_worker_current?(root.not_nil!, generation, cancellation.not_nil!)
            query = @quick_open.pending_query
            break unless query
            @quick_open.pending_query = nil
            break if cancellation.not_nil!.cancelled?

            index = @quick_open.index
            unless index
              index = QuickOpenSearch.index_file_paths(
                root.not_nil!,
                generation: generation,
                cancellation: cancellation
              )
              break if cancellation.not_nil!.cancelled?
              break unless quick_open_worker_current?(root.not_nil!, generation, cancellation.not_nil!)
              @quick_open.index = index
              @quick_open.partial = index.partial
            end

            result = QuickOpenSearch.rank_file_paths(
              index.not_nil!,
              query,
              generation: generation,
              max_results: QUICK_OPEN_MAX_RESULTS,
              cancellation: cancellation
            )
            break if result.cancelled || cancellation.not_nil!.cancelled?

            # A query may have changed while this bounded ranking pass ran.
            # Publish only if every captured identity still agrees, then let
            # the loop consume the one replaceable pending query.
            if quick_open_worker_current?(root.not_nil!, generation, cancellation.not_nil!) && @quick_open.query == query
              @quick_open.matches = result.matches
              @quick_open.partial = index.partial || result.partial
              @quick_open.selected_index = 0 if @quick_open.matches.empty? || @quick_open.selected_index >= @quick_open.matches.size
              @quick_open.scroll = 0 if @quick_open.matches.empty?
              @quick_open.searching = false
              @quick_open.status = quick_open_result_status(result)
              ensure_quick_open_selection_visible
              mark_dirty!
              wakeup
            end
          end
        rescue ex
          if quick_open_worker_current?(root.not_nil!, generation, cancellation.not_nil!)
            @quick_open.searching = false
            @quick_open.partial = true
            @quick_open.status = "Quick open failed: #{quick_open_display_excerpt(ex.message || ex.class.to_s)}"
            mark_dirty!
            wakeup
          end
        ensure
          # There is only one owner by construction.  Clear ownership only
          # after this fiber has unwound, then let a reopened/current modal
          # schedule its replaceable pending query.
          @quick_open.worker_active = false
          wakeup
          schedule_quick_open_worker if @quick_open.open && !@quick_open.pending_query.nil?
        end
      end
    end

    private def quick_open_worker_current?(root : Path, generation : UInt64, cancellation : QuickOpenSearch::Cancellation) : Bool
      @quick_open.open &&
        @quick_open.generation == generation &&
        @quick_open.root == root &&
        @project_root.expand == root &&
        @quick_open.cancellation.same?(cancellation)
    end

    private def quick_open_result_status(result : QuickOpenSearch::FilePathResult) : String
      if result.matches.empty?
        result.partial || @quick_open.partial ? "No matches (partial)" : "No matches"
      elsif result.partial || @quick_open.partial
        "#{result.matches.size} matches (partial)"
      else
        "#{result.matches.size} matches"
      end
    end

    private def cancel_quick_open_search : Nil
      @quick_open.cancellation.try(&.cancel)
      @quick_open.cancellation = nil
      @quick_open.pending_query = nil
      @quick_open.searching = false
    end

    private def quick_open_root_changed : Nil
      return unless @quick_open.open

      close_quick_open
    end

    private def render_quick_open(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless @quick_open.open

      return if clip.width <= 2 || clip.height <= 2
      width = [[clip.width - 2, 2].max, QUICK_OPEN_MAX_POPUP_WIDTH].min
      height = [QUICK_OPEN_DEFAULT_POPUP_HEIGHT, [clip.height, 1].max].min
      return if width < 2 || height < 2

      editor = current_editor
      base = editor ? editor.rect : @body_split.rect
      x = (base.x + (base.width - width) // 2).clamp(clip.x, [clip.right - width, clip.x].max)
      y = (base.y + 1).clamp(clip.y, [clip.bottom - height, clip.y].max)

      border = Tui::Style.new(fg: Theme::Popup.border, bg: Theme::Popup.active_bg)
      normal = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      active = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)

      draw_box_border(buffer, clip, x, y, width, height, border, normal, "Quick Open", title_style)
      inner_width = [width - 2, 1].max
      draw_text_line(buffer, clip, x + 1, y + 1, "> #{quick_open_sanitize_display(@quick_open.query)}", active, inner_width)

      list_top = y + 2
      list_bottom = y + height - 3
      visible_rows = [list_bottom - list_top + 1, 1].max
      ensure_quick_open_selection_visible(visible_rows)

      if @quick_open.matches.empty?
        draw_text_line(buffer, clip, x + 1, list_top, quick_open_status_text, normal, inner_width)
      else
        @quick_open.matches[@quick_open.scroll, visible_rows].try do |rows|
          rows.each_with_index do |match, index|
            row = list_top + index
            break if row > list_bottom
            style = (@quick_open.scroll + index == @quick_open.selected_index) ? active : normal
            draw_text_line(buffer, clip, x + 1, row, quick_open_match_label(match), style, inner_width)
          end
        end
      end

      status_y = y + height - 2
      draw_text_line(buffer, clip, x + 1, status_y, quick_open_status_text, normal, inner_width)
    end

    private def quick_open_status_text : String
      return "Loading file paths..." if @quick_open.searching && @quick_open.matches.empty?
      return @quick_open.status unless @quick_open.status.empty?
      return "No matches" if @quick_open.matches.empty?
      "#{@quick_open.matches.size} matches"
    end

    private def quick_open_match_label(match : QuickOpenSearch::FilePathMatch) : String
      quick_open_sanitize_display(match.entry.relative_path)
    end

    private def quick_open_display_excerpt(value : String, max_codepoints : Int32 = 120) : String
      sanitized = quick_open_sanitize_display(value)
      return sanitized if sanitized.size <= max_codepoints
      "#{sanitized[0, max_codepoints]}…"
    end

    private def quick_open_sanitize_display(value : String) : String
      String.build do |builder|
        value.each_char do |char|
          codepoint = char.ord
          builder << ((codepoint < 0x20 || (0x7f..0x9f).includes?(codepoint)) ? ' ' : char)
        end
      end
    end
  end
end
