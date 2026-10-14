require "json"
require "crystal_tui"

require "./chat_submission"
require "./chat_provider_config"
require "./chat_provider_transport"
require "./settings_config"
require "./editable_input"
require "./editable_input_renderer"

module Adamantine
  class ChatUiReviewCapture
    getter approval : Chat::SubmissionReview
    getter provider_json : String
    getter lifetime_revision : UInt64
    getter composer : Chat::Composer
    getter composer_text : String
    getter composer_revision : UInt64
    getter composer_cursor : Tuple(Int32, Int32)
    getter composer_selection : Tuple(Int32, Int32, Int32, Int32)?
    getter source_buffer : OpenBuffer?
    getter source_editor : Tui::TextEditor?
    getter source_version : Int32?
    getter source_reference : EditorToolsController::BufferReference?
    getter source_coordinates : Tuple(Int32, Int32, Int32, Int32)?
    getter source_relative_path : String?
    getter source_modified : Bool?
    getter lua_entry : LuaScripts::Entry?
    getter lua_source : String?

    def initialize(@approval : Chat::SubmissionReview, provider_json : String,
                   @lifetime_revision : UInt64, @composer : Chat::Composer,
                   composer_text : String, @composer_revision : UInt64,
                   @composer_cursor : Tuple(Int32, Int32),
                   @composer_selection : Tuple(Int32, Int32, Int32, Int32)?,
                   @source_buffer : OpenBuffer?, @source_editor : Tui::TextEditor?,
                   @source_version : Int32?,
                   @source_reference : EditorToolsController::BufferReference?,
                   @source_coordinates : Tuple(Int32, Int32, Int32, Int32)?,
                   source_relative_path : String?, @source_modified : Bool?,
                   @lua_entry : LuaScripts::Entry?, lua_source : String?)
      @provider_json = provider_json.dup
      @composer_text = composer_text.dup
      @source_relative_path = source_relative_path.try(&.dup)
      @lua_source = lua_source.try(&.dup)
    end
  end

  module ChatSettingsController
    CHAT_REVIEW_MODE   = InputModeController::InputMode::ChatReview
    CHAT_SETTINGS_MODE = InputModeController::InputMode::ChatSettings

    @chat_provider_config : Chat::ProviderConfig = Chat::ProviderConfig.new
    @chat_provider_revision : UInt64 = 0_u64
    @chat_injected_transport = false
    @chat_approved_tool_context : Chat::SubmissionContext? = nil
    @chat_approved_tool_root_identity : String? = nil
    @chat_context_mode : Chat::ContextMode = Chat::ContextMode::None
    @chat_settings_open = false
    @chat_settings_overlay : Tui::OverlayRenderer? = nil
    @chat_settings_fields = [] of EditableInput
    @chat_settings_index = 0
    @chat_settings_error : String? = nil
    @chat_review_capture : ChatUiReviewCapture? = nil
    @chat_review_overlay : Tui::OverlayRenderer? = nil
    @chat_review_scroll = 0
    @chat_review_lines = [] of String

    def chat_settings_action : Bool
      open_chat_settings
      true
    end

    def chat_context_action : Bool
      open_chat_context_menu
      true
    end

    private def initialize_chat_provider(transport : Chat::Transport?) : Nil
      @chat_injected_transport = !transport.nil?
      @chat_provider_config = SettingsConfig.load_chat(@keymap_path,
        ->(message : String) { @status_log.warning(message) })
      @chat_provider_revision &+= 1_u64
      return if @chat_injected_transport
      @chat_frontend.not_nil!.replace_transport(Chat::ProviderTransport.new(@chat_provider_config))
    end

    private def chat_provider_transport_changed(config : Chat::ProviderConfig) : Nil
      revoke_chat_edit_proposal("Chat proposed edits were discarded because provider settings changed")
      @chat_provider_config = config
      @chat_provider_revision &+= 1_u64
      unless @chat_injected_transport
        @chat_frontend.not_nil!.replace_transport(Chat::ProviderTransport.new(config))
      else
        # A settings operation is still a review-lifetime boundary for an
        # injected transport, while its local control seam remains installed.
        @chat_frontend.not_nil!.retire_context
        @chat_frontend.not_nil!.clear_exportable_history
      end
      mark_dirty!
    end

    private def chat_external_transport? : Bool
      @chat_frontend.try(&.external?) || false
    end

    private def open_chat_context_menu : Nil
      return if close_confirmation_active? || external_review_active? || recovery_review_active?
      actions = [] of LspContextAction
      actions << LspContextAction.new("None", "", -> { choose_chat_context(Chat::ContextMode::None) })
      actions << LspContextAction.new("Selection", "", -> { choose_chat_context(Chat::ContextMode::Selection) },
        -> { chat_context_unavailable_reason(Chat::ContextMode::Selection) })
      actions << LspContextAction.new("Active buffer", "", -> { choose_chat_context(Chat::ContextMode::ActiveBuffer) },
        -> { chat_context_unavailable_reason(Chat::ContextMode::ActiveBuffer) })
      actions << LspContextAction.new("Buffer read tools", "", -> { choose_chat_context(Chat::ContextMode::BufferTools) },
        -> { chat_context_unavailable_reason(Chat::ContextMode::BufferTools) })
      actions << LspContextAction.new("Buffer proposals (read + propose)", "", -> { choose_chat_context(Chat::ContextMode::BufferProposals) },
        -> { chat_context_unavailable_reason(Chat::ContextMode::BufferProposals) })
      actions << LspContextAction.new("Buffer read tools + Lua…", "", -> { open_chat_lua_picker_for_context(Chat::ContextMode::BufferTools) },
        -> { chat_lua_context_shortcut_unavailable_reason(Chat::ContextMode::BufferTools) })
      actions << LspContextAction.new("Buffer proposals + Lua…", "", -> { open_chat_lua_picker_for_context(Chat::ContextMode::BufferProposals) },
        -> { chat_lua_context_shortcut_unavailable_reason(Chat::ContextMode::BufferProposals) })
      open_context_menu("Chat context", actions)
    end

    private def choose_chat_context(mode : Chat::ContextMode) : Nil
      clear_chat_lua_script_selection unless mode.buffer_tools? || mode.buffer_proposals?
      if mode.none?
        @chat_context_mode = mode
        @chat_panel.not_nil!.context_label = "None"
        @status_log.info("Chat context set to None for the next accepted send")
        return
      end
      if reason = chat_context_unavailable_reason(mode)
        @status_log.warning(reason)
        return
      end
      @chat_context_mode = mode
      @chat_panel.not_nil!.context_label = chat_context_header_label(mode)
      @status_log.info("Chat context set to #{chat_context_header_label(mode)} for the next accepted send")
    end

    private def chat_lua_context_shortcut_unavailable_reason(mode : Chat::ContextMode) : String?
      return "Chat Lua requires an external Chat provider" unless chat_external_transport?
      if reason = chat_context_unavailable_reason(mode)
        return reason
      end
      return "Wait for the current Chat request to finish before selecting a Lua script" if @chat_frontend.try(&.active?)
      return "Cancel the active local Lua script before selecting Chat Lua" if lua_script_active?
      return "Close the local Lua review before selecting Chat Lua" if lua_script_review_active?
      return "A Lua worker is already active" if lua_execution_busy?
      nil
    rescue
      "Chat Lua context shortcut is unavailable"
    end

    private def chat_context_header_label(mode : Chat::ContextMode) : String
      case mode
      when .none?             then "None"
      when .selection?        then "Selection"
      when .active_buffer?    then "Buffer"
      when .buffer_proposals? then "Propose"
      else                         "Tools"
      end
    end

    private def chat_context_unavailable_reason(mode : Chat::ContextMode) : String?
      return nil if mode.none?
      buffer = active_buffer_internal
      editor = active_editor_internal
      return "No active editor" unless buffer && editor
      return "Active editor is not a file in the project" unless editor_tools_file_context_for(buffer.not_nil!)
      editing = editor.not_nil!.as?(EditingTextEditor)
      return "Active editor context is unavailable" unless editing
      if mode.selection?
        bytes = editing.not_nil!.chat_selection_byte_length(Chat::MAX_CONTEXT_BYTES)
        return "No non-empty editor selection" unless bytes
        return "Selection exceeds the 16 KiB context limit" if bytes.not_nil! > Chat::MAX_CONTEXT_BYTES
        return "Selection is empty" if bytes.not_nil! == 0
      elsif mode.active_buffer? && editing.not_nil!.search_byte_length > Chat::MAX_CONTEXT_BYTES
        return "Active buffer exceeds the 16 KiB context limit; choose Buffer read tools"
      end
      nil
    rescue
      "Active editor context is unavailable"
    end

    private def editor_tools_file_context_for(buffer : OpenBuffer) : EditorTools::Context?
      context = editor_tools_current_context
      canonical_editor_tool_file(buffer.path, context) ? context : nil
    rescue
      nil
    end

    private def capture_chat_snapshot(mode : Chat::ContextMode) : NamedTuple(
      context: Chat::SubmissionContext,
      tool_context: EditorTools::Context?,
      buffer: OpenBuffer?,
      editor: Tui::TextEditor?,
      reference: EditorToolsController::BufferReference?,
      coordinates: Tuple(Int32, Int32, Int32, Int32)?,
    )?
      unless mode.none?
        buffer = active_buffer_internal
        editor = active_editor_internal
        return unless buffer && editor
        tool_context = editor_tools_file_context_for(buffer.not_nil!)
        return unless tool_context
        return unless canonical_editor_tool_file(buffer.not_nil!.path, tool_context.not_nil!)
        editing = editor.not_nil!.as?(EditingTextEditor)
        return unless editing
        reference = editor_tool_buffer_reference(buffer.not_nil!)
        reference.refresh_revision!
        coordinates = editing.not_nil!.chat_selection_coordinates
        text = case mode
               when .selection?
                 value = editing.not_nil!.chat_selection_snapshot(Chat::MAX_CONTEXT_BYTES)
                 return unless value && !value.not_nil!.empty?
                 value.not_nil!
               when .active_buffer?
                 return if editing.not_nil!.search_byte_length > Chat::MAX_CONTEXT_BYTES
                 editing.not_nil!.text
               when .buffer_tools?
                 ""
               when .buffer_proposals?
                 ""
               else
                 return
               end
        label = case mode
                when .selection?        then "Selection"
                when .active_buffer?    then "Active buffer"
                when .buffer_proposals? then "Buffer proposals (read + propose)"
                else                         "Buffer read tools"
                end
        snapshot = Chat::SubmissionContext.new(mode, label, text,
          reference.id, reference.revision, chat_lua_grant(mode))
        return {
          context:      snapshot,
          tool_context: tool_context,
          buffer:       buffer,
          editor:       editor,
          reference:    reference,
          coordinates:  coordinates,
        }
      end

      tool_context = editor_tools_current_context
      {
        context:      Chat::SubmissionContext.none,
        tool_context: tool_context,
        buffer:       nil,
        editor:       nil,
        reference:    nil,
        coordinates:  nil,
      }
    rescue
      nil
    end

    private def open_chat_settings : Nil
      return if close_confirmation_active? || external_review_active? || recovery_review_active?
      close_command_palette
      close_context_menu
      close_lsp_popup
      close_quick_open
      close_problems
      close_git_view
      close_settings_dialog if @settings.open
      close_search_panel if @search.open
      @clipboard_paste_generation &+= 1_u64

      config = @chat_provider_config
      safe_config = JSON.parse(config.to_json).as_h
      enabled = config.validation_error.nil? && safe_config["enabled"].as_bool
      endpoint = safe_config["endpoint"].as_s
      model = safe_config["model"].as_s
      key_env = safe_config["key_env"].as_s
      tokens = safe_config["max_completion_tokens"].as_i
      @chat_settings_fields = [
        EditableInput.new(enabled.to_s, 5),
        EditableInput.new(endpoint, 2048),
        EditableInput.new(model, 256),
        EditableInput.new(key_env, 128),
        EditableInput.new(tokens.to_s, 5),
      ] of EditableInput
      @chat_settings_index = 0
      @chat_settings_error = if config.validation_error
                               "Saved provider values were invalid; Chat stays disabled until reviewed."
                             else
                               nil
                             end
      @chat_settings_open = true
      enter_input_mode(CHAT_SETTINGS_MODE)
      @chat_settings_overlay = open_overlay(@chat_settings_overlay, ->(buffer : Tui::Buffer, clip : Tui::Rect) {
        render_chat_settings(buffer, clip)
      })
      mark_dirty!
    end

    private def chat_settings_active? : Bool
      @chat_settings_open && active_input_mode == CHAT_SETTINGS_MODE
    end

    private def chat_review_active? : Bool
      !@chat_review_capture.nil? && active_input_mode == CHAT_REVIEW_MODE
    end

    private def close_chat_settings : Nil
      return unless @chat_settings_open
      close_overlay(@chat_settings_overlay)
      @chat_settings_overlay = nil
      @chat_settings_open = false
      @chat_settings_fields.clear
      @chat_settings_error = nil
      exit_input_mode(CHAT_SETTINGS_MODE)
      mark_dirty!
    end

    private def handle_chat_settings_input(event : Tui::KeyEvent) : Bool
      if event.matches?("escape") || event.matches?("esc")
        close_chat_settings
      elsif event.matches?("ctrl+s")
        save_chat_settings
      elsif event.matches?("shift+tab")
        @chat_settings_index = (@chat_settings_index - 1) % @chat_settings_fields.size
        mark_dirty!
      elsif event.matches?("up")
        @chat_settings_index = (@chat_settings_index - 1) % @chat_settings_fields.size
        mark_dirty!
      elsif event.matches?("down") || event.matches?("tab")
        @chat_settings_index = (@chat_settings_index + 1) % @chat_settings_fields.size
        mark_dirty!
      else
        field = @chat_settings_fields[@chat_settings_index]?
        if field
          if @chat_settings_index == 0 && event.matches?("space")
            field.not_nil!.value = if field.not_nil!.value == "true"
                                     "false"
                                   else
                                     "true"
                                   end
            @chat_settings_error = nil
            mark_dirty!
          else
            handle_editable_input_key(field.not_nil!, event, -> { @chat_settings_error = nil; mark_dirty! },
              -> { @chat_settings_error = "Field limit reached" })
          end
        end
      end
      true
    end

    private def handle_chat_settings_paste(text : String) : Bool
      field = @chat_settings_fields[@chat_settings_index]?
      if field
        handle_editable_input_paste(field.not_nil!, text, -> { @chat_settings_error = nil; mark_dirty! },
          -> { @chat_settings_error = "Field limit reached" })
      end
      true
    end

    private def save_chat_settings : Nil
      return if @chat_settings_fields.size != 5
      enabled_text = @chat_settings_fields[0].value
      unless enabled_text == "true" || enabled_text == "false"
        @chat_settings_error = "Enabled must be true or false"
        mark_dirty!
        return
      end
      token_value = @chat_settings_fields[4].value.to_i?
      unless token_value
        @chat_settings_error = "Output-token limit must be an integer from 1 to 32768"
        mark_dirty!
        return
      end
      config = Chat::ProviderConfig.new(
        enabled: enabled_text == "true",
        endpoint: @chat_settings_fields[1].value,
        model: @chat_settings_fields[2].value,
        key_env: @chat_settings_fields[3].value,
        max_completion_tokens: token_value.not_nil!
      )
      if message = config.validation_error
        @chat_settings_error = message
        mark_dirty!
        return
      end
      path = @keymap_path
      unless path && !path.not_nil!.empty?
        @chat_settings_error = "No settings file is available to save Chat provider settings"
        mark_dirty!
        return
      end
      begin
        SettingsConfig.save_chat(path.not_nil!, config)
      rescue
        @chat_settings_error = "Chat provider settings could not be saved"
        mark_dirty!
        return
      end
      chat_provider_transport_changed(config)
      close_chat_settings
    end

    private def open_chat_send_review : Bool
      return false unless chat_external_transport?
      return true if @chat_review_capture
      unless capture = build_chat_review_capture
        reason = @chat_frontend.try(&.review_unavailable_reason) ||
                 chat_context_unavailable_reason(@chat_context_mode) ||
                 "Editor context changed; choose Chat context again or select None."
        @status_log.warning(reason)
        mark_dirty!
        return false
      end
      @chat_review_capture = capture
      @chat_review_scroll = 0
      @chat_review_lines = chat_review_content_lines(capture, [@rect.width - 12, 20].max)
      @clipboard_paste_generation &+= 1_u64
      enter_input_mode(CHAT_REVIEW_MODE)
      @chat_review_overlay = open_overlay(@chat_review_overlay, ->(buffer : Tui::Buffer, clip : Tui::Rect) {
        render_chat_send_review(buffer, clip)
      })
      mark_dirty!
      true
    end

    private def build_chat_review_capture : ChatUiReviewCapture?
      panel = @chat_panel
      frontend = @chat_frontend
      return unless panel && frontend && frontend.external?
      snapshot = capture_chat_snapshot(@chat_context_mode)
      return unless snapshot
      request = frontend.review_request(snapshot.not_nil![:context])
      return unless request
      composer = panel.not_nil!.composer
      approval = Chat::SubmissionReview.new(
        request.not_nil!,
        @chat_provider_revision,
        chat_root_identity(snapshot.not_nil![:tool_context]),
        composer.mutation_revision
      )
      source_buffer = snapshot.not_nil![:buffer]
      source_editor = snapshot.not_nil![:editor]
      tool_context = snapshot.not_nil![:tool_context]
      source_relative_path = if source_buffer && tool_context
                               canonical = canonical_editor_tool_file(source_buffer.not_nil!.path, tool_context.not_nil!)
                               canonical.try { |path| editor_tools_relative_path(path, tool_context.not_nil!) }
                             else
                               nil
                             end
      return if !@chat_context_mode.none? && source_relative_path.nil?
      ChatUiReviewCapture.new(
        approval,
        @chat_provider_config.to_json,
        frontend.lifetime_revision,
        composer,
        composer.text,
        composer.mutation_revision,
        {composer.cursor_line, composer.cursor_col},
        composer.chat_selection_coordinates,
        source_buffer,
        source_editor,
        source_buffer.try(&.version),
        snapshot.not_nil![:reference],
        snapshot.not_nil![:coordinates],
        source_relative_path,
        source_editor.try(&.modified?),
        chat_lua_selected_entry,
        chat_lua_selected_entry.try(&.source)
      )
    rescue
      nil
    end

    private def chat_root_identity(context : EditorTools::Context?) : String
      return "unavailable" unless context
      "#{context.not_nil!.project_root}\0#{context.not_nil!.epoch}"
    end

    private def handle_chat_review_input(event : Tui::KeyEvent) : Bool
      if event.matches?("y")
        if chat_review_approvable?
          approve_chat_send_review
        else
          mark_dirty!
        end
      elsif event.matches?("escape") || event.matches?("esc") || event.matches?("enter") || event.matches?("return")
        close_chat_send_review
      elsif event.matches?("up")
        @chat_review_scroll = Math.max(@chat_review_scroll - 1, 0)
        mark_dirty!
      elsif event.matches?("down")
        @chat_review_scroll += 1
        mark_dirty!
      elsif event.matches?("pageup")
        @chat_review_scroll = Math.max(@chat_review_scroll - [@rect.height - 6, 1].max, 0)
        mark_dirty!
      elsif event.matches?("pagedown")
        @chat_review_scroll += [@rect.height - 6, 1].max
        mark_dirty!
      end
      true
    end

    private def approve_chat_send_review : Nil
      previous = @chat_review_capture
      return close_chat_send_review unless previous
      current = build_chat_review_capture
      unless current && chat_review_capture_matches?(previous.not_nil!, current.not_nil!)
        close_chat_send_review
        @status_log.warning("Chat send review is stale; prompt retained")
        mark_dirty!
        return
      end
      request = previous.not_nil!.approval.request
      context = request.context
      if context.mode.buffer_tools? || context.mode.buffer_proposals?
        @chat_approved_tool_context = context
        @chat_approved_tool_root_identity = previous.not_nil!.approval.root_identity
      end
      submitted = false
      begin
        chat_edit_turn_started
        chat_lua_turn_started(context, previous.not_nil!.lua_entry)
        submitted = @chat_frontend.not_nil!.submit(context)
      ensure
        @chat_approved_tool_context = nil
        @chat_approved_tool_root_identity = nil
      end
      close_chat_send_review
      if submitted
        @chat_lua_selected_entry = nil
        @chat_context_mode = Chat::ContextMode::None
        @chat_panel.not_nil!.context_label = "None"
      else
        chat_lua_turn_finished
        @status_log.warning("Chat provider could not start the approved request; draft retained")
      end
      @chat_panel.not_nil!.sync_from_frontend
      mark_dirty!
    end

    private def chat_review_capture_matches?(captured : ChatUiReviewCapture,
                                             current : ChatUiReviewCapture) : Bool
      a = captured.approval
      b = current.approval
      return false unless a.matches?(b.request, @chat_provider_revision,
                            b.root_identity, current.composer_revision)
      return false unless captured.provider_json == current.provider_json
      return false unless captured.lifetime_revision == current.lifetime_revision
      return false unless captured.composer.same?(current.composer)
      return false unless captured.composer_text == current.composer_text
      return false unless captured.composer_revision == current.composer_revision
      return false unless captured.composer_cursor == current.composer_cursor
      return false unless captured.composer_selection == current.composer_selection
      return false unless same_optional_object?(captured.source_buffer, current.source_buffer)
      return false unless same_optional_object?(captured.source_editor, current.source_editor)
      return false unless captured.source_version == current.source_version
      return false unless captured.source_relative_path == current.source_relative_path
      return false unless captured.source_modified == current.source_modified
      return false unless captured.source_coordinates == current.source_coordinates
      return false unless same_optional_object?(captured.lua_entry, current.lua_entry)
      return false unless captured.lua_source == current.lua_source
      captured_ref = captured.source_reference
      current_ref = current.source_reference
      return false unless same_optional_object?(captured_ref, current_ref)
      if captured_ref && current_ref
        return false unless captured_ref.not_nil!.id == current_ref.not_nil!.id
        return false unless captured_ref.not_nil!.revision == current_ref.not_nil!.revision
      end
      true
    end

    private def same_optional_object?(left : T?, right : T?) : Bool forall T
      if left && right
        left.not_nil!.same?(right.not_nil!)
      else
        left.nil? && right.nil?
      end
    end

    private def close_chat_send_review : Nil
      close_overlay(@chat_review_overlay)
      @chat_review_overlay = nil
      @chat_review_capture = nil
      @chat_review_lines.clear
      @chat_review_scroll = 0
      exit_input_mode(CHAT_REVIEW_MODE)
      @clipboard_paste_generation &+= 1_u64
      mark_dirty!
    end

    private def chat_review_approvable? : Bool
      if @chat_review_capture.try(&.lua_entry)
        @rect.width >= 72 && @rect.height >= 14
      else
        @rect.width >= 36 && @rect.height >= 8
      end
    end

    private def chat_context_session(context : Chat::SubmissionContext) : EditorTools::Session
      approved = @chat_approved_tool_context
      raise "read-buffer scope is not approved" unless approved && approved.not_nil! == context
      owner_context = editor_tools_current_context
      approved_root = @chat_approved_tool_root_identity
      raise "selected-buffer root is not approved" unless approved_root && chat_root_identity(owner_context) == approved_root
      raise "selected-buffer context is unavailable" unless context.mode.buffer_tools? || context.mode.buffer_proposals?
      receipt = chat_edit_capture_turn(context)
      @chat_edit_turn_receipt = receipt
      @chat_lua_turn_receipt = receipt

      source = resolve_editor_tool_buffer(context.buffer_id.not_nil!, owner_context)
      source.refresh_revision!
      unless source.id == context.buffer_id && source.revision == context.revision
        raise "approved buffer revision changed"
      end
      grant = context.lua_script_grant
      if entry = chat_lua_turn_entry
        raise "approved Chat Lua grant is unavailable" unless grant
        unless grant.not_nil!.id == entry.not_nil!.id && grant.not_nil!.name == entry.not_nil!.name &&
               grant.not_nil!.digest == entry.not_nil!.digest &&
               grant.not_nil!.effective_capabilities == chat_lua_effective_capabilities(entry.not_nil!, context.mode)
          raise "approved Chat Lua grant changed"
        end
      elsif grant
        raise "Chat Lua grant has no frozen host entry"
      end

      capabilities = [EditorTools::Capability::ReadEditor]
      capabilities << EditorTools::Capability::ProposeEdits if context.mode.buffer_proposals?
      capabilities << EditorTools::Capability::RunScript if grant
      backend = EditorToolsController::Backend.new(
        -> { chat_scoped_context(context, receipt) },
        ->(request : EditorTools::Request, permit : EditorTools::ExecutionPermit) {
          execute_chat_scoped_tool(context, receipt, request, permit)
        }
      )
      EditorTools::Host.new(backend,
        EditorTools::Limits.new(max_calls: Chat::MAX_TOOL_ATTEMPTS)).open_session(
        EditorTools::Consumer::Chat, capabilities
      )
    end

    private def chat_scoped_context(context : Chat::SubmissionContext,
                                    receipt : ChatEditProposalReceipt) : EditorTools::Context
      frontend = @chat_frontend
      submission_live = frontend.try(&.active?) == true ||
                        frontend.try(&.constructing_context_session?(context)) == true
      if submission_live &&
         @chat_lua_turn_context.try(&.== context) == true &&
         @chat_lua_turn_receipt.try(&.same?(receipt)) == true &&
         @chat_edit_turn_receipt.try(&.same?(receipt)) == true &&
         chat_edit_receipt_current?(receipt, check_frontend_state: false)
        receipt.context
      else
        EditorTools::Context.new(receipt.context.project_root,
          "chat-revoked-#{receipt.proposal_revision}")
      end
    rescue
      EditorTools::Context.new(receipt.context.project_root,
        "chat-revoked-#{receipt.proposal_revision}")
    end

    private def execute_chat_scoped_tool(context : Chat::SubmissionContext,
                                         receipt : ChatEditProposalReceipt,
                                         request : EditorTools::Request,
                                         permit : EditorTools::ExecutionPermit) : JSON::Any
      require_editor_tools_permit!(permit)
      unless @chat_lua_turn_context.try(&.== context) == true &&
             @chat_lua_turn_receipt.try(&.same?(receipt)) == true &&
             @chat_frontend.try(&.active?) == true &&
             chat_edit_receipt_current?(receipt, check_frontend_state: false)
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "approved Chat buffer receipt is stale")
      end
      if chat_lua_turn_entry && chat_lua_child_failed? && request.is_a?(EditorTools::ProposeEditsRequest)
        raise EditorTools::Failure.new(EditorTools::Status::Denied,
          "proposal is unavailable after the named-script child failed")
      end
      result = case request
               when EditorTools::ReadBufferRequest
                 unless request.buffer_id == receipt.buffer_id && request.revision == receipt.revision
                   raise EditorTools::Failure.new(EditorTools::Status::Denied, "read is outside the approved buffer revision")
                 end
                 editor_tools_read_buffer(request, permit)
               when EditorTools::ProposeEditsRequest
                 unless context.mode.buffer_proposals? && request.buffer_id == receipt.buffer_id &&
                        request.revision == receipt.revision
                   raise EditorTools::Failure.new(EditorTools::Status::Denied, "proposal is outside the approved buffer revision and mode")
                 end
                 chat_edit_prepare_proposal(request, permit)
               else
                 raise EditorTools::Failure.new(EditorTools::Status::Denied,
                   "Chat only supports exact selected-buffer reads and reviewed proposals")
               end
      require_editor_tools_permit!(permit)
      unless chat_edit_receipt_current?(receipt, check_frontend_state: false)
        raise EditorTools::Failure.new(EditorTools::Status::Stale, "approved Chat buffer receipt changed")
      end
      result
    end

    private def render_chat_settings(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      width = [@rect.width - 4, 84].min
      height = [10, @rect.height - 2].min
      if width < 8 || height < 5
        draw_text_line(buffer, clip, @rect.x, @rect.y, "Chat Provider Settings", Tui::Style.new(fg: Theme::Popup.title), @rect.width)
        draw_text_line(buffer, clip, @rect.x, @rect.y + 1, "Resize to edit | Esc cancel", Tui::Style.new(fg: Theme::Popup.text), @rect.width) if @rect.height > 1
        return
      end
      x = @rect.x + (@rect.width - width) // 2
      y = @rect.y + (@rect.height - height) // 2
      modal_clip = clip.intersect(Tui::Rect.new(x, y, width, height))
      return unless modal_clip
      bg = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Popup.active_bg)
      border = Tui::Style.new(fg: Theme::Popup.border, bg: Theme::Popup.active_bg)
      title = Tui::Style.new(fg: Theme::Popup.title, bg: Theme::Popup.active_bg, attrs: Tui::Attributes::Bold)
      active = Tui::Style.new(fg: Theme::Popup.active_fg, bg: Theme::Popup.active_bg, attrs: Tui::Attributes::Bold)
      error = Tui::Style.new(fg: Theme::Status.error, bg: Theme::Popup.active_bg)
      draw_box_border(buffer, modal_clip.not_nil!, x, y, width, height, border, bg, "Chat Provider Settings", title)
      labels = ["Enabled", "Endpoint", "Model", "Credential env var", "Max output tokens/round"]
      @chat_settings_fields.each_with_index do |field, index|
        row = y + 1 + index
        next if row >= y + height - 2
        label = "#{labels[index]}:"
        draw_text_line(buffer, modal_clip.not_nil!, x + 2, row, label,
          index == @chat_settings_index ? active : bg, [label.size + 1, width - 5].min)
        value_x = x + 2 + Tui::Unicode.display_width(label) + 1
        value_width = width - (value_x - x) - 2
        if value_width > 0
          if index == @chat_settings_index
            cursor = Tui::Style.new(fg: Theme::Popup.active_bg, bg: Theme::Popup.title,
              attrs: Tui::Attributes::Bold)
            EditableInputRenderer.render(buffer, Tui::Rect.new(value_x, row, value_width, 1),
              chat_safe_editable_input(field), active, bg, cursor, modal_clip.not_nil!)
          else
            shown = field.value.empty? ? "<blank>" : chat_safe_display(field.value)
            draw_text_line(buffer, modal_clip.not_nil!, value_x, row, shown, bg, value_width)
          end
        end
      end
      message = @chat_settings_error || "Space toggle enabled | Ctrl+S save | Esc cancel"
      draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2,
        message, @chat_settings_error ? error : bg, width - 4)
    end

    private def render_chat_send_review(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      capture = @chat_review_capture
      return unless capture
      unless chat_review_approvable?
        draw_text_line(buffer, clip, @rect.x, @rect.y, "Review Chat send", Tui::Style.new(fg: Theme::Popup.title), @rect.width)
        draw_text_line(buffer, clip, @rect.x, @rect.y + 1, "Resize to review | Enter/Esc cancel", Tui::Style.new(fg: Theme::Popup.text), @rect.width) if @rect.height > 1
        return
      end
      width = [@rect.width - 2, 96].min
      height = [@rect.height, 24].min
      if width < 8 || height < 4
        draw_text_line(buffer, clip, @rect.x, @rect.y, "Review Chat send", Tui::Style.new(fg: Theme::Popup.title), @rect.width)
        draw_text_line(buffer, clip, @rect.x, @rect.y + 1, "Resize to review | Enter/Esc cancel", Tui::Style.new(fg: Theme::Popup.text), @rect.width) if @rect.height > 1
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
      draw_box_border(buffer, modal_clip.not_nil!, x, y, width, height, border, bg, "Review Chat send", title)
      content_width = width - 4
      @chat_review_lines = chat_review_content_lines(capture.not_nil!, content_width)
      visible = height - 4
      max_scroll = [@chat_review_lines.size - visible, 0].max
      @chat_review_scroll = @chat_review_scroll.clamp(0, max_scroll)
      visible.times do |index|
        line = @chat_review_lines[@chat_review_scroll + index]?
        break unless line
        draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + 1 + index,
          line.not_nil!, index == 0 ? active : bg, content_width)
      end
      draw_text_line(buffer, modal_clip.not_nil!, x + 2, y + height - 2,
        "#{chat_review_approvable? ? "Y send" : "Resize to review"} | Enter/Esc cancel | Up/Down scroll", muted, content_width)
    end

    private def chat_review_content_lines(capture : ChatUiReviewCapture, width : Int32) : Array(String)
      request = capture.approval.request
      context = request.context
      config = Chat::ProviderConfig.from_json(JSON.parse(capture.provider_json))
      lines = [] of String
      append_chat_review_text(lines, "Send this prompt and visible history to #{config.model}", width)
      append_chat_review_text(lines, "Destination: #{config.endpoint}", width)
      credential = if config.key_env.empty? && (config.endpoint.starts_with?("http://127.0.0.1") || config.endpoint.starts_with?("http://[::1]"))
                     "Credential: none (loopback)"
                   else
                     "Credential: environment variable #{config.key_env} (value not shown)"
                   end
      append_chat_review_text(lines, credential, width)
      append_chat_review_text(lines, "Output limit: #{config.max_completion_tokens} tokens/request; at most 4 requests/turn", width)
      append_chat_review_text(lines, "History: #{request.history.size} previous messages, #{request.history_bytes} bytes (shown below)", width)
      case context.mode
      when .none?
        append_chat_review_text(lines, "Editor context: None (0 bytes)", width)
      when .selection?, .active_buffer?
        source = capture.source_relative_path || "approved file"
        marker = capture.source_modified ? " (unsaved buffer)" : ""
        append_chat_review_text(lines, "Editor source: #{source}#{marker}, revision #{context.revision}", width)
        append_chat_review_text(lines, "Editor context: #{context.label}, #{context.bytesize} bytes (shown below)", width)
      when .buffer_tools?, .buffer_proposals?
        source = capture.source_relative_path || "approved file"
        marker = capture.source_modified ? " (unsaved buffer)" : ""
        append_chat_review_text(lines, "Initial editor context: 0 bytes", width)
        append_chat_review_text(lines, "Model may read and send bounded excerpts from exact buffer #{source}#{marker}, revision #{context.revision}", width)
        append_chat_review_text(lines, "Read scope: 64 KiB/result, 512 KiB/session; max 16 calls, 4 requests, 4 calls/round", width)
        if context.mode.buffer_proposals?
          append_chat_review_text(lines, "One proposal attempt: at most 32 edits / 8 KiB tool request; manual review only; never auto-applied/saved", width)
        end
      end
      if entry = capture.lua_entry
        requested = entry.not_nil!.capabilities.map(&.wire_name).join(", ")
        effective_caps = chat_lua_effective_capabilities(entry.not_nil!, context.mode)
        effective = effective_caps.map(&.wire_name).join(", ")
        excluded = entry.not_nil!.capabilities.reject { |capability| effective_caps.includes?(capability) }
          .map(&.wire_name).join(", ")
        append_chat_review_text(lines, "Named Lua: one execution this turn only; output is returned to #{config.model}", width)
        append_chat_review_text(lines, "Frozen script: #{entry.not_nil!.name} (ID #{entry.not_nil!.id})", width)
        append_chat_review_text(lines, "SHA-256: #{entry.not_nil!.digest}", width)
        append_chat_review_text(lines, "Requested capabilities: #{requested.empty? ? "none" : requested}", width)
        append_chat_review_text(lines, "Effective capabilities: #{effective.empty? ? "none" : effective}", width)
        append_chat_review_text(lines, "Excluded capabilities: #{excluded.empty? ? "none" : excluded}", width)
        append_chat_review_text(lines,
          "Limits: 64 KiB source, 8 MiB tracked Lua heap, 5 s, 16 KiB output; Chat shares 16 calls / 512 KiB result budget", width)
        append_chat_review_text(lines, "Script source (frozen locally; not sent to provider):", width)
        lines.concat(chat_wrap_text(capture.lua_source || "", width))
      end
      lines << ""
      request.history.each_with_index do |message, index|
        role = message.role.user? ? "User" : "Assistant"
        append_chat_review_text(lines, "Previous #{role} message #{index + 1}:", width)
        lines.concat(chat_wrap_text(message.text, width))
      end
      append_chat_review_text(lines, "Current prompt:", width)
      lines.concat(chat_wrap_text(request.text, width))
      unless context.text.empty?
        append_chat_review_text(lines, "Editor context text:", width)
        lines.concat(chat_wrap_text(context.text, width))
      end
      lines
    end

    private def append_chat_review_text(lines : Array(String), text : String, width : Int32) : Nil
      lines.concat(chat_wrap_text(text, width))
    end

    private def chat_wrap_text(text : String, width : Int32) : Array(String)
      safe = chat_safe_display(text, preserve_newlines: true)
      rows = [] of String
      row = String::Builder.new
      used = 0
      limit = [width, 1].max
      flush = -> {
        rows << row.to_s
        row = String::Builder.new
        used = 0
      }
      safe.each_grapheme do |grapheme|
        glyph = grapheme.to_s
        if glyph == "\n"
          flush.call
          next
        end
        glyph_width = Tui::Unicode.grapheme_width(glyph)
        if used > 0 && used + glyph_width > limit
          flush.call
        end
        row << glyph
        used += glyph_width
      end
      rows << row.to_s unless row.empty?
      rows << "" if rows.empty?
      rows
    end

    private def chat_safe_display(value : String, preserve_newlines : Bool = false) : String
      return "[invalid UTF-8]" unless value.valid_encoding?
      String.build do |output|
        value.each_char do |char|
          code = char.ord
          if char == '\n' && preserve_newlines
            output << '\n'
          elsif char == '\t'
            output << "\\t"
          elsif code < 0x20 || code.in?(0x7f..0x9f) || code == 0x061c ||
                code.in?(0x200e..0x200f) || code.in?(0x202a..0x202e) ||
                code.in?(0x2028..0x2029) || code.in?(0x2060..0x206f) ||
                code == 0x200b || code == 0xfeff || code.in?(0xfff9..0xfffb)
            output << "\\u{" << code.to_s(16) << "}"
          else
            output << char
          end
        end
      end
    end

    private def chat_safe_editable_input(input : EditableInput) : EditableInput
      mapping = [0]
      display_length = 0
      value = String.build do |output|
        input.value.each_char do |char|
          safe = chat_safe_display(char.to_s)
          output << safe
          display_length += safe.size
          mapping << display_length
        end
      end
      projected = EditableInput.new(value)
      projected.cursor = mapping[input.cursor]? || value.size
      if selection = input.selection_range
        lower = mapping[selection[0]]? || 0
        upper = mapping[selection[1]]? || value.size
        cursor = mapping[input.cursor]? || value.size
        anchor = input.cursor == selection[0] ? upper : lower
        projected.select_range(anchor, cursor)
      end
      projected
    end
  end
end
