require "crystal_tui"
require "./unicode_layout"
require "./text_coordinates"

module Adamantine
  # Unicode-aware behavior layered on top of the pinned Tui text editor.
  #
  # The public cursor/selection columns remain codepoint indexes.  Only the
  # horizontal viewport and terminal hit-testing use display-cell offsets.
  class EditingTextEditor
    include TextCoordinates::LineProvider
    include TextCoordinates::Utf16ColumnProvider
    include TextCoordinates::CodepointColumnProvider

    def line_text(line : Int32) : String
      raise ArgumentError.new("line outside editor") unless line >= 0 && line < line_count
      @buffer.line(line)
    end

    def line_utf16_column(line : Int32, column : Int32) : Int32
      raise ArgumentError.new("line outside editor") unless line >= 0 && line < line_count
      raise ArgumentError.new("column outside line") unless column >= 0 && column <= line_length(line)
      @buffer.line_utf16_column(line, column)
    end

    # Invert the tree's monotone UTF-16 prefix count without copying the line.
    # Equality is essential: a lower bound inside a surrogate pair is invalid.
    def line_codepoint_column(line : Int32, column : Int32, clamp : Bool) : Int32
      raise ArgumentError.new("line outside editor") unless line >= 0 && line < line_count
      raise ArgumentError.new("negative UTF-16 column") if column < 0
      low = 0
      high = line_length(line)
      maximum = @buffer.line_utf16_column(line, high)
      if column > maximum
        return high if clamp
        raise ArgumentError.new("UTF-16 column outside line")
      end
      while low < high
        middle = low + (high - low) // 2
        if @buffer.line_utf16_column(line, middle) < column
          low = middle + 1
        else
          high = middle
        end
      end
      unless @buffer.line_utf16_column(line, low) == column
        raise ArgumentError.new("UTF-16 column falls inside a surrogate pair")
      end
      low
    end

    private def unicode_tab_size : Int32
      @tab_size.clamp(1, 8)
    end

    def set_cursor(line : Int32, col : Int32) : Nil
      return if line_count == 0

      @cursor.line = line.clamp(0, line_count - 1)
      @cursor.col = col.clamp(0, line_length(@cursor.line))
      @selection = nil
      ensure_cursor_visible
      mark_dirty!
    end

    def move_left(with_selection : Bool = false) : Nil
      update_selection_start if with_selection && !@selection
      clear_selection unless with_selection

      if @cursor.col > 0
        @cursor.col = UnicodeLayout.previous_boundary(@buffer, @cursor.line, @cursor.col, unicode_tab_size)
      elsif @cursor.line > 0
        @cursor.line -= 1
        @cursor.col = line_length(@cursor.line)
      end

      update_selection_end if with_selection
      ensure_cursor_visible
      mark_dirty!
    end

    def move_right(with_selection : Bool = false) : Nil
      update_selection_start if with_selection && !@selection
      clear_selection unless with_selection

      length = line_length(@cursor.line)
      if @cursor.col < length
        @cursor.col = UnicodeLayout.next_boundary(@buffer, @cursor.line, @cursor.col, unicode_tab_size)
      elsif @cursor.line < line_count - 1
        @cursor.line += 1
        @cursor.col = 0
      end

      update_selection_end if with_selection
      ensure_cursor_visible
      mark_dirty!
    end

    def backspace : Nil
      if selection_active?
        delete_selection
        return
      end

      return if @cursor.line == 0 && @cursor.col == 0

      if @cursor.col == 0
        # Keep the dependency's CRLF-aware line join behavior intact.
        begin_edit(:backspace)
        finish_position = current_text_position
        previous_line = @cursor.line - 1
        previous_length = line_length(previous_line)
        start_position = text_position(previous_line, previous_length)
        offset = byte_offset(previous_line, previous_length)
        finish = @buffer.line_start_offset(@cursor.line)
        exact = delete_buffer_range(offset, finish - offset)
        @cursor.line = previous_line
        @cursor.col = previous_length
        text_changed(exact ? TextChange.new(start_position, finish_position, "") : TextChange.full)
        return
      end

      bounds = UnicodeLayout.cluster_bounds_at(@buffer, @cursor.line, @cursor.col, unicode_tab_size)
      start_col = bounds[0]
      finish_col = bounds[1]
      if start_col == finish_col
        start_col = UnicodeLayout.previous_boundary(@buffer, @cursor.line, @cursor.col, unicode_tab_size)
        finish_col = @cursor.col
      end
      return if start_col >= finish_col

      begin_edit(:backspace)
      finish_position = text_position(@cursor.line, finish_col)
      start_position = text_position(@cursor.line, start_col)
      start_offset = byte_offset(@cursor.line, start_col)
      finish_offset = byte_offset(@cursor.line, finish_col)
      exact = delete_buffer_range(start_offset, finish_offset - start_offset)
      @cursor.col = start_col
      text_changed(exact ? TextChange.new(start_position, finish_position, "") : TextChange.full)
    end

    def delete : Nil
      if selection_active?
        delete_selection
        return
      end

      length = line_length(@cursor.line)
      if @cursor.col >= length
        return if @cursor.line >= line_count - 1

        begin_edit(:delete)
        start_position = current_text_position
        finish_position = text_position(@cursor.line + 1, 0)
        offset = byte_offset(@cursor.line, length)
        finish = @buffer.line_start_offset(@cursor.line + 1)
        exact = delete_buffer_range(offset, finish - offset)
        text_changed(exact ? TextChange.new(start_position, finish_position, "") : TextChange.full)
        return
      end

      bounds = UnicodeLayout.cluster_bounds_at(@buffer, @cursor.line, @cursor.col, unicode_tab_size)
      if bounds[0] == bounds[1]
        start_col = @cursor.col
        finish_col = UnicodeLayout.next_boundary(@buffer, @cursor.line, @cursor.col, unicode_tab_size)
      else
        start_col = bounds[0]
        finish_col = bounds[1]
      end
      return if start_col >= finish_col

      begin_edit(:delete)
      start_position = text_position(@cursor.line, start_col)
      finish_position = text_position(@cursor.line, finish_col)
      start_offset = byte_offset(@cursor.line, start_col)
      finish_offset = byte_offset(@cursor.line, finish_col)
      exact = delete_buffer_range(start_offset, finish_offset - start_offset)
      @cursor.col = start_col
      text_changed(exact ? TextChange.new(start_position, finish_position, "") : TextChange.full)
    end

    # The base editor stores this offset as a codepoint column.  In this
    # subclass it is a terminal-cell offset, which keeps scroll and painting
    # in the same coordinate system as tabs and wide clusters.
    private def ensure_cursor_visible : Nil
      reveal_cursor_line!
      return if line_count == 0

      if @cursor.line < @scroll_y || line_hidden?(@scroll_y)
        @scroll_y = first_visible_from(@cursor.line)
      elsif !cursor_in_viewport?
        @scroll_y = @cursor.line
        remaining = Math.max(content_height - 1, 0)
        while remaining > 0
          previous = previous_visible_line(@scroll_y)
          break unless previous
          @scroll_y = previous
          remaining -= 1
        end
      end

      return if content_width <= 0

      cursor_cell = UnicodeLayout.cell_offset_for_column(@buffer, @cursor.line, @cursor.col, unicode_tab_size)
      if cursor_cell < @scroll_x
        @scroll_x = cursor_cell
      elsif cursor_cell >= @scroll_x + content_width - 1
        @scroll_x = cursor_cell - content_width + 2
      end
      @scroll_x = 0 if @scroll_x < 0
    end

    def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless visible?
      return if @rect.empty?

      text_style = Tui::Style.new(fg: @text_fg, bg: @text_bg)
      line_num_style = Tui::Style.new(fg: @line_number_fg, bg: @line_number_bg)
      fold_style = Tui::Style.new(fg: @fold_gutter_fg, bg: @line_number_bg)
      placeholder_style = Tui::Style.new(fg: @fold_placeholder_fg, bg: @text_bg)
      cursor_style = Tui::Style.new(fg: @cursor_fg, bg: @cursor_bg)
      selection_style = Tui::Style.new(fg: @selection_fg, bg: @selection_bg)
      current_line_style = Tui::Style.new(fg: @text_fg, bg: @current_line_bg)

      fold_width = fold_gutter_width
      ln_width = line_number_width
      visible_rows = content_height
      doc_line = first_visible_from(@scroll_y)
      content_x = @rect.x + gutter_width
      content_right = content_x + content_width
      visible_end = @scroll_x + content_width

      visible_rows.times do |row|
        y = @rect.y + row

        if doc_line >= line_count
          @rect.width.times do |x|
            buffer.set(@rect.x + x, y, ' ', text_style) if clip.contains?(@rect.x + x, y)
          end
          next
        end

        is_current_line = doc_line == @cursor.line
        base_style = is_current_line && focused? ? current_line_style : text_style
        full_length = line_length(doc_line)
        blank_selected = in_selection?(doc_line, full_length)

        if fold_width > 0
          marker = fold_marker_at(doc_line) || ' '
          buffer.set(@rect.x, y, marker, fold_style) if clip.contains?(@rect.x, y)
        end

        if @show_line_numbers
          num_str = (doc_line + 1).to_s.rjust(ln_width - 1)
          num_str.each_char_with_index do |char, ci|
            x = @rect.x + fold_width + ci
            buffer.set(x, y, char, line_num_style) if clip.contains?(x, y)
          end
        end

        # Fill the viewport first.  Besides preserving current-line and
        # selection backgrounds, this clears a former wide-glyph continuation
        # before a later clipped frame is painted.
        content_width.times do |offset|
          x = content_x + offset
          next unless clip.contains?(x, y)

          style = blank_selected ? selection_style : base_style
          if style_callback = @on_cell_style
            style = style_callback.call(doc_line, full_length, ' ', style)
          end
          buffer.set(x, y, ' ', style)
        end

        placeholder = fold_placeholder_at(doc_line)
        line_style = is_current_line && focused? ? Tui::Style.new(fg: @fold_placeholder_fg, bg: @current_line_bg) : placeholder_style
        cursor_drawn = false
        scan = UnicodeLayout.each_cluster(@buffer, doc_line, unicode_tab_size, visible_end) do |cluster|
          # Tabs are spaces and may be partially visible.  A non-tab grapheme
          # must be wholly inside the viewport or it is omitted at the clip
          # boundary; Buffer#set(String) then never emits a half-wide glyph.
          if cluster.cell_end <= @scroll_x
            next true
          end
          if cluster.text != "\t" && cluster.cell_start < @scroll_x
            next true
          end
          if cluster.text != "\t" && cluster.cell_end > visible_end
            next false
          end

          selected = cluster_selected?(doc_line, cluster.start_col, cluster.end_col)
          cursor_here = is_current_line && focused? && @cursor.col >= cluster.start_col && @cursor.col < cluster.end_col
          cursor_drawn ||= cursor_here && cluster.width > 0
          style = if cursor_here
                    cursor_style
                  elsif selected
                    selection_style
                  elsif style_callback = @on_cell_style
                    style_callback.call(doc_line, cluster.start_col, cluster.text[0], base_style)
                  else
                    base_style
                  end

          x = content_x + cluster.cell_start - @scroll_x
          if cluster.text == "\t"
            cluster.width.times do |index|
              cell_x = x + index
              next unless cell_x >= content_x && cell_x < content_right
              next unless clip.contains?(cell_x, y)

              cell_style = if cursor_here && index == 0
                             cursor_style
                           else
                             style
                           end
              buffer.set(cell_x, y, ' ', cell_style)
            end
          elsif cluster.width > 0
            draw_unicode_grapheme(buffer, clip, x, y, cluster.text, style)
          end
          true
        end

        if placeholder && scan.complete
          draw_unicode_placeholder(buffer, clip, content_x, y, scan.cell_width, placeholder, line_style)
        end

        if is_current_line && focused? && !cursor_drawn && scan.complete
          cursor_cell = UnicodeLayout.cell_offset_for_column(@buffer, doc_line, @cursor.col, unicode_tab_size)
          if cursor_cell >= @scroll_x && cursor_cell < visible_end && (!placeholder || cursor_cell < scan.cell_width)
            x = content_x + cursor_cell - @scroll_x
            if clip.contains?(x, y)
              buffer.set(x, y, ' ', cursor_style)
            end
          end
        end

        following = next_visible_line(doc_line)
        break unless following
        doc_line = following
      end

      if @show_scrollbar && needs_scrollbar?
        sync_scrollbar!
        @v_scrollbar.render(buffer, clip)
      end
    end

    private def cluster_selected?(line : Int32, start_col : Int32, end_col : Int32) : Bool
      return in_selection?(line, start_col) if start_col == end_col

      selection = @selection
      return false unless selection
      normalized = selection.normalize
      if line < normalized.start_line || line > normalized.end_line
        false
      elsif line == normalized.start_line && line == normalized.end_line
        end_col > normalized.start_col && start_col < normalized.end_col
      elsif line == normalized.start_line
        end_col > normalized.start_col
      elsif line == normalized.end_line
        start_col < normalized.end_col
      else
        true
      end
    end

    private def draw_unicode_grapheme(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      x : Int32,
      y : Int32,
      text : String,
      style : Tui::Style,
    ) : Nil
      width = Tui::Unicode.grapheme_width(text)
      return if width <= 0

      fully_visible = x >= @rect.x + gutter_width && x + width <= @rect.x + gutter_width + content_width &&
                      (0...width).all? { |index| clip.contains?(x + index, y) }
      unless fully_visible
        width.times do |index|
          cell_x = x + index
          next unless cell_x >= @rect.x + gutter_width && cell_x < @rect.x + gutter_width + content_width
          buffer.set(cell_x, y, ' ', style) if clip.contains?(cell_x, y)
        end
        return
      end

      buffer.set(x, y, text, style)
    end

    private def draw_unicode_placeholder(
      buffer : Tui::Buffer,
      clip : Tui::Rect,
      content_x : Int32,
      y : Int32,
      cell_offset : Int32,
      text : String,
      style : Tui::Style,
    ) : Nil
      text.each_grapheme do |grapheme|
        glyph = grapheme.to_s
        width = Tui::Unicode.grapheme_width(glyph)
        x = content_x + cell_offset - @scroll_x
        break if x >= content_x + content_width
        draw_unicode_grapheme(buffer, clip, x, y, glyph, style) if cell_offset + width > @scroll_x
        cell_offset += width
      end
    end

    def on_event(event : Tui::Event) : Bool
      case event
      when Tui::MouseEvent
        if unicode_handle_mouse(event)
          event.stop!
          return true
        end
      when Tui::PasteEvent
        return false unless focused?
        paste(event.text)
        event.stop!
        return true
      when Tui::KeyEvent
        return false unless focused?
        if unicode_handle_key(event)
          event.stop!
          return true
        end
      end

      false
    end

    private def unicode_handle_key(event : Tui::KeyEvent) : Bool
      if event.matches?("ctrl+shift+z") || event.matches?("ctrl+y")
        redo
        return true
      end
      if event.matches?("ctrl+z")
        undo
        return true
      end

      shift = event.modifiers.shift?
      ctrl = event.modifiers.ctrl?
      alt = event.modifiers.alt?

      case event.key
      when .left?
        if ctrl || alt
          move_word_left(shift)
        else
          move_left(shift)
        end
        true
      when .right?
        if ctrl || alt
          move_word_right(shift)
        else
          move_right(shift)
        end
        true
      when .up?
        move_up(shift)
        true
      when .down?
        move_down(shift)
        true
      when .home?
        move_home(shift)
        true
      when .end?
        move_end(shift)
        true
      when .page_up?
        page_up
        true
      when .page_down?
        page_down
        true
      when .backspace?
        backspace
        true
      when .delete?
        delete
        true
      when .enter?
        insert_newline
        true
      when .tab?
        insert_text("  ")
        true
      else
        if ctrl
          case event.char
          when 'a'
            select_all
            return true
          when 's'
            save
            return true
          when 'c'
            copy
            return true
          when 'x'
            cut
            return true
          when 'v'
            return true
          when 'g'
            return true
          end
        end

        if char = event.char
          if char.printable? && !ctrl && !alt && !event.meta?
            insert_char(char)
            return true
          end
        end

        false
      end
    end

    private def unicode_handle_mouse(event : Tui::MouseEvent) : Bool
      return false unless event.in_rect?(@rect) || @v_scrollbar.dragging?

      if @show_scrollbar && needs_scrollbar?
        sync_scrollbar!
        if @v_scrollbar.hit_test?(event.x, event.y) || @v_scrollbar.dragging?
          focus unless focused?
          return @v_scrollbar.on_event(event)
        end
      end

      if event.button.wheel_up?
        scroll_view_by(-@scroll_lines)
        return true
      elsif event.button.wheel_down?
        scroll_view_by(@scroll_lines)
        return true
      end

      rel_x, rel_y = event.relative_to(@rect)
      doc_line = document_line_at_visual_row(rel_y)
      return true if doc_line < 0 || doc_line >= line_count

      case event.action
      when Tui::MouseAction::Press
        focus unless focused?

        if fold_gutter_width > 0 && rel_x < fold_gutter_width
          toggle_fold_at(doc_line)
          return true
        end

        text_cell = rel_x - gutter_width + @scroll_x
        if placeholder = fold_placeholder_at(doc_line)
          line_width = UnicodeLayout.cell_offset_for_column(@buffer, doc_line, line_length(doc_line), unicode_tab_size)
          placeholder_width = Tui::Unicode.display_width(placeholder)
          if text_cell >= line_width && text_cell < line_width + placeholder_width
            toggle_fold_at(doc_line)
            return true
          end
        end

        col = UnicodeLayout.column_at_cell(@buffer, doc_line, text_cell, unicode_tab_size)
        if hyperclick_mouse?(event)
          @cursor.line = doc_line
          @cursor.col = col
          @selection = nil
          mark_dirty!
          @on_hyperclick.try(&.call(doc_line, col, event.modifiers))
          return true
        end

        @cursor.line = doc_line
        @cursor.col = col
        @selection = nil
        ensure_cursor_visible
        mark_dirty!
        true
      when Tui::MouseAction::Drag
        focus unless focused?
        text_cell = rel_x - gutter_width + @scroll_x
        text_y = doc_line.clamp(0, line_count - 1)
        unless @selection
          @selection = Selection.new(@cursor.line, @cursor.col, @cursor.line, @cursor.col)
        end

        @cursor.line = text_y
        @cursor.col = UnicodeLayout.column_at_cell(@buffer, text_y, text_cell, unicode_tab_size)
        update_selection_end
        ensure_cursor_visible
        mark_dirty!
        true
      else
        false
      end
    end

    private def hyperclick_mouse?(event : Tui::MouseEvent) : Bool
      return true if event.button.middle?
      return false unless event.button.left?
      event.shift? || event.alt? || event.ctrl?
    end
  end
end
