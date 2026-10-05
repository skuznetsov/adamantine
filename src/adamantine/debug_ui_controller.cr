require "json"
require "random/secure"

require "./debug_controller"
require "./debug_workspace"
require "./debug_profile_store"
require "./debug_variable_presenter"

module Adamantine
  # A bounded, read-only display buffer for adapter-owned source. Sparse
  # checkpoints keep scrolling work bounded even when the source has millions
  # of short lines; this text never becomes an OpenBuffer or editor document.
  class DebugReadOnlySource
    CHECKPOINT_BYTES = 64 * 1024
    MAX_LINE_BYTES   = 512

    getter checksum_status : String
    getter outdated : Bool
    getter line_count : Int32

    @text : String
    @label : String
    @reason : String?
    @checkpoints : Array({Int32, Int32}) = [] of {Int32, Int32}
    @last_checkpoint_byte = 0

    def initialize(label : String, reason : String?, @checksum_status : String,
                   @outdated : Bool, @text : String)
      @label = label.dup
      @reason = reason.try(&.dup)
      raise ArgumentError.new("adapter source exceeds the read-only view limit") if @text.bytesize > DebugController::SourceBaseline::MAX_BYTES
      raise ArgumentError.new("adapter source is not valid UTF-8") unless @text.valid_encoding?
      @checkpoints << {0, 0}
      newline_count = 0
      index = 0
      while index < @text.bytesize
        if @text.byte_at(index) == '\n'.ord.to_u8
          newline_count += 1
          next_line_start = index + 1
          if next_line_start - @last_checkpoint_byte >= CHECKPOINT_BYTES
            @checkpoints << {newline_count, next_line_start}
            @last_checkpoint_byte = next_line_start
          end
        end
        index += 1
      end
      @line_count = if @text.empty?
                      0
                    elsif @text.byte_at(@text.bytesize - 1) == '\n'.ord.to_u8
                      newline_count
                    else
                      newline_count + 1
                    end
    end

    def label : String
      @label.dup
    end

    def line(index : Int32, max_bytes : Int32 = MAX_LINE_BYTES) : String
      return "" unless index >= 0 && index < @line_count
      byte_limit = max_bytes.clamp(0, MAX_LINE_BYTES)
      return "" if byte_limit == 0
      checkpoint = @checkpoints.first
      @checkpoints.each do |candidate|
        break if candidate[0] > index
        checkpoint = candidate
      end
      line_index, byte_index = checkpoint
      while line_index < index
        line_index += 1 if @text.byte_at(byte_index) == '\n'.ord.to_u8
        byte_index += 1
      end
      start = byte_index
      prefix_bytes = 0
      prefix_limit = byte_limit >= 3 ? byte_limit - 3 : byte_limit
      while byte_index < @text.bytesize && @text.byte_at(byte_index) != '\n'.ord.to_u8
        character_bytes = utf8_character_bytes(@text.byte_at(byte_index))
        break if prefix_bytes + character_bytes > prefix_limit
        prefix_bytes += character_bytes
        byte_index += character_bytes
      end
      prefix = @text.byte_slice(start, prefix_bytes) || ""
      if byte_limit >= 3 && byte_index < @text.bytesize && @text.byte_at(byte_index) != '\n'.ord.to_u8
        prefix + "…"
      else
        prefix
      end
    end

    def reason : String?
      @reason.try(&.dup)
    end

    private def utf8_character_bytes(first_byte : UInt8) : Int32
      return 1 if first_byte < 0x80
      return 2 if (first_byte & 0xe0) == 0xc0
      return 3 if (first_byte & 0xf0) == 0xe0
      4
    end
  end

  enum DebugAppTransitionKind
    Quit
    ChangeRoot
  end

  struct DebugAppTransition
    getter kind : DebugAppTransitionKind
    getter root : Path?

    def initialize(@kind : DebugAppTransitionKind, root : Path? = nil)
      @root = root.try { |path| Path.new(path.to_s) }
    end
  end

  # Stable, ID-backed projection for the dock's visible Variables tree. A
  # snapshot's flat node array is insertion ordered, so hierarchy is recovered
  # only from the authoritative roots/child IDs. It is rebuilt per variable
  # generation, never per rendered row.
  class DebugVariableProjection
    MAX_DEPTH = 32

    struct Row
      getter node_id : String?
      getter depth : Int32
      getter message : String?

      def initialize(@node_id : String?, @depth : Int32 = 0, message : String? = nil)
        @message = message.try(&.dup)
      end

      def message : String?
        @message.try(&.dup)
      end
    end

    @rows : Array(Row) = [] of Row
    @nodes : Hash(String, Debugging::DebugVariableNode) = {} of String => Debugging::DebugVariableNode

    def rebuild(snapshot : Debugging::DebugVariableSnapshot, expanded_ids : Set(String)) : Nil
      @rows.clear
      @nodes.clear
      snapshot.nodes.each { |node| @nodes[node.id] = node }
      @rows << Row.new(nil, message: "Partial: #{snapshot.truncation_reason || "some values omitted"}") if snapshot.truncated?

      visited = Set(String).new
      snapshot.roots.each do |root|
        next unless root.parent_id.nil?
        append_subtree(root, 0, expanded_ids, visited)
      end
    end

    def rows : Array(Row)
      @rows.dup
    end

    def row_count : Int32
      @rows.size
    end

    def row_index(node_id : String) : Int32?
      @rows.index { |row| row.node_id == node_id }
    end

    def row(index : Int32) : Row?
      @rows[index]?
    end

    def node(id : String) : Debugging::DebugVariableNode?
      @nodes[id]?
    end

    def includes_node?(id : String) : Bool
      @nodes.has_key?(id)
    end

    # Expansion choices belong to loaded node identities, not current
    # visibility. A collapsed ancestor must not erase a descendant's choice.
    def retain_existing_expansions(snapshot : Debugging::DebugVariableSnapshot,
                                   expanded_ids : Set(String)) : Nil
      available = Set(String).new
      snapshot.nodes.each { |node| available << node.id }
      expanded_ids.select! { |id| available.includes?(id) }
    end

    private def append_subtree(node : Debugging::DebugVariableNode, depth : Int32,
                               expanded_ids : Set(String), visited : Set(String)) : Nil
      return if depth > MAX_DEPTH || visited.includes?(node.id)
      visited << node.id
      @rows << Row.new(node.id, depth)
      return unless expanded_ids.includes?(node.id)

      node.child_ids.each do |child_id|
        child = @nodes[child_id]?
        next unless child && child.not_nil!.parent_id == node.id
        append_subtree(child.not_nil!, depth + 1, expanded_ids, visited)
      end
    end
  end

  # Keeps the user's current variable identity stable while async child pages
  # insert rows before it. The UI restores by ID when the row is visible.
  class DebugVariableSelection
    @selected_id : String? = nil

    def select(projection : DebugVariableProjection, row_index : Int32) : Nil
      @selected_id = projection.row(row_index).try(&.node_id).try(&.dup)
    end

    def restore_index(projection : DebugVariableProjection) : Int32?
      id = @selected_id
      return nil unless id
      projection.row_index(id.not_nil!)
    end

    def reconcile(projection : DebugVariableProjection) : Nil
      id = @selected_id
      return unless id
      @selected_id = nil unless projection.includes_node?(id.not_nil!)
    end
  end

  # App-facing adapter for the UI-agnostic DebugController.  All protocol
  # pumping happens at the App event boundary; renderers consume only the
  # latest immutable snapshot.
  module DebugUiController
    enum DebugModalKind
      Profile
      Review
      Dirty
      Watch
      WatchConfirm
      Source
      ValueDetail
      AppTransition
    end

    DEBUG_BASELINE_MAX_ROOTS      = 32
    DEBUG_BASELINE_MAX_BYTES      = 32_i64 * 1024 * 1024
    DEBUG_PROFILE_MIN_HEIGHT      = 10
    DEBUG_VALUE_DETAIL_MIN_HEIGHT = 10
    DEBUG_STOCK_REVIEW_MIN_HEIGHT = 14
    # The longest required provider-effect disclosure is 69 cells; the modal
    # reserves four cells horizontally inside its outer width.
    DEBUG_STOCK_REVIEW_MIN_WIDTH = 77

    @debug_controller : DebugController
    @debug_workspace : DebugWorkspace
    @debug_profile_store : Debugging::DebugProfileStore
    @debug_snapshot : DebugController::Snapshot
    @debug_profile_rows : Array(Debugging::LaunchProfile) = [] of Debugging::LaunchProfile
    @debug_form_fields : Array(EditableInput) = [] of EditableInput
    @debug_form_index : Int32 = 0
    @debug_form_profile_template : Debugging::LaunchProfile? = nil
    @debug_native_values : Debugging::NativeValueProvider = Debugging::NativeValueProvider::Generic
    @debug_profile_hint : String? = nil
    @debug_modal_kind : DebugModalKind? = nil
    @debug_modal_overlay : Tui::OverlayRenderer? = nil
    @debug_modal_error : String? = nil
    @debug_candidate_profile : Debugging::LaunchProfile? = nil
    @debug_pending_review : DebugController::LaunchReview? = nil
    @debug_dirty_choice : Int32 = 0
    @debug_projected_generation : UInt64 = UInt64::MAX
    @debug_variable_projected_generation : UInt64 = UInt64::MAX
    @debug_variable_projection : DebugVariableProjection = DebugVariableProjection.new
    @debug_variable_selection : DebugVariableSelection = DebugVariableSelection.new
    @debug_variable_expanded_ids : Set(String) = Set(String).new
    @debug_scopes_request_frame_id : Int64? = nil
    @debug_scopes_request_error : String? = nil
    @debug_project_generation : UInt64 = 0_u64
    @debug_readonly_source : DebugReadOnlySource? = nil
    @debug_source_scroll : Int32 = 0
    @debug_source_cached_scroll : Int32? = nil
    @debug_source_cached_width : Int32? = nil
    @debug_source_cached_rows : Int32? = nil
    @debug_source_cached_lines : Array(String) = [] of String
    @debug_source_open_states : Hash(Debugging::DebugSourceKey, String) = {} of Debugging::DebugSourceKey => String
    @debug_source_row_views : Array(DebugController::SourceView) = [] of DebugController::SourceView
    @debug_source_row_keys : Array(Debugging::DebugSourceKey) = [] of Debugging::DebugSourceKey
    @debug_source_projected_generation : UInt64 = UInt64::MAX
    @debug_pending_watch_id : String? = nil
    @debug_value_detail_node_id : String? = nil
    @debug_value_detail_format : Debugging::DebugValueFormat = Debugging::DebugValueFormat::Summary
    @debug_value_detail_render : Debugging::DebugValueRender? = nil
    @debug_value_detail_lines : Array(String) = [] of String
    @debug_value_detail_node_label : String = "variable unavailable"
    @debug_value_detail_type_label : String = "type unavailable"
    @debug_value_detail_cache_key : Tuple(String, UInt64, UInt64, Int64?, UInt64, UInt64, DebugController::ValueFormatStatus?, Debugging::DebugValueFormat, Int32)? = nil
    @debug_value_detail_origin_key : Tuple(UInt64, UInt64, Int64?, UInt64)? = nil
    @debug_value_detail_display_limited : Bool = false
    @debug_value_detail_scroll : Int32 = 0
    @debug_value_detail_content_width : Int32 = 80
    @debug_pending_transition : DebugAppTransition? = nil
    @debug_transition_stop_requested : Bool = false
    @debug_transition_cancelled : Bool = false
    @debug_transition_approvals : Hash(String, CloseTarget) = {} of String => CloseTarget
    @debug_polling : Bool = false
    @debug_gutter_callbacks : Set(UInt64) = Set(UInt64).new
    @debug_dock_visible : Bool = false

    private def initialize_debug_ui : Nil
      @debug_workspace.panel.on_viewport_request do |pane, offset, limit|
        debug_project_panel_page(pane, offset, limit)
      end
      @debug_workspace.panel.on_row_selected do |pane, index|
        debug_panel_row_selected(pane, index)
      end
      @debug_workspace.panel.on_row_action do |pane, index, action|
        debug_panel_row_action(pane, index, action)
      end
      @debug_workspace.panel.on_hide { debug_hide_panel }
      @debug_workspace.panel.summary = "#{key_hint("debug.start_continue", "unbound")} reviews a launch profile; #{key_hint("debug.toggle_breakpoint", "unbound")} adds a breakpoint; #{key_hint("app.command_palette", "unbound")} discovers actions"
      @debug_workspace.panel.error = nil
    end

    private def start_debug_polling : Nil
      return if @debug_polling
      @debug_polling = true
      spawn do
        while @debug_polling
          sleep 100.milliseconds
          wakeup if @debug_polling
        end
      end
    end

    private def stop_debug_polling : Nil
      @debug_polling = false
    end

    private def close_debug_ui : Nil
      stop_debug_polling
      close_debug_modal
      @debug_controller.close
    end

    private def debug_poll_and_project : Nil
      @debug_snapshot = @debug_controller.poll
      debug_advance_pending_transition
      return if @debug_snapshot.generation == @debug_projected_generation
      @debug_projected_generation = @debug_snapshot.generation
      debug_refresh_value_detail if @debug_modal_kind == DebugModalKind::ValueDetail
      debug_project_summary
      debug_refresh_source_rows
      debug_project_panel_page(
        @debug_workspace.panel.selected_pane,
        @debug_workspace.panel.first_visible_row(@debug_workspace.panel.selected_pane),
        [@debug_workspace.panel.viewport_capacity, DebugPanel::MAX_PAGE_LINES].min
      )
      debug_project_gutters
      mark_dirty!
    rescue ex
      @status_log.error("Debugger UI refresh failed: #{debug_ui_text(ex.message || ex.class.name, 256)}")
    end

    private def debug_project_summary : Nil
      state = @debug_snapshot.state
      location = case state.execution
                 when DebugSessionState::Execution::Stopped       then "Stopped"
                 when DebugSessionState::Execution::Partial       then "Partially stopped"
                 when DebugSessionState::Execution::Running       then "Running"
                 when DebugSessionState::Execution::ResumePending then "Resume pending"
                 when DebugSessionState::Execution::PausePending  then "Pause pending"
                 else                                                  "Execution state unknown"
                 end
      lifecycle = state.lifecycle.to_s
      target = state.target_liveness.to_s
      @debug_workspace.panel.summary = "#{lifecycle} · #{location} · target #{target}"
      message = @debug_snapshot.last_error
      if message.nil? && @debug_snapshot.cleanup_pending
        message = "Adapter cleanup is pending; target exit is not confirmed"
      end
      if message.nil? && (scope_error = @debug_snapshot.scopes_error)
        message = "Scopes unavailable: #{scope_error}"
      end
      if message.nil?
        selected_frame = state.selected_frame_id.try { |id| @debug_snapshot.frames.find { |frame| frame.id == id } }
        if reason = selected_frame.try(&.unavailable_reason)
          message = "Frame source unavailable: #{reason}"
        end
      end
      @debug_workspace.panel.error = message
    end

    private def debug_project_panel_page(pane : DebugPanel::Pane, offset : Int32, limit : Int32) : Nil
      debug_ensure_variable_projection if pane.variables?
      total = debug_panel_row_count(pane)
      rows = [] of String
      return @debug_workspace.panel.set_page(pane, offset, total, rows) if limit <= 0 || total <= 0
      effective_offset = pane.variables? ? @debug_workspace.panel.first_visible_row(pane) : offset
      finish = {effective_offset + limit, total}.min
      row_width = @debug_workspace.panel.rect.width > 0 ? Math.max(@debug_workspace.panel.rect.width - 2, 0) : 512
      effective_offset.upto(finish - 1) { |index| rows << debug_panel_row(pane, index, row_width) }
      @debug_workspace.panel.set_page(pane, effective_offset, total, rows)
    end

    private def debug_panel_row_count(pane : DebugPanel::Pane) : Int32
      case pane
      when .stack?
        @debug_snapshot.frames.size
      when .threads?
        @debug_snapshot.threads.size
      when .variables?
        debug_ensure_variable_projection
        count = @debug_variable_projection.row_count
        count > 0 ? count : (@debug_snapshot.scopes_loaded || @debug_snapshot.scopes_request_pending ||
          @debug_snapshot.scopes_error || @debug_scopes_request_error || debug_can_open_scopes? ? 1 : 0)
      when .watch?
        @debug_snapshot.watches.size
      when .breakpoints?
        @debug_snapshot.breakpoints.size
      when .sources?
        debug_source_visible_count
      when .output?
        @debug_snapshot.output.size + (@debug_snapshot.output_dropped > 0 ? 1 : 0)
      else
        0
      end
    end

    private def debug_panel_row(pane : DebugPanel::Pane, index : Int32, max_cells : Int32 = 512) : String
      case pane
      when .stack?
        frame = @debug_snapshot.frames[index]?
        return "[stale frame]" unless frame
        prefix = frame.selected ? "▶ " : "  "
        source = frame.source_name || frame.source_path.try { |path| File.basename(path) } || "source unavailable"
        source = File.basename(source)
        line_suffix = frame.dap_line.try { |line| ":#{line}" } || ""
        separator = " · "
        fixed_width = Tui::Unicode.display_width(prefix) + Tui::Unicode.display_width(separator) +
                      Tui::Unicode.display_width(line_suffix)
        location_width = Math.min(Tui::Unicode.display_width(source) + Tui::Unicode.display_width(line_suffix),
          Math.max(max_cells - fixed_width - 1, 0))
        source_width = Math.max(location_width - Tui::Unicode.display_width(line_suffix), 0)
        source = Debugging::DebugVariablePresenter.truncate(source, source_width)
        location = "#{source}#{line_suffix}"
        name_width = max_cells - Tui::Unicode.display_width(prefix + location + separator)
        return Debugging::DebugVariablePresenter.truncate("#{prefix}#{location}", max_cells) if name_width <= 0
        name = Debugging::DebugVariablePresenter.truncate(frame.name, name_width)
        Debugging::DebugVariablePresenter.truncate("#{prefix}#{name}#{separator}#{location}", max_cells)
      when .threads?
        thread = @debug_snapshot.threads[index]?
        return "[thread unavailable]" unless thread
        selected = @debug_snapshot.state.selected_thread_id == thread.id ? "▶ " : "  "
        debug_ui_text("#{selected}#{thread.id} · #{thread.name} · #{thread.execution}", 512)
      when .variables?
        debug_ensure_variable_projection
        row = @debug_variable_projection.row(index)
        unless row
          return debug_variable_placeholder(max_cells)
        end
        return Debugging::DebugVariablePresenter.truncate(row.not_nil!.message.not_nil!, max_cells) if row.not_nil!.message
        node = @debug_variable_projection.node(row.not_nil!.node_id.not_nil!)
        return "[variable unavailable]" unless node
        expanded = @debug_variable_expanded_ids.includes?(node.not_nil!.id)
        Debugging::DebugVariablePresenter.row(node.not_nil!, row.not_nil!.depth, expanded, max_cells)
      when .watch?
        watch = @debug_snapshot.watches[index]?
        return "[watch unavailable]" unless watch
        value = watch.result || watch.reason || watch.status.to_s
        type = watch.type ? " (#{watch.type})" : ""
        debug_ui_text("#{watch.expression} = #{value}#{type}", 512)
      when .breakpoints?
        row = @debug_snapshot.breakpoints[index]?
        return "[breakpoint unavailable]" unless row
        path = row.source_key.local_path || "adapter-owned source"
        bp = row.breakpoint
        line = bp.resolved_line || bp.requested_line
        reason = bp.reason ? " · #{bp.reason}" : ""
        enabled = bp.enabled ? "" : "disabled · "
        debug_ui_text("#{path}:#{line + 1} · #{enabled}#{bp.status}#{reason}", 512)
      when .output?
        if @debug_snapshot.output_dropped > 0 && index == 0
          return "#{@debug_snapshot.output_dropped} older output rows dropped"
        end
        output_index = index - (@debug_snapshot.output_dropped > 0 ? 1 : 0)
        item = @debug_snapshot.output[output_index]?
        return "[output unavailable]" unless item
        debug_ui_text("#{item.category}: #{item.text}", 512)
      when .sources?
        debug_refresh_source_rows
        if source = @debug_source_row_views[index]?
          return debug_source_row_text(source)
        end
        key_index = index - @debug_source_row_views.size
        key = @debug_source_row_keys[key_index]?
        return "[source unavailable]" unless key
        state = @debug_source_open_states[key.not_nil!]? || "Unavailable: request status lost"
        identity = key.not_nil!.source_reference.try { |reference| "sourceReference=#{reference}" } || key.not_nil!.local_path || "source"
        return debug_ui_text("#{identity} · #{state}", 512)
      else
        ""
      end
    end

    private def debug_source_row_text(source : DebugController::SourceView) : String
      identity = source.key.source_reference.try { |reference| "sourceReference=#{reference}" } || "local source"
      display_path = source.display_path
      path = display_path ? debug_ui_text(display_path.not_nil!, 240) : identity
      origin = source.origin.to_s
      checksum = source.checksum_status.to_s
      state = source.outdated ? "outdated" : "current"
      reason = source.reason.try { |value| " · #{debug_ui_text(value, 160)}" } || ""
      debug_ui_text("#{path} · #{origin} · #{checksum} · #{state}#{reason}", 512)
    end

    private def debug_refresh_source_rows : Nil
      generation = @debug_snapshot.source_generation
      return if generation == @debug_source_projected_generation
      @debug_source_projected_generation = generation
      @debug_source_row_views = @debug_snapshot.sources
      loaded = Set(Debugging::DebugSourceKey).new
      @debug_source_row_views.each { |source| loaded << source.key }
      @debug_source_open_states.keys.each do |key|
        @debug_source_open_states.delete(key) if loaded.includes?(key)
      end
      @debug_source_row_keys = @debug_source_open_states.keys.reject { |key| loaded.includes?(key) }
    end

    private def debug_source_visible_count : Int32
      debug_refresh_source_rows
      @debug_source_row_views.size + @debug_source_row_keys.size
    end

    private def debug_ensure_variable_projection : Nil
      debug_sync_scope_request
      generation = @debug_snapshot.variable_generation
      return if generation == @debug_variable_projected_generation
      @debug_variable_projected_generation = generation
      debug_rebuild_variable_projection
      @debug_workspace.panel.clamp_selection(DebugPanel::Pane::Variables, @debug_variable_projection.row_count)
    end

    private def debug_sync_scope_request : Nil
      requested_frame = @debug_scopes_request_frame_id
      return unless requested_frame
      state = @debug_snapshot.state
      if state.selected_frame_id != requested_frame
        @debug_scopes_request_frame_id = nil
        @debug_scopes_request_error = nil
      elsif @debug_snapshot.scopes_loaded
        if @debug_snapshot.variables.roots.any?
          @debug_snapshot.variables.roots.each { |root| @debug_variable_expanded_ids << root.id if root.expandable? }
        end
        @debug_scopes_request_frame_id = nil
        @debug_scopes_request_error = nil
      elsif error = @debug_snapshot.scopes_error
        @debug_scopes_request_frame_id = nil
        @debug_scopes_request_error = error
      elsif !@debug_snapshot.scopes_request_pending
        # Completion is tied to this exact frame by the controller's scope
        # request certificate. Global generation changes are not evidence
        # that a particular scopes request finished.
        @debug_scopes_request_frame_id = nil
      end
    end

    private def debug_can_open_scopes? : Bool
      state = @debug_snapshot.state
      state.lifecycle == DebugSessionState::Lifecycle::Active &&
        state.execution.stopped? && !state.selected_thread_id.nil? && !state.selected_frame_id.nil? &&
        @debug_snapshot.available?(DebugController::Action::OpenScopes)
    end

    private def debug_variable_placeholder(max_cells : Int32) : String
      width = max_cells.clamp(0, 4096)
      message = if @debug_snapshot.scopes_loaded && @debug_snapshot.variables.roots.empty?
                  "No scopes or variables reported for this frame"
                elsif @debug_snapshot.scopes_request_pending || @debug_scopes_request_frame_id
                  "Loading scopes for the stopped frame…"
                elsif @debug_scopes_request_error || @debug_snapshot.scopes_error
                  debug_scopes_failure_placeholder(width)
                elsif debug_can_open_scopes?
                  "Press Enter to load scopes for the stopped frame"
                else
                  "No stopped frame selected"
                end
      Debugging::DebugVariablePresenter.truncate(message, width)
    end

    private def debug_scopes_failure_placeholder(width : Int32) : String
      retry_label = "Enter: retry"
      suffix = " · #{retry_label}"
      prefix = "Scopes unavailable: "
      reason = @debug_snapshot.scopes_error || @debug_scopes_request_error || "scope request failed"
      reason_budget = width - Tui::Unicode.display_width(prefix) - Tui::Unicode.display_width(suffix)
      if reason_budget >= 1
        clipped_reason = Debugging::DebugVariablePresenter.truncate(reason, reason_budget)
        "#{prefix}#{clipped_reason}#{suffix}"
      elsif width >= Tui::Unicode.display_width("Scopes unavailable#{suffix}")
        "Scopes unavailable#{suffix}"
      elsif width >= Tui::Unicode.display_width(retry_label)
        retry_label
      elsif width >= Tui::Unicode.display_width("retry")
        "retry"
      else
        Debugging::DebugVariablePresenter::ELLIPSIS
      end
    end

    private def debug_rebuild_variable_projection : Nil
      @debug_variable_projection.retain_existing_expansions(@debug_snapshot.variables, @debug_variable_expanded_ids)
      @debug_variable_projection.rebuild(@debug_snapshot.variables, @debug_variable_expanded_ids)
      @debug_variable_selection.reconcile(@debug_variable_projection)
      if selected_index = @debug_variable_selection.restore_index(@debug_variable_projection)
        @debug_workspace.panel.restore_selected_row(DebugPanel::Pane::Variables, selected_index,
          @debug_variable_projection.row_count)
      end
    end

    private def debug_panel_row_selected(pane : DebugPanel::Pane, index : Int32) : Nil
      case pane
      when .stack?
        frame = @debug_snapshot.frames[index]?
        if frame
          @debug_controller.select_frame(frame.not_nil!.id)
          debug_refresh_after_action
        end
      when .threads?
        thread = @debug_snapshot.threads[index]?
        if thread && thread.not_nil!.execution.stopped?
          submission = @debug_controller.select_thread(thread.not_nil!.id)
          unless submission.accepted?
            @status_log.warning("Thread unavailable: #{debug_ui_text(submission.reason || "selection rejected", 256)}")
          end
          debug_refresh_after_action
        end
      when .variables?
        # Selection is local; a child request requires an explicit row action.
        debug_ensure_variable_projection
        @debug_variable_selection.select(@debug_variable_projection, index)
      when .watch?, .breakpoints?, .output?
      when .sources?
      end
    end

    private def debug_panel_row_action(pane : DebugPanel::Pane, index : Int32, action : String) : Bool
      case pane
      when .stack?
        frame = @debug_snapshot.frames[index]?
        return false unless frame
        if action == "show"
          debug_show_frame_location(frame.not_nil!)
        else
          submission = @debug_controller.select_frame(frame.not_nil!.id)
          @status_log.warning("Frame unavailable: #{debug_ui_text(submission.reason || "selection rejected", 256)}") unless submission.accepted?
          debug_refresh_after_action
        end
      when .variables?
        debug_ensure_variable_projection
        row = @debug_variable_projection.row(index)
        unless row
          return true if @debug_snapshot.scopes_loaded || @debug_snapshot.scopes_request_pending
          return debug_open_scopes if action.in?("activate", "expand", "toggle")
          return true
        end
        return true unless node_id = row.not_nil!.node_id
        node = @debug_variable_projection.node(node_id.not_nil!)
        return true unless node
        case action
        when "collapse"
          debug_collapse_variable(node.not_nil!)
        when "load-more"
          debug_expand_variable(node.not_nil!, load_more: true)
        when "expand"
          debug_expand_variable(node.not_nil!) unless @debug_variable_expanded_ids.includes?(node.not_nil!.id)
        when "detail"
          debug_show_value_detail(node.not_nil!.id, Debugging::DebugValueFormat::Summary)
        when "next-format"
          debug_show_value_detail(node.not_nil!.id, Debugging::DebugValueFormat::Hex)
        when "local-json"
          debug_show_value_detail(node.not_nil!.id, Debugging::DebugValueFormat::JsonInterpretation)
        when "toggle", "activate"
          if @debug_variable_expanded_ids.includes?(node.not_nil!.id)
            debug_collapse_variable(node.not_nil!)
          elsif node.not_nil!.expandable?
            debug_expand_variable(node.not_nil!)
          else
            debug_show_value_detail(node.not_nil!.id, Debugging::DebugValueFormat::Summary)
          end
        end
      when .watch?
        watch = @debug_snapshot.watches[index]?
        return false unless watch
        if action == "evaluate"
          @debug_pending_watch_id = watch.not_nil!.id
          @debug_modal_error = nil
          open_debug_modal(DebugModalKind::WatchConfirm)
        end
      when .breakpoints?
        row = @debug_snapshot.breakpoints[index]?
        return false unless row
        breakpoint = row.not_nil!.breakpoint
        key = row.not_nil!.source_key
        if action == "remove"
          @debug_controller.remove_breakpoint(key, breakpoint.id)
        else
          @debug_controller.set_breakpoint_enabled(key, breakpoint.id, !breakpoint.enabled)
        end
        debug_refresh_after_action
      when .output?
      when .sources?
        debug_refresh_source_rows
        if source = @debug_source_row_views[index]?
          if action == "show" || action == "activate"
            debug_show_readonly_source(source.not_nil!)
          end
        elsif key = @debug_source_row_keys[index - @debug_source_row_views.size]?
          if action == "show" || action == "activate"
            submission = @debug_controller.open_source(key.not_nil!)
            if submission.accepted?
              @debug_source_open_states[key.not_nil!] = "Pending adapter source response"
            else
              reason = submission.reason || "source request was rejected"
              @debug_source_open_states[key.not_nil!] = "Unavailable: #{debug_ui_text(reason, 256)}"
            end
            debug_refresh_after_action
          end
        end
      end
      true
    end

    private def debug_open_scopes : Bool
      return true if @debug_snapshot.scopes_loaded || @debug_snapshot.scopes_request_pending || @debug_scopes_request_frame_id
      unless debug_can_open_scopes?
        @debug_scopes_request_error = "no current stopped frame is available"
        @debug_workspace.panel.refresh_viewport
        return true
      end
      frame_id = @debug_snapshot.state.selected_frame_id.not_nil!
      submission = @debug_controller.open_scopes
      if submission.accepted?
        @debug_scopes_request_frame_id = frame_id
        @debug_scopes_request_error = nil
      else
        @debug_scopes_request_error = submission.reason || "scope request was rejected"
      end
      debug_refresh_after_action
      true
    end

    private def debug_collapse_variable(node : Debugging::DebugVariableNode) : Nil
      @debug_variable_expanded_ids.delete(node.id)
      debug_rebuild_variable_projection
      @debug_variable_projected_generation = @debug_snapshot.variable_generation
      @debug_workspace.panel.refresh_viewport
    end

    private def debug_expand_variable(node : Debugging::DebugVariableNode, load_more : Bool = false) : Nil
      return unless node.expandable?
      expanded = @debug_variable_expanded_ids.includes?(node.id)
      state = node.load_state
      should_request = if load_more
                         state == Debugging::DebugVariableLoadState::Partial
                       else
                         state.in?(Debugging::DebugVariableLoadState::Unloaded, Debugging::DebugVariableLoadState::Partial)
                       end
      @debug_variable_expanded_ids << node.id
      if should_request
        submission = @debug_controller.expand_variable(node.id)
        unless submission.accepted?
          @status_log.warning("Children unavailable: #{debug_ui_text(submission.reason || "request rejected", 256)}")
          @debug_variable_expanded_ids.delete(node.id) unless expanded
        end
      end
      debug_rebuild_variable_projection
      @debug_variable_projected_generation = UInt64::MAX if should_request
      debug_refresh_after_action if should_request
      @debug_workspace.panel.refresh_viewport unless should_request
    end

    private def debug_show_value_detail(node_id : String, format : Debugging::DebugValueFormat) : Nil
      close_debug_modal if @debug_modal_kind == DebugModalKind::ValueDetail
      @debug_value_detail_node_id = node_id.dup
      @debug_value_detail_format = format
      @debug_value_detail_origin_key = debug_value_detail_context_key
      @debug_value_detail_cache_key = nil
      @debug_value_detail_scroll = 0
      @debug_modal_error = nil
      if format == Debugging::DebugValueFormat::Hex
        submission = @debug_controller.request_value_format(node_id, format)
        @debug_modal_error = submission.reason unless submission.accepted?
      end
      debug_refresh_value_detail
      open_debug_modal(DebugModalKind::ValueDetail)
      debug_show_panel(true)
      debug_refresh_after_action if format == Debugging::DebugValueFormat::Hex
    end

    private def debug_value_detail_context_key : Tuple(UInt64, UInt64, Int64?, UInt64)?
      state = @debug_snapshot.state
      return nil unless state.lifecycle == DebugSessionState::Lifecycle::Active && state.execution.stopped?
      frame_id = state.selected_frame_id
      return nil unless frame_id
      {state.session_generation, state.stop_epoch, frame_id, @debug_snapshot.variable_generation}
    end

    private def debug_value_detail_view_rows(height : Int32) : Int32
      {height - 7, 1}.max
    end

    private def debug_refresh_value_detail(width : Int32 = @debug_value_detail_content_width) : Nil
      node_id = @debug_value_detail_node_id
      return unless node_id
      state = @debug_snapshot.state
      context = debug_value_detail_context_key
      node = context ? @debug_snapshot.variables.node(node_id.not_nil!) : nil
      current_context = context
      if !current_context || current_context != @debug_value_detail_origin_key || !node
        @debug_value_detail_cache_key = nil
        @debug_value_detail_render = Debugging::DebugValueRender.new(
          Debugging::DebugValueAvailability::Unavailable, @debug_value_detail_format,
          "Unavailable", "", false, "variable data or the stopped frame changed; reopen detail")
        @debug_value_detail_lines = ["Value unavailable; reopen detail after selecting the current frame"] of String
        @debug_value_detail_node_label = "variable unavailable"
        @debug_value_detail_type_label = "type unavailable"
        @debug_value_detail_display_limited = false
        @debug_value_detail_scroll = 0
        return
      end

      key = {node_id.not_nil!, current_context.not_nil![0], current_context.not_nil![1],
             current_context.not_nil![2], current_context.not_nil![3], @debug_snapshot.value_format_generation,
             @debug_snapshot.value_format_status, @debug_value_detail_format, width.clamp(1, 4096)}
      if @debug_value_detail_cache_key == key
        # Viewport height changes how many cached wrapped rows fit, but it does
        # not change wrapping identity. Clamp scroll without rebuilding the
        # retained value lines when a taller terminal exposes more rows.
        @debug_value_detail_scroll = @debug_value_detail_scroll.clamp(0,
          [@debug_value_detail_lines.size - debug_value_detail_view_rows([12, @rect.height - 2].min), 0].max)
        return
      end

      @debug_value_detail_content_width = width.clamp(1, 4096)
      @debug_value_detail_node_label = node.not_nil!.name
      @debug_value_detail_type_label = node.not_nil!.type || "type unavailable"
      detail = @debug_controller.render_value(node_id.not_nil!, @debug_value_detail_format)
      @debug_value_detail_render = detail
      if detail.available?
        text = detail.text
        text = "Adapter supplied an empty summary" if text.empty?
        lines, wrapping_limited = Debugging::DebugVariablePresenter.wrap(text, @debug_value_detail_content_width)
        @debug_value_detail_lines = lines
        @debug_value_detail_display_limited = detail.truncated? || wrapping_limited
      else
        reason = detail.reason || "value is unavailable"
        @debug_value_detail_lines = [Debugging::DebugVariablePresenter.truncate(reason, @debug_value_detail_content_width)] of String
        @debug_value_detail_display_limited = false
      end
      @debug_value_detail_cache_key = key
      @debug_value_detail_scroll = @debug_value_detail_scroll.clamp(0,
        [@debug_value_detail_lines.size - debug_value_detail_view_rows([12, @rect.height - 2].min), 0].max)
    end

    private def debug_set_value_detail_format(format : Debugging::DebugValueFormat) : Nil
      return unless @debug_modal_kind == DebugModalKind::ValueDetail
      node_id = @debug_value_detail_node_id
      return unless node_id
      if @debug_value_detail_format == Debugging::DebugValueFormat::Hex && format != Debugging::DebugValueFormat::Hex
        @debug_controller.cancel_value_format(node_id)
      end
      @debug_value_detail_format = format
      @debug_value_detail_cache_key = nil
      @debug_value_detail_scroll = 0
      @debug_modal_error = nil
      if format == Debugging::DebugValueFormat::Hex
        submission = @debug_controller.request_value_format(node_id.not_nil!, format)
        @debug_modal_error = submission.reason unless submission.accepted?
      end
      debug_refresh_value_detail
      debug_refresh_after_action if format == Debugging::DebugValueFormat::Hex
      mark_dirty!
    end

    private def debug_show_frame_location(frame : DebugController::FrameView) : Nil
      key = frame.source_key
      unless key
        @status_log.warning("Frame location unavailable: #{debug_ui_text(frame.unavailable_reason || "no source identity", 256)}")
        return
      end
      if key.not_nil!.source_reference && key.not_nil!.source_reference.not_nil! > 0
        submission = @debug_controller.open_source(key.not_nil!)
        @debug_source_open_states[key.not_nil!] = if submission.accepted?
                                                    "Pending adapter source response"
                                                  else
                                                    "Unavailable: #{debug_ui_text(submission.reason || "request rejected", 256)}"
                                                  end
        @debug_workspace.panel.selected_pane = DebugPanel::Pane::Sources
        debug_refresh_after_action
        if submission.accepted?
          @status_log.info("Read-only adapter source request pending; inspect Sources for its result")
        else
          @status_log.warning("Read-only adapter source unavailable: #{debug_ui_text(submission.reason || "request rejected", 256)}")
        end
        return
      end
      path = key.not_nil!.local_path
      unless path && debug_path_within_project?(Path.new(path.not_nil!)) && File.file?(path.not_nil!)
        @status_log.warning("Frame source is not an existing project-local file")
        return
      end
      source = @debug_snapshot.sources.find { |candidate| candidate.key == key.not_nil! }
      open_file(Path.new(File.realpath(path.not_nil!)), frame.editor_line, frame.editor_column)
      unless source && source.not_nil!.checksum_status == Debugging::ChecksumStatus::Match && !source.not_nil!.outdated
        @status_log.warning("Opened the reported location explicitly, but source is unverified; no precise live gutter marker is shown")
      end
    rescue ex
      @status_log.warning("Could not show frame location: #{debug_ui_text(ex.message || ex.class.name, 256)}")
    end

    private def debug_project_gutters : Nil
      breakpoints = Hash(String, Set(Int32)).new { |hash, key| hash[key] = Set(Int32).new }
      inactive_breakpoints = Hash(String, Set(Int32)).new { |hash, key| hash[key] = Set(Int32).new }
      live_gutter_callbacks = Set(UInt64).new
      @debug_snapshot.breakpoints.each do |row|
        next unless path = row.source_key.local_path
        breakpoint = row.breakpoint
        if breakpoint.enabled && breakpoint.status.in?(Debugging::BreakpointStatus::Verified, Debugging::BreakpointStatus::Moved)
          breakpoints[path] << breakpoint.requested_line
        else
          inactive_breakpoints[path] << breakpoint.requested_line
        end
      end

      execution_path : String? = nil
      execution_line : Int32? = nil
      inspection_path : String? = nil
      inspection_line : Int32? = nil
      state = @debug_snapshot.state
      if state.lifecycle == DebugSessionState::Lifecycle::Active &&
         state.selected_thread_id && state.selected_frame_id &&
         @debug_snapshot.threads.any? { |thread| thread.id == state.selected_thread_id && thread.execution.stopped? }
        selected_frame = @debug_snapshot.frames.find { |candidate| candidate.id == state.selected_frame_id }
        # The first returned stack frame is the actual stopped location. The
        # selected inspection frame may be a historical caller and must not
        # move the execution arrow.
        frame = @debug_snapshot.frames.first?
        if frame
          if location = debug_verified_local_frame_location(frame)
            execution_path, execution_line = location
          end
          if selected_frame && selected_frame.id != frame.id
            if location = debug_verified_local_frame_location(selected_frame)
              inspection_path, inspection_line = location
            end
          end
        end
      end

      @document_session.open_buffers.each_value do |buffer|
        path = begin
          File.realpath(buffer.path.to_s)
        rescue
          buffer.path.expand.to_s
        end
        lines = breakpoints[path]? || Set(Int32).new
        inactive_lines = Set(Int32).new
        (inactive_breakpoints[path]? || Set(Int32).new).each do |line|
          inactive_lines << line unless lines.includes?(line)
        end
        active_line = execution_path == path ? execution_line : nil
        selected_line = inspection_path == path ? inspection_line : nil
        selected_line = nil if active_line == selected_line
        @document_session.views_for(buffer).each do |view|
          editor = view.as?(EditingTextEditor)
          next unless editor
          view_id = view.object_id
          live_gutter_callbacks << view_id
          editor.not_nil!.debug_gutter_enabled = true
          editor.not_nil!.debug_breakpoint_lines = lines
          editor.not_nil!.debug_inactive_breakpoint_lines = inactive_lines
          editor.not_nil!.debug_execution_line = active_line
          editor.not_nil!.debug_inspection_line = selected_line
          # Object IDs are only live-view accounting, not callback authority:
          # a retired ID can be reused before the next projection. Rebind the
          # current widget every time so a stale cache entry cannot suppress it.
          source_path = path.dup
          editor.not_nil!.on_debug_breakpoint_toggle do |line|
            debug_toggle_breakpoint(source_path, line)
          end
        end
      end
      @debug_gutter_callbacks = live_gutter_callbacks
    end

    private def debug_verified_local_frame_location(frame : DebugController::FrameView) : Tuple(String, Int32)?
      return nil unless frame.unavailable_reason.nil? && frame.source_reference.nil?
      source_key = frame.source_key
      return nil unless source_key
      path = source_key.not_nil!.local_path
      line = frame.editor_line
      return nil unless path && line
      source = @debug_snapshot.sources.find { |candidate| candidate.key == source_key }
      return nil unless source && source.not_nil!.origin == Debugging::SourceOrigin::LaunchBaseline &&
                        source.not_nil!.checksum_status == Debugging::ChecksumStatus::Match &&
                        !source.not_nil!.outdated
      {path.not_nil!, line.not_nil!}
    end

    private def debug_toggle_breakpoint(path : String, line : Int32) : Nil
      key = Debugging::DebugSourceKey.local(path)
      submission = @debug_controller.toggle_breakpoint(key, line)
      if submission.accepted?
        debug_status("Breakpoint toggled at #{File.basename(path)}:#{line + 1}")
        @debug_projected_generation = UInt64::MAX
        debug_poll_and_project
      else
        @status_log.warning("Breakpoint unavailable: #{debug_ui_text(submission.reason || "request rejected", 256)}")
      end
      mark_dirty!
    rescue ex
      @status_log.warning("Breakpoint unavailable: #{debug_ui_text(ex.message || ex.class.name, 256)}")
    end

    private def debug_toggle_current_breakpoint : Bool
      buffer = current_buffer
      editor = current_editor.as?(EditingTextEditor)
      unless buffer && editor && File.file?(buffer.not_nil!.path.to_s)
        @status_log.warning("F9 requires an open local source file")
        return true
      end
      debug_toggle_breakpoint(File.realpath(buffer.not_nil!.path.to_s), editor.not_nil!.cursor_line)
      true
    rescue ex
      @status_log.warning("F9 could not identify this source: #{debug_ui_text(ex.message || ex.class.name, 256)}")
      true
    end

    private def debug_start_continue : Bool
      state = @debug_snapshot.state
      if state.lifecycle == DebugSessionState::Lifecycle::Active
        submission = @debug_controller.continue
        @status_log.warning("Continue unavailable: #{debug_ui_text(submission.reason || "action rejected", 256)}") unless submission.accepted?
        debug_refresh_after_action
      elsif state.lifecycle.in?(DebugSessionState::Lifecycle::Idle, DebugSessionState::Lifecycle::Ended, DebugSessionState::Lifecycle::Failed)
        if @debug_snapshot.cleanup_pending
          @status_log.info("Waiting for debugger adapter cleanup before another launch")
        else
          open_debug_profile_form
        end
      else
        @status_log.info("Debugger launch or shutdown is already in progress")
      end
      true
    end

    private def debug_stop : Bool
      submission = @debug_controller.stop
      if submission.accepted?
        @status_log.info("Stop requested; target exit remains unconfirmed until an exited event")
      else
        @status_log.warning("Stop unavailable: #{debug_ui_text(submission.reason || "action rejected", 256)}")
      end
      debug_refresh_after_action
      true
    end

    private def debug_step(action : DebugController::Action) : Bool
      submission = case action
                   when .step_over? then @debug_controller.step_over
                   when .step_into? then @debug_controller.step_into
                   when .step_out?  then @debug_controller.step_out
                   when .pause?     then @debug_controller.pause
                   else                  @debug_controller.continue
                   end
      @status_log.warning("#{action}: #{debug_ui_text(submission.reason || "action rejected", 256)}") unless submission.accepted?
      debug_refresh_after_action
      true
    end

    private def debug_refresh_after_action : Nil
      @debug_snapshot = @debug_controller.snapshot
      @debug_projected_generation = UInt64::MAX
      debug_poll_and_project
    end

    private def request_debug_app_transition(kind : DebugAppTransitionKind, root : Path? = nil,
                                             approvals : Hash(String, CloseTarget) = {} of String => CloseTarget) : Nil
      if @debug_pending_transition && @debug_transition_stop_requested
        @status_log.warning("A previously approved debugger Stop is still pending; wait for cleanup before another app transition")
        return
      end

      @debug_pending_transition = DebugAppTransition.new(kind, root)
      @debug_transition_approvals = approvals.dup
      @debug_transition_stop_requested = false
      @debug_transition_cancelled = false
      @debug_modal_error = nil
      state = @debug_snapshot.state
      if debug_requires_app_transition?
        open_debug_modal(DebugModalKind::AppTransition)
      else
        debug_commit_app_transition(@debug_pending_transition.not_nil!)
        @debug_pending_transition = nil
      end
    end

    private def debug_requires_app_transition? : Bool
      state = @debug_snapshot.state
      state.lifecycle.in?(
        DebugSessionState::Lifecycle::Starting,
        DebugSessionState::Lifecycle::Configuring,
        DebugSessionState::Lifecycle::Active,
        DebugSessionState::Lifecycle::Disconnecting
      ) || @debug_snapshot.cleanup_pending
    end

    private def approve_debug_app_transition : Nil
      transition = @debug_pending_transition
      return unless transition
      return if @debug_transition_stop_requested

      state = @debug_snapshot.state
      if state.lifecycle.in?(DebugSessionState::Lifecycle::Starting,
           DebugSessionState::Lifecycle::Configuring,
           DebugSessionState::Lifecycle::Active,
           DebugSessionState::Lifecycle::Disconnecting)
        submission = @debug_controller.stop
        unless submission.accepted?
          @debug_modal_error = "Stop was not accepted: #{debug_ui_text(submission.reason || "request rejected", 256)}"
          mark_dirty!
          return
        end
      end

      @debug_transition_stop_requested = true
      @debug_modal_error = nil
      @debug_snapshot = @debug_controller.snapshot
      mark_dirty!
      debug_advance_pending_transition
    end

    private def cancel_debug_app_transition : Nil
      if @debug_transition_stop_requested
        @debug_transition_cancelled = true
        @status_log.warning("Application transition cancelled; the approved debugger Stop cannot be undone")
      else
        @debug_pending_transition = nil
        @debug_transition_approvals.clear
        debug_status("Application transition cancelled; debugger session and project root are unchanged")
      end
      close_debug_modal
    end

    private def debug_advance_pending_transition : Nil
      transition = @debug_pending_transition
      return unless transition && @debug_transition_stop_requested
      state = @debug_snapshot.state
      return unless state.lifecycle.in?(DebugSessionState::Lifecycle::Ended, DebugSessionState::Lifecycle::Failed)
      return if @debug_snapshot.cleanup_pending

      was_cancelled = @debug_transition_cancelled
      close_debug_modal if @debug_modal_kind == DebugModalKind::AppTransition
      @debug_pending_transition = nil
      @debug_transition_stop_requested = false
      @debug_transition_cancelled = false
      if was_cancelled
        @debug_transition_approvals.clear
        @status_log.warning("Approved debugger Stop finished; the cancelled application action was not committed")
      else
        debug_commit_app_transition(transition.not_nil!)
      end
    end

    private def debug_commit_app_transition(transition : DebugAppTransition) : Nil
      pending = @document_session.open_buffers.values.find do |buffer|
        next false unless unsafe_to_close?(buffer)
        approval = @debug_transition_approvals[buffer.path.to_s]?
        !(approval && approval.current?(@document_session))
      end
      if pending
        approvals = @debug_transition_approvals.dup
        @debug_transition_approvals.clear
        @debug_pending_transition = nil
        @debug_transition_stop_requested = false
        @debug_transition_cancelled = false
        review_app_transition(transition, approvals)
        return
      end
      @debug_transition_approvals.clear
      case transition.kind
      when .quit?
        @close_quit_committing = true
        begin
          quit
        ensure
          @close_quit_committing = false
        end
      when .change_root?
        if root = transition.root
          commit_project_root_change(root)
        end
      end
    end

    private def debug_focus_panel : Bool
      debug_show_panel(true)
    end

    private def debug_focus_pane(pane : DebugPanel::Pane) : Bool
      @debug_workspace.panel.selected_pane = pane
      debug_show_panel(true)
      @debug_workspace.panel.refresh_viewport
      true
    end

    private def debug_show_selected_location : Bool
      frame = if @debug_workspace.panel.selected_pane.stack?
                @debug_snapshot.frames[@debug_workspace.panel.selected_row]?
              else
                selected_id = @debug_snapshot.state.selected_frame_id
                selected_id.try { |id| @debug_snapshot.frames.find { |candidate| candidate.id == id } }
              end
      unless frame
        @status_log.info("Select a stack frame before showing its location")
        return true
      end
      debug_show_frame_location(frame.not_nil!)
      true
    end

    private def debug_show_panel(focus : Bool = false) : Bool
      selected = @inspector_layout.select_section(DebugInspectorSection::Debug)
      if selected && focus && inspector_layout_selection_allowed?
        inspector = @inspector_layout.geometry.inspector
        if inspector && inspector.width >= DebugInspectorLayout::MIN_VISIBLE_INSPECTOR_WIDTH && inspector.height >= DebugInspectorLayout::MIN_INSPECTOR_HEIGHT
          @debug_workspace.panel.focus
        else
          @inspector_layout.activity_rail.focus
        end
      end
      true
    end

    private def debug_hide_panel : Nil
      return unless @debug_dock_visible
      @inspector_layout.select_section(DebugInspectorSection::Files)
      mark_dirty!
    end

    private def debug_toggle_panel : Bool
      if @debug_dock_visible
        debug_hide_panel
        true
      else
        debug_show_panel(true)
      end
    end

    private def open_debug_watch_form : Nil
      return if debug_modal_active?
      @debug_form_fields = [EditableInput.new("", 128)]
      @debug_form_index = 0
      @debug_modal_error = nil
      open_debug_modal(DebugModalKind::Watch)
    end

    private def open_debug_profile_form : Nil
      return if debug_modal_active?
      loaded = @debug_profile_store.load(@project_root)
      loaded.warnings.each { |warning| @status_log.warning(debug_ui_text(warning, 256)) }
      @debug_profile_rows = loaded.profiles
      preferred = loaded.last_profile_id.try { |id| @debug_profile_rows.find { |profile| profile.id == id } }
      profile = preferred || @debug_profile_rows.first?
      adapter = if profile
                  @debug_profile_hint = nil
                  profile.adapter_argv.to_json
                elsif path = discover_lldb_dap
                  @debug_profile_hint = "Found lldb-dap; review its path and --no-lldbinit argv"
                  [path, "--no-lldbinit"].to_json
                else
                  @debug_profile_hint = "No lldb-dap found; set ADAMANTINE_DEBUG_LLDB_DAP or enter its absolute path"
                  "[]"
                end
      program = profile ? profile.program : ""
      cwd = profile ? profile.cwd : @project_root.to_s
      target = profile ? profile.target_argv.to_json : "[]"
      @debug_form_fields = [
        EditableInput.new(adapter, 1024),
        EditableInput.new(program, 4096),
        EditableInput.new(cwd, 4096),
        EditableInput.new(target, 1024),
      ]
      @debug_native_values = profile.try(&.native_values) || Debugging::NativeValueProvider::Generic
      # The visible form edits only these four fields. Keep all selected
      # profile metadata (identity and source maps) attached to its review
      # candidate rather than silently replacing it with a generic profile.
      @debug_form_profile_template = profile
      @debug_form_index = 0
      @debug_candidate_profile = nil
      @debug_pending_review = nil
      @debug_modal_error = nil
      open_debug_modal(DebugModalKind::Profile)
    rescue ex
      @status_log.error("Could not load debugger profiles: #{debug_ui_text(ex.message || ex.class.name, 256)}")
    end

    # Discovery is deliberately inert: resolve only an existing executable;
    # never run it, install it, or read debugger startup configuration.
    private def discover_lldb_dap : String?
      configured = ENV["ADAMANTINE_DEBUG_LLDB_DAP"]?
      candidate = if configured && !configured.not_nil!.empty?
                    value = configured.not_nil!
                    value.includes?("/") ? value : Process.find_executable(value)
                  else
                    Process.find_executable("lldb-dap")
                  end
      return nil unless candidate && File.file?(candidate.not_nil!)
      canonical = File.realpath(candidate.not_nil!)
      return nil unless (File.info(canonical).permissions.value & 0o111) != 0
      canonical
    rescue
      nil
    end

    private def open_debug_modal(kind : DebugModalKind) : Nil
      close_command_palette
      close_context_menu
      close_lsp_popup
      close_settings_dialog if @settings.open
      close_search_panel if @search.open
      close_quick_open
      close_problems
      close_git_view
      @clipboard_paste_generation &+= 1_u64
      @debug_modal_kind = kind
      enter_input_mode(InputModeController::InputMode::DebugModal)
      @debug_modal_overlay = open_overlay(@debug_modal_overlay, ->(buffer : Tui::Buffer, clip : Tui::Rect) {
        render_debug_modal(buffer, clip)
      })
      mark_dirty!
    end

    private def close_debug_modal : Nil
      return unless @debug_modal_kind
      was_source = @debug_modal_kind == DebugModalKind::Source
      if @debug_modal_kind == DebugModalKind::ValueDetail
        @debug_controller.cancel_value_format(@debug_value_detail_node_id)
        @debug_value_detail_node_id = nil
        @debug_value_detail_render = nil
        @debug_value_detail_format = Debugging::DebugValueFormat::Summary
      end
      @debug_pending_watch_id = nil if @debug_modal_kind == DebugModalKind::WatchConfirm
      close_overlay(@debug_modal_overlay)
      @debug_modal_overlay = nil
      @debug_modal_kind = nil
      @debug_modal_error = nil
      @debug_pending_review = nil
      @debug_candidate_profile = nil
      @debug_form_profile_template = nil
      @debug_readonly_source = nil if was_source
      exit_input_mode(InputModeController::InputMode::DebugModal)
      mark_dirty!
    end

    private def debug_modal_active? : Bool
      !@debug_modal_kind.nil? && active_input_mode == InputModeController::InputMode::DebugModal
    end

    private def handle_debug_modal_input(event : Tui::KeyEvent) : Bool
      case event.key
      when .escape?
        if @debug_modal_kind == DebugModalKind::AppTransition
          cancel_debug_app_transition
        else
          close_debug_modal
        end
      when .tab?
        return true if @debug_modal_kind == DebugModalKind::Profile && @rect.height < DEBUG_PROFILE_MIN_HEIGHT
        if @debug_modal_kind == DebugModalKind::Profile
          @debug_form_index = (@debug_form_index + (event.modifiers.shift? ? 4 : 1)) % 5
        else
          @debug_dirty_choice = (@debug_dirty_choice + (event.modifiers.shift? ? 2 : 1)) % 3 if @debug_modal_kind == DebugModalKind::Dirty
        end
        mark_dirty!
      when .enter?
        return true if @debug_modal_kind == DebugModalKind::Profile && @rect.height < DEBUG_PROFILE_MIN_HEIGHT
        if @debug_modal_kind == DebugModalKind::AppTransition
          approve_debug_app_transition
        elsif @debug_modal_kind == DebugModalKind::Source
          close_debug_modal
        elsif @debug_modal_kind == DebugModalKind::ValueDetail
          close_debug_modal
        else
          advance_debug_modal
        end
      else
        return true if @debug_modal_kind == DebugModalKind::Profile && @rect.height < DEBUG_PROFILE_MIN_HEIGHT
        return true if @debug_modal_kind == DebugModalKind::ValueDetail && @rect.height < DEBUG_VALUE_DETAIL_MIN_HEIGHT
        if @debug_modal_kind == DebugModalKind::ValueDetail && event.matches?("x")
          debug_set_value_detail_format(Debugging::DebugValueFormat::Hex)
        elsif @debug_modal_kind == DebugModalKind::ValueDetail && event.matches?("z")
          debug_set_value_detail_format(Debugging::DebugValueFormat::JsonInterpretation)
        elsif @debug_modal_kind == DebugModalKind::ValueDetail && event.matches?("s")
          debug_set_value_detail_format(Debugging::DebugValueFormat::Summary)
        elsif @debug_modal_kind == DebugModalKind::ValueDetail
          visible = debug_value_detail_view_rows([12, @rect.height - 2].min)
          delta = if event.matches?("up")
                    -1
                  elsif event.matches?("down")
                    1
                  elsif event.matches?("pageup")
                    -visible
                  elsif event.matches?("pagedown")
                    visible
                  elsif event.matches?("home")
                    -Int32::MAX
                  elsif event.matches?("end")
                    Int32::MAX
                  else
                    0
                  end
          max_scroll = [@debug_value_detail_lines.size - visible, 0].max
          next_scroll = (@debug_value_detail_scroll.to_i64 + delta.to_i64).clamp(0_i64, max_scroll.to_i64).to_i32
          if next_scroll != @debug_value_detail_scroll
            @debug_value_detail_scroll = next_scroll
            mark_dirty!
          end
        elsif @debug_modal_kind == DebugModalKind::Source
          visible = debug_source_viewport_rows
          delta = if event.matches?("up")
                    -1
                  elsif event.matches?("down")
                    1
                  elsif event.matches?("pageup")
                    -visible
                  elsif event.matches?("pagedown")
                    visible
                  elsif event.matches?("home")
                    -Int32::MAX
                  elsif event.matches?("end")
                    Int32::MAX
                  else
                    0
                  end
          @debug_source_scroll = (@debug_source_scroll.to_i64 + delta.to_i64).clamp(0_i64, debug_source_max_scroll.to_i64).to_i32 if delta != 0
          @debug_source_cached_scroll = nil if delta != 0
          mark_dirty! if delta != 0
        elsif @debug_modal_kind == DebugModalKind::Profile && @debug_form_index == 4 &&
              (event.matches?("left") || event.matches?("right") || event.matches?("space"))
          @debug_native_values = if @debug_native_values == Debugging::NativeValueProvider::Generic
                                   Debugging::NativeValueProvider::StockCrystal
                                 else
                                   Debugging::NativeValueProvider::Generic
                                 end
          @debug_modal_error = nil
          mark_dirty!
        elsif @debug_modal_kind == DebugModalKind::Profile || @debug_modal_kind == DebugModalKind::Watch
          field = @debug_form_fields[@debug_form_index]?
          if field
            handle_editable_input_key(field.not_nil!, event, -> { mark_dirty! }, -> { @debug_modal_error = "Input exceeds the field limit" })
          end
        end
      end
      true
    end

    private def handle_debug_modal_paste(text : String) : Bool
      kind = @debug_modal_kind
      return true unless kind && kind.not_nil!.in?(DebugModalKind::Profile, DebugModalKind::Watch)
      return true if kind == DebugModalKind::Profile && @rect.height < DEBUG_PROFILE_MIN_HEIGHT
      field = @debug_form_fields[@debug_form_index]?
      if field
        handle_editable_input_paste(field.not_nil!, text, -> { mark_dirty! }, -> { @debug_modal_error = "Paste exceeds the field limit" })
      end
      true
    end

    private def advance_debug_modal : Nil
      kind = @debug_modal_kind
      return unless kind
      case kind
      when .watch_confirm?
        watch_id = @debug_pending_watch_id
        watch = watch_id.try { |id| @debug_snapshot.watches.find { |candidate| candidate.id == id } }
        unless watch_id && watch
          @debug_modal_error = "Watch is no longer available"
          @debug_pending_watch_id = nil
          mark_dirty!
          return
        end
        submission = @debug_controller.evaluate_watch(watch_id.not_nil!)
        unless submission.accepted?
          @debug_modal_error = submission.reason || "evaluation was rejected"
          mark_dirty!
          return
        end
        @debug_pending_watch_id = nil
        close_debug_modal
        @debug_workspace.panel.selected_pane = DebugPanel::Pane::Watch
        debug_refresh_after_action
      when .watch?
        expression = @debug_form_fields.first?.try(&.value) || ""
        submission = @debug_controller.add_watch(expression)
        if submission.accepted?
          close_debug_modal
          @debug_workspace.panel.selected_pane = DebugPanel::Pane::Watch
          debug_refresh_after_action
        else
          @debug_modal_error = submission.reason
          mark_dirty!
        end
      when .profile?
        if @rect.height < DEBUG_PROFILE_MIN_HEIGHT
          return
        end
        if @debug_form_index < 4
          @debug_form_index += 1
        else
          build_debug_profile_review
        end
      when .review?
        if profile = @debug_candidate_profile
          if profile.native_values == Debugging::NativeValueProvider::StockCrystal &&
             (@rect.height < DEBUG_STOCK_REVIEW_MIN_HEIGHT || @rect.width < DEBUG_STOCK_REVIEW_MIN_WIDTH)
            @debug_modal_error = if @rect.width < DEBUG_STOCK_REVIEW_MIN_WIDTH
                                   "Resize to #{DEBUG_STOCK_REVIEW_MIN_WIDTH} columns before continuing Stock Crystal review"
                                 else
                                   "Resize to #{DEBUG_STOCK_REVIEW_MIN_HEIGHT} rows before continuing Stock Crystal review"
                                 end
            mark_dirty!
            return
          end
        end
        if @document_session.open_buffers.values.any? { |buffer| buffer.editor.modified? || buffer.external_conflict }
          @debug_dirty_choice = 2
          @debug_modal_kind = DebugModalKind::Dirty
          mark_dirty!
        else
          start_reviewed_debug_launch(false)
        end
      when .dirty?
        case @debug_dirty_choice
        when 0
          failed = [] of String
          @document_session.open_buffers.values.each do |buffer|
            next unless buffer.editor.modified? || buffer.external_conflict
            failed << buffer.path.basename unless @document_orchestrator.save_target(buffer)
          end
          if failed.empty?
            start_reviewed_debug_launch(true)
          else
            @debug_modal_error = "Save failed or requires external-change review: #{failed.first(4).join(", ")}"
            mark_dirty!
          end
        when 1
          start_reviewed_debug_launch(false)
        else
          close_debug_modal
        end
      else
      end
    end

    private def build_debug_profile_review : Nil
      adapter_argv = parse_debug_argv(@debug_form_fields[0].value)
      program = @debug_form_fields[1].value.strip
      cwd = @debug_form_fields[2].value.strip
      target_argv = parse_debug_argv(@debug_form_fields[3].value)
      template = @debug_form_profile_template
      if @debug_native_values == Debugging::NativeValueProvider::StockCrystal && adapter_argv[1]? != "--no-lldbinit"
        @debug_form_index = 0
        @debug_modal_error = "Stock Crystal values require --no-lldbinit immediately after lldb-dap; add it to Adapter argv JSON"
        @debug_modal_kind = DebugModalKind::Profile
        mark_dirty!
        return
      end
      profile = Debugging::LaunchProfile.new(
        id: template.try(&.id) || "default",
        name: template.try(&.name) || "Launch",
        adapter_argv: adapter_argv,
        program: program,
        cwd: cwd,
        target_argv: target_argv,
        source_maps: template ? template.not_nil!.source_maps : [] of Debugging::DebugSourceMap,
        native_values: @debug_native_values
      )
      @debug_candidate_profile = profile
      @debug_pending_review = nil
      review_errors = profile.review_errors(@project_root)
      @debug_modal_error = review_errors.empty? ? nil : review_errors.join("; ")
      @debug_modal_kind = DebugModalKind::Review
      mark_dirty!
    rescue ex
      @debug_modal_error = ex.message || "Profile fields are invalid; argv fields must be JSON string arrays"
      @debug_modal_kind = DebugModalKind::Profile
      mark_dirty!
    end

    private def parse_debug_argv(text : String) : Array(String)
      value = JSON.parse(text).as_a
      raise ArgumentError.new("argv must be a JSON array of strings") if value.size > 128 || value.any? { |item| item.as_s?.nil? }
      value.map(&.as_s)
    end

    private def start_reviewed_debug_launch(saved_files : Bool) : Nil
      profile = @debug_candidate_profile
      unless profile
        @debug_modal_error = "No reviewed launch profile"
        mark_dirty!
        return
      end
      baselines = capture_debug_baselines
      unless baselines
        mark_dirty!
        return
      end
      review = @debug_controller.prepare_launch(profile.not_nil!, @project_root, baselines.not_nil!)
      unless review.valid?
        @debug_modal_error = review.errors.join("; ")
        @debug_modal_kind = DebugModalKind::Review
        mark_dirty!
        return
      end
      saved_profile = @debug_profile_store.save(@project_root, upsert_debug_profile(profile.not_nil!), profile.not_nil!.id)
      saved_profile.warnings.each { |warning| @status_log.warning(debug_ui_text(warning, 256)) }
      submission = @debug_controller.start(review)
      unless submission.accepted?
        @debug_modal_error = submission.reason
        @debug_modal_kind = DebugModalKind::Review
        mark_dirty!
        return
      end
      close_debug_modal
      debug_show_panel(true)
      @status_log.info(saved_files ? "Reviewed debug launch started after saving dirty files" : "Reviewed debug launch started; unsaved editor text was retained as source baseline")
      @debug_snapshot = @debug_controller.snapshot
      @debug_projected_generation = UInt64::MAX
      debug_poll_and_project
    rescue ex
      @debug_modal_error = ex.message || "Debugger launch could not be prepared"
      @debug_modal_kind = DebugModalKind::Review
      mark_dirty!
    end

    private def upsert_debug_profile(profile : Debugging::LaunchProfile) : Array(Debugging::LaunchProfile)
      profiles = @debug_profile_rows.reject { |item| item.id == profile.id }
      profiles << profile
      profiles.last(Debugging::DebugProfileStore::MAX_PROFILES)
    end

    private def capture_debug_baselines : Array(DebugController::SourceBaseline)?
      selected = [] of OpenBuffer
      total = 0_i64
      @document_session.open_buffers.each_value do |buffer|
        path = begin
          Path.new(File.realpath(buffer.path.to_s))
        rescue
          next
        end
        next unless debug_path_within_project?(path)
        selected << buffer
        if editor = buffer.editor.as?(EditingTextEditor)
          total += editor.search_byte_length.to_i64
        end
        if selected.size > DEBUG_BASELINE_MAX_ROOTS || total > DEBUG_BASELINE_MAX_BYTES
          @debug_modal_error = "Open source baselines exceed the safe limit (32 files / 32 MiB); close source files to continue"
          @debug_modal_kind = DebugModalKind::Review
          return nil
        end
      end
      baselines = [] of DebugController::SourceBaseline
      selected.each do |buffer|
        editor = buffer.editor.as?(EditingTextEditor)
        next unless editor
        baselines << DebugController::SourceBaseline.new(buffer.path, editor.not_nil!.text)
      end
      baselines
    rescue ex
      @debug_modal_error = "Could not capture bounded source baselines: #{debug_ui_text(ex.message || ex.class.name, 256)}"
      @debug_modal_kind = DebugModalKind::Review
      nil
    end

    private def debug_path_within_project?(path : Path) : Bool
      root = Path.new(File.realpath(@project_root.to_s))
      path == root || path.to_s.starts_with?(root.to_s.ends_with?("/") ? root.to_s : "#{root}/")
    rescue
      false
    end

    private def render_debug_modal(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      kind = @debug_modal_kind
      return unless kind
      return if @rect.width < 8 || @rect.height < 5
      width = [@rect.width - 4, 84].min
      width = [width, 8].max
      width = [width, @rect.width].min
      height = kind.profile? ? 15 : (kind.review? ? 14 : 8)
      height = 15 if kind.source?
      height = 10 if kind.app_transition?
      height = 12 if kind.value_detail?
      height = [height, @rect.height - 2].min
      x = @rect.x + (@rect.width - width) // 2
      y = @rect.y + (@rect.height - height) // 2
      modal_clip = clip.intersect(Tui::Rect.new(x, y, width, height))
      return unless modal_clip
      border = Tui::Style.new(fg: Theme::Popup.border, bg: Theme::Popup.active_bg)
      title_style = Tui::Style.new(fg: Theme::Popup.title, bg: Theme::Popup.active_bg, attrs: Tui::Attributes::Bold)
      text_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      active_style = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg, attrs: Tui::Attributes::Bold)
      error_style = Tui::Style.new(fg: Theme::Status.error, bg: Theme::Popup.active_bg)
      muted_style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      draw_debug_box(buffer, modal_clip.not_nil!, x, y, width, height, border)
      title = case kind
              when .profile?        then " Debug launch profile "
              when .review?         then " Review launch; Enter starts explicitly "
              when .dirty?          then " Unsaved files "
              when .watch?          then " Add watch (manual; evaluation is separate) "
              when .watch_confirm?  then " Confirm watch evaluation "
              when .value_detail?   then " Read-only variable detail "
              when .app_transition? then " Debug target transition "
              else                       " Read-only adapter source "
              end
      draw_text_line(buffer, modal_clip.not_nil!, x + 2, y, title, title_style, width - 4)
      if kind.source?
        render_debug_readonly_source(buffer, modal_clip.not_nil!, x, y, width, height, text_style, muted_style)
      elsif kind.profile?
        if @rect.height < DEBUG_PROFILE_MIN_HEIGHT
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2,
            "Resize to #{DEBUG_PROFILE_MIN_HEIGHT} rows to edit profile", error_style, width - 4)
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2,
            "Esc cancels", text_style, width - 4)
        else
          labels = ["Adapter argv JSON", "Program path", "Working directory", "Target argv JSON"]
          visible_count = ((height - 7) // 2).clamp(1, 4)
          first_field = @debug_form_index.clamp(0, 4 - visible_count)
          finish_field = [first_field + visible_count, @debug_form_fields.size].min
          first_field.upto(finish_field - 1) do |index|
            field = @debug_form_fields[index]
            row = y + 2 + (index - first_field) * 2
            label = index == @debug_form_index ? "> #{labels[index]}" : labels[index]
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, row, label, text_style, width - 4)
            field_style = index == @debug_form_index ? active_style : text_style
            draw_text_line(buffer, modal_clip.not_nil!, x + 3, row + 1, debug_ui_text(field.value, width - 6), field_style, width - 6)
          end
          provider = if @debug_native_values == Debugging::NativeValueProvider::StockCrystal
                       "Stock Crystal (LLDB)"
                     else
                       "Adapter (default)"
                     end
          provider_line = "#{@debug_form_index == 4 ? "> " : "  "}Values: #{provider}"
          provider_row = {y + 2 + visible_count * 2, y + height - 4}.min
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, provider_row,
            Debugging::DebugVariablePresenter.truncate(provider_line, width - 4),
            @debug_form_index == 4 ? active_style : text_style, width - 4)
          hint = @debug_profile_hint || "Tab moves fields · selector: Left/Right/Space · Enter reviews · Esc cancels"
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2, debug_ui_text(hint, width - 4), text_style, width - 4)
        end
      elsif kind.review?
        profile = @debug_candidate_profile
        profile.try do |item|
          provider = item.native_values == Debugging::NativeValueProvider::StockCrystal ? "Stock Crystal (LLDB)" : "Adapter (default)"
          if item.native_values == Debugging::NativeValueProvider::StockCrystal &&
             @rect.width < DEBUG_STOCK_REVIEW_MIN_WIDTH
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2,
              "Stock values", text_style, width - 4)
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 3,
              "Need #{DEBUG_STOCK_REVIEW_MIN_WIDTH} cols", error_style, width - 4)
            if @rect.height < DEBUG_STOCK_REVIEW_MIN_HEIGHT
              draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 4,
                "Need #{DEBUG_STOCK_REVIEW_MIN_HEIGHT} rows", error_style, width - 4)
            end
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2,
              "Esc cancels · resize to review", text_style, width - 4)
          elsif item.native_values == Debugging::NativeValueProvider::StockCrystal && height < 12
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2,
              "Values: #{provider}", text_style, width - 4)
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 3,
              "Bundled provider runs inside LLDB", text_style, width - 4)
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 4,
              "Stock Crystal only; not Adamas", text_style, width - 4)
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 3,
              "Resize to 14 rows before continuing", error_style, width - 4)
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2,
              "Esc cancels · Enter disabled until resize", text_style, width - 4)
          else
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2, "Adapter argv: #{debug_ui_text(item.adapter_argv.to_json, width - 4)}", text_style, width - 4)
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 3, "Program: #{debug_ui_text(item.program, width - 4)}", text_style, width - 4)
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 4, "CWD: #{debug_ui_text(item.cwd, width - 4)}", text_style, width - 4)
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 5, "Arguments: #{debug_ui_text(item.target_argv.to_json, width - 4)}", text_style, width - 4)
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 6,
              Debugging::DebugVariablePresenter.truncate("Values: #{provider}", width - 4), text_style, width - 4)
            if item.native_values == Debugging::NativeValueProvider::StockCrystal
              draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 7,
                "Bundled LLDB provider; bounded passive String/integer Array previews.", text_style, width - 4)
              draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 8,
                "Stock Crystal only; not Adamas.", text_style, width - 4)
              draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 9,
                "--no-lldbinit must be first argument after lldb-dap.", text_style, width - 4)
            else
              draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 7,
                "Adapter summaries stay opaque; no native provider is enabled.", text_style, width - 4)
            end
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2, "Enter continues to dirty-file review or starts · Esc cancels", text_style, width - 4)
          end
        end
      elsif kind.dirty?
        choices = ["Save dirty files", "Start without saving", "Cancel"]
        choices.each_with_index do |choice, index|
          prefix = index == @debug_dirty_choice ? "> " : "  "
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2 + index, "#{prefix}#{choice}", index == @debug_dirty_choice ? active_style : text_style, width - 4)
        end
      elsif kind.app_transition?
        transition = @debug_pending_transition
        if @debug_transition_stop_requested
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2, "Stop was approved; waiting for adapter cleanup.", text_style, width - 4)
          action = transition.try { |item| item.kind.quit? ? "Quit" : "root change" } || "application action"
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 3, "Esc cancels only the pending #{action}; Stop cannot be undone.", text_style, width - 4)
        else
          action = transition.try { |item| item.kind.quit? ? "quit" : "change project root" } || "continue"
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2, "Stop the active debug target before #{action}?", text_style, width - 4)
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 3, "Target exit is unconfirmed until an exited event.", text_style, width - 4)
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2, "Enter: Stop and continue · Esc: Cancel", text_style, width - 4)
        end
      elsif kind.watch_confirm?
        watch = @debug_pending_watch_id.try { |id| @debug_snapshot.watches.find { |candidate| candidate.id == id } }
        expression = watch.try(&.expression) || "unavailable watch"
        draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2,
          "Evaluation may execute code in the debuggee.", error_style, width - 4)
        draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 3,
          "Expression: #{debug_ui_text(expression, width - 15)}", text_style, width - 4)
        draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2,
          "Enter: Evaluate explicitly · Esc: Cancel", text_style, width - 4)
      elsif kind.value_detail?
        if @rect.height < DEBUG_VALUE_DETAIL_MIN_HEIGHT
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2,
            "Resize to #{DEBUG_VALUE_DETAIL_MIN_HEIGHT} rows to read detail", error_style, width - 4)
        else
          detail_height = [12, @rect.height - 2].min
          detail_width = [@rect.width - 4, 84].min.clamp(8, @rect.width) - 4
          debug_refresh_value_detail(detail_width)
          if value = @debug_value_detail_render
            detail = value.not_nil!
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2,
              Debugging::DebugVariablePresenter.truncate("Name: #{@debug_value_detail_node_label}", width - 4),
              text_style, width - 4)
            type_line = @debug_value_detail_type_label.empty? ? "Type unavailable" : "Type: #{@debug_value_detail_type_label}"
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 3,
              Debugging::DebugVariablePresenter.truncate(type_line, width - 4), text_style, width - 4)

            visible_rows = debug_value_detail_view_rows(detail_height)
            first = @debug_value_detail_scroll
            finish = [first + visible_rows, @debug_value_detail_lines.size].min
            if first < finish
              first.upto(finish - 1) do |index|
                row = y + 4 + index - first
                line = @debug_value_detail_lines[index]?
                draw_text_line(buffer, modal_clip.not_nil!, x + 2, row,
                  line || "[value line unavailable]", active_style, width - 4)
              end
            end

            status = if detail.available?
                       range = "value lines #{first + 1}-#{finish}/#{@debug_value_detail_lines.size}"
                       @debug_value_detail_display_limited ? "#{detail.label} · display clipped · #{range}" : "#{detail.label} · #{range}"
                     else
                       "#{detail.label} · #{detail.reason || "value unavailable"}"
                     end
            if error = @debug_modal_error
              status = "#{status} · #{error}" unless status.includes?(error)
            end
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + detail_height - 3,
              Debugging::DebugVariablePresenter.truncate(status, width - 4),
              detail.available? ? muted_style : error_style, width - 4)
          else
            draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2,
              "Value detail unavailable", muted_style, width - 4)
          end
        end
        footer_width = width - 4
        footer = "Esc/Enter close · ↑↓ scroll · PgUp/PgDn page · x Hex · z JSON · s Summary"
        if footer_width < Tui::Unicode.display_width("Esc/Enter close")
          footer = footer_width >= Tui::Unicode.display_width("Esc close") ? "Esc close" : "Esc"
        end
        draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2,
          Debugging::DebugVariablePresenter.truncate(footer, footer_width), text_style, footer_width)
      else
        draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 2, "Expression (not evaluated automatically)", text_style, width - 4)
        draw_text_line(buffer, modal_clip.not_nil!, x + 3, y + 3, debug_ui_text(@debug_form_fields.first?.try(&.value) || "", width - 6), active_style, width - 6)
        draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2, "Enter adds watch · evaluate explicitly from Watch pane", text_style, width - 4)
      end
      if error = @debug_modal_error
        unless kind.value_detail?
          draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 3, debug_ui_text(error, width - 4), error_style, width - 4)
        end
      end
    end

    private def draw_debug_box(buffer : Tui::Buffer, clip : Tui::Rect, x : Int32, y : Int32,
                               width : Int32, height : Int32, style : Tui::Style) : Nil
      return if width < 4 || height < 3
      (0...height).each do |dy|
        (0...width).each do |dx|
          cell_x = x + dx
          cell_y = y + dy
          next unless clip.contains?(cell_x, cell_y)
          glyph = if dy == 0
                    dx == 0 ? '┌' : (dx == width - 1 ? '┐' : '─')
                  elsif dy == height - 1
                    dx == 0 ? '└' : (dx == width - 1 ? '┘' : '─')
                  else
                    dx == 0 || dx == width - 1 ? '│' : ' '
                  end
          buffer.set(cell_x, cell_y, glyph, style)
        end
      end
    end

    private def debug_ui_text(value : String, limit : Int32) : String
      return "[invalid text]" unless value.valid_encoding?
      max_bytes = limit.clamp(0, Int32::MAX)
      return "" if max_bytes == 0
      String.build do |text|
        bytes = 0
        value.each_char do |char|
          code = char.ord
          safe = !(code < 0x20 || code.in?(0x7f..0x9f) || code == 0x061c ||
                   code.in?(0x200e..0x200f) || code.in?(0x202a..0x202e) ||
                   code.in?(0x2066..0x2069) || code == 0x200b || code == 0xfeff)
          displayed = safe ? char : ' '
          break if bytes + displayed.bytesize > max_bytes
          text << displayed
          bytes += displayed.bytesize
        end
      end
    end

    private def debug_show_readonly_source(source : DebugController::SourceView) : Nil
      text = source.text
      if text.bytesize > DebugController::SourceBaseline::MAX_BYTES || !text.valid_encoding?
        @status_log.warning("Adapter source is unavailable: it exceeds the UI source limit or is not valid UTF-8")
        return
      end
      @debug_readonly_source = DebugReadOnlySource.new(debug_ui_text(source.display_path || "Adapter-owned source", 240), source.reason,
        source.checksum_status.to_s, source.outdated, text)
      @debug_source_scroll = 0
      @debug_source_cached_scroll = nil
      @debug_source_cached_width = nil
      @debug_source_cached_rows = nil
      @debug_source_cached_lines.clear
      open_debug_modal(DebugModalKind::Source)
    rescue ex
      @status_log.warning("Could not show adapter source: #{debug_ui_text(ex.message || ex.class.name, 256)}")
    end

    private def debug_source_viewport_rows : Int32
      kind = @debug_modal_kind
      return 0 unless kind == DebugModalKind::Source
      height = [15, @rect.height - 2].min
      height = [height, @rect.height].min
      [height - 5, 1].max
    end

    private def debug_source_max_scroll : Int32
      source = @debug_readonly_source
      return 0 unless source
      [source.not_nil!.line_count - debug_source_viewport_rows, 0].max
    end

    private def render_debug_readonly_source(buffer : Tui::Buffer, clip : Tui::Rect, x : Int32, y : Int32,
                                             width : Int32, height : Int32, text_style : Tui::Style,
                                             muted_style : Tui::Style) : Nil
      source = @debug_readonly_source
      unless source
        draw_text_line(buffer, clip, x + 2, y + 2, "No adapter source is retained", muted_style, width - 4)
        return
      end
      item = source.not_nil!
      banner = "#{item.checksum_status} · #{item.outdated ? "outdated" : "captured"} · read-only; path is display metadata"
      draw_text_line(buffer, clip, x + 2, y + 1, debug_ui_text("#{item.label}: #{banner}", width - 4), muted_style, width - 4)
      first = @debug_source_scroll.clamp(0, debug_source_max_scroll)
      rows = debug_source_viewport_rows
      content_width = [width - 4, 0].max
      if @debug_source_cached_scroll != first || @debug_source_cached_width != content_width || @debug_source_cached_rows != rows
        @debug_source_cached_lines.clear
        finish = [first + rows, item.line_count].min
        line_index = first
        while line_index < finish
          prefix = "#{line_index + 1}: "
          source_width = [content_width - prefix.bytesize, 0].max.clamp(0, DebugReadOnlySource::MAX_LINE_BYTES)
          text = item.line(line_index, source_width)
          @debug_source_cached_lines << debug_ui_text(prefix + text, content_width)
          line_index += 1
        end
        @debug_source_cached_scroll = first
        @debug_source_cached_width = content_width
        @debug_source_cached_rows = rows
      end
      @debug_source_cached_lines.each_with_index do |line, row_index|
        draw_text_line(buffer, clip, x + 2, y + 2 + row_index, line, text_style, content_width)
      end
      footer = "↑/↓ scroll · Enter/Esc close · #{item.line_count} lines"
      draw_text_line(buffer, clip, x + 2, y + height - 2, debug_ui_text(footer, width - 4), muted_style, width - 4)
    end

    private def debug_status(message : String) : Nil
      @status_log.info(debug_ui_text(message, 256))
    end
  end
end
