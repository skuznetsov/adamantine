require "atomic"
require "json"
require "random/secure"

require "./chat_submission"
require "./editor_tools"
require "./editor_tools_controller"
require "./lua_script_catalog"
require "./lua_script_runtime"

module Adamantine
  module ChatLuaController
    CHAT_LUA_PICKER_ACTION_PREFIX = "chat.lua.script:"
    CHAT_LUA_OUTPUT_BYTES         = 16 * 1024

    @chat_lua_picker_active : Bool = false
    @chat_lua_selected_entry : LuaScripts::Entry? = nil
    @chat_lua_turn_entry : LuaScripts::Entry? = nil
    @chat_lua_turn_context : Chat::SubmissionContext? = nil
    @chat_lua_turn_receipt : ChatEditProposalReceipt? = nil
    @chat_lua_turn_attempted = false
    @chat_lua_child_succeeded = false
    @chat_lua_child_failed = false
    @chat_lua_worker_active : Bool = false
    @chat_lua_active_run : ChatLuaRun? = nil

    # A Chat child retains the deferred parent ticket until its bounded process
    # is reaped. All fields are App-owner state; the worker only communicates
    # through LuaScripts::Run's bounded event queue.
    class ChatLuaRun
      getter identity : String
      getter entry : LuaScripts::Entry
      getter ticket : EditorTools::DeferredCall
      getter run : LuaScripts::Run
      getter context : Chat::SubmissionContext
      getter receipt : ChatEditProposalReceipt
      getter session : EditorTools::Session
      getter wake_stopped : Atomic(Bool)
      property terminal_event_seen = false
      property failure_code : String? = nil
      property failure_message : String? = nil
      property failure_result : EditorTools::Result? = nil
      property output : String = ""
      property output_bytes = 0
      property retired = false

      def initialize(@identity : String, @entry : LuaScripts::Entry,
                     @ticket : EditorTools::DeferredCall,
                     @run : LuaScripts::Run,
                     @context : Chat::SubmissionContext,
                     @receipt : ChatEditProposalReceipt,
                     @session : EditorTools::Session)
        @wake_stopped = Atomic(Bool).new(false)
      end
    end

    private def chat_lua_picker_entries : Array(CommandEntry)
      @lua_script_catalog.entries.map do |entry|
        requested = entry.capabilities.map(&.wire_name).join(", ")
        detail = requested.empty? ? "No editor capabilities requested" : "Requests: #{requested}"
        CommandEntry.new(entry.name, "#{CHAT_LUA_PICKER_ACTION_PREFIX}#{entry.id}", [] of String,
          detail, "", "", false)
      end
    end

    private def open_chat_lua_script_picker : Nil
      if reason = chat_lua_selection_unavailable_reason
        @status_log.warning(reason)
        mark_dirty!
        return
      end
      @lua_script_catalog = LuaScripts::Catalog.new unless @lua_catalog_injected
      if error = @lua_script_catalog.user_error
        @status_log.warning(error.not_nil!)
      end
      @lua_picker_active = false
      @chat_lua_picker_active = true
      @command_palette.mode = CommandPaletteState::Mode::Discovery
      @command_palette.input = ""
      @command_palette.selected_index = 0
      @command_palette.scroll = 0
      @command_palette.argument_hint = ""
      @command_palette.prepared_action = nil
      update_command_palette_candidates
      mark_dirty!
    end

    private def open_chat_lua_picker_for_context(mode : Chat::ContextMode) : Nil
      if reason = chat_context_unavailable_reason(mode)
        @status_log.warning(reason)
        mark_dirty!
        return
      end
      unless mode.tool_context?
        @status_log.warning("Chat Lua requires an approved editor tool context")
        mark_dirty!
        return
      end
      @chat_context_mode = mode
      @chat_panel.not_nil!.context_label = chat_context_header_label(mode)
      @status_log.info("Chat context set to #{chat_context_header_label(mode)}; choose one Lua script for the next reviewed send")
      open_command_palette("")
      open_chat_lua_script_picker
    end

    private def select_chat_lua_script(entry_id : String) : Nil
      entry = @lua_script_catalog.find(entry_id)
      unless entry
        @status_log.warning("Lua script is no longer in the trusted local catalog")
        mark_dirty!
        return
      end
      if reason = chat_lua_selection_unavailable_reason
        @status_log.warning(reason)
        mark_dirty!
        return
      end
      @chat_lua_selected_entry = entry
      @status_log.info("Chat Lua script selected for the next turn: #{entry.name} [#{entry.digest[0, 12]}]")
      mark_dirty!
    end

    private def clear_chat_lua_script_selection : Nil
      return unless @chat_lua_selected_entry
      previous = @chat_lua_selected_entry.not_nil!
      @chat_lua_selected_entry = nil
      @status_log.info("Chat Lua script selection cleared: #{previous.name}")
      mark_dirty!
    end

    private def chat_lua_selection_unavailable_reason : String?
      return "Chat Lua requires an external Chat provider" unless chat_external_transport?
      return "Choose an editor tool context before selecting a Chat Lua script" unless @chat_context_mode.tool_context?
      if reason = chat_context_unavailable_reason(@chat_context_mode)
        return reason
      end
      return "Wait for the current Chat request to finish before selecting a Lua script" if @chat_frontend.try(&.active?)
      return "Cancel the active local Lua script before selecting Chat Lua" if lua_script_active?
      return "Close the local Lua review before selecting Chat Lua" if lua_script_review_active?
      return "A Lua worker is already active" if lua_execution_busy?
      nil
    rescue
      "Chat Lua selection is unavailable"
    end

    private def chat_lua_selection_eligible? : Bool
      @chat_context_mode.tool_context?
    end

    private def chat_lua_selected_entry : LuaScripts::Entry?
      @chat_lua_selected_entry
    end

    private def chat_lua_turn_entry : LuaScripts::Entry?
      @chat_lua_turn_entry
    end

    private def chat_lua_picker_active? : Bool
      @chat_lua_picker_active
    end

    private def chat_lua_active? : Bool
      @chat_lua_worker_active
    end

    private def chat_lua_effective_capabilities(entry : LuaScripts::Entry,
                                                mode : Chat::ContextMode) : Array(EditorTools::Capability)
      available = if mode.proposal_context?
                    [EditorTools::Capability::ReadEditor, EditorTools::Capability::ProposeEdits]
                  elsif mode.tool_context?
                    [EditorTools::Capability::ReadEditor]
                  else
                    [] of EditorTools::Capability
                  end
      entry.capabilities.select { |capability| available.includes?(capability) }
    end

    private def chat_lua_grant(mode : Chat::ContextMode) : Chat::LuaScriptGrant?
      entry = @chat_lua_selected_entry
      return unless entry
      return unless mode.tool_context?
      Chat::LuaScriptGrant.new(entry.not_nil!.id, entry.not_nil!.name,
        entry.not_nil!.digest, chat_lua_effective_capabilities(entry.not_nil!, mode))
    end

    private def chat_lua_turn_started(context : Chat::SubmissionContext,
                                      entry : LuaScripts::Entry?) : Nil
      @chat_lua_turn_entry = entry
      # Also guards ordinary Chat buffer-tool calls when no Lua grant exists.
      @chat_lua_turn_context = context
      @chat_lua_turn_receipt = nil
      @chat_lua_turn_attempted = false
      @chat_lua_child_succeeded = false
      @chat_lua_child_failed = false
    end

    private def chat_lua_turn_finished : Nil
      @chat_lua_turn_entry = nil
      @chat_lua_turn_context = nil
      @chat_lua_turn_receipt = nil
      @chat_lua_turn_attempted = false
      @chat_lua_child_succeeded = false
      @chat_lua_child_failed = false
    end

    private def chat_lua_child_succeeded? : Bool
      @chat_lua_child_succeeded
    end

    private def chat_lua_child_failed? : Bool
      @chat_lua_child_failed
    end

    private def chat_lua_turn_attempted? : Bool
      @chat_lua_turn_attempted
    end

    private def observe_chat_lua_turn_end : Nil
      return unless @chat_lua_turn_entry
      return if @chat_lua_active_run || @chat_lua_worker_active
      return if @chat_frontend.try(&.active?)
      chat_lua_turn_finished
    end

    private def chat_lua_context_json(context : Chat::SubmissionContext) : JSON::Any
      selected = JSON::Any.new({
        "buffer_id" => JSON::Any.new(context.buffer_id || ""),
        "revision"  => JSON::Any.new(context.revision || ""),
      } of String => JSON::Any)
      range = context.source_range.try do |source_range|
        JSON::Any.new({
          "start_line"   => JSON::Any.new(source_range.start_line),
          "start_column" => JSON::Any.new(source_range.start_column),
          "end_line"     => JSON::Any.new(source_range.end_line),
          "end_column"   => JSON::Any.new(source_range.end_column),
        } of String => JSON::Any)
      end
      mode = if context.mode.selection_proposals?
               "selection_proposals"
             elsif context.mode.buffer_proposals?
               "buffer_proposals"
             else
               "buffer_tools"
             end
      JSON::Any.new({
        "mode"             => JSON::Any.new(mode),
        "selected_buffer"  => selected,
        "source_path"      => JSON::Any.new(context.source_path || ""),
        "source_range"     => range ? range.not_nil! : JSON::Any.new(nil),
        "coordinate_units" => JSON::Any.new("1-based lines, 0-based Unicode codepoint columns; end-exclusive"),
        "scope"            => JSON::Any.new(context.mode.selection_proposals? ? "selection" : (context.mode.buffer_proposals? ? "whole_file" : "read_only")),
      } of String => JSON::Any)
    end

    private def chat_lua_deferred_tool(ticket : EditorTools::DeferredCall,
                                       context : Chat::SubmissionContext) : Nil
      entry = @chat_lua_turn_entry
      grant = context.lua_script_grant
      unless entry && grant && @chat_lua_turn_context.try(&.== context) &&
             @chat_frontend.try(&.active?) && ticket.active?
        reject_chat_lua_deferred(ticket, EditorTools::Status::Denied,
          "approved named script is unavailable for this Chat turn", context)
        return
      end
      selected = entry.not_nil!
      unless grant.not_nil!.id == selected.id && grant.not_nil!.name == selected.name &&
             grant.not_nil!.digest == selected.digest &&
             grant.not_nil!.effective_capabilities == chat_lua_effective_capabilities(selected, context.mode) &&
             ticket.request.script_id == selected.id
        reject_chat_lua_deferred(ticket, EditorTools::Status::Denied,
          "named script does not match the frozen Send review", context)
        return
      end
      if @chat_lua_turn_attempted || @chat_lua_worker_active || lua_execution_busy?
        reject_chat_lua_deferred(ticket, EditorTools::Status::Busy,
          "only one Lua worker may run, and this Chat turn permits one script call", context)
        return
      end
      unless context.mode.tool_context?
        reject_chat_lua_deferred(ticket, EditorTools::Status::Denied,
          "Chat Lua is limited to an approved editor tool context", context)
        return
      end
      receipt = @chat_lua_turn_receipt
      unless receipt && chat_edit_receipt_current?(receipt.not_nil!, check_frontend_state: false)
        reject_chat_lua_deferred(ticket, EditorTools::Status::Stale,
          "approved selected-buffer receipt is stale", context)
        return
      end

      @chat_lua_turn_attempted = true
      @chat_lua_worker_active = true
      identity = Random::Secure.hex(16)
      unless reserve_lua_execution(identity)
        @chat_lua_worker_active = false
        reject_chat_lua_deferred(ticket, EditorTools::Status::Busy,
          "another Lua worker still owns the shared process slot", context)
        return
      end
      session : EditorTools::Session? = nil
      begin
        session = ticket.child_session(selected.capabilities)
        runner = @lua_script_runner || LuaScripts::Runner.new
        run = runner.start(selected.id, selected.source, chat_lua_context_json(context))
        active = ChatLuaRun.new(identity, selected, ticket,
          run, context, receipt.not_nil!, session.not_nil!)
        @chat_lua_active_run = active
        @status_log.info("Chat Lua started: #{selected.name} [#{selected.digest[0, 12]}]")
        wake_chat_lua_owner(active)
      rescue ex
        session.try(&.close)
        @chat_lua_worker_active = false
        release_lua_execution(identity) unless @chat_lua_active_run.try(&.identity) == identity
        owns_turn = @chat_lua_turn_context.try(&.== context) == true &&
                    @chat_lua_turn_entry.try(&.same?(selected)) == true
        if owns_turn
          @chat_lua_child_failed = true
          @chat_lua_child_succeeded = false
          if chat_lua_parent_context_current?(context)
            discard_chat_edit_candidate_keep_turn_receipt("Chat Lua failed before starting; any staged proposal was discarded")
          else
            discard_chat_edit_candidate("Chat Lua failed before starting; any staged proposal was discarded")
          end
        end
        if @chat_frontend.try(&.fail_deferred_tool(ticket, EditorTools::Status::Unavailable,
             "named script could not start: #{ex.message || "runtime unavailable"}")) != true
          ticket.fail(EditorTools::Status::Unavailable, "named script could not start")
        end
      end
      mark_dirty!
    end

    private def drain_chat_lua_run : Bool
      active = @chat_lua_active_run
      return false unless active
      changed = false
      unless chat_lua_active_current?(active.not_nil!)
        retire_chat_lua_for_stale_receipt(active.not_nil!)
        changed = true
      end
      active.not_nil!.run.drain_events.each do |event|
        case event.kind
        when LuaScripts::EventKind::ToolRequest
          next if active.not_nil!.retired
          call_id = event.call_id
          raw = event.request_json
          unless call_id && raw && chat_lua_active_current?(active.not_nil!)
            mark_chat_lua_failure(active.not_nil!, EditorTools::Status::InvalidRequest,
              "named script emitted an invalid or stale editor-tool request")
            active.not_nil!.run.cancel unless active.not_nil!.run.reaped?
            changed = true
            next
          end
          session = active.not_nil!.session
          guard = ->(request : EditorTools::Request) { validate_chat_lua_request!(active.not_nil!, request) }
          result = session.invoke_json(raw.not_nil!, expected_call_id: call_id.not_nil!, request_guard: guard)
          active.not_nil!.run.reply(call_id.not_nil!, result.to_json)
          unless result.status.ok?
            note_chat_lua_child_refusal(active.not_nil!, result)
          end
          changed = true
        when LuaScripts::EventKind::Output
          next if active.not_nil!.retired
          if text = event.text
            if active.not_nil!.output_bytes + text.not_nil!.bytesize <= CHAT_LUA_OUTPUT_BYTES
              active.not_nil!.output += text.not_nil!
              active.not_nil!.output_bytes += text.not_nil!.bytesize
            else
              mark_chat_lua_failure(active.not_nil!, EditorTools::Status::LimitExceeded,
                "named-script output exceeds the reviewed result limit")
              active.not_nil!.run.cancel unless active.not_nil!.run.reaped?
            end
            changed = true
          end
        when LuaScripts::EventKind::Complete
          active.not_nil!.terminal_event_seen = true
          changed = true
        when LuaScripts::EventKind::Failed
          active.not_nil!.failure_code = event.failure_code
          active.not_nil!.failure_message = event.failure_message
          active.not_nil!.terminal_event_seen = true
          changed = true
        end
      end

      if active = @chat_lua_active_run
        current = active.not_nil!
        if current.run.reaped? && current.terminal_event_seen
          finish_chat_lua_run(current)
          changed = true
        end
      end
      mark_dirty! if changed
      changed
    end

    private def validate_chat_lua_request!(active : ChatLuaRun,
                                           request : EditorTools::Request) : Nil
      raise EditorTools::Failure.new(EditorTools::Status::Stale, "named-script child was retired") unless chat_lua_active_current?(active)
      if active.ticket.child_failed?
        raise EditorTools::Failure.new(EditorTools::Status::Denied,
          "named-script child authority was revoked after an earlier refusal")
      end
      case request
      when EditorTools::ReadBufferRequest
        unless request.buffer_id == active.receipt.buffer_id && request.revision == active.receipt.revision
          raise EditorTools::Failure.new(EditorTools::Status::Denied, "read is outside the approved buffer revision")
        end
      when EditorTools::ProposeEditsRequest
        unless active.receipt.submission_mode.proposal_context? &&
               request.buffer_id == active.receipt.buffer_id && request.revision == active.receipt.revision
          raise EditorTools::Failure.new(EditorTools::Status::Denied, "proposal is outside the approved buffer revision and mode")
        end
      else
        raise EditorTools::Failure.new(EditorTools::Status::Denied,
          "Chat Lua child only supports exact selected-buffer reads and proposals")
      end

      frontend = @chat_frontend || raise EditorTools::Failure.new(
        EditorTools::Status::Stale, "Chat Lua frontend is unavailable")
      frontend.guard_deferred_buffer_request!(active.ticket, request)
    end

    private def chat_lua_active_current?(active : ChatLuaRun) : Bool
      @chat_lua_active_run.try(&.same?(active)) == true && !active.retired && active.ticket.active? &&
        @chat_lua_turn_context.try(&.== active.context) == true &&
        @chat_lua_turn_entry.try(&.same?(active.entry)) == true &&
        @chat_lua_turn_receipt.try(&.same?(active.receipt)) == true &&
        @chat_frontend.try(&.active?) == true && chat_edit_receipt_current?(active.receipt, check_frontend_state: false)
    rescue
      false
    end

    private def chat_lua_run_owns_current_turn?(active : ChatLuaRun) : Bool
      @chat_lua_turn_context.try(&.== active.context) == true &&
        @chat_lua_turn_entry.try(&.same?(active.entry)) == true &&
        @chat_lua_turn_receipt.try(&.same?(active.receipt)) == true
    end

    # Keep the exact selected-buffer receipt alive only while its parent Chat
    # turn remains current. This is deliberately separate from
    # DeferredCall#active?: that ticket is settled after the child result is
    # delivered, while the provider turn may continue using its root Session.
    private def chat_lua_parent_context_current?(context : Chat::SubmissionContext) : Bool
      receipt = @chat_lua_turn_receipt
      @chat_lua_turn_context.try(&.== context) == true &&
        @chat_frontend.try(&.active?) == true && !receipt.nil? &&
        @chat_edit_turn_receipt.try(&.same?(receipt.not_nil!)) == true &&
        chat_edit_receipt_current?(receipt.not_nil!, check_frontend_state: false)
    rescue
      false
    end

    private def chat_lua_parent_turn_current?(active : ChatLuaRun) : Bool
      chat_lua_run_owns_current_turn?(active) &&
        @chat_lua_turn_receipt.try(&.same?(active.receipt)) == true &&
        chat_lua_parent_context_current?(active.context)
    rescue
      false
    end

    private def note_chat_lua_child_refusal(active : ChatLuaRun,
                                            result : EditorTools::Result) : Nil
      if chat_lua_run_owns_current_turn?(active)
        @chat_lua_child_failed = true
        @chat_lua_child_succeeded = false
        if chat_lua_parent_turn_current?(active)
          discard_chat_edit_candidate_keep_turn_receipt("Chat Lua child was refused; staged proposals were discarded")
        else
          discard_chat_edit_candidate("Chat Lua child was refused; staged proposals were discarded")
        end
      end
      @status_log.warning("Chat Lua editor call refused: #{result.message || result.status.wire_name}")
    end

    private def mark_chat_lua_failure(active : ChatLuaRun,
                                      status : EditorTools::Status,
                                      message : String) : Nil
      return if active.failure_result
      result = EditorTools::Result.new(active.ticket.id, status, nil, message)
      active.failure_result = result
      owns_turn = chat_lua_run_owns_current_turn?(active)
      if owns_turn
        @chat_lua_child_failed = true
        @chat_lua_child_succeeded = false
      end
      active.session.close
      if owns_turn
        if chat_lua_parent_turn_current?(active)
          discard_chat_edit_candidate_keep_turn_receipt("Chat Lua child failed; staged proposals were discarded")
        else
          discard_chat_edit_candidate("Chat Lua child failed; staged proposals were discarded")
        end
      end
      active.run.cancel unless active.run.reaped?
    end

    private def finish_chat_lua_run(active : ChatLuaRun) : Nil
      return unless @chat_lua_active_run.try(&.same?(active))
      active.session.close
      owns_turn = chat_lua_run_owns_current_turn?(active)
      successful_worker = active.terminal_event_seen && active.failure_code.nil? &&
                          active.failure_result.nil? && !active.retired &&
                          chat_edit_receipt_current?(active.receipt, check_frontend_state: false)
      if successful_worker && active.ticket.active?
        data = JSON::Any.new({
          "script_id" => JSON::Any.new(active.entry.id),
          "name"      => JSON::Any.new(active.entry.name),
          "sha256"    => JSON::Any.new(active.entry.digest),
          "output"    => JSON::Any.new(active.output),
        } of String => JSON::Any)
        result = @chat_frontend.try(&.complete_deferred_tool_result(active.ticket, data))
        if result && result.not_nil!.ok? && !active.ticket.child_failed? && owns_turn
          @chat_lua_child_succeeded = true
          @status_log.success("Chat Lua complete: #{active.entry.name}")
        else
          if owns_turn
            @chat_lua_child_failed = true
            if chat_lua_parent_turn_current?(active)
              discard_chat_edit_candidate_keep_turn_receipt("Chat Lua child did not complete successfully; staged proposals were discarded")
            else
              discard_chat_edit_candidate("Chat Lua child did not complete successfully; staged proposals were discarded")
            end
          end
        end
      elsif active.ticket.active?
        code = active.failure_result.try(&.status.wire_name) || active.failure_code || "worker_failed"
        message = active.failure_result.try(&.message) || active.failure_message || "named script did not complete successfully"
        @chat_frontend.try(&.fail_deferred_tool(active.ticket,
          active.failure_result.try(&.status) || EditorTools::Status::Unavailable,
          "named script failed (#{code}): #{message}"))
        if owns_turn
          @chat_lua_child_failed = true
          if chat_lua_parent_turn_current?(active)
            discard_chat_edit_candidate_keep_turn_receipt("Chat Lua child failed; staged proposals were discarded")
          else
            discard_chat_edit_candidate("Chat Lua child failed; staged proposals were discarded")
          end
        end
      else
        if owns_turn
          @chat_lua_child_failed = true
          discard_chat_edit_candidate("Chat Lua did not complete successfully; staged proposals were discarded")
        end
        @status_log.warning("Chat Lua failed or was revoked: #{active.entry.name}")
      end
      active.wake_stopped.set(true)
      @chat_lua_active_run = nil
      @chat_lua_worker_active = false
      release_lua_execution(active.identity)
      mark_dirty!
    end

    private def reject_chat_lua_deferred(ticket : EditorTools::DeferredCall,
                                         status : EditorTools::Status,
                                         message : String,
                                         context : Chat::SubmissionContext) : Nil
      owns_turn = @chat_lua_turn_context.try(&.== context) == true &&
                  @chat_frontend.try(&.active?) == true && ticket.active?
      if owns_turn
        @chat_lua_turn_attempted = true
        @chat_lua_child_failed = true
        @chat_lua_child_succeeded = false
        if chat_lua_parent_context_current?(context)
          discard_chat_edit_candidate_keep_turn_receipt("Chat Lua request was denied; staged proposals were discarded")
        else
          discard_chat_edit_candidate("Chat Lua request was denied; staged proposals were discarded")
        end
      end
      if @chat_frontend.try(&.fail_deferred_tool(ticket, status, message)) != true
        ticket.fail(status, message)
      end
      mark_dirty!
    end

    private def retire_chat_lua_for_stale_receipt(active : ChatLuaRun) : Nil
      return unless @chat_lua_active_run.try(&.same?(active)) && !active.retired
      active.retired = true
      if chat_lua_run_owns_current_turn?(active)
        discard_chat_edit_candidate("Chat Lua work was revoked because its selected-buffer receipt changed")
        @chat_lua_child_failed = true
        @chat_lua_child_succeeded = false
      end
      # The parent Frontend owns the exact generation/ticket match. Its
      # cancellation closes the root Session and revokes the ticket before
      # the retirement callback cancels this child; never cancel a newer turn.
      cancelled_turn = @chat_frontend.try(&.cancel_deferred_turn(active.ticket)) || false
      unless cancelled_turn
        active.session.close
        active.ticket.revoke
        active.run.cancel unless active.run.reaped?
      end
      mark_dirty!
    end

    private def retire_chat_lua_deferred(ticket : EditorTools::DeferredCall) : Nil
      active = @chat_lua_active_run
      return unless active && active.not_nil!.ticket.same?(ticket)
      state = active.not_nil!
      state.retired = true
      state.session.close
      owns_turn = chat_lua_run_owns_current_turn?(state)
      discard_chat_edit_candidate("Chat Lua work was retired; staged proposals were discarded") if owns_turn
      state.ticket.revoke
      state.run.cancel unless state.run.reaped?
      if owns_turn
        @chat_lua_child_failed = true
        @chat_lua_child_succeeded = false
      end
      if state.run.reaped? && state.terminal_event_seen
        state.wake_stopped.set(true)
        @chat_lua_active_run = nil
        @chat_lua_worker_active = false
        release_lua_execution(state.identity)
      elsif @editor_tools_shutdown
        # Shutdown has committed; Runner retains bounded process reap ownership.
        state.wake_stopped.set(true)
      else
        # Frontend retirement revokes authority first, but the App must keep
        # draining until the runner publishes terminal state and is reaped.
        wake_chat_lua_owner(state)
      end
      mark_dirty!
    end

    private def retire_chat_lua_run(cancel : Bool = true, wait : Bool = false) : Bool
      active = @chat_lua_active_run
      return true unless active
      state = active.not_nil!
      state.retired = true
      state.session.close
      owns_turn = chat_lua_run_owns_current_turn?(state)
      discard_chat_edit_candidate if owns_turn
      state.ticket.revoke
      if cancel && !state.run.reaped?
        if wait
          state.run.cancel_and_wait(1.second)
        else
          state.run.cancel
        end
      end
      if state.run.reaped? && state.terminal_event_seen
        state.wake_stopped.set(true)
        @chat_lua_active_run = nil if @chat_lua_active_run.try(&.same?(state))
        @chat_lua_worker_active = false
        release_lua_execution(state.identity)
      elsif @editor_tools_shutdown
        # Committed shutdown leaves bounded kill/reap responsibility with the
        # Runner supervisor; there can be no subsequent worker start.
        state.wake_stopped.set(true)
      else
        @chat_lua_worker_active = true
        wake_chat_lua_owner(state)
      end
      state.run.reaped?
    end

    private def wake_chat_lua_owner(active : ChatLuaRun) : Nil
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
  end
end
