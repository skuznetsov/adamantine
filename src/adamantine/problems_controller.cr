require "crystal_tui"

module Adamantine
  module ProblemsController
    PROBLEMS_MAX_ROWS               = 1000
    PROBLEMS_MAX_MESSAGE_CODEPOINTS = 4096
    PROBLEMS_MAX_SOURCE_CODEPOINTS  =  256
    PROBLEMS_MAX_PATH_CODEPOINTS    = 4096
    PROBLEMS_MAX_WIDTH              =   96

    private def problems_active? : Bool
      @problems.open && problems_mode_active?
    end

    private def open_problems : Nil
      buffer = current_buffer
      editor = current_editor
      unless buffer && editor
        @status_log.warning("No active buffer")
        return
      end

      close_context_menu
      close_lsp_popup(false)
      rows = [] of ProblemsState::Row
      partial = false
      truncated = false
      display_root = problems_display_root
      @document_session.open_buffers.each_value do |open_buffer|
        partial ||= open_buffer.diagnostics_partial
        display_path = problems_display_path(open_buffer.path, display_root)
        open_buffer.diagnostics.each_with_index do |diagnostic, index|
          rows << ProblemsState::Row.new(
            diagnostic,
            index.to_i32,
            open_buffer.path.to_s,
            display_path,
            open_buffer.object_id,
            open_buffer.editor.object_id,
            open_buffer.version,
            open_buffer.diagnostics_generation,
          )
          if rows.size > PROBLEMS_MAX_ROWS * 2
            rows = problems_sorted_rows(rows).first(PROBLEMS_MAX_ROWS)
            truncated = true
          end
        end
      end
      rows = problems_sorted_rows(rows)
      truncated ||= rows.size > PROBLEMS_MAX_ROWS

      @problems.rows = rows.first(PROBLEMS_MAX_ROWS)
      @problems.selected = 0
      @problems.top = 0
      @problems.partial = partial || truncated
      @problems.client_id = @lsp.try(&.object_id)

      with_input_mode_guard(InputModeController::InputMode::Problems) do
        previous_overlay = @problems.overlay
        @problems.overlay = ->(surface : Tui::Buffer, clip : Tui::Rect) {
          render_problems(surface, clip)
        }
        @problems.overlay = open_overlay(previous_overlay, @problems.overlay.not_nil!)
        @problems.open = true
        mark_dirty!
      end
    end

    private def problems_sorted_rows(rows : Array(ProblemsState::Row)) : Array(ProblemsState::Row)
      rows.sort_by do |row|
        diagnostic = row.diagnostic
        {
          problems_severity_rank(diagnostic.severity),
          row.display_path,
          row.buffer_path,
          diagnostic.line,
          diagnostic.character,
          diagnostic.end_line,
          diagnostic.end_character,
          row.source_index,
          diagnostic.source || "",
          diagnostic.message,
        }
      end
    end

    private def close_problems : Nil
      close_modal(@problems, InputModeController::InputMode::Problems)
      @problems.reset_snapshot
    end

    private def handle_problems_input(event : Tui::KeyEvent) : Bool
      case
      when action_pressed?("lsp.problems_up", event)
        move_problems_selection(-1)
      when action_pressed?("lsp.problems_down", event)
        move_problems_selection(1)
      when action_pressed?("lsp.problems_accept", event)
        accept_problem_selection
      when action_pressed?("lsp.problems_cancel", event)
        close_problems
      else
        # Problems is a hard modal boundary.  Unknown keys are consumed so
        # text editing, paste and remapped editor commands cannot leak below
        # the overlay.  Mouse and paste are handled by App#on_capture.
        return true
      end
      true
    end

    private def move_problems_selection(delta : Int32) : Nil
      rows = @problems.rows
      return if rows.empty?

      index = @problems.selected + delta
      index = rows.size - 1 if index < 0
      index = 0 if index >= rows.size
      @problems.selected = index
      problems_keep_selection_visible
      mark_dirty!
    end

    private def accept_problem_selection : Nil
      row = @problems.rows[@problems.selected]?
      unless row
        @status_log.info(problems_empty_status)
        return
      end

      unless problems_row_current?(row)
        @status_log.warning("Problems list is stale")
        close_problems
        return
      end

      unless navigate_problem(row)
        @status_log.warning("Diagnostic position is invalid")
        close_problems
        return
      end
      close_problems
    end

    private def problems_next_action : Bool
      navigate_diagnostic(1)
      true
    end

    private def problems_previous_action : Bool
      navigate_diagnostic(-1)
      true
    end

    private def navigate_diagnostic(delta : Int32) : Nil
      buffer = current_buffer
      editor = current_editor
      unless buffer && editor
        @status_log.warning("No active buffer")
        return
      end

      rows = buffer.diagnostics.first(PROBLEMS_MAX_ROWS).sort_by do |diagnostic|
        {
          diagnostic.line,
          diagnostic.character,
          diagnostic.end_line,
          diagnostic.end_character,
          problems_severity_rank(diagnostic.severity),
          diagnostic.source || "",
          diagnostic.message,
        }
      end
      if rows.empty?
        @status_log.info(problems_empty_status(buffer.diagnostics_partial))
        return
      end

      cursor_key = {editor.cursor_line, editor.cursor_col}
      target = if delta >= 0
                 rows.find { |diagnostic| {diagnostic.line, diagnostic.character} > cursor_key } || rows.first
               else
                 rows.reverse_each.find { |diagnostic| {diagnostic.line, diagnostic.character} < cursor_key } || rows.last
               end
      unless navigate_problem(target)
        @status_log.warning("Diagnostic position is invalid")
      end
    end

    private def navigate_problem(diagnostic : Lsp::Diagnostic) : Bool
      editor = current_editor
      return false unless editor
      navigate_problem_in_editor(editor, diagnostic)
    end

    private def navigate_problem(row : ProblemsState::Row) : Bool
      return false unless problems_row_current?(row)
      buffer = @document_session.open_buffers[row.buffer_path]?
      return false unless buffer

      editor = buffer.editor
      return false unless diagnostic_position_valid?(editor, row.diagnostic)

      @document_orchestrator.switch_to_tab_by_position_buffer(row.buffer_path)
      return false unless problems_live_row_target?(row)
      return false unless current_buffer.try(&.same?(buffer))
      return false unless current_editor.try(&.same?(editor))

      editor.set_cursor(row.diagnostic.line, row.diagnostic.character)
      mark_dirty!
      true
    end

    private def navigate_problem_in_editor(editor : Tui::TextEditor, diagnostic : Lsp::Diagnostic) : Bool
      return false unless diagnostic_position_valid?(editor, diagnostic)
      editor.set_cursor(diagnostic.line, diagnostic.character)
      mark_dirty!
      true
    end

    private def diagnostic_position_valid?(editor : Tui::TextEditor, diagnostic : Lsp::Diagnostic) : Bool
      return false if diagnostic.line < 0 || diagnostic.character < 0
      return false if diagnostic.end_line < diagnostic.line
      return false if diagnostic.end_line == diagnostic.line && diagnostic.end_character < diagnostic.character

      # Stored diagnostics are codepoint coordinates.  Validate the boundary
      # through the editor-owned adapter before mutating the cursor; this
      # rejects a malformed externally supplied row without copying the file.
      begin
        TextCoordinates.codepoint_to_utf16(editor, diagnostic.line, diagnostic.character)
        TextCoordinates.codepoint_to_utf16(editor, diagnostic.end_line, diagnostic.end_character)
      rescue ArgumentError
        return false
      end
      true
    end

    private def problems_row_current?(row : ProblemsState::Row) : Bool
      return false unless @problems.client_id == @lsp.try(&.object_id)
      problems_live_row_target?(row)
    end

    private def problems_live_row_target?(row : ProblemsState::Row) : Bool
      buffer = @document_session.open_buffers[row.buffer_path]?
      return false unless buffer
      return false unless row.buffer_id == buffer.object_id
      return false unless row.editor_id == buffer.editor.object_id
      return false unless row.version == buffer.version
      return false unless row.diagnostics_generation == buffer.diagnostics_generation
      true
    end

    private def clear_buffer_diagnostics(buffer : OpenBuffer) : Nil
      buffer.diagnostics = [] of Lsp::Diagnostic
      buffer.diagnostics_partial = false
      buffer.diagnostics_generation &+= 1_u64
      buffer.diagnostics_notification_generation &+= 1_u64
      close_problems if @problems.open
      mark_dirty!
    end

    private def clear_all_buffer_diagnostics : Nil
      @document_session.open_buffers.each_value do |buffer|
        buffer.diagnostics = [] of Lsp::Diagnostic
        buffer.diagnostics_partial = false
        buffer.diagnostics_generation &+= 1_u64
        buffer.diagnostics_notification_generation &+= 1_u64
      end
      close_problems
      mark_dirty!
    end

    private def close_problems_for_buffer(buffer : OpenBuffer) : Nil
      close_problems if @problems.open
    end

    private def problems_diagnostics_updated(buffer : OpenBuffer) : Nil
      # A publication replaces the rows wholesale.  Never leave a modal row
      # authorized against the previous generation, including an empty list.
      close_problems if @problems.open
    end

    private def problems_severity_rank(severity : Int32?) : Int32
      case severity
      when 1 then 0 # Error
      when 2 then 1 # Warning
      when 3 then 2 # Information
      when 4 then 3 # Hint
      else        4
      end
    end

    private def problems_empty_status(partial : Bool? = nil) : String
      is_partial = partial.nil? ? @problems.partial : partial.not_nil!
      is_partial ? "No diagnostics in open files (partial)" : "No diagnostics in open files"
    end

    private def problems_keep_selection_visible(visible_rows : Int32 = 1) : Nil
      rows = @problems.rows.size
      visible = [visible_rows, 1].max
      if @problems.selected < @problems.top
        @problems.top = @problems.selected
      elsif @problems.selected >= @problems.top + visible
        @problems.top = @problems.selected - visible + 1
      end
      @problems.top = @problems.top.clamp(0, [rows - visible, 0].max)
    end

    private def render_problems(surface : Tui::Buffer, clip : Tui::Rect) : Nil
      width = [clip.width, PROBLEMS_MAX_WIDTH].min
      return if width < 4 || clip.height < 2

      rows = @problems.rows
      visible = [rows.size, [clip.height - 4, 1].max].min
      popup_height = [visible + 4, clip.height].min
      width = [width, 4].max
      x = (clip.x + (clip.width - width) // 2).clamp(clip.x, [clip.right - width, clip.x].max)
      y = (clip.y + (clip.height - popup_height) // 2).clamp(clip.y, [clip.bottom - popup_height, clip.y].max)

      problems_keep_selection_visible(visible.to_i32)
      fg_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      active_style = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, attrs: Tui::Attributes::Bold)
      title = @problems.partial ? "Problems: Open Files (partial)" : "Problems: Open Files"
      draw_box_border(surface, clip, x, y, width, popup_height, fg_style, fg_style, title, title_style)

      body_width = width - 3
      if rows.empty?
        draw_text_line(surface, clip, x + 1, y + 1, problems_empty_status, fg_style, body_width)
      else
        rows[@problems.top, visible]?.try do |visible_rows|
          visible_rows.each_with_index do |row, index|
            row_index = @problems.top + index
            style = row_index == @problems.selected ? active_style : fg_style
            draw_text_line(surface, clip, x + 1, y + 1 + index, problems_row_text(row), style, body_width)
          end
        end
      end

      indicator = rows.empty? ? "Esc Close" : "#{@problems.selected + 1}/#{rows.size}  Enter Open  Esc Close"
      draw_text_line(surface, clip, x + 1, y + popup_height - 2, indicator, fg_style, body_width)
    end

    private def problems_row_text(row : ProblemsState::Row) : String
      diagnostic = row.diagnostic
      severity = case diagnostic.severity
                 when 1 then "E"
                 when 2 then "W"
                 when 3 then "I"
                 when 4 then "H"
                 else        "?"
                 end
      source = diagnostic.source
      source_text = source ? " [#{problems_sanitize(source.not_nil!, PROBLEMS_MAX_SOURCE_CODEPOINTS)}]" : ""
      message = problems_sanitize(diagnostic.message, PROBLEMS_MAX_MESSAGE_CODEPOINTS)
      path = problems_sanitize(row.display_path, PROBLEMS_MAX_PATH_CODEPOINTS)
      "#{severity} #{path}:#{diagnostic.line + 1}:#{diagnostic.character + 1}#{source_text} #{message}"
    end

    private def problems_display_root : Path
      Path.new(File.realpath(@project_root.to_s))
    rescue
      @project_root.expand
    end

    private def problems_display_path(path : Path, root : Path) : String
      lexical = path.relative_to(@project_root).to_s
      return lexical unless problems_parent_path?(lexical)

      expanded = path.expand.relative_to(root).to_s
      return expanded unless problems_parent_path?(expanded)

      Path.new(File.realpath(path.to_s)).relative_to(root).to_s
    rescue
      path.to_s
    end

    private def problems_parent_path?(path : String) : Bool
      path == ".." || path.starts_with?("../") || path.starts_with?("..\\")
    end

    private def problems_sanitize(value : String, max_codepoints : Int32) : String
      builder = String::Builder.new
      count = 0
      value.each_char do |char|
        break if count >= max_codepoints
        codepoint = char.ord
        control = codepoint < 0x20 || (0x7f..0x9f).includes?(codepoint)
        builder << (control ? ' ' : char)
        count += 1
      end
      builder.to_s
    end
  end
end
