require "crystal_tui"

module Adamantine
  module ProblemsController
    PROBLEMS_MAX_ROWS               = 1000
    PROBLEMS_MAX_MESSAGE_CODEPOINTS = 4096
    PROBLEMS_MAX_SOURCE_CODEPOINTS  =  256
    PROBLEMS_MAX_PATH_CODEPOINTS    = 4096
    PROBLEMS_MAX_WIDTH              =   96

    private struct WorkspaceProblemsRequest
      getter client : Lsp::Client
      getter generation : UInt64
      getter root_identity : String

      def initialize(@client : Lsp::Client, @generation : UInt64, @root_identity : String)
      end
    end

    macro included
      @problems_request_generation : UInt64 = 0_u64
      @problems_workspace_running : Bool = false
      @problems_workspace_queued : WorkspaceProblemsRequest? = nil
    end

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

      if client = @lsp
        if client.workspace_diagnostics_supported? && lsp_recovery_client_ready?(client)
          open_workspace_problems(client)
          return
        end
      end

      open_open_files_problems
    end

    private def open_open_files_problems : Nil
      @problems_request_generation &+= 1_u64
      @problems_workspace_queued = nil
      rows, partial = capture_open_file_problems
      publish_problems_snapshot(
        rows,
        partial,
        ProblemsState::Coverage::OpenFiles,
        @lsp.try(&.object_id),
        @problems_request_generation,
        problems_display_root.to_s,
      )
    end

    private def capture_open_file_problems : Tuple(Array(ProblemsState::Row), Bool)
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

      {rows.first(PROBLEMS_MAX_ROWS), partial || truncated}
    end

    private def publish_problems_snapshot(
      rows : Array(ProblemsState::Row),
      partial : Bool,
      coverage : ProblemsState::Coverage,
      client_id : UInt64?,
      generation : UInt64,
      root_identity : String,
      loading : Bool = false,
    ) : Nil
      @problems.rows = rows
      @problems.selected = 0
      @problems.top = 0
      @problems.partial = partial
      @problems.client_id = client_id
      @problems.coverage = coverage
      @problems.loading = loading
      @problems.request_generation = generation
      @problems.root_identity = root_identity

      open_problems_modal
    end

    private def open_problems_modal : Nil
      if @problems.open
        mark_dirty!
        return
      end

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

    private def open_workspace_problems(client : Lsp::Client) : Nil
      @problems_request_generation &+= 1_u64
      root_identity = problems_display_root.to_s
      request = WorkspaceProblemsRequest.new(client, @problems_request_generation, root_identity)
      publish_problems_snapshot(
        [] of ProblemsState::Row,
        false,
        ProblemsState::Coverage::ServerWorkspace,
        client.object_id,
        request.generation,
        root_identity,
        loading: true,
      )
      schedule_workspace_problems(request)
    end

    private def schedule_workspace_problems(request : WorkspaceProblemsRequest) : Nil
      if @problems_workspace_running
        @problems_workspace_queued = request
        return
      end

      @problems_workspace_running = true
      spawn(name: "workspace-problems") do
        result : Lsp::WorkspaceDiagnosticResult? = nil
        error : Exception? = nil
        begin
          result = request.client.workspace_diagnostics
        rescue ex
          error = ex
        ensure
          finish_workspace_problems(request, result, error)
        end
      end
    end

    private def finish_workspace_problems(
      request : WorkspaceProblemsRequest,
      result : Lsp::WorkspaceDiagnosticResult?,
      _error : Exception?,
    ) : Nil
      if workspace_problems_request_current?(request)
        if result
          rows, partial = capture_workspace_problems(request, result.not_nil!)
          if workspace_problems_request_current?(request)
            publish_problems_snapshot(
              rows,
              partial,
              ProblemsState::Coverage::ServerWorkspace,
              request.client.object_id,
              request.generation,
              request.root_identity,
            )
            wakeup
          end
        else
          rows, partial = capture_open_file_problems
          if workspace_problems_request_current?(request)
            publish_problems_snapshot(
              rows,
              partial,
              ProblemsState::Coverage::OpenFiles,
              request.client.object_id,
              request.generation,
              request.root_identity,
            )
            @status_log.warning("Workspace diagnostics failed; showing open files")
            wakeup
          end
        end
      end

      @problems_workspace_running = false
      if queued = @problems_workspace_queued
        @problems_workspace_queued = nil
        schedule_workspace_problems(queued) if workspace_problems_request_current?(queued)
      end
    end

    private def workspace_problems_request_current?(request : WorkspaceProblemsRequest) : Bool
      return false unless @problems.open
      return false unless @problems.coverage.server_workspace?
      return false unless @problems.request_generation == request.generation
      return false unless @problems.client_id == request.client.object_id
      return false unless @problems.root_identity == request.root_identity
      return false unless @lsp.try(&.same?(request.client))
      return false unless lsp_recovery_client_ready?(request.client)
      problems_display_root.to_s == request.root_identity
    rescue
      false
    end

    private def capture_workspace_problems(
      request : WorkspaceProblemsRequest,
      result : Lsp::WorkspaceDiagnosticResult,
    ) : Tuple(Array(ProblemsState::Row), Bool)
      rows, partial = capture_open_file_problems
      partial ||= result.partial
      truncated = false
      root = Path.new(request.root_identity)

      open_uris = Hash(String, Bool).new
      open_target_stamps = [] of FileRevision::Stamp
      @document_session.open_buffers.each_value do |buffer|
        open_uris[buffer.uri] = true
        stamp = FileRevision.probe(buffer.path)
        open_target_stamps << stamp if stamp.stable?
      end

      result.documents.each_with_index do |document, document_index|
        Fiber.yield if document_index > 0 && document_index % 32 == 0
        unless workspace_problems_request_current?(request)
          return {[] of ProblemsState::Row, true}
        end
        partial ||= document.partial
        next if open_uris.has_key?(document.uri)

        path = UriCodec.uri_to_path(document.uri)
        unless path && path.absolute?
          partial = true
          next
        end

        stamp = FileRevision.probe(path)
        target_identity = stamp.target_identity
        unless stamp.stable? && target_identity &&
               stamp.size <= DocumentOrchestrator::MAX_FILE_BYTES &&
               problems_target_within_root?(target_identity, root)
          partial = true
          next
        end
        next if open_target_stamps.any? { |open_stamp| open_stamp.same_target?(stamp) }

        display_path = problems_display_path(path, root)
        document.diagnostics.each_with_index do |diagnostic, index|
          rows << ProblemsState::Row.workspace_file(
            diagnostic,
            index.to_i32,
            path,
            display_path,
            document.uri,
            document.version,
            stamp,
            request.generation,
            request.root_identity,
          )
          if rows.size > PROBLEMS_MAX_ROWS * 2
            rows = problems_sorted_rows(rows).first(PROBLEMS_MAX_ROWS)
            truncated = true
          end
        end
      end

      rows = problems_sorted_rows(rows)
      truncated ||= rows.size > PROBLEMS_MAX_ROWS
      {rows.first(PROBLEMS_MAX_ROWS), partial || truncated}
    end

    private def problems_target_within_root?(target_identity : String, root : Path) : Bool
      relative = Path.new(target_identity).relative_to(root).to_s
      !problems_parent_path?(relative) && relative != target_identity
    rescue
      false
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
      @problems_request_generation &+= 1_u64
      @problems_workspace_queued = nil
      close_modal(@problems, InputModeController::InputMode::Problems)
      @problems.reset_snapshot
    end

    private def handle_problems_input(event : Tui::KeyEvent) : Bool
      case
      # Raw modal controls take precedence over remapped actions so a
      # conflicting binding can never invert or remove the recovery path.
      when event.matches?("up")
        move_problems_selection(-1)
      when event.matches?("down")
        move_problems_selection(1)
      when event.matches?("enter") || event.matches?("return")
        accept_problem_selection
      when event.matches?("escape") || event.matches?("esc")
        close_problems
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
      return navigate_workspace_problem(row) if row.workspace_file?

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

    private def navigate_workspace_problem(row : ProblemsState::Row) : Bool
      return false unless row.workspace_file?
      stamp = row.stamp
      uri = row.uri
      return false unless stamp && uri
      path = Path.new(row.buffer_path)

      resolved_position : TextCoordinates::Position? = nil
      cursor_resolver = ->(target_editor : Tui::TextEditor) : Tuple(Int32, Int32)? do
        return nil unless problems_workspace_row_current?(row)
        begin
          start = TextCoordinates.position(target_editor, row.diagnostic.line, row.diagnostic.character, clamp: true)
          finish = TextCoordinates.position(target_editor, row.diagnostic.end_line, row.diagnostic.end_character, clamp: true)
          return nil if finish.line < start.line
          return nil if finish.line == start.line && finish.column < start.column
          resolved_position = start
          {start.line, start.column}
        rescue ArgumentError
          nil
        end
      end

      committed = false
      opened = open_file(
        path,
        nil,
        nil,
        -> { problems_workspace_row_current?(row) },
        -> { committed = true },
        cursor_resolver,
        stamp,
      )
      return false unless opened && committed && resolved_position
      return false unless current_buffer.try(&.uri) == uri
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
      if row.workspace_file?
        problems_workspace_row_current?(row)
      else
        problems_live_row_target?(row)
      end
    end

    private def problems_live_row_target?(row : ProblemsState::Row) : Bool
      return false unless row.open_buffer?
      buffer = @document_session.open_buffers[row.buffer_path]?
      return false unless buffer
      return false unless row.buffer_id == buffer.object_id
      return false unless row.editor_id == buffer.editor.object_id
      return false unless row.version == buffer.version
      return false unless row.diagnostics_generation == buffer.diagnostics_generation
      true
    end

    private def problems_workspace_row_current?(row : ProblemsState::Row) : Bool
      return false unless row.workspace_file?
      return false unless @problems.open
      return false unless @problems.coverage.server_workspace?
      return false unless @problems.request_generation == row.request_generation
      return false unless @problems.root_identity == row.root_identity
      client = @lsp
      return false unless client
      return false unless @problems.client_id == client.object_id
      return false unless lsp_recovery_client_ready?(client)

      root_identity = row.root_identity
      stamp = row.stamp
      return false unless root_identity && stamp
      return false unless problems_display_root.to_s == root_identity
      current = FileRevision.probe(row.buffer_path)
      return false unless current.same_as?(stamp)
      # An alias of this target may have become a live, possibly dirty buffer
      # after the workspace snapshot was published. Never bypass that editor
      # by reopening the same inode under the server's path spelling.
      @document_session.open_buffers.each_value do |buffer|
        return false if FileRevision.probe(buffer.path).same_target?(current)
      end
      target_identity = current.target_identity
      return false unless target_identity
      problems_target_within_root?(target_identity, Path.new(root_identity))
    rescue
      false
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
      if @problems.loading
        "Loading server workspace diagnostics..."
      elsif @problems.coverage.server_workspace?
        is_partial ? "No server workspace diagnostics (partial)" : "No server workspace diagnostics"
      else
        is_partial ? "No diagnostics in open files (partial)" : "No diagnostics in open files"
      end
    end

    private def problems_title : String
      if @problems.coverage.server_workspace?
        return "Problems: Server Workspace (loading)" if @problems.loading
        return "Problems: Server Workspace (partial)" if @problems.partial
        "Problems: Server Workspace"
      else
        @problems.partial ? "Problems: Open Files (partial)" : "Problems: Open Files"
      end
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
      title = problems_title
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

      indicator = if @problems.loading || rows.empty?
                    "Esc Close"
                  else
                    "#{@problems.selected + 1}/#{rows.size}  Enter Open  Esc Close"
                  end
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
