require "crystal_tui"
require "./theme"

module Adamantine
  # Read-only projection of controller-owned debugger DTOs. This widget keeps
  # only bounded display text; it never performs protocol I/O or retains DAP
  # handles.
  class DebugPanel < Tui::Widget
    enum Pane
      Stack
      Threads
      Variables
      Watch
      Breakpoints
      Output
      Sources
    end

    MAX_SUMMARY_BYTES = 256
    MAX_ERROR_BYTES   = 512
    MAX_LINES         =  48
    MAX_LINE_BYTES    = 512
    MAX_TOTAL_BYTES   = 16 * 1024
    MAX_PAGE_LINES    = MAX_TOTAL_BYTES // MAX_LINE_BYTES

    getter summary : String
    getter error : String?
    @lines : Hash(Pane, Array(String)) = {} of Pane => Array(String)
    @stored_line_bytes = 0
    @row_counts : Hash(Pane, Int32) = {} of Pane => Int32
    @row_offsets : Hash(Pane, Int32) = {} of Pane => Int32
    @page_starts : Hash(Pane, Int32) = {} of Pane => Int32
    @selected_rows : Hash(Pane, Int32) = {} of Pane => Int32
    @selected_pane : Pane = Pane::Stack
    @on_viewport_request : Proc(Pane, Int32, Int32, Nil)? = nil
    @on_row_selected : Proc(Pane, Int32, Nil)? = nil
    @on_row_action : Proc(Pane, Int32, String, Bool)? = nil
    @on_hide : Proc(Nil)? = nil

    def initialize(id : String = "debug-panel")
      super(id)
      @summary = "No debug session"
      @error = nil
      @focusable = true
    end

    def selected_pane : Pane
      @selected_pane
    end

    def selected_pane=(pane : Pane) : Pane
      return pane if @selected_pane == pane
      @selected_pane = pane
      if @on_viewport_request
        clear_other_pages(pane)
        request_viewport(pane)
      end
      mark_dirty!
      pane
    end

    def summary=(value : String) : String
      @summary = bounded_display_text(value, MAX_SUMMARY_BYTES)
      mark_dirty!
      @summary
    end

    def error=(value : String?) : String?
      @error = value.try { |message| bounded_display_text(message, MAX_ERROR_BYTES) }
      refresh_viewport if @on_viewport_request
      mark_dirty!
      @error
    end

    def set_lines(pane : Pane, lines : Array(String)) : Nil
      if lines.size > MAX_PAGE_LINES
        raise ArgumentError.new("use paged viewport requests for lists with more than #{MAX_PAGE_LINES} rows")
      end
      set_page(pane, 0, lines.size, lines)
    end

    # Replace only the requested viewport slice. The controller/App keeps the
    # authoritative full collection and can provide another slice on scroll;
    # this widget never copies an unbounded frame, variable, or output list.
    def set_page(pane : Pane, start_row : Int32, total_rows : Int32, lines : Array(String)) : Nil
      raise ArgumentError.new("row offset cannot be negative") if start_row < 0
      raise ArgumentError.new("row count cannot be negative") if total_rows < 0
      raise ArgumentError.new("page exceeds #{MAX_PAGE_LINES} rows") if lines.size > MAX_PAGE_LINES

      offset = start_row.clamp(0, global_max_row_offset(total_rows))
      replace_page(pane, offset, total_rows, lines)
      clamp_selection_bounds(pane, total_rows)
      mark_dirty!
    end

    def on_viewport_request(&block : Pane, Int32, Int32 -> Nil) : Nil
      @on_viewport_request = block
      request_viewport(@selected_pane)
    end

    def total_rows(pane : Pane) : Int32
      @row_counts[pane]? || 0
    end

    def first_visible_row(pane : Pane) : Int32
      @row_offsets[pane]? || 0
    end

    def selected_row(pane : Pane = @selected_pane) : Int32
      @selected_rows[pane]? || 0
    end

    def clamp_selection(pane : Pane, total : Int32) : Nil
      next_row = clamp_selection_bounds(pane, total)
      offset = @row_offsets[pane]? || 0
      capacity = viewport_capacity
      if capacity > 0 && next_row < offset
        @row_offsets[pane] = next_row
      elsif capacity > 0 && next_row >= offset + capacity
        @row_offsets[pane] = next_row - capacity + 1
      end
    end

    private def clamp_selection_bounds(pane : Pane, total : Int32) : Int32
      current = selected_row(pane)
      next_row = total <= 0 ? 0 : current.clamp(0, total - 1)
      @selected_rows[pane] = next_row
      @on_row_selected.try(&.call(pane, next_row)) if current != next_row
      next_row
    end

    # Restore an ID-backed selection after an async tree rebuild without
    # treating the moved row as a new user action. The next viewport request
    # will fetch the adjusted slice if this pane is visible.
    def restore_selected_row(pane : Pane, index : Int32, total : Int32) : Nil
      @row_counts[pane] = total
      next_row = total <= 0 ? 0 : index.clamp(0, total - 1)
      @selected_rows[pane] = next_row
      capacity = viewport_capacity
      offset = @row_offsets[pane]? || 0
      if capacity > 0 && next_row < offset
        @row_offsets[pane] = next_row
      elsif capacity > 0 && next_row >= offset + capacity
        @row_offsets[pane] = next_row - capacity + 1
      end
      mark_dirty!
    end

    def on_row_selected(&block : Pane, Int32 -> Nil) : Nil
      @on_row_selected = block
    end

    def on_row_action(&block : Pane, Int32, String -> Bool) : Nil
      @on_row_action = block
    end

    def on_hide(&block : -> Nil) : Nil
      @on_hide = block
    end

    # Call after layout/resize changes. This requests exactly the current
    # visible slice, without asking the controller for protocol work.
    def refresh_viewport : Nil
      pane = @selected_pane
      total = @row_counts[pane]? || 0
      current = @row_offsets[pane]? || 0
      @row_offsets[pane] = current.clamp(0, global_max_row_offset(total))
      request_viewport(pane)
      mark_dirty!
    end

    def viewport_capacity : Int32
      [@rect.height - 2 - (@error ? 1 : 0), 0].max
    end

    # Move the selected pane's bounded viewport. A provider is called only
    # when the offset changes; it should synchronously map the requested slice
    # from the latest immutable controller snapshot and call set_page.
    def scroll_rows(delta : Int32) : Bool
      pane = @selected_pane
      capacity = viewport_capacity
      return false if capacity <= 0

      current = @row_offsets[pane]? || 0
      total = @row_counts[pane]? || 0
      max_offset = global_max_row_offset(total)
      proposed = (current.to_i64 + delta.to_i64).clamp(0_i64, max_offset.to_i64).to_i32
      return false if proposed == current

      if @on_viewport_request.nil?
        page_start = @page_starts[pane]? || 0
        page_end = page_start + (@lines[pane]? || [] of String).size
        max_cached_offset = {max_offset, {page_start, page_end - capacity}.max}.min
        proposed = proposed.clamp(page_start, max_cached_offset)
        return false if proposed == current
      end

      @row_offsets[pane] = proposed
      if callback = @on_viewport_request
        @lines[pane] = [] of String
        @page_starts[pane] = proposed
        callback.call(pane, proposed, [capacity, MAX_PAGE_LINES].min)
      end
      mark_dirty!
      true
    end

    def scroll_page(direction : Int32) : Bool
      return false if direction == 0
      scroll_rows(direction > 0 ? viewport_capacity : -viewport_capacity)
    end

    def scroll_to_start : Bool
      scroll_rows(-Int32::MAX)
    end

    def scroll_to_end : Bool
      scroll_rows(Int32::MAX)
    end

    def move_selection(delta : Int32) : Bool
      total = total_rows(@selected_pane)
      return false if total <= 0 || delta == 0
      current = selected_row
      proposed = (current.to_i64 + delta.to_i64).clamp(0_i64, (total - 1).to_i64).to_i32
      changed = move_to_row(proposed)
      return false unless changed
      mark_dirty!
      true
    end

    def activate_selected_row(action : String = "activate") : Bool
      callback = @on_row_action
      return false unless callback && total_rows(@selected_pane) > 0
      result = callback.call(@selected_pane, selected_row, action)
      mark_dirty!
      result
    end

    def lines_for(pane : Pane) : Array(String)
      (@lines[pane]? || [] of String).map(&.dup)
    end

    def on_event(event : Tui::Event) : Bool
      return false unless focused?
      case event
      when Tui::KeyEvent
        case
        when event.matches?("escape"), event.matches?("esc"), event.matches?("h")
          @on_hide.try(&.call)
        when event.matches?("up"), event.matches?("k")
          move_selection(-1)
        when event.matches?("down"), event.matches?("j")
          move_selection(1)
        when event.matches?("pageup")
          move_selection(-[viewport_capacity, 1].max)
        when event.matches?("pagedown")
          move_selection([viewport_capacity, 1].max)
        when event.matches?("home")
          move_selection(-Int32::MAX)
        when event.matches?("end")
          move_selection(Int32::MAX)
        when event.matches?("enter"), event.matches?("return")
          activate_selected_row
        when event.matches?("tab"), event.matches?("shift+tab")
          select_adjacent_pane(event.modifiers.shift? ? -1 : 1)
        when event.matches?("o")
          activate_selected_row("show")
        when event.matches?("d")
          activate_selected_row("detail")
        when event.matches?("x")
          activate_selected_row("next-format")
        when event.matches?("z")
          activate_selected_row("local-json")
        when event.matches?("e")
          activate_selected_row(@selected_pane.watch? ? "evaluate" : "toggle")
        when event.matches?("m")
          activate_selected_row("load-more")
        when event.matches?("delete"), event.matches?("backspace")
          activate_selected_row("remove")
        when event.matches?("left")
          if @selected_pane.variables?
            activate_selected_row("collapse")
          else
            select_adjacent_pane(-1)
          end
        when event.matches?("right")
          if @selected_pane.variables?
            activate_selected_row("expand")
          else
            select_adjacent_pane(1)
          end
        else
          return false
        end
        event.stop!
        true
      when Tui::MouseEvent
        return false unless event.left? && event.click? && event.in_rect?(@rect)
        focus
        if event.y == @rect.y + 1
          if pane = pane_at_header_x(event.x - @rect.x)
            self.selected_pane = pane
          end
        elsif event.y >= @rect.y + 2 + (@error ? 1 : 0)
          row = first_visible_row(@selected_pane) + event.y - (@rect.y + 2 + (@error ? 1 : 0))
          move_to_row(row)
        end
        event.stop!
        true
      else
        false
      end
    end

    def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless visible?
      return if @rect.empty?
      paint = @rect.intersect(clip)
      return unless paint

      bg = Theme::Editor.text_bg
      fg = Theme::Editor.text_fg
      fill_style = Tui::Style.new(fg: fg, bg: bg)
      @rect.height.times do |dy|
        @rect.width.times do |dx|
          x = @rect.x + dx
          y = @rect.y + dy
          buffer.set(x, y, ' ', fill_style) if paint.contains?(x, y)
        end
      end

      title_style = Tui::Style.new(fg: Theme::Split.focus_title, bg: bg, attrs: Tui::Attributes::Bold)
      text_style = Tui::Style.new(fg: fg, bg: bg)
      muted_style = Tui::Style.new(fg: Theme::Status.debug, bg: bg)
      error_style = Tui::Style.new(fg: Theme::Status.error, bg: bg, attrs: Tui::Attributes::Bold)
      active_style = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg, attrs: Tui::Attributes::Bold)

      draw_text(buffer, paint, @rect.x, @rect.y, "DEBUG", title_style)
      summary_x = @rect.x + 7
      draw_text(buffer, paint, summary_x, @rect.y, @summary, muted_style)
      return if @rect.height == 1

      if @rect.width >= 64
        draw_text(buffer, paint, @rect.x + 1, @rect.y + 1,
          "STACK THREADS VARS WATCH BP OUTPUT SOURCES", muted_style)
        pane_header_entries.each do |pane, start, active_label|
          if pane == @selected_pane
            # Keep active-pane identity in text as well as color so screen
            # readers and terminal captures can distinguish wide headers.
            draw_text(buffer, paint, @rect.x + start - 1, @rect.y + 1, "▶", active_style)
            draw_text(buffer, paint, @rect.x + start, @rect.y + 1, active_label, active_style)
            break
          end
        end
      else
        pane, start, active_label = pane_header_entries.first
        draw_text(buffer, paint, @rect.x + start, @rect.y + 1, active_label, active_style)
      end
      range = visible_range_text(@selected_pane)
      if range && @rect.width >= 20
        draw_text(buffer, paint, @rect.x + @rect.width - range.bytesize - 1, @rect.y + 1, range, muted_style)
      end

      line_y = @rect.y + 2
      if message = @error
        draw_text(buffer, paint, @rect.x + 1, line_y, "! #{message}", error_style)
        line_y += 1
      end

      body = visible_lines(@selected_pane)
      if body.empty?
        message = total_rows(@selected_pane) > 0 ? "Rows unavailable for this viewport" : empty_message(@selected_pane)
        draw_text(buffer, paint, @rect.x + 1, line_y, message, muted_style)
      else
        body.each_with_index do |line, index|
          break if line_y >= @rect.y + @rect.height
          row_index = (@row_offsets[@selected_pane]? || 0) + index
          draw_text(buffer, paint, @rect.x + 1, line_y, line,
            row_index == selected_row ? active_style : text_style)
          line_y += 1
        end
      end
    end

    private def replace_page(pane : Pane, offset : Int32, total : Int32, lines : Array(String)) : Nil
      previous_bytes = (@lines[pane]? || [] of String).sum(&.bytesize)
      other_pane_bytes = @stored_line_bytes - previous_bytes
      remaining_bytes = {MAX_TOTAL_BYTES - other_pane_bytes, 0}.max
      retained = lines.map { |line| bounded_display_text(line, MAX_LINE_BYTES) }
      retained_bytes = retained.sum(&.bytesize)
      raise ArgumentError.new("debug viewport exceeds the panel display budget") if retained_bytes > remaining_bytes
      @lines[pane] = retained
      @stored_line_bytes = other_pane_bytes + retained_bytes
      @row_counts[pane] = total
      @row_offsets[pane] = offset
      @page_starts[pane] = offset
    end

    private def visible_lines(pane : Pane) : Array(String)
      all = @lines[pane]? || [] of String
      relative_start = {@row_offsets[pane]? || 0, @page_starts[pane]? || 0}.max - (@page_starts[pane]? || 0)
      all.skip(relative_start).first(viewport_capacity)
    end

    private def visible_range_text(pane : Pane) : String?
      total = @row_counts[pane]? || 0
      return nil if total == 0
      count = visible_lines(pane).size
      return nil if count == 0
      first = (@row_offsets[pane]? || 0) + 1
      "#{first}-#{first + count - 1}/#{total}"
    end

    private def global_max_row_offset(total : Int32) : Int32
      cap = viewport_capacity
      return 0 if cap <= 0 || total <= cap
      total - cap
    end

    private def request_viewport(pane : Pane) : Nil
      callback = @on_viewport_request
      return unless callback
      callback.call(pane, @row_offsets[pane]? || 0, [viewport_capacity, MAX_PAGE_LINES].min)
    end

    private def clear_other_pages(keep : Pane) : Nil
      @lines.keys.each do |pane|
        next if pane == keep
        @stored_line_bytes -= (@lines.delete(pane) || [] of String).sum(&.bytesize)
        @page_starts.delete(pane)
      end
    end

    private def select_adjacent_pane(direction : Int32) : Bool
      panes = {Pane::Stack, Pane::Threads, Pane::Variables, Pane::Watch, Pane::Breakpoints, Pane::Output, Pane::Sources}
      index = panes.index(@selected_pane) || 0
      next_index = (index + direction + panes.size) % panes.size
      self.selected_pane = panes[next_index]
      true
    end

    private def pane_label(pane : Pane) : String
      case pane
      when .stack?       then "STACK"
      when .threads?     then "THREADS"
      when .variables?   then "VARIABLES"
      when .watch?       then "WATCH"
      when .breakpoints? then "BREAKPOINTS"
      when .output?      then "OUTPUT"
      when .sources?     then "SOURCES"
      else                    raise "unknown debug pane"
      end
    end

    private def pane_header_entries : Array(Tuple(Pane, Int32, String))
      if @rect.width >= 64
        [
          {Pane::Stack, 1, "STACK"},
          {Pane::Threads, 7, "THREADS"},
          {Pane::Variables, 15, "VARS"},
          {Pane::Watch, 20, "WATCH"},
          {Pane::Breakpoints, 26, "BP"},
          {Pane::Output, 29, "OUTPUT"},
          {Pane::Sources, 36, "SOURCES"},
        ]
      else
        [{@selected_pane, 1, "[#{pane_label(@selected_pane)}]"}]
      end
    end

    private def empty_message(pane : Pane) : String
      case pane
      when .stack?       then "No stopped stack"
      when .threads?     then "No target threads"
      when .variables?   then "Locals are unavailable"
      when .watch?       then "No watches; add one explicitly"
      when .breakpoints? then "No breakpoints"
      when .output?      then "No inferior output"
      when .sources?     then "No adapter-owned source opened; use Show Location"
      else                    raise "unknown debug pane"
      end
    end

    private def move_to_row(row : Int32) : Bool
      total = total_rows(@selected_pane)
      return false if total <= 0
      next_row = row.clamp(0, total - 1)
      return false if next_row == selected_row
      @selected_rows[@selected_pane] = next_row
      capacity = viewport_capacity
      offset = @row_offsets[@selected_pane]? || 0
      if capacity > 0 && next_row < offset
        @row_offsets[@selected_pane] = next_row
        request_viewport(@selected_pane)
      elsif capacity > 0 && next_row >= offset + capacity
        @row_offsets[@selected_pane] = next_row - capacity + 1
        request_viewport(@selected_pane)
      end
      @on_row_selected.try(&.call(@selected_pane, next_row))
      mark_dirty!
      true
    end

    private def pane_at_header_x(relative_x : Int32) : Pane?
      pane_header_entries.each do |pane, start, label|
        finish = start + label.size
        return pane if relative_x >= start && relative_x < finish
      end
      nil
    end

    private def bounded_display_text(value : String, byte_limit : Int32) : String
      return "[invalid text]" unless value.valid_encoding?
      String.build do |output|
        value.each_grapheme do |grapheme|
          text = grapheme.to_s
          safe = String.build do |part|
            text.each_char do |char|
              next if display_control?(char.ord)
              part << char
            end
          end
          break if output.bytesize + safe.bytesize > byte_limit
          output << safe
        end
      end
    end

    private def display_control?(codepoint : Int32) : Bool
      codepoint <= 0x1f || (0x7f..0x9f).includes?(codepoint) ||
        codepoint == 0x061c || codepoint == 0x200b ||
        (0x200e..0x200f).includes?(codepoint) ||
        (0x202a..0x202e).includes?(codepoint) ||
        codepoint == 0x2028 || codepoint == 0x2029 || codepoint == 0x2060 ||
        (0x2066..0x2069).includes?(codepoint) || codepoint == 0xfeff
    end

    private def draw_text(buffer : Tui::Buffer, clip : Tui::Rect, x : Int32, y : Int32,
                          value : String, style : Tui::Style) : Nil
      cursor = x
      right = @rect.x + @rect.width
      value.each_grapheme do |grapheme|
        text = grapheme.to_s
        width = Tui::Unicode.grapheme_width(text)
        break if cursor + width > right
        buffer.set(cursor, y, text, style) if clip.contains?(cursor, y)
        cursor += width
      end
    end
  end
end
