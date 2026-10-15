require "json"

require "../adamantine/editor_tools"
require "../adamantine/editor_tools_controller"
require "../adamantine/safe_document_edits"
require "../adamantine/text_coordinates"

module Adamantine
  # Manual-acceptance authority retained after a successful Chat turn. This is
  # deliberately separate from EditorTools::ExecutionPermit, which expires at
  # the end of one tool invocation.
  class ChatEditProposalReceipt
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
    getter provider_revision : UInt64
    getter provider_json : String
    getter proposal_revision : UInt64
    getter submission_mode : Chat::ContextMode
    getter reference : EditorToolsController::BufferReference
    getter snapshot : Tui::PieceTreeBuffer::Snapshot
    getter line_ending : String

    def initialize(
      @buffer_id : String,
      @revision : String,
      @owner : OpenBuffer,
      @editor : EditingTextEditor,
      @editor_group : Tui::TabbedPanel,
      @owner_version : Int32,
      @view_epoch : UInt64,
      @group : Int32,
      @context : EditorTools::Context,
      source_relative_path : String,
      @provider_revision : UInt64,
      provider_json : String,
      @proposal_revision : UInt64,
      @submission_mode : Chat::ContextMode,
      @reference : EditorToolsController::BufferReference,
      @snapshot : Tui::PieceTreeBuffer::Snapshot,
      line_ending : String,
    )
      @buffer_id = @buffer_id.dup
      @revision = @revision.dup
      @source_relative_path = source_relative_path.dup
      @provider_json = provider_json.dup
      @line_ending = line_ending.dup
    end
  end

  # A candidate remains private to the App until a successful Complete event.
  class ChatEditStagedProposal
    getter receipt : ChatEditProposalReceipt
    getter plan : SafeDocumentEdits::Plan

    def initialize(@receipt : ChatEditProposalReceipt, @plan : SafeDocumentEdits::Plan)
    end
  end

  module ChatEditController
    CHAT_EDIT_PREVIEW_TITLE = "Chat proposed edits · manual review"

    @chat_edit_view_epoch : UInt64 = 0_u64
    @chat_edit_turn_receipt : ChatEditProposalReceipt? = nil
    @chat_edit_staged_proposal : ChatEditStagedProposal? = nil
    @chat_edit_spent_revision : UInt64? = nil

    private def chat_edit_capture_turn(context : Chat::SubmissionContext) : ChatEditProposalReceipt
      approved = @chat_approved_tool_context
      raise "proposal scope is not approved" unless approved && approved.not_nil! == context
      approved_root = @chat_approved_tool_root_identity
      raise "proposal root was not approved" unless approved_root
      unless context.mode.buffer_tools? || context.mode.buffer_proposals?
        raise "selected-buffer tool context is unavailable"
      end
      raise "proposal buffer identity is unavailable" unless context.buffer_id && context.revision

      owner_context = editor_tools_current_context
      raise "proposal root changed" unless chat_root_identity(owner_context) == approved_root
      reference = resolve_editor_tool_buffer(context.buffer_id.not_nil!, owner_context)
      owner = reference.owner
      editor = active_editor_internal.as?(EditingTextEditor)
      raise "proposal buffer is no longer active" unless editor && active_buffer_internal.try(&.same?(owner))
      unless owner.views.any? { |view| view.same?(editor.not_nil!) } &&
             editor.not_nil!.document.same?(owner.editor.document)
        raise "proposal source is not a live view of the selected buffer"
      end
      raise "proposal source event version is exhausted" if owner.version == Int32::MAX

      reference.refresh_revision!
      unless reference.id == context.buffer_id && reference.revision == context.revision
        raise "proposal source revision changed"
      end
      canonical = canonical_editor_tool_file(owner.path, owner_context)
      relative = canonical.try { |path| editor_tools_relative_path(path, owner_context) }
      raise "proposal source path is unavailable" unless relative

      ChatEditProposalReceipt.new(
        reference.id,
        reference.revision,
        owner,
        editor.not_nil!,
        active_editor_tabs,
        owner.version,
        @chat_edit_view_epoch,
        @active_editor_group,
        owner_context,
        relative.not_nil!,
        @chat_provider_revision,
        @chat_provider_config.to_json,
        @chat_frontend.not_nil!.proposal_revision,
        context.mode,
        reference,
        editor.not_nil!.document.buffer.snapshot,
        editor.not_nil!.document.line_ending
      )
    end

    private def chat_edit_prepare_proposal(
      request : EditorTools::ProposeEditsRequest,
      permit : EditorTools::ExecutionPermit,
    ) : JSON::Any
      require_editor_tools_permit!(permit)
      receipt = @chat_edit_turn_receipt
      raise EditorTools::Failure.new(EditorTools::Status::Denied, "manual proposal scope is unavailable") unless receipt
      raise EditorTools::Failure.new(EditorTools::Status::Denied, "manual proposal scope is unavailable") unless receipt.not_nil!.submission_mode.buffer_proposals?
      current = @chat_frontend.not_nil!.proposal_revision
      raise EditorTools::Failure.new(EditorTools::Status::Stale, "proposal turn has expired") unless current == receipt.not_nil!.proposal_revision
      raise EditorTools::Failure.new(EditorTools::Status::Denied, "only one proposal is allowed per turn") if @chat_edit_spent_revision == current
      unless request.buffer_id == receipt.not_nil!.buffer_id && request.revision == receipt.not_nil!.revision
        raise EditorTools::Failure.new(EditorTools::Status::Denied, "proposal is outside the approved buffer revision")
      end
      # Once a well-formed tool request is bound to the exact approved source,
      # it spends this turn's single proposal attempt even if range validation
      # or SafeDocumentEdits later rejects the batch.
      @chat_edit_spent_revision = current
      raise EditorTools::Failure.new(EditorTools::Status::Busy, "a proposal is already staged for this turn") if @chat_edit_staged_proposal
      unless chat_edit_receipt_current?(receipt.not_nil!, check_frontend_state: false)
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "approved proposal source changed")
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
        range = JSON::Any.new({
          "start" => start_position,
          "end"   => end_position,
        } of String => JSON::Any)
        JSON::Any.new({
          "range"   => range,
          "newText" => JSON::Any.new(edit.new_text),
        } of String => JSON::Any)
      end
      plan = begin
        editor.prepare_document_edits(edits)
      rescue
        raise EditorTools::Failure.new(EditorTools::Status::InvalidRequest, "proposal ranges are invalid for the selected buffer")
      end
      unless plan.changed?
        raise EditorTools::Failure.new(EditorTools::Status::InvalidRequest, "proposal does not change the selected buffer")
      end
      require_editor_tools_permit!(permit)
      unless chat_edit_receipt_current?(receipt.not_nil!, check_frontend_state: false)
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "approved proposal source changed")
      end
      @chat_edit_staged_proposal = ChatEditStagedProposal.new(receipt.not_nil!, plan)
      JSON::Any.new({
        "status"    => JSON::Any.new("pending_review"),
        "applied"   => JSON::Any.new(false),
        "buffer_id" => JSON::Any.new(receipt.not_nil!.buffer_id),
        "revision"  => JSON::Any.new(receipt.not_nil!.revision),
        "message"   => JSON::Any.new("No edit applied. Manual review appears only after a successful response."),
      } of String => JSON::Any)
    rescue failure : EditorTools::Failure
      raise failure
    rescue
      raise EditorTools::Failure.new(EditorTools::Status::InvalidRequest, "proposal could not be prepared")
    end

    private def sync_chat_edit_proposal : Nil
      candidate = @chat_edit_staged_proposal
      unless candidate
        turn_receipt = @chat_edit_turn_receipt
        if turn_receipt && @chat_frontend.not_nil!.state != Chat::TurnState::Generating
          @chat_edit_turn_receipt = nil
        end
        return
      end

      receipt = candidate.not_nil!.receipt
      frontend = @chat_frontend.not_nil!
      if chat_lua_turn_attempted? && !chat_lua_child_succeeded?
        if frontend.state != Chat::TurnState::Generating
          discard_chat_edit_candidate("Chat proposed edits were discarded because the named script did not succeed")
        end
        return
      end
      unless frontend.state == Chat::TurnState::Complete &&
             frontend.proposal_revision == receipt.proposal_revision &&
             chat_edit_receipt_current?(receipt)
        if frontend.state != Chat::TurnState::Generating
          message = if frontend.state == Chat::TurnState::Complete
                      "Chat proposed edits were discarded because the approved source changed"
                    else
                      "Chat proposed edits were discarded because the response did not complete successfully"
                    end
          discard_chat_edit_candidate(message)
        end
        return
      end

      if chat_edit_modal_conflict?
        discard_chat_edit_candidate("Chat proposed edits were discarded because another review is open")
        return
      end

      plan = candidate.not_nil!.plan
      preview = plan.inline_preview(CHAT_EDIT_PREVIEW_TITLE)
      @lsp_popup.clear_completion
      @lsp_popup.clear_quick_fix
      @lsp_popup.clear_formatting
      @lsp_popup.clear_refactor
      @lsp_popup.title = CHAT_EDIT_PREVIEW_TITLE
      @lsp_popup.lines = plan.preview_lines
      @lsp_popup.chat_proposal_receipt = receipt
      @lsp_popup.chat_proposal_plan = plan
      @lsp_popup.chat_proposal_preview = preview
      @lsp_popup.chat_proposal_top = 0
      @lsp_popup.chat_proposal_max_lines = 16
      @lsp_popup.open = true
      @clipboard_paste_generation &+= 1_u64
      with_input_mode_guard(InputModeController::InputMode::LspPopup) do
        previous_overlay = @lsp_popup.overlay
        @lsp_popup.overlay = ->(buffer : Tui::Buffer, clip : Tui::Rect) { render_lsp_popup(buffer, clip, 16) }
        @lsp_popup.overlay = open_overlay(previous_overlay, @lsp_popup.overlay.not_nil!)
      end
      # Ownership of the detached plan and receipt has moved into the popup.
      @chat_edit_staged_proposal = nil
      @chat_edit_turn_receipt = nil
      @status_log.info("Chat proposed edits are ready for manual review in #{receipt.source_relative_path}")
      mark_dirty!
    rescue
      candidate = @chat_edit_staged_proposal
      if candidate
        cleanup_partial_chat_edit_popup(candidate.not_nil!.receipt)
      end
      discard_chat_edit_candidate("Chat proposed edits could not be opened for manual review")
    end

    private def cleanup_partial_chat_edit_popup(receipt : ChatEditProposalReceipt) : Nil
      return unless @lsp_popup.chat_proposal_receipt.try(&.same?(receipt))

      if @lsp_popup.open
        close_modal(@lsp_popup, InputModeController::InputMode::LspPopup)
      else
        close_overlay(@lsp_popup.overlay)
        @lsp_popup.overlay = nil
        exit_input_mode(InputModeController::InputMode::LspPopup) if active_input_mode == InputModeController::InputMode::LspPopup
      end
      @lsp_popup.clear_chat_proposal
      @lsp_popup.title = ""
      @lsp_popup.lines = [] of String
    end

    private def chat_edit_modal_conflict? : Bool
      active_input_mode != InputModeController::InputMode::Normal || @lsp_popup.open ||
        @context_menu.open || close_confirmation_active? || external_review_active? || recovery_review_active?
    rescue
      true
    end

    private def chat_edit_receipt_current?(receipt : ChatEditProposalReceipt,
                                           check_frontend_state : Bool = true) : Bool
      frontend = @chat_frontend
      return false unless frontend
      return false unless frontend.not_nil!.proposal_revision == receipt.proposal_revision
      return false unless @chat_provider_revision == receipt.provider_revision
      return false unless @chat_provider_config.to_json == receipt.provider_json
      return false if receipt.owner_version == Int32::MAX || receipt.owner.version == Int32::MAX
      return false unless receipt.owner.version == receipt.owner_version
      return false unless @chat_edit_view_epoch == receipt.view_epoch
      return false unless @active_editor_group == receipt.group
      return false unless active_editor_tabs.same?(receipt.editor_group)
      return false unless active_buffer_internal.try(&.same?(receipt.owner))
      return false unless receipt.owner.views.any? { |view| view.same?(receipt.editor) }
      return false unless receipt.editor.document.same?(receipt.owner.editor.document)
      return false unless active_editor_internal.try(&.same?(receipt.editor))
      return false unless @document_session.open_buffers[receipt.owner.path.to_s]?.try(&.same?(receipt.owner))
      return false unless receipt.editor.document.line_ending == receipt.line_ending
      return false unless receipt.editor.document.buffer.same_state?(receipt.snapshot)
      return false unless receipt.context == editor_tools_current_context
      reference = resolve_editor_tool_buffer(receipt.buffer_id, receipt.context)
      reference.refresh_revision!
      return false unless reference.same?(receipt.reference)
      return false unless reference.id == receipt.buffer_id && reference.revision == receipt.revision
      canonical = canonical_editor_tool_file(receipt.owner.path, receipt.context)
      relative = canonical.try { |path| editor_tools_relative_path(path, receipt.context) }
      return false unless relative == receipt.source_relative_path
      return false if check_frontend_state && frontend.not_nil!.state != Chat::TurnState::Complete
      true
    rescue
      false
    end

    private def chat_edit_document_changed(buffer : OpenBuffer) : Nil
      receipt = @chat_edit_turn_receipt || @chat_edit_staged_proposal.try(&.receipt) || @lsp_popup.chat_proposal_receipt
      return unless receipt && receipt.not_nil!.owner.same?(buffer)
      revoke_chat_edit_proposal("Chat proposed edits were discarded because the source buffer changed")
    end

    private def chat_edit_view_changed : Nil
      @chat_edit_view_epoch &+= 1_u64
      revoke_chat_edit_proposal("Chat proposed edits were discarded because the active editor changed")
    end

    private def reject_chat_edit_proposal : Nil
      revoke_chat_edit_proposal("Chat proposed edits rejected; buffer unchanged")
    end

    private def chat_edit_turn_started : Nil
      revoke_chat_edit_proposal
      @chat_edit_turn_receipt = nil
    end

    private def discard_chat_edit_candidate(message : String) : Nil
      had_candidate = !@chat_edit_staged_proposal.nil? || !@chat_edit_turn_receipt.nil?
      @chat_edit_staged_proposal = nil
      @chat_edit_turn_receipt = nil
      @status_log.warning(message) if had_candidate
      mark_dirty! if had_candidate
    end

    # A named-script result is still being delivered to its exact live parent
    # turn when a child RPC fails. Drop any staged edit immediately, but keep
    # the receipt that binds the parent Session until the parent turn ends.
    # Source/view/root/provider invalidation still uses the full revocation
    # paths above and below.
    private def discard_chat_edit_candidate_keep_turn_receipt(message : String) : Nil
      had_candidate = !@chat_edit_staged_proposal.nil? || !@chat_edit_turn_receipt.nil?
      @chat_edit_staged_proposal = nil
      @status_log.warning(message) if had_candidate
      mark_dirty! if had_candidate
    end

    private def revoke_chat_edit_proposal(message : String? = nil) : Nil
      had_proposal = !@chat_edit_staged_proposal.nil? || !@chat_edit_turn_receipt.nil? || @lsp_popup.chat_proposal_open?
      @chat_edit_staged_proposal = nil
      @chat_edit_turn_receipt = nil
      if @lsp_popup.chat_proposal_open?
        # Close through the shared modal transition before clearing `open`;
        # close_modal owns the InputMode exit as well as overlay removal.
        close_modal(@lsp_popup, InputModeController::InputMode::LspPopup)
        @lsp_popup.clear_chat_proposal
        @lsp_popup.title = ""
        @lsp_popup.lines = [] of String
      end
      if had_proposal
        @status_log.warning(message) if message
        mark_dirty!
      end
    end

    private def accept_chat_edit_proposal(selected_ids : Array(Int32)?) : Nil
      receipt = @lsp_popup.chat_proposal_receipt
      plan = @lsp_popup.chat_proposal_plan
      unless receipt && plan && chat_edit_receipt_current?(receipt.not_nil!)
        revoke_chat_edit_proposal("Chat proposed edits are stale; nothing was applied")
        return
      end
      editor = receipt.not_nil!.editor
      selected = selected_ids
      clear_chat_edit_popup_for_acceptance
      unless chat_edit_receipt_current?(receipt.not_nil!)
        @status_log.warning("Chat proposed edits are stale; nothing was applied")
        mark_dirty!
        return
      end
      applied = if selected
                  editor.apply_selected_document_edits(plan.not_nil!, selected.not_nil!)
                else
                  editor.apply_document_edits(plan.not_nil!)
                end
      unless applied
        @status_log.warning("Chat proposed edits are stale; nothing was applied")
        mark_dirty!
        return
      end
      editor.focus
      detail = selected ? " (#{selected.not_nil!.size} selected edits)" : ""
      @status_log.success("Chat proposed edits accepted#{detail}; not saved · Undo to restore")
      mark_dirty!
    rescue
      revoke_chat_edit_proposal("Chat proposed edits could not be applied; buffer unchanged")
    end

    private def clear_chat_edit_popup_for_acceptance : Nil
      @chat_edit_turn_receipt = nil
      @chat_edit_staged_proposal = nil
      @lsp_popup.clear_chat_proposal
      @lsp_popup.title = ""
      @lsp_popup.lines = [] of String
      close_modal(@lsp_popup, InputModeController::InputMode::LspPopup)
      close_overlay(@lsp_popup.overlay)
      @lsp_popup.overlay = nil
    end
  end
end
