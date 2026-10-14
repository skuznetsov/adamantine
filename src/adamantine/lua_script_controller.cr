require "atomic"
require "json"
require "random/secure"

require "./editor_tools"
require "./editor_tools_controller"
require "./lua_script_catalog"
require "./lua_script_runtime"
require "./safe_document_edits"
require "./text_coordinates"

module Adamantine
  # Lua's retained manual-review authority is independent of the Chat receipt.
  # It binds one run to the exact selected view, source revision and project
  # context captured immediately before the child starts.
  class LuaEditProposalReceipt
    getter run_identity : String
    getter buffer_id : String
    getter revision : String
    getter owner : OpenBuffer
    getter editor : EditingTextEditor
    getter editor_group : Tui::TabbedPanel
    getter owner_version : Int32
    getter view_epoch : UInt64
    getter group : Int32
    getter context : EditorTools::Context
    getter source_relative_path : String
    getter reference : EditorToolsController::BufferReference
    getter snapshot : Tui::PieceTreeBuffer::Snapshot
    getter line_ending : String

    def initialize(@run_identity : String, @buffer_id : String, @revision : String,
                   @owner : OpenBuffer, @editor : EditingTextEditor,
                   @editor_group : Tui::TabbedPanel, @owner_version : Int32,
                   @view_epoch : UInt64, @group : Int32,
                   @context : EditorTools::Context, source_relative_path : String,
                   @reference : EditorToolsController::BufferReference,
                   @snapshot : Tui::PieceTreeBuffer::Snapshot, line_ending : String)
      @run_identity = @run_identity.dup
      @buffer_id = @buffer_id.dup
      @revision = @revision.dup
      @source_relative_path = source_relative_path.dup
      @line_ending = line_ending.dup
    end
  end

  class LuaEditStagedProposal
    getter receipt : LuaEditProposalReceipt
    getter plan : SafeDocumentEdits::Plan

    def initialize(@receipt : LuaEditProposalReceipt, @plan : SafeDocumentEdits::Plan)
    end
  end

  class LuaScriptRun
    getter identity : String
    getter entry : LuaScripts::Entry
    getter run : LuaScripts::Run
    getter tool_context : EditorTools::Context
    getter receipt : LuaEditProposalReceipt?
    getter wake_stopped : Atomic(Bool)
    property session : EditorTools::Session? = nil
    property staged_proposal : LuaEditStagedProposal? = nil
    property proposal_attempted : Bool = false
    property receipt_revoked : Bool = false
    property terminal_success : Bool = false
    property terminal_event_seen : Bool = false
    property failure_code_override : String? = nil

    def initialize(@identity : String, @entry : LuaScripts::Entry,
                   @run : LuaScripts::Run, @tool_context : EditorTools::Context,
                   @receipt : LuaEditProposalReceipt?)
      @wake_stopped = Atomic(Bool).new(false)
    end
  end

  module LuaScriptController
    LUA_REVIEW_MODE          = InputModeController::InputMode::LuaReview
    LUA_SCRIPT_PREVIEW_TITLE = "Lua script proposed edits"

    @lua_script_catalog : LuaScripts::Catalog = LuaScripts::Catalog.new
    @lua_picker_active : Bool = false
    @lua_review_entry : LuaScripts::Entry? = nil
    @lua_review_target : LuaEditProposalReceipt? = nil
    @lua_review_lines : Array(String) = [] of String
    @lua_review_overlay : Tui::OverlayRenderer? = nil
    @lua_active_run : LuaScriptRun? = nil
    @lua_script_view_epoch : UInt64 = 0_u64

    private def lua_script_picker_entries : Array(CommandEntry)
      @lua_script_catalog.entries.map do |entry|
        requested = entry.capabilities.map(&.wire_name).join(", ")
        detail = requested.empty? ? "No editor capabilities" : "Requests: #{requested}"
        CommandEntry.new(entry.name, "lua.script:#{entry.id}", [] of String,
          detail, "", "", false)
      end
    end

    private def open_lua_script_picker : Nil
      if chat_lua_active?
        @status_log.warning("A Chat Lua worker is already active; wait for it to finish")
        mark_dirty!
        return
      end
      if lua_script_active?
        @status_log.warning("A Lua script is already active; cancel it before starting another")
        mark_dirty!
        return
      end
      @lua_script_catalog = LuaScripts::Catalog.new unless @lua_catalog_injected
      if error = @lua_script_catalog.user_error
        @status_log.warning(error.not_nil!)
      end
      @lua_picker_active = true
      @command_palette.mode = CommandPaletteState::Mode::Discovery
      @command_palette.input = ""
      @command_palette.selected_index = 0
      @command_palette.scroll = 0
      @command_palette.argument_hint = ""
      @command_palette.prepared_action = nil
      update_command_palette_candidates
      mark_dirty!
    end

    private def select_lua_script(entry_id : String) : Nil
      entry = @lua_script_catalog.find(entry_id)
      unless entry
        @status_log.warning("Lua script is no longer in the trusted local catalog")
        mark_dirty!
        return
      end
      open_lua_script_review(entry.not_nil!)
    end

    private def open_lua_script_review(entry : LuaScripts::Entry) : Nil
      return if lua_script_active?
      target = nil.as(LuaEditProposalReceipt?)
      if entry.capabilities.includes?(EditorTools::Capability::ProposeEdits)
        begin
          target = capture_lua_proposal_receipt("review")
        rescue ex
          @status_log.warning("Cannot review this script: #{ex.message || "selected buffer is unavailable"}")
          mark_dirty!
          return
        end
      end
      @lua_review_entry = entry
      @lua_review_target = target
      @lua_review_lines = lua_review_content_lines(entry, target, [@rect.width - 8, 1].max)
      @clipboard_paste_generation &+= 1_u64
      enter_input_mode(LUA_REVIEW_MODE)
      @lua_review_overlay = open_overlay(@lua_review_overlay, ->(buffer : Tui::Buffer, clip : Tui::Rect) {
        render_lua_script_review(buffer, clip)
      })
      mark_dirty!
    end

    private def handle_lua_review_input(event : Tui::KeyEvent) : Bool
      if event.matches?("escape") || event.matches?("esc")
        close_lua_script_review
      elsif event.matches?("enter") || event.matches?("return")
        if lua_script_review_approvable?
          approve_lua_script_review
        else
          @status_log.warning("Resize to review the full script digest, permissions and limits; no run started")
          mark_dirty!
        end
      end
      true
    end

    private def close_lua_script_review : Nil
      close_overlay(@lua_review_overlay)
      @lua_review_overlay = nil
      @lua_review_entry = nil
      @lua_review_target = nil
      @lua_review_lines.clear
      exit_input_mode(LUA_REVIEW_MODE)
      @clipboard_paste_generation &+= 1_u64
      mark_dirty!
    end

    private def lua_script_review_approvable? : Bool
      entry = @lua_review_entry
      return false unless entry
      geometry = lua_review_modal_geometry
      return false unless geometry[:width] >= 42 && geometry[:height] >= 8
      lines = lua_review_content_lines(entry.not_nil!, @lua_review_target, geometry[:content_width])
      return false if lines.size > geometry[:visible]
      if entry.not_nil!.capabilities.includes?(EditorTools::Capability::ProposeEdits)
        return false unless target = @lua_review_target
        return false unless lua_edit_receipt_current?(target.not_nil!, check_view: true)
      end
      true
    rescue
      false
    end

    private def approve_lua_script_review : Nil
      entry = @lua_review_entry
      return close_lua_script_review unless entry
      unless lua_script_review_approvable?
        @status_log.warning("Resize to review the full script digest, permissions and limits; no run started")
        mark_dirty!
        return
      end
      review_target = @lua_review_target
      close_lua_script_review
      begin
        start_lua_script_run(entry.not_nil!, review_target)
      rescue ex
        @status_log.error("Lua script could not start: #{ex.message || "runtime unavailable"}")
        mark_dirty!
      end
    end

    private def start_lua_script_run(entry : LuaScripts::Entry,
                                     review_target : LuaEditProposalReceipt?) : Nil
      raise "another Lua script is active" if lua_script_active?
      raise "a Lua worker is already active" if lua_execution_busy?
      identity = Random::Secure.hex(16)
      reserved = false
      context = editor_tools_current_context
      receipt = nil.as(LuaEditProposalReceipt?)
      selected_context = nil.as(NamedTuple(buffer_id: String, revision: String)?)
      if entry.capabilities.includes?(EditorTools::Capability::ProposeEdits)
        reviewed = review_target || raise "manual proposal target was not reviewed"
        current = capture_lua_proposal_receipt(identity)
        raise "selected buffer changed since review" unless lua_same_review_target?(reviewed.not_nil!, current)
        receipt = current
        selected_context = {buffer_id: current.buffer_id, revision: current.revision}
      else
        selected_context = capture_lua_selected_buffer_context(context)
      end

      selected = selected_context.try do |captured|
        JSON::Any.new({
          "buffer_id" => JSON::Any.new(captured[:buffer_id]),
          "revision"  => JSON::Any.new(captured[:revision]),
        } of String => JSON::Any)
      end
      mode = receipt ? "buffer_proposals" : "buffer_tools"
      context_hash = {"mode" => JSON::Any.new(mode)} of String => JSON::Any
      context_hash["selected_buffer"] = selected.not_nil! if selected
      context_json = JSON::Any.new(context_hash)
      runner = @lua_script_runner || LuaScripts::Runner.new
      raise "another Lua worker is already active" unless reserve_lua_execution(identity)
      reserved = true
      run = runner.start(entry.id, entry.source, context_json)
      active = LuaScriptRun.new(identity, entry, run, context, receipt)
      @lua_active_run = active
      wake_lua_script_owner(active)
      backend = EditorToolsController::Backend.new(
        -> { lua_script_session_context(active) },
        ->(request : EditorTools::Request, permit : EditorTools::ExecutionPermit) {
          if request.is_a?(EditorTools::ProposeEditsRequest)
            lua_script_prepare_proposal(active, request, permit)
          else
            execute_editor_tool(request, permit)
          end
        }
      )
      active.session = EditorTools::Host.new(backend).open_session(
        EditorTools::Consumer::Lua, entry.capabilities
      )
      @status_log.info("Lua script started: #{entry.name} [run=#{lua_script_run_tag(active)}]")
      mark_dirty!
    rescue ex
      if current = @lua_active_run
        retire_lua_script_run(current.not_nil!, cancel: true) if current.not_nil!.entry.same?(entry)
      elsif reserved
        release_lua_execution(identity.not_nil!)
      end
      raise ex
    end

    # EditorTools checks Backend#context again after each host call. Including
    # Run#active? here makes a parent deadline revoke a permit synchronously,
    # even while this App owner is blocked in a yielding open_file operation.
    private def lua_script_session_context(active : LuaScriptRun) : EditorTools::Context
      unless @lua_active_run.try(&.same?(active)) && active.run.active?
        return EditorTools::Context.new(active.tool_context.project_root, "lua-revoked-#{active.identity}")
      end
      current = editor_tools_current_context
      return current if current == active.tool_context
      EditorTools::Context.new(active.tool_context.project_root, "lua-stale-#{active.identity}")
    rescue
      EditorTools::Context.new(active.tool_context.project_root, "lua-stale-#{active.identity}")
    end

    private def lua_script_prepare_proposal(active : LuaScriptRun,
                                            request : EditorTools::ProposeEditsRequest,
                                            permit : EditorTools::ExecutionPermit) : JSON::Any
      require_editor_tools_permit!(permit)
      unless @lua_active_run.try(&.same?(active)) && active.run.active?
        raise EditorTools::Failure.new(EditorTools::Status::Denied, "Lua run is no longer active")
      end
      receipt = active.receipt
      raise EditorTools::Failure.new(EditorTools::Status::Denied, "manual proposal scope is unavailable") unless receipt
      if active.proposal_attempted
        raise EditorTools::Failure.new(EditorTools::Status::Denied, "only one proposal attempt is allowed per Lua run")
      end
      # The single proposal attempt is consumed before source/range checks,
      # including host rejection, so scripts cannot probe revisions repeatedly.
      active.proposal_attempted = true
      unless request.buffer_id == receipt.not_nil!.buffer_id && request.revision == receipt.not_nil!.revision
        raise EditorTools::Failure.new(EditorTools::Status::Denied, "proposal is outside the run-start selected buffer revision")
      end
      if active.receipt_revoked || !lua_edit_receipt_current?(receipt.not_nil!, check_view: true)
        active.receipt_revoked = true
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "selected proposal source changed")
      end

      editor = receipt.not_nil!.editor
      edits = request.edits.map do |edit|
        start_line = edit.start_line - 1
        end_line = edit.end_line - 1
        start_character = TextCoordinates.codepoint_to_utf16(editor, start_line, edit.start_column)
        end_character = TextCoordinates.codepoint_to_utf16(editor, end_line, edit.end_column)
        start_position = JSON::Any.new({
          "line"      => JSON::Any.new(start_line),
          "character" => JSON::Any.new(start_character),
        } of String => JSON::Any)
        end_position = JSON::Any.new({
          "line"      => JSON::Any.new(end_line),
          "character" => JSON::Any.new(end_character),
        } of String => JSON::Any)
        JSON::Any.new({
          "range" => JSON::Any.new({
            "start" => start_position,
            "end"   => end_position,
          } of String => JSON::Any),
          "newText" => JSON::Any.new(edit.new_text),
        } of String => JSON::Any)
      end
      plan = begin
        editor.prepare_document_edits(edits)
      rescue
        raise EditorTools::Failure.new(EditorTools::Status::InvalidRequest, "proposal ranges are invalid for the run-start buffer")
      end
      unless plan.changed?
        raise EditorTools::Failure.new(EditorTools::Status::InvalidRequest, "proposal does not change the run-start buffer")
      end
      require_editor_tools_permit!(permit)
      unless active.run.active? && !active.receipt_revoked &&
             lua_edit_receipt_current?(receipt.not_nil!, check_view: true)
        active.receipt_revoked = true
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "selected proposal source changed")
      end
      active.staged_proposal = LuaEditStagedProposal.new(receipt.not_nil!, plan)
      JSON::Any.new({
        "status"    => JSON::Any.new("pending_review"),
        "applied"   => JSON::Any.new(false),
        "buffer_id" => JSON::Any.new(receipt.not_nil!.buffer_id),
        "revision"  => JSON::Any.new(receipt.not_nil!.revision),
        "message"   => JSON::Any.new("No edit applied. Manual review is available only after this Lua process exits successfully."),
      } of String => JSON::Any)
    rescue failure : EditorTools::Failure
      raise failure
    rescue
      raise EditorTools::Failure.new(EditorTools::Status::InvalidRequest, "Lua proposal could not be prepared")
    end

    private def drain_lua_script_run : Bool
      active = @lua_active_run
      return false unless active
      changed = false
      active.not_nil!.run.drain_events.each do |event|
        case event.kind
        when LuaScripts::EventKind::ToolRequest
          if request = event.request_json
            session = active.not_nil!.session
            response = if session && @lua_active_run.try(&.same?(active.not_nil!))
                         result = session.not_nil!.invoke_json(request.not_nil!)
                         if result.status.limit_exceeded?
                           active.not_nil!.failure_code_override = "editor_tools_limit_exceeded"
                           active.not_nil!.run.cancel
                         end
                         result.to_json
                       else
                         EditorTools::Result.new(event.call_id, EditorTools::Status::Denied, nil,
                           "Lua run was retired").to_json
                       end
            active.not_nil!.run.reply(event.call_id.not_nil!, response)
            changed = true
          end
        when LuaScripts::EventKind::Output
          if text = event.text
            @status_log.info("Lua [#{lua_script_run_tag(active.not_nil!)}] #{active.not_nil!.entry.name}: #{lua_safe_log_text(text.not_nil!, 2048)}")
            changed = true
          end
        when LuaScripts::EventKind::Complete
          active.not_nil!.terminal_event_seen = true
          finish_lua_script_run(active.not_nil!, success: true, failure_code: nil)
          changed = true
        when LuaScripts::EventKind::Failed
          active.not_nil!.terminal_event_seen = true
          finish_lua_script_run(active.not_nil!, success: false,
            failure_code: event.failure_code, failure_message: event.failure_message)
          changed = true
        end
      end
      mark_dirty! if changed
      changed
    end

    private def finish_lua_script_run(active : LuaScriptRun, success : Bool,
                                      failure_code : String?, failure_message : String? = nil) : Nil
      return unless @lua_active_run.try(&.same?(active))
      unless active.run.reaped?
        retire_lua_script_run(active, cancel: true, wait: true)
        @status_log.error("Lua script failed: #{active.entry.name} [run=#{lua_script_run_tag(active)}] (worker_not_reaped)")
        return
      end
      active.session.try(&.close)
      active.wake_stopped.set(true)
      @lua_active_run = nil
      release_lua_execution(active.identity)
      active.terminal_success = success
      active.receipt_revoked = true unless success
      if success
        @status_log.success("Lua script complete: #{active.entry.name} [run=#{lua_script_run_tag(active)}]")
        if candidate = active.staged_proposal
          receipt = candidate.not_nil!.receipt
          if lua_edit_receipt_current?(receipt, check_view: true) && !lua_proposal_modal_conflict?
            open_lua_edit_proposal(candidate.not_nil!)
          else
            @status_log.warning("Lua proposed edits were discarded because the selected source or review context changed")
          end
        end
      else
        active.staged_proposal = nil
        code = active.failure_code_override || failure_code || active.run.failure_code || "worker_failed"
        if code == "cancelled"
          @status_log.warning("Lua script cancelled: #{active.entry.name} [run=#{lua_script_run_tag(active)}]")
        else
          detail = lua_failure_detail(code, failure_message)
          suffix = detail ? ": #{detail.not_nil!}" : ""
          @status_log.error("Lua script failed: #{active.entry.name} [run=#{lua_script_run_tag(active)}] (#{code})#{suffix}")
        end
      end
      mark_dirty!
    end

    private def cancel_lua_script_action : Nil
      active = @lua_active_run
      unless active
        @status_log.info("No Lua script is active")
        mark_dirty!
        return
      end
      name = active.not_nil!.entry.name
      run_tag = lua_script_run_tag(active.not_nil!)
      reaped = retire_lua_script_run(active.not_nil!, cancel: true, wait: true)
      if reaped
        @status_log.warning("Lua script cancelled: #{name} [run=#{run_tag}]")
      else
        @status_log.warning("Lua script cancellation requested: #{name} [run=#{run_tag}]; worker cleanup is still pending")
      end
      mark_dirty!
    end

    # Retirement revokes the App-owned session before stopping the child so
    # no queued or late RPC can retain editor authority.
    private def retire_lua_script_run(active : LuaScriptRun? = @lua_active_run,
                                      cancel : Bool = true, wait : Bool = false) : Bool
      return true unless active
      state = active.not_nil!
      state.staged_proposal = nil
      state.receipt_revoked = true
      state.session.try(&.close)
      if cancel && !state.run.reaped?
        if wait
          unless state.run.cancel_and_wait(1.second)
            @status_log.error("Lua worker [run=#{lua_script_run_tag(state)}] was cancelled; reaping is still pending")
          end
        else
          state.run.cancel
        end
      end
      if state.run.reaped? && state.terminal_event_seen
        @lua_active_run = nil if @lua_active_run.try(&.same?(state))
        state.wake_stopped.set(true)
        release_lua_execution(state.identity)
      elsif @editor_tools_shutdown
        # The supervisor retains bounded kill/reap ownership during committed
        # App shutdown; no later App start can reuse this process slot.
        state.wake_stopped.set(true)
      else
        # Keep owner wakeups alive until the terminal event is drained and the
        # worker is reaped. Clearing it here would strand the shared lease.
        wake_lua_script_owner(state)
      end
      discard_lua_popup_for_run(state.identity)
      state.run.reaped? && state.terminal_event_seen
    end

    private def wake_lua_script_owner(active : LuaScriptRun) : Nil
      events = @input.events
      spawn do
        loop do
          break if active.wake_stopped.get
          select
          when events.send(Tui::WakeupEvent.new)
          else
          end
          sleep 10.milliseconds
        end
      rescue
      end
    end

    private def lua_script_active? : Bool
      !@lua_active_run.nil?
    end

    private def lua_execution_busy? : Bool
      !@lua_execution_owner.nil?
    end

    private def reserve_lua_execution(identity : String) : Bool
      return false if @lua_execution_owner
      @lua_execution_owner = identity.dup
      true
    end

    private def release_lua_execution(identity : String) : Nil
      @lua_execution_owner = nil if @lua_execution_owner == identity
    end

    private def lua_script_review_active? : Bool
      active_input_mode == LUA_REVIEW_MODE && !@lua_review_entry.nil?
    end

    private def capture_lua_selected_buffer_context(context : EditorTools::Context) : NamedTuple(buffer_id: String, revision: String)?
      owner = active_buffer_internal
      editor = active_editor_internal.as?(EditingTextEditor)
      return unless owner && editor && editor.not_nil!.document.same?(owner.not_nil!.editor.document)
      return unless owner.not_nil!.views.any? { |view| view.same?(editor.not_nil!) }
      reference = editor_tool_buffer_reference(owner.not_nil!)
      reference.refresh_revision!
      canonical = canonical_editor_tool_file(owner.not_nil!.path, context)
      return unless canonical
      return unless editor_tools_relative_path(canonical.not_nil!, context)
      {buffer_id: reference.id, revision: reference.revision}
    rescue
      nil
    end

    private def capture_lua_proposal_receipt(run_identity : String) : LuaEditProposalReceipt
      context = editor_tools_current_context
      owner = active_buffer_internal || raise "selected buffer is unavailable"
      editor = active_editor_internal.as?(EditingTextEditor) || raise "selected editor is unavailable"
      unless owner.not_nil!.views.any? { |view| view.same?(editor.not_nil!) } &&
             editor.not_nil!.document.same?(owner.not_nil!.editor.document)
        raise "selected editor is not a live view of the selected buffer"
      end
      raise "selected buffer event version is exhausted" if owner.not_nil!.version == Int32::MAX
      reference = editor_tool_buffer_reference(owner.not_nil!)
      reference.refresh_revision!
      canonical = canonical_editor_tool_file(owner.not_nil!.path, context)
      relative = canonical.try { |path| editor_tools_relative_path(path, context) }
      raise "selected buffer path is unavailable" unless relative
      LuaEditProposalReceipt.new(
        run_identity, reference.id, reference.revision, owner.not_nil!, editor.not_nil!,
        active_editor_tabs, owner.not_nil!.version, @lua_script_view_epoch,
        @active_editor_group, context, relative.not_nil!, reference,
        reference.snapshot, reference.line_ending
      )
    end

    private def lua_same_review_target?(reviewed : LuaEditProposalReceipt,
                                        current : LuaEditProposalReceipt) : Bool
      reviewed.buffer_id == current.buffer_id && reviewed.revision == current.revision &&
        reviewed.owner.same?(current.owner) && reviewed.editor.same?(current.editor) &&
        reviewed.editor_group.same?(current.editor_group) && reviewed.owner_version == current.owner_version &&
        reviewed.view_epoch == current.view_epoch && reviewed.group == current.group &&
        reviewed.context == current.context && reviewed.source_relative_path == current.source_relative_path &&
        reviewed.reference.same?(current.reference) && reviewed.editor.document.buffer.same_state?(current.snapshot) &&
        reviewed.line_ending == current.line_ending
    end

    private def lua_edit_receipt_current?(receipt : LuaEditProposalReceipt,
                                          check_view : Bool = true) : Bool
      return false if receipt.owner.version == Int32::MAX || receipt.owner.version != receipt.owner_version
      return false unless receipt.context == editor_tools_current_context
      return false unless receipt.owner.views.any? { |view| view.same?(receipt.editor) }
      return false unless receipt.editor.document.same?(receipt.owner.editor.document)
      return false unless @document_session.open_buffers[receipt.owner.path.to_s]?.try(&.same?(receipt.owner))
      return false unless receipt.editor.document.line_ending == receipt.line_ending
      return false unless receipt.editor.document.buffer.same_state?(receipt.snapshot)
      if check_view
        return false unless @lua_script_view_epoch == receipt.view_epoch
        return false unless @active_editor_group == receipt.group
        return false unless active_editor_tabs.same?(receipt.editor_group)
        return false unless active_buffer_internal.try(&.same?(receipt.owner))
        return false unless active_editor_internal.try(&.same?(receipt.editor))
      end
      reference = resolve_editor_tool_buffer(receipt.buffer_id, receipt.context)
      reference.refresh_revision!
      return false unless reference.same?(receipt.reference)
      return false unless reference.id == receipt.buffer_id && reference.revision == receipt.revision
      canonical = canonical_editor_tool_file(receipt.owner.path, receipt.context)
      relative = canonical.try { |path| editor_tools_relative_path(path, receipt.context) }
      relative == receipt.source_relative_path
    rescue
      false
    end

    private def lua_script_document_changed(buffer : OpenBuffer) : Nil
      if active = @lua_active_run
        if receipt = active.not_nil!.receipt
          if receipt.not_nil!.owner.same?(buffer)
            active.not_nil!.receipt_revoked = true
            active.not_nil!.staged_proposal = nil
          end
        end
      end
      if receipt = @lsp_popup.lua_proposal_receipt
        revoke_lua_edit_proposal("Lua proposed edits were discarded because the source buffer changed") if receipt.not_nil!.owner.same?(buffer)
      end
    end

    private def lua_script_view_changed : Nil
      @lua_script_view_epoch &+= 1_u64
      if active = @lua_active_run
        active.not_nil!.receipt_revoked = true if active.not_nil!.receipt
        active.not_nil!.staged_proposal = nil
      end
      revoke_lua_edit_proposal("Lua proposed edits were discarded because the active editor changed") if @lsp_popup.lua_proposal_open?
    end

    private def lua_script_context_retired : Nil
      retire_lua_script_run(cancel: true, wait: true)
      revoke_lua_edit_proposal("Lua proposed edits were discarded because the project context changed")
    end

    private def lua_review_content_lines(entry : LuaScripts::Entry,
                                         target : LuaEditProposalReceipt?, width : Int32) : Array(String)
      lines = [] of String
      append_lua_review_line(lines, "Script: #{entry.name}", width)
      append_lua_review_line(lines, "Source SHA-256: #{entry.digest}", width)
      append_lua_review_line(lines, "Source: #{entry.builtin? ? "built-in" : "trusted local user catalog"}", width)
      capabilities = entry.capabilities
      if capabilities.empty?
        append_lua_review_line(lines, "Requested capabilities: none", width)
      else
        append_lua_review_line(lines, "Requested capabilities:", width)
      end
      capabilities.each do |capability|
        disclosure = case capability
                     when .read_editor?   then "ReadEditor: bounded shared buffer/list/search reads (not selected-buffer-only)"
                     when .read_debugger? then "ReadDebugger: bounded debugger snapshot reads"
                     when .navigate?      then "Navigate: open/focus files and buffers inside the project"
                     when .propose_edits? then "ProposeEdits: one proposal attempt; explicit inline review only"
                     else                      "#{capability.wire_name}: granted editor tools"
                     end
        append_lua_review_line(lines, "  #{disclosure}", width)
      end
      if entry.capabilities.includes?(EditorTools::Capability::ProposeEdits)
        if receipt = target
          append_lua_review_line(lines, "Proposal target: #{receipt.not_nil!.source_relative_path}, revision #{receipt.not_nil!.revision}", width)
        else
          append_lua_review_line(lines, "Proposal target: unavailable; run cannot be approved", width)
        end
        append_lua_review_line(lines, "No proposal is applied or saved automatically; accepted edits remain undoable", width)
      end
      lines << "Runtime limits: 5 s wall time · 8 MiB Lua heap · 64 KiB source"
      lines << "Output: 16 KiB / 64 events · tools: 64 calls · 8 KiB/request"
      lines << "Editor results: 64 KiB/call · 512 KiB cumulative; no shell or network"
      lines.flat_map { |line| lua_wrap_text(line, width) }
    end

    private def append_lua_review_line(lines : Array(String), text : String, width : Int32) : Nil
      lines.concat(lua_wrap_text(text, width))
    end

    private def lua_wrap_text(text : String, width : Int32) : Array(String)
      rows = [] of String
      row = String::Builder.new
      used = 0
      limit = [width, 1].max
      text.each_grapheme do |grapheme|
        glyph = grapheme.to_s
        glyph_width = Tui::Unicode.grapheme_width(glyph)
        if used > 0 && used + glyph_width > limit
          rows << row.to_s
          row = String::Builder.new
          used = 0
        end
        row << glyph
        used += glyph_width
      end
      rows << row.to_s unless row.empty?
      rows << "" if rows.empty?
      rows
    end

    private def render_lua_script_review(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      entry = @lua_review_entry
      return unless entry
      geometry = lua_review_modal_geometry
      width = geometry[:width]
      height = geometry[:height]
      if width < 42 || height < 8
        draw_text_line(buffer, clip, @rect.x, @rect.y, "Review Lua script", Tui::Style.new(fg: Theme::Popup.title), @rect.width)
        draw_text_line(buffer, clip, @rect.x, @rect.y + 1, "Resize to review all | Esc: cancel", Tui::Style.new(fg: Theme::Popup.text), @rect.width) if @rect.height > 1
        return
      end
      x = @rect.x + (@rect.width - width) // 2
      y = @rect.y + (@rect.height - height) // 2
      modal_clip = clip.intersect(Tui::Rect.new(x, y, width, height))
      return unless modal_clip
      bg = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      border = Tui::Style.new(fg: Theme::Popup.border, bg: Theme::Popup.active_bg)
      title = Tui::Style.new(fg: Theme::Popup.title, bg: Theme::Popup.active_bg, attrs: Tui::Attributes::Bold)
      muted = Tui::Style.new(fg: Theme::Status.timestamp, bg: Theme::Popup.active_bg)
      active = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg, attrs: Tui::Attributes::Bold)
      draw_box_border(buffer, modal_clip.not_nil!, x, y, width, height, border, bg, "Review Lua script: #{entry.not_nil!.name}", title)
      content_width = geometry[:content_width]
      @lua_review_lines = lua_review_content_lines(entry.not_nil!, @lua_review_target, content_width)
      @lua_review_lines.first(geometry[:visible]).each_with_index do |line, index|
        draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 1 + index, line, index == 0 ? active : bg, content_width)
      end
      footer = lua_script_review_approvable? ? "Enter: run once | Esc: cancel" : "Resize to review all | Esc: cancel"
      draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2, footer, muted, content_width)
    end

    # Keep layout calculation shared by the renderer and approval gate so
    # Enter cannot approve disclosures the current viewport clips.
    private def lua_review_modal_geometry : NamedTuple(width: Int32, height: Int32, content_width: Int32, visible: Int32)
      width = [@rect.width - 2, 96].min
      height = [@rect.height, 30].min
      {width: width, height: height, content_width: width - 4, visible: height - 4}
    end

    private def open_lua_edit_proposal(candidate : LuaEditStagedProposal) : Nil
      receipt = candidate.receipt
      raise "Lua proposal receipt is stale" unless lua_edit_receipt_current?(receipt, check_view: true)
      preview = candidate.plan.inline_preview(LUA_SCRIPT_PREVIEW_TITLE)
      @lsp_popup.clear_completion
      @lsp_popup.clear_quick_fix
      @lsp_popup.clear_formatting
      @lsp_popup.clear_refactor
      @lsp_popup.title = LUA_SCRIPT_PREVIEW_TITLE
      @lsp_popup.lines = candidate.plan.preview_lines
      @lsp_popup.lua_proposal_receipt = receipt
      @lsp_popup.lua_proposal_plan = candidate.plan
      @lsp_popup.lua_proposal_preview = preview
      @lsp_popup.lua_proposal_top = 0
      @lsp_popup.lua_proposal_max_lines = 16
      @lsp_popup.open = true
      @clipboard_paste_generation &+= 1_u64
      with_input_mode_guard(InputModeController::InputMode::LspPopup) do
        previous_overlay = @lsp_popup.overlay
        @lsp_popup.overlay = ->(surface : Tui::Buffer, clip : Tui::Rect) { render_lsp_popup(surface, clip, 16) }
        @lsp_popup.overlay = open_overlay(previous_overlay, @lsp_popup.overlay.not_nil!)
      end
      @status_log.info("Lua proposed edits ready for manual review in #{receipt.source_relative_path}")
    rescue
      revoke_lua_edit_proposal("Lua proposed edits could not be opened for manual review")
    end

    private def lua_proposal_modal_conflict? : Bool
      active_input_mode != InputModeController::InputMode::Normal || @lsp_popup.open ||
        @context_menu.open || close_confirmation_active? || external_review_active? || recovery_review_active?
    rescue
      true
    end

    private def discard_lua_popup_for_run(identity : String) : Nil
      receipt = @lsp_popup.lua_proposal_receipt
      return unless receipt && receipt.not_nil!.run_identity == identity
      clear_lua_edit_popup
    end

    private def revoke_lua_edit_proposal(message : String? = nil) : Nil
      if active = @lua_active_run
        if active.not_nil!.receipt
          active.not_nil!.receipt_revoked = true
          active.not_nil!.staged_proposal = nil
        end
      end
      had = !@lsp_popup.lua_proposal_receipt.nil? || !@lsp_popup.lua_proposal_plan.nil?
      clear_lua_edit_popup if had
      if had
        @status_log.warning(message) if message
        mark_dirty!
      end
    end

    private def clear_lua_edit_popup : Nil
      @lsp_popup.clear_lua_proposal
      @lsp_popup.title = ""
      @lsp_popup.lines = [] of String
      close_modal(@lsp_popup, InputModeController::InputMode::LspPopup)
      close_overlay(@lsp_popup.overlay)
      @lsp_popup.overlay = nil
    end

    private def accept_lua_edit_proposal(selected_ids : Array(Int32)?) : Nil
      receipt = @lsp_popup.lua_proposal_receipt
      plan = @lsp_popup.lua_proposal_plan
      unless receipt && plan && lua_edit_receipt_current?(receipt.not_nil!, check_view: true)
        revoke_lua_edit_proposal("Lua proposed edits are stale; nothing was applied")
        return
      end
      editor = receipt.not_nil!.editor
      clear_lua_edit_popup
      unless lua_edit_receipt_current?(receipt.not_nil!, check_view: true)
        @status_log.warning("Lua proposed edits are stale; nothing was applied")
        mark_dirty!
        return
      end
      applied = if selected_ids
                  editor.apply_selected_document_edits(plan.not_nil!, selected_ids.not_nil!)
                else
                  editor.apply_document_edits(plan.not_nil!)
                end
      unless applied
        @status_log.warning("Lua proposed edits are stale; nothing was applied")
        mark_dirty!
        return
      end
      editor.focus
      detail = selected_ids ? " (#{selected_ids.not_nil!.size} selected edits)" : ""
      @status_log.success("Lua proposed edits accepted#{detail}; not saved · Undo to restore")
      mark_dirty!
    rescue
      revoke_lua_edit_proposal("Lua proposed edits could not be applied; buffer unchanged")
    end

    private def handle_lua_proposal_preview_input(event : Tui::KeyEvent) : Bool
      case
      when formatting_apply_key_event?(event)
        receipt = @lsp_popup.lua_proposal_receipt
        preview = @lsp_popup.lua_proposal_preview
        unless receipt && preview && inline_preview_reviewable?(preview.not_nil!, receipt.not_nil!.editor.rect)
          @status_log.warning("Resize the editor to inspect proposed changes before accepting")
          mark_dirty!
          return true
        end
        if preview.not_nil!.selected_group_count == 0
          @status_log.warning("Select at least one proposed edit before applying")
        else
          selected = preview.not_nil!.all_edit_groups_selected? ? nil : preview.not_nil!.selected_source_edit_indices
          accept_lua_edit_proposal(selected)
        end
        return true
      when formatting_cancel_key_event?(event)
        revoke_lua_edit_proposal("Lua proposed edits rejected; buffer unchanged")
        return true
      when formatting_toggle_group_key_event?(event)
        toggle_document_edit_group
        mark_dirty!
        return true
      when formatting_select_all_key_event?(event)
        select_document_edit_groups(true)
        mark_dirty!
        return true
      when formatting_select_none_key_event?(event)
        select_document_edit_groups(false)
        mark_dirty!
        return true
      when formatting_up_key_event?(event)
        move_document_edit_scroll(-1)
        mark_dirty!
        return true
      when formatting_down_key_event?(event)
        move_document_edit_scroll(1)
        mark_dirty!
        return true
      when formatting_page_up_key_event?(event)
        move_document_edit_page(-1)
        mark_dirty!
        return true
      when formatting_page_down_key_event?(event)
        move_document_edit_page(1)
        mark_dirty!
        return true
      when formatting_home_key_event?(event)
        move_document_edit_home
        mark_dirty!
        return true
      when formatting_end_key_event?(event)
        move_document_edit_end
        mark_dirty!
        return true
      when formatting_next_change_key_event?(event)
        move_document_edit_change(1)
        mark_dirty!
        return true
      when formatting_previous_change_key_event?(event)
        move_document_edit_change(-1)
        mark_dirty!
        return true
      when formatting_horizontal_left_key_event?(event)
        move_document_edit_horizontal(-1, formatting_horizontal_fine_key_event?(event))
        mark_dirty!
        return true
      when formatting_horizontal_right_key_event?(event)
        move_document_edit_horizontal(1, formatting_horizontal_fine_key_event?(event))
        mark_dirty!
        return true
      else
        true
      end
    end

    private def show_lua_script_log : Nil
      @bottom_panel_visible = true
      synchronize_geometry_before_input
      @chat_panel.not_nil!.select_log(focus: true)
      mark_dirty!
    rescue
      @status_log.info("Lua output and run status are in the status log")
      mark_dirty!
    end

    private def lua_script_run_tag(active : LuaScriptRun) : String
      active.identity[0, 8]
    end

    # Worker messages are already bounded, but keep the renderer/log boundary
    # independently control-safe in case that wire contract changes later.
    private def lua_safe_log_text(text : String, max_bytes : Int32) : String
      builder = String::Builder.new
      used = 0
      truncated = false
      text.each_char do |char|
        display = if char == '\n' || char == '\t' || !EditorTools.control_char?(char)
                    char.to_s
                  else
                    "�"
                  end
        if used + display.bytesize > max_bytes
          truncated = true
          break
        end
        builder << display
        used += display.bytesize
      end
      if truncated && used + "…".bytesize <= max_bytes
        builder << "…"
      end
      builder.to_s
    end

    private def lua_failure_detail(code : String, worker_message : String?) : String?
      case code
      when "lua_incompatible", "lua_unavailable", "lua_library_unavailable"
        "Lua 5.4 is required; set ADAMANTINE_LUA_LIBRARY to an absolute compatible shared-library path"
      when "script_error", "lua_compile_error"
        message = worker_message.try { |text| lua_safe_log_text(text, 512) }
        message && !message.empty? ? message : "script syntax or runtime failure (no diagnostic supplied)"
      else
        worker_message.try { |text| lua_safe_log_text(text, 512) }
      end
    end
  end
end
