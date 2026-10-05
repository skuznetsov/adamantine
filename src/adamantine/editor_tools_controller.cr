require "random/secure"

require "./editor_tools"
require "./file_revision"

module Adamantine
  module EditorToolsController
    MAX_BUFFER_REFERENCES =  256
    MAX_BUFFER_PAGE       =   64
    MAX_READ_LINES        =   64
    MAX_READ_COLUMNS      = 1024
    MAX_READ_TEXT_BYTES   = 8 * 1024
    MAX_TOOL_PATH_BYTES   = 4096
    MAX_BUFFER_PAGE_BYTES = 48 * 1024
    MAX_DEBUG_ROW_BYTES   = 42 * 1024

    class BufferReference
      getter id : String
      getter owner : OpenBuffer
      getter owner_path : String
      getter revision : String
      getter line_ending : String
      getter snapshot : Tui::PieceTreeBuffer::Snapshot

      def initialize(@owner : OpenBuffer)
        @id = Random::Secure.hex(16)
        @owner_path = @owner.path.to_s.dup
        @revision = Random::Secure.hex(16)
        @line_ending = @owner.editor.document.line_ending.dup
        @snapshot = @owner.editor.document.buffer.snapshot
      end

      def owns?(buffer : OpenBuffer) : Bool
        @owner.same?(buffer) && @owner_path == buffer.path.to_s
      end

      def refresh_revision! : Nil
        document = @owner.editor.document
        buffer = document.buffer
        line_ending = document.line_ending
        return if line_ending == @line_ending && buffer.same_state?(@snapshot)

        @snapshot = buffer.snapshot
        @line_ending = line_ending.dup
        @revision = Random::Secure.hex(16)
      end
    end

    class Backend < EditorTools::Backend
      @context_provider : Proc(EditorTools::Context)
      @dispatch : Proc(EditorTools::Request, EditorTools::ExecutionPermit, JSON::Any)

      def initialize(@context_provider : Proc(EditorTools::Context),
                     @dispatch : Proc(EditorTools::Request, EditorTools::ExecutionPermit, JSON::Any))
      end

      def context : EditorTools::Context
        @context_provider.call
      end

      def execute(request : EditorTools::Request, permit : EditorTools::ExecutionPermit) : JSON::Any
        @dispatch.call(request, permit)
      end
    end

    class DebugRowsBudget
      getter remaining : Int32

      def initialize
        @remaining = MAX_DEBUG_ROW_BYTES
      end

      def append(rows : Array(JSON::Any), row : JSON::Any) : Bool
        bytes = row.to_json.bytesize
        if bytes > @remaining
          return false
        end
        rows << row
        @remaining -= bytes
        true
      end
    end

    def open_tool_session(
      consumer : EditorTools::Consumer = EditorTools::Consumer::Chat,
      capabilities : Array(EditorTools::Capability) = [
        EditorTools::Capability::ReadEditor,
        EditorTools::Capability::ReadDebugger,
      ],
    ) : EditorTools::Session
      if @editor_tools_shutdown
        raise EditorTools::Failure.new(EditorTools::Status::Unavailable, "editor tools are shut down")
      end
      editor_tools_host.open_session(consumer, capabilities)
    end

    private def editor_tools_host : EditorTools::Host
      @editor_tools_host ||= begin
        backend = Backend.new(
          -> { editor_tools_current_context },
          ->(request : EditorTools::Request, permit : EditorTools::ExecutionPermit) {
            execute_editor_tool(request, permit)
          }
        )
        EditorTools::Host.new(backend)
      end
    end

    private def editor_tools_current_context : EditorTools::Context
      if @editor_tools_shutdown
        raise EditorTools::Failure.new(EditorTools::Status::Unavailable, "editor tools are shut down")
      end
      root = begin
        File.realpath(@project_root.to_s)
      rescue
        observe_editor_tools_root(nil, nil)
        raise EditorTools::Failure.new(EditorTools::Status::Unavailable, "project root is unavailable")
      end
      stamp = FileRevision.probe(root)
      unless stamp.directory? && stamp.target_type == File::Type::Directory && !stamp.symlink? &&
             File.realpath(root) == root
        observe_editor_tools_root(nil, nil)
        raise EditorTools::Failure.new(EditorTools::Status::Unavailable, "project root is unavailable")
      end
      observe_editor_tools_root(root, stamp)
      EditorTools::Context.new(root, @editor_tools_epoch)
    rescue failure : EditorTools::Failure
      raise failure
    rescue
      observe_editor_tools_root(nil, nil)
      raise EditorTools::Failure.new(EditorTools::Status::Unavailable, "project root is unavailable")
    end

    private def observe_editor_tools_root(root : String?, stamp : FileRevision::Stamp?) : Nil
      if @editor_tools_root_observation_initialized
        changed = if previous_root = @editor_tools_observed_root
                    current_root = root
                    previous_stamp = @editor_tools_observed_root_stamp
                    current_stamp = stamp
                    current_root != previous_root || previous_stamp.nil? || current_stamp.nil? ||
                      current_stamp.not_nil!.identity_changed?(previous_stamp.not_nil!)
                  else
                    !root.nil? || !stamp.nil?
                  end
        retire_editor_tools_context if changed
      end
      @editor_tools_root_observation_initialized = true
      @editor_tools_observed_root = root.try(&.dup)
      @editor_tools_observed_root_stamp = stamp
    end

    private def retire_editor_tools_context : Nil
      @editor_tools_epoch = Random::Secure.hex(16)
      @editor_tools_buffer_refs.clear
      @editor_tools_search_generation &+= 1_u64
    end

    private def execute_editor_tool(request : EditorTools::Request,
                                    permit : EditorTools::ExecutionPermit) : JSON::Any
      context = permit.context
      require_editor_tools_permit!(permit)
      result = case request
               when EditorTools::ListBuffersRequest
                 editor_tools_list_buffers(request, permit)
               when EditorTools::ReadBufferRequest
                 editor_tools_read_buffer(request, permit)
               when EditorTools::FindFilesRequest
                 editor_tools_find_files(request, permit)
               when EditorTools::OpenFileRequest
                 editor_tools_open_file(request, permit)
               when EditorTools::FocusBufferRequest
                 editor_tools_focus_buffer(request, permit)
               when EditorTools::DebugSnapshotRequest
                 editor_tools_debug_snapshot(request, permit)
               else
                 raise EditorTools::Failure.new(EditorTools::Status::InvalidRequest, "unsupported editor tool request")
               end
      require_editor_tools_permit!(permit)
      result
    end

    private def require_editor_tools_permit!(permit : EditorTools::ExecutionPermit) : Nil
      context = permit.context
      unless permit.active?
        current = begin
          editor_tools_current_context
        rescue
          nil
        end
        if current && current.not_nil! != context
          raise EditorTools::Failure.new(EditorTools::Status::Stale, "tool session context changed")
        end
        raise EditorTools::Failure.new(EditorTools::Status::Denied, "tool session is closed")
      end
      current = editor_tools_current_context
      unless current == context
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "tool session context changed")
      end
    rescue failure : EditorTools::Failure
      raise failure
    rescue
      raise EditorTools::Failure.new(EditorTools::Status::Stale, "tool session context changed")
    end

    private def editor_tools_list_buffers(request : EditorTools::ListBuffersRequest,
                                          permit : EditorTools::ExecutionPermit) : JSON::Any
      context = permit.context
      prune_editor_tool_buffer_refs
      entries = [] of NamedTuple(buffer: OpenBuffer, path: String)
      partial = false
      omitted = 0

      @document_session.open_buffers.values.to_a.sort_by(&.path.to_s).each do |buffer|
        require_editor_tools_permit!(permit)
        canonical = canonical_editor_tool_file(buffer.path, context)
        unless canonical
          partial = true
          omitted += 1
          next
        end
        relative = editor_tools_relative_path(canonical, context)
        unless relative
          partial = true
          omitted += 1
          next
        end
        if relative.bytesize > MAX_TOOL_PATH_BYTES
          partial = true
          omitted += 1
          next
        end
        entries << {buffer: buffer, path: relative}
      end

      if entries.size > MAX_BUFFER_REFERENCES
        omitted += entries.size - MAX_BUFFER_REFERENCES
        entries = entries.first(MAX_BUFFER_REFERENCES)
        partial = true
      end

      @editor_tools_buffer_refs.reject! do |_id, reference|
        !entries.any? { |entry| entry[:buffer].same?(reference.owner) }
      end

      page = [] of JSON::Any
      page_start = Math.min(request.offset, entries.size)
      requested_finish = Math.min(request.offset.to_i64 + request.limit, entries.size.to_i64).to_i32
      finish = page_start
      page_bytes = 0
      page_truncated = false
      active_group = @active_editor_group + 1
      while finish < requested_finish
        index = finish
        entry = entries[index]
        buffer = entry[:buffer]
        reference = editor_tool_buffer_reference(buffer)
        reference.refresh_revision!
        views = [] of JSON::Any
        group_indices = [] of JSON::Any
        active_here = false
        editor_tab_groups.each_with_index do |panel, group_index|
          tab = panel.tabs.find { |candidate| candidate.id == buffer.path.to_s }
          next unless tab
          group_indices << JSON::Any.new((group_index + 1).to_i64)
          is_active = panel.active_tab_id == buffer.path.to_s
          active_here ||= group_index == @active_editor_group && is_active
          views << JSON::Any.new({
            "group"  => JSON::Any.new((group_index + 1).to_i64),
            "active" => JSON::Any.new(is_active),
          } of String => JSON::Any)
        end
        row = tool_json_object(
          buffer_id: reference.id,
          revision: reference.revision,
          path: entry[:path],
          language: bounded_tool_text(buffer.language_id || "plaintext", 64)[0],
          modified: buffer.editor.modified?,
          view_count: buffer.views.size,
          group_indices: group_indices,
          views: views,
          active_group: active_here ? active_group : nil
        )
        row_bytes = row.to_json.bytesize
        if page_bytes + row_bytes > MAX_BUFFER_PAGE_BYTES
          partial = true
          page_truncated = true
          break
        end
        page << row
        page_bytes += row_bytes
        finish += 1
      end

      has_more = finish < entries.size || page_truncated
      tool_json_object(
        buffers: page,
        offset: request.offset,
        limit: request.limit,
        total: entries.size,
        omitted: omitted,
        has_more: has_more,
        next_offset: (finish < entries.size) ? finish : nil,
        partial: partial || page_truncated
      )
    end

    private def editor_tools_read_buffer(request : EditorTools::ReadBufferRequest,
                                         permit : EditorTools::ExecutionPermit) : JSON::Any
      context = permit.context
      reference = resolve_editor_tool_buffer(request.buffer_id, context)
      reference.refresh_revision!
      unless reference.revision == request.revision
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "buffer revision changed")
      end
      tree = reference.owner.editor.document.buffer
      line_count = tree.line_count
      first_line = request.start_line - 1
      if first_line < 0 || first_line > line_count
        raise EditorTools::Failure.new(EditorTools::Status::InvalidRequest, "start_line is outside the buffer")
      end
      if request.max_columns > MAX_READ_COLUMNS || request.line_count > MAX_READ_LINES
        raise EditorTools::Failure.new(EditorTools::Status::LimitExceeded, "read fragment exceeds the editor tool limit")
      end

      text_budget = MAX_READ_TEXT_BYTES
      rows = [] of JSON::Any
      line_index = first_line
      first_column = request.start_column
      partial = false
      continuation_line : Int32? = nil
      continuation_column : Int32? = nil

      while line_index < line_count && rows.size < request.line_count
        require_editor_tools_permit!(permit)
        line_length = tree.line_character_length(line_index)
        start_column = rows.empty? ? first_column : 0
        if start_column > line_length
          raise EditorTools::Failure.new(EditorTools::Status::InvalidRequest, "start_column is outside the line")
        end

        requested_columns = Math.min(request.max_columns, line_length - start_column)
        fragment = tree.line_slice(line_index, start_column, requested_columns)
        allowed_bytes = Math.min(text_budget, fragment.bytesize)
        if fragment.bytesize > allowed_bytes
          selected_columns = 0
          selected_bytes = 0
          fragment.each_char do |char|
            break if selected_bytes + char.bytesize > allowed_bytes
            selected_bytes += char.bytesize
            selected_columns += 1
          end
          requested_columns = selected_columns
          fragment = tree.line_slice(line_index, start_column, requested_columns)
          partial = true
        end

        text_budget -= fragment.bytesize
        end_column = start_column + requested_columns
        line_complete = end_column >= line_length
        rows << tool_json_object(
          line: line_index + 1,
          start_column: start_column,
          end_column: end_column,
          text: fragment,
          complete: line_complete,
          next_column: line_complete ? nil : end_column
        )

        unless line_complete
          partial = true
          continuation_line = line_index + 1
          continuation_column = end_column
          break
        end

        line_index += 1
        if text_budget == 0 && line_index < line_count && rows.size < request.line_count
          partial = true
          continuation_line = line_index + 1
          continuation_column = 0
          break
        end
      end

      if continuation_line.nil? && line_index < line_count && rows.size >= request.line_count
        partial = true
        continuation_line = line_index + 1
        continuation_column = 0
      end

      require_editor_tools_permit!(permit)
      reference.refresh_revision!
      unless reference.revision == request.revision
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "buffer revision changed during read")
      end
      canonical = canonical_editor_tool_file(reference.owner.path, context)
      unless canonical
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "buffer path can no longer be proven inside the project")
      end
      relative = editor_tools_relative_path(canonical, context)
      unless relative && relative.bytesize <= MAX_TOOL_PATH_BYTES
        raise EditorTools::Failure.new(EditorTools::Status::LimitExceeded, "buffer path exceeds its output bound")
      end
      tool_json_object(
        buffer_id: reference.id,
        revision: reference.revision,
        path: relative,
        start_line: request.start_line,
        lines: rows,
        complete: !partial,
        partial: partial,
        continuation: continuation_line ? tool_json_object(
          start_line: continuation_line,
          start_column: continuation_column || 0
        ) : nil
      )
    end

    private def editor_tools_find_files(request : EditorTools::FindFilesRequest,
                                        permit : EditorTools::ExecutionPermit) : JSON::Any
      context = permit.context
      unless request.query.valid_encoding? && request.query.bytesize <= 1024
        raise EditorTools::Failure.new(EditorTools::Status::LimitExceeded, "search query exceeds its bound")
      end
      cancellation = QuickOpenSearch::Cancellation.new
      @editor_tools_search_generation &+= 1_u64
      generation = @editor_tools_search_generation
      checkpoint = -> do
        unless editor_tools_permit_current?(permit)
          cancellation.cancel
        end
      end
      root = Path.new(context.project_root)
      index = QuickOpenSearch.index_file_paths(
        root,
        generation: generation,
        cancellation: cancellation,
        checkpoint: checkpoint
      )
      require_editor_tools_permit!(permit)
      result = QuickOpenSearch.rank_file_paths(
        index,
        request.query,
        generation: generation,
        max_results: request.limit + 1,
        cancellation: cancellation,
        checkpoint: checkpoint
      )
      require_editor_tools_permit!(permit)

      matches = [] of JSON::Any
      partial = result.partial? || result.cancelled? || result.query_too_long?
      omitted = 0
      page_bytes = 0
      response_truncated = false
      result.matches.each do |match|
        require_editor_tools_permit!(permit)
        canonical = canonical_editor_tool_file(match.path, context)
        unless canonical
          partial = true
          next
        end
        relative = editor_tools_relative_path(canonical, context)
        unless relative
          partial = true
          omitted += 1
          next
        end
        if relative.bytesize > MAX_TOOL_PATH_BYTES
          partial = true
          omitted += 1
          next
        end
        if matches.size >= request.limit
          partial = true
          break
        end
        row = tool_json_object(path: relative)
        if page_bytes + row.to_json.bytesize > MAX_BUFFER_PAGE_BYTES
          partial = true
          response_truncated = true
          break
        end
        matches << row
        page_bytes += row.to_json.bytesize
      end
      tool_json_object(
        query: request.query,
        paths: matches,
        partial: partial,
        cancelled: result.cancelled?,
        query_too_long: result.query_too_long?,
        omitted: omitted,
        has_more: response_truncated || result.matches.size > request.limit,
        response_truncated: response_truncated
      )
    end

    private def editor_tools_open_file(request : EditorTools::OpenFileRequest,
                                       permit : EditorTools::ExecutionPermit) : JSON::Any
      context = permit.context
      require_editor_tools_permit!(permit)
      require_editor_tools_normal_mode!
      requested = resolve_project_root_path(request.path)
      path = begin
        resolve_path_within_project_root(requested)
      rescue
        raise EditorTools::Failure.new(EditorTools::Status::Denied, "file path is outside the project")
      end
      canonical = canonical_editor_tool_file(path, context)
      unless canonical
        raise EditorTools::Failure.new(EditorTools::Status::NotFound, "in-project regular file was not found")
      end
      path = Path.new(canonical)
      stamp = FileRevision.probe(path)
      unless stamp.regular? && stamp.size <= DocumentOrchestrator::MAX_FILE_BYTES
        raise EditorTools::Failure.new(EditorTools::Status::Unavailable, "file cannot be opened as bounded text")
      end
      relative = editor_tools_relative_path(path.to_s, context)
      unless relative
        raise EditorTools::Failure.new(EditorTools::Status::Denied, "file path is not representable inside the project")
      end
      if relative.not_nil!.bytesize > MAX_TOOL_PATH_BYTES
        raise EditorTools::Failure.new(EditorTools::Status::LimitExceeded, "opened path exceeds its output bound")
      end
      require_editor_tools_permit!(permit)
      require_editor_tools_normal_mode!

      guard = -> do
        permit.active? && editor_tools_context_current?(context) &&
        active_input_mode == InputModeController::InputMode::Normal &&
        begin
          resolve_path_within_project_root(requested).to_s == path.to_s &&
          FileRevision.probe(path).same_as?(stamp)
        rescue
          false
        end
      end
      require_editor_tools_permit!(permit)
      opened = open_file(path, guard: guard, expected_stamp: stamp)
      require_editor_tools_permit!(permit)
      unless opened
        unless active_input_mode == InputModeController::InputMode::Normal
          raise EditorTools::Failure.new(EditorTools::Status::Busy, "navigation is blocked by the active modal")
        end
        current_stamp = FileRevision.probe(path)
        unless current_stamp.same_as?(stamp)
          raise EditorTools::Failure.new(EditorTools::Status::Stale, "file identity changed before open")
        end
        raise EditorTools::Failure.new(EditorTools::Status::Unavailable, "file could not be opened as bounded text")
      end
      relative_after = editor_tools_relative_path(path.to_s, context)
      unless relative_after == relative
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "opened path identity changed")
      end
      tool_json_object(opened: true, path: relative.not_nil!)
    end

    private def editor_tools_focus_buffer(request : EditorTools::FocusBufferRequest,
                                          permit : EditorTools::ExecutionPermit) : JSON::Any
      context = permit.context
      require_editor_tools_permit!(permit)
      require_editor_tools_normal_mode!
      reference = resolve_editor_tool_buffer(request.buffer_id, context)
      reference.refresh_revision!
      unless reference.revision == request.revision
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "buffer revision changed")
      end
      require_editor_tools_permit!(permit)
      require_editor_tools_normal_mode!
      require_editor_tools_permit!(permit)
      switch_to_tab_by_position_buffer(reference.owner_path)
      require_editor_tools_permit!(permit)
      tool_json_object(focused: true, buffer_id: reference.id, revision: reference.revision)
    end

    private def editor_tools_debug_snapshot(request : EditorTools::DebugSnapshotRequest,
                                            permit : EditorTools::ExecutionPermit) : JSON::Any
      context = permit.context
      require_editor_tools_permit!(permit)
      inspection = @debug_controller.inspection_snapshot
      require_editor_tools_permit!(permit)
      origin_root = inspection.origin_project_root
      origin_stamp = inspection.origin_project_stamp
      unless origin_root && origin_stamp
        raise EditorTools::Failure.new(EditorTools::Status::Unavailable, "debugger project is not bound")
      end
      current_root_stamp = @editor_tools_observed_root_stamp
      unless @editor_tools_observed_root == context.project_root && current_root_stamp
        raise EditorTools::Failure.new(EditorTools::Status::Unavailable, "project root identity is unavailable")
      end
      unless origin_root.not_nil! == context.project_root &&
             origin_stamp.not_nil!.same_target?(current_root_stamp.not_nil!)
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "debugger observation belongs to another project")
      end
      state = inspection.state
      budget = DebugRowsBudget.new
      thread_partial = false
      frame_partial = false
      variable_partial = false

      thread_rows = [] of JSON::Any
      inspection.threads.each_with_index do |thread, index|
        if index >= request.limit
          thread_partial = true
          break
        end
        name, name_clipped = bounded_tool_text(thread.name, 128)
        row = tool_json_object(
          dap_thread_id: thread.id.to_s,
          name: name,
          execution: thread.execution.to_s.downcase,
          name_clipped: name_clipped
        )
        unless budget.append(thread_rows, row)
          thread_partial = true
          break
        end
      end

      frame_rows = [] of JSON::Any
      frames = inspection.stack_fresh ? inspection.frames : [] of DebugController::FrameView
      frames.each_with_index do |frame, index|
        if index >= request.limit
          frame_partial = true
          break
        end
        frame_name, frame_name_clipped = bounded_tool_text(frame.name, 160)
        source_path, source_path_clipped = safe_debug_source_path(frame.source_path, context)
        source_name, source_name_clipped = bounded_optional_tool_text(frame.source_name, 128)
        unavailable_reason, reason_clipped = bounded_optional_tool_text(frame.unavailable_reason, 256)
        source_line = frame.dap_line
        row = tool_json_object(
          function: frame_name,
          dap_frame_id: frame.id.to_s,
          source_path: source_path,
          source_name: source_name,
          dap_line: source_line,
          editor_line: frame.editor_line,
          selected: frame.selected,
          unavailable_reason: unavailable_reason,
          function_clipped: frame_name_clipped,
          source_name_clipped: source_name_clipped,
          source_path_clipped: source_path_clipped,
          unavailable_reason_clipped: reason_clipped
        )
        unless budget.append(frame_rows, row)
          frame_partial = true
          break
        end
      end

      variable_rows = [] of JSON::Any
      nodes = inspection.variables.nodes
      root_ids = inspection.variables.roots.map(&.id).to_set
      nodes.each_with_index do |node, index|
        if index >= request.limit
          variable_partial = true
          break
        end
        name, name_clipped = bounded_tool_text(node.name, 128)
        value, value_clipped = bounded_tool_text(node.value, 192)
        type, type_clipped = bounded_optional_tool_text(node.type, 64)
        reason, reason_clipped = bounded_optional_tool_text(node.reason, 256)
        row = tool_json_object(
          observation_node_id: node.id,
          parent_observation_node_id: node.parent_id,
          root: root_ids.includes?(node.id),
          name: name,
          value: value,
          type: type,
          depth: node.depth,
          state: node.load_state.to_s.downcase,
          child_count: node.child_ids.size,
          reason: reason,
          value_truncated: node.value_truncated || value_clipped,
          name_clipped: name_clipped,
          value_clipped: value_clipped,
          type_clipped: type_clipped,
          reason_clipped: reason_clipped
        )
        unless budget.append(variable_rows, row)
          variable_partial = true
          break
        end
      end

      require_editor_tools_permit!(permit)
      overall_partial = thread_partial || frame_partial || variable_partial
      scopes_error, scopes_error_clipped = bounded_optional_tool_text(inspection.scopes_error, 256)
      truncation_reason, truncation_reason_clipped = bounded_optional_tool_text(inspection.variables.truncation_reason, 256)
      tool_json_object(
        state: {
          lifecycle:          state.lifecycle.to_s.downcase,
          execution:          state.execution.to_s.downcase,
          target_liveness:    state.target_liveness.to_s.downcase,
          session_generation: state.session_generation.to_s,
          project_generation: state.project_generation.to_s,
          selected_thread_id: state.selected_thread_id.try(&.to_s),
        },
        observation: {
          generation:           inspection.generation.to_s,
          variable_generation:  inspection.variable_generation.to_s,
          stack_fresh:          inspection.stack_fresh,
          stack_completeness:   "unknown",
          scopes_state:         scope_state(inspection),
          scopes_error:         scopes_error,
          scopes_error_clipped: scopes_error_clipped,
        },
        threads: {items: thread_rows, partial: thread_partial},
        frames: {
          items:        frame_rows,
          fresh:        inspection.stack_fresh,
          completeness: "unknown",
          partial:      frame_partial,
        },
        variables: {
          items:                     variable_rows,
          loaded:                    inspection.scopes_loaded,
          pending:                   inspection.scopes_request_pending,
          partial:                   variable_partial,
          source_partial:            inspection.variables.partial?,
          source_truncated:          inspection.variables.truncated?,
          truncation_reason:         truncation_reason,
          truncation_reason_clipped: truncation_reason_clipped,
        },
        partial: overall_partial
      )
    end

    private def scope_state(snapshot : DebugController::InspectionSnapshot) : String
      if snapshot.scopes_request_pending
        "pending"
      elsif snapshot.scopes_error
        "failed"
      elsif snapshot.scopes_loaded
        "loaded"
      else
        "unloaded"
      end
    end

    private def safe_debug_source_path(source_path : String?, context : EditorTools::Context) : Tuple(String?, Bool)
      return {nil, false} unless source_path
      path_text = source_path.not_nil!
      return {nil, true} unless editor_tools_wire_path_text?(path_text)
      candidate = Path.new(path_text)
      candidate = Path.new(context.project_root) / candidate unless candidate.absolute?
      canonical = canonical_editor_tool_file(candidate, context)
      return {nil, false} unless canonical
      relative = editor_tools_relative_path(canonical.not_nil!, context)
      return {nil, true} unless relative
      return {nil, true} if relative.not_nil!.bytesize > MAX_TOOL_PATH_BYTES
      {relative, false}
    rescue
      {nil, true}
    end

    private def editor_tools_context_current?(context : EditorTools::Context) : Bool
      editor_tools_current_context == context
    rescue
      false
    end

    private def editor_tools_permit_current?(permit : EditorTools::ExecutionPermit) : Bool
      permit.active? && editor_tools_context_current?(permit.context)
    rescue
      false
    end

    private def require_editor_tools_normal_mode! : Nil
      unless active_input_mode == InputModeController::InputMode::Normal
        raise EditorTools::Failure.new(EditorTools::Status::Busy, "navigation is blocked by the active modal")
      end
    end

    private def prune_editor_tool_buffer_refs : Nil
      @editor_tools_buffer_refs.reject! do |_id, reference|
        buffer = @document_session.open_buffers[reference.owner_path]?
        !buffer || !buffer.same?(reference.owner) || buffer.path.to_s != reference.owner_path
      end
    end

    private def editor_tool_buffer_reference(buffer : OpenBuffer) : BufferReference
      prune_editor_tool_buffer_refs
      if existing = @editor_tools_buffer_refs.values.find(&.owns?(buffer))
        return existing
      end
      if @editor_tools_buffer_refs.size >= MAX_BUFFER_REFERENCES
        raise EditorTools::Failure.new(EditorTools::Status::LimitExceeded, "buffer identity registry is full")
      end
      reference = BufferReference.new(buffer)
      @editor_tools_buffer_refs[reference.id] = reference
      reference
    end

    private def resolve_editor_tool_buffer(id : String,
                                           context : EditorTools::Context) : BufferReference
      prune_editor_tool_buffer_refs
      reference = @editor_tools_buffer_refs[id]?
      raise EditorTools::Failure.new(EditorTools::Status::NotFound, "buffer identity was not found") unless reference
      buffer = @document_session.open_buffers[reference.not_nil!.owner_path]?
      unless buffer && reference.not_nil!.owns?(buffer.not_nil!)
        @editor_tools_buffer_refs.delete(id)
        raise EditorTools::Failure.new(EditorTools::Status::NotFound, "buffer is no longer open")
      end
      unless canonical_editor_tool_file(reference.not_nil!.owner_path, context)
        raise EditorTools::Failure.new(EditorTools::Status::Denied, "buffer path cannot be proven inside the project")
      end
      reference.not_nil!
    end

    private def canonical_editor_tool_file(path : Path | String,
                                           context : EditorTools::Context) : String?
      candidate = Path.new(path.to_s)
      info = File.info?(candidate, follow_symlinks: false)
      return unless info && info.file? && !info.symlink?
      real = File.realpath(candidate.to_s)
      return unless path_within_editor_tools_root?(real, context.project_root)
      target = File.info?(real, follow_symlinks: false)
      return unless target && target.file? && !target.symlink?
      return unless File.realpath(candidate.to_s) == real
      real
    rescue
      nil
    end

    private def editor_tools_relative_path(path : String,
                                           context : EditorTools::Context) : String?
      return unless path_within_editor_tools_root?(path, context.project_root)
      return unless editor_tools_wire_path_text?(path)
      relative = Path.new(path).relative_to(Path.new(context.project_root)).to_s
      return unless editor_tools_wire_path_text?(relative)
      relative
    rescue
      nil
    end

    private def editor_tools_wire_path_text?(path : String) : Bool
      return false unless path.valid_encoding?
      path.each_char do |char|
        return false if EditorTools.control_char?(char)
      end
      true
    end

    private def path_within_editor_tools_root?(candidate : String, root : String) : Bool
      return true if candidate == root
      prefix = root.ends_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      candidate.starts_with?(prefix)
    end

    private def bounded_tool_text(value : String?, max_bytes : Int32) : Tuple(String, Bool)
      source = value || ""
      return {"<invalid UTF-8>", true} unless source.valid_encoding?
      clipped = false
      result = String.build(max_bytes) do |output|
        source.each_char do |char|
          replacement = char.ord < 0x20 || char.ord.in?(0x7f..0x9f) ? ' ' : char
          if output.bytesize + replacement.bytesize > max_bytes
            clipped = true
            break
          end
          output << replacement
        end
      end
      {result, clipped}
    end

    private def bounded_optional_tool_text(value : String?, max_bytes : Int32) : Tuple(String?, Bool)
      return {nil, false} unless value
      text, clipped = bounded_tool_text(value, max_bytes)
      {text, clipped}
    end

    private def tool_json_object(**fields) : JSON::Any
      JSON.parse(fields.to_json)
    end
  end
end
