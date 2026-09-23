require "./text_coordinates"
require "./completion_selection_adapter"
require "./lsp_recovery_controller"
require "./safe_document_edits"
require "./workspace_document_edits"

module Adamantine
  module LspController
    include LspRecoveryController

    RENAME_MAX_NAME_CODEPOINTS = 256
    RENAME_MAX_NAME_BYTES      = 4 * 1024
    QUICK_FIX_MAX_ITEMS        = 100
    QUICK_FIX_MAX_TITLE_CHARS  = 160

    macro included
      @lsp_recovery_state : LspRecoveryController::RecoveryState?
    end

    # Lifecycle owners (App and project switching) call this hook to discard
    # a client before replacing the project root or leaving the UI.
    def shutdown_lsp : Nil
      lsp_recovery_shutdown
      close_lsp_popup(false)
      close_problems
    end

    def lsp_project_root_changed : Nil
      lsp_recovery_root_changed
    end

    private def goto_definition : Nil
      request_lsp_action(InteractiveLspAction::Definition)
    end

    private def goto_declaration : Nil
      request_lsp_action(InteractiveLspAction::Declaration)
    end

    private def goto_type_definition : Nil
      request_lsp_action(InteractiveLspAction::TypeDefinition)
    end

    private def goto_implementation : Nil
      request_lsp_action(InteractiveLspAction::Implementation)
    end

    private def hyperclick_at(line : Int32, col : Int32, modifiers : Tui::Modifiers) : Nil
      # Cursor is already placed by TextEditor; keep position explicit for safety.
      if editor = current_editor
        editor.set_cursor(line, col)
      end

      # Shift+Click is the iTerm-safe gesture (SGR reports Shift; Ctrl/Option often do not).
      # Shift+Alt or Shift+Ctrl → always references; otherwise smart definition/usages.
      if modifiers.shift? && (modifiers.alt? || modifiers.ctrl?)
        show_references_hint
        mark_dirty!
        wakeup
        return
      end

      hyperclick_smart
      mark_dirty!
      wakeup
    end

    private def hyperclick_smart : Nil
      request_lsp_action(InteractiveLspAction::Hyperclick)
    end

    private def jump_to_locations(
      request : InteractiveLspRequest,
      label : String,
      locations : Array(Lsp::Location),
    ) : Nil
      return if locations.empty?
      return unless lsp_action_current?(request)

      location = locations.first
      uri_to_path(location.uri).try do |path|
        # Resolve UTF-16 against the exact editor instance that open_file is
        # about to commit.  This covers unsaved open targets and avoids the
        # stale window caused by reading an unopened target before open_file
        # reads it again.
        resolved_position : TextCoordinates::Position? = nil
        cursor_resolver = ->(target_editor : Tui::TextEditor) : Tuple(Int32, Int32)? do
          return nil unless lsp_action_current?(request)
          begin
            resolved_position = TextCoordinates.position(target_editor, location.line, location.character, clamp: true)
            {resolved_position.not_nil!.line, resolved_position.not_nil!.column}
          rescue ArgumentError
            nil
          end
        end

        commit_reached = false
        opened = open_file(
          path,
          nil,
          nil,
          -> { lsp_action_current?(request) },
          -> {
            # The guard sealed the request immediately before the UI commit;
            # this callback runs before sync_open, where transport may yield.
            commit_reached = true
            context = lsp_action_context(request)
            @document_session.navigation_forward_history.clear
            @document_session.navigation_history << NavigationLocation.new(context[:uri], context[:line], context[:character])
            prune_navigation_history
            if position = resolved_position
              @status_log.success("Jump to #{path.basename}:#{position.line + 1}:#{position.column + 1}")
            end
          },
          cursor_resolver
        )

        # A stale guard cancellation is intentionally silent. Only report an
        # open failure when the request is still current and no UI commit ran.
        if !commit_reached && !opened && lsp_action_current?(request)
          @status_log.error("Failed to jump to #{path}")
        end
      end
    end

    private def show_hover_hint : Nil
      request_lsp_action(InteractiveLspAction::Hover)
    end

    private def show_references_hint : Nil
      request_lsp_action(InteractiveLspAction::References)
    end

    private def show_signature_hint : Nil
      request_lsp_action(InteractiveLspAction::Signature)
    end

    private def show_completion_hint : Nil
      request_lsp_action(InteractiveLspAction::Completion)
    end

    private def show_diagnostics_hint : Nil
      # Diagnostics are local but still replace any pending server preview.
      close_lsp_popup
      buffer = current_buffer
      editor = current_editor
      if buffer.nil? || editor.nil?
        @status_log.warning("No active editor")
        return
      end

      diagnostics = buffer.diagnostics.select do |diagnostic|
        diagnostic.line == editor.cursor_line
      end
      if diagnostics.empty?
        @status_log.info("No diagnostics on current line")
        close_lsp_popup
        return
      end

      lines = diagnostics.map do |diagnostic|
        source = diagnostic.source ? " [#{diagnostic.source}]" : ""
        "ln #{diagnostic.line + 1}:#{diagnostic.character + 1}#{source} #{diagnostic.message}"
      end
      open_lsp_popup("Diagnostics", lines, 12)
    end

    private def execute_code_action_hint : Nil
      request_lsp_action(InteractiveLspAction::CodeAction)
    end

    private def execute_quick_fix_hint : Nil
      quick_fix_document
    end

    # Start a current-document rename without advertising prepareRename or
    # accepting arbitrary server-side name syntax. The server remains the
    # language-specific grammar authority; the UI only bounds and sanitizes
    # the command argument before capturing it in the request snapshot.
    private def rename_document(raw_name : String) : Bool
      name = raw_name.strip
      if name.empty?
        @status_log.warning("Usage: :rename NEW_NAME")
        return false
      end

      unless valid_rename_name?(name)
        @status_log.warning("Rename unavailable: name must be nonempty, control-free, and at most #{RENAME_MAX_NAME_CODEPOINTS} characters")
        return false
      end

      request_lsp_action(InteractiveLspAction::Rename, name)
      true
    end

    private def valid_rename_name?(name : String) : Bool
      return false unless name.valid_encoding?
      return false if name.empty? || name.bytesize > RENAME_MAX_NAME_BYTES
      codepoints = 0
      name.each_char do
        codepoints += 1
        return false if codepoints > RENAME_MAX_NAME_CODEPOINTS
      end

      name.each_char.all? do |char|
        codepoint = char.ord
        !(codepoint < 0x20 || (0x7f..0x9f).includes?(codepoint))
      end
    end

    private def quick_fix_document : Nil
      request_lsp_action(InteractiveLspAction::QuickFix)
    end

    # Request whole-document formatting through the same one-inflight/latest
    # queued scheduler as the other interactive LSP actions. The response is
    # only prepared into a detached preview; Enter is the apply authority.
    private def format_document : Nil
      request_lsp_action(InteractiveLspAction::Formatting)
    end

    # Interactive requests are deliberately funneled through one scheduler:
    # one request may be waiting on the server and one latest request may wait
    # behind it. The queued request is replaced rather than accumulated.
    private def request_lsp_action(action : InteractiveLspAction, rename_name : String? = nil) : Nil
      close_lsp_popup

      reason = lsp_action_disabled_reason(action)
      if reason
        @status_log.warning(reason)
        return
      end

      buffer = current_buffer.not_nil!
      editor = current_editor.not_nil!
      context = current_lsp_context.not_nil!
      client = @lsp.not_nil!

      format_tab_size, format_insert_spaces = formatting_options_for(editor)

      @lsp_action_generation += 1_u64
      request = InteractiveLspRequest.new(
        action,
        client,
        buffer,
        @project_root,
        context[:uri],
        context[:line],
        context[:character],
        buffer.version,
        @lsp_action_generation,
        editor,
        action == InteractiveLspAction::Completion,
        format_tab_size,
        format_insert_spaces,
        rename_name
      )

      @status_log.info("LSP #{lsp_action_label(action)} loading")
      if @lsp_action_running
        @lsp_action_queued = request
      else
        @lsp_action_running = true
        launch_lsp_action(request)
      end
    end

    private def launch_lsp_action(request : InteractiveLspRequest) : Nil
      spawn(name: "lsp-interactive-action") do
        run_lsp_action(request)
      end
    end

    private def run_lsp_action(request : InteractiveLspRequest) : Nil
      # A request can sit behind the scheduler until a newer cursor, buffer or
      # client state supersedes it. Avoid even sending a stale request when
      # that state is observable before the client call begins.
      return unless lsp_action_current?(request)
      # The editor and request snapshot use public codepoint columns.  Convert
      # exactly once at this outbound LSP boundary; incremental TextChange
      # already carries its own UTF-16 columns and does not pass here.
      wire_character = request.utf16_character

      case request.action
      when InteractiveLspAction::Hover
        publish_hover(request, request.client.hover(request.uri, request.line, wire_character))
      when InteractiveLspAction::Completion
        publish_completion(request, request.client.completion(request.uri, request.line, wire_character))
      when InteractiveLspAction::Signature
        publish_signature(request, request.client.signature_help(request.uri, request.line, wire_character))
      when InteractiveLspAction::References
        publish_references(request, request.client.references(request.uri, request.line, wire_character))
      when InteractiveLspAction::Definition
        publish_locations(request, "definition", request.client.goto_definition(request.uri, request.line, wire_character))
      when InteractiveLspAction::Declaration
        publish_locations(request, "declaration", request.client.declaration(request.uri, request.line, wire_character))
      when InteractiveLspAction::TypeDefinition
        publish_locations(request, "type definition", request.client.type_definition(request.uri, request.line, wire_character))
      when InteractiveLspAction::Implementation
        publish_locations(request, "implementation", request.client.implementation(request.uri, request.line, wire_character))
      when InteractiveLspAction::Hyperclick
        locations = request.client.goto_definition(request.uri, request.line, wire_character)
        publish_hyperclick(request, locations)
      when InteractiveLspAction::CodeAction
        publish_code_actions(request, request.client.code_action(request.uri, request.line, wire_character))
      when InteractiveLspAction::Formatting
        edits = request.client.formatting(request.uri, request.format_tab_size, request.format_insert_spaces)
        return unless lsp_action_current?(request)
        editor = request.editor.as?(EditingTextEditor)
        unless editor
          @status_log.warning("Document formatting unavailable for this editor")
          return
        end
        plan = editor.prepare_document_edits(edits)
        publish_formatting(request, plan)
      when InteractiveLspAction::Rename
        new_name = request.rename_name
        unless new_name
          publish_lsp_action_failure(request, ArgumentError.new("missing rename name"))
          return
        end
        publish_rename(request, request.client.rename(request.uri, request.line, wire_character, new_name))
      when InteractiveLspAction::QuickFix
        publish_quick_fixes(request, request.client.quick_fix(request.uri, request.line, wire_character))
      end
    rescue ex
      publish_lsp_action_failure(request, ex)
    ensure
      finish_lsp_action
    end

    private def finish_lsp_action : Nil
      if queued = @lsp_action_queued
        @lsp_action_queued = nil
        @lsp_action_running = true
        launch_lsp_action(queued)
      else
        @lsp_action_running = false
      end
    end

    private def invalidate_lsp_actions : Nil
      @lsp_action_generation += 1_u64
      @lsp_action_queued = nil
    end

    # Hyperclick may turn a definition result into a references lookup. Keep
    # that lookup under the original action generation: it is one user action,
    # and no new snapshot should be taken between the two server requests.
    private def queue_lsp_followup(request : InteractiveLspRequest, action : InteractiveLspAction) : Nil
      return unless lsp_action_current?(request)
      return unless @lsp_action_running

      followup = InteractiveLspRequest.new(
        action,
        request.client,
        request.buffer,
        request.project_root,
        request.uri,
        request.line,
        request.character,
        request.version,
        request.generation,
        request.editor,
        false,
        request.format_tab_size,
        request.format_insert_spaces,
        request.rename_name
      )
      @status_log.info("LSP #{lsp_action_label(action)} loading")
      @lsp_action_queued = followup
    end

    private def lsp_action_current?(request : InteractiveLspRequest) : Bool
      return false unless request.generation == @lsp_action_generation
      return false unless @project_root == request.project_root
      client = @lsp
      return false unless client && client.same?(request.client)
      return false unless request.client.connected?

      buffer = current_buffer
      return false unless buffer && buffer.same?(request.buffer)
      return false unless buffer.uri == request.uri && buffer.version == request.version

      editor = current_editor
      return false unless editor && editor.same?(request.editor)
      return false unless request.editor.same?(request.buffer.editor)
      if request.action == InteractiveLspAction::Completion
        return false unless completion_selection_supported?(editor)
        selection_present = editor.as?(TextCoordinates::SelectionProvider).not_nil!.selection_present?
        return false unless selection_present == request.selection_present
      end
      editor.cursor_line == request.line && editor.cursor_col == request.character
    end

    private def lsp_action_context(request : InteractiveLspRequest) : NamedTuple(uri: String, line: Int32, character: Int32)
      {uri: request.uri, line: request.line, character: request.character}
    end

    private def lsp_action_label(action : InteractiveLspAction) : String
      case action
      when InteractiveLspAction::Hover          then "hover"
      when InteractiveLspAction::Completion     then "completion"
      when InteractiveLspAction::Signature      then "signature"
      when InteractiveLspAction::References     then "references"
      when InteractiveLspAction::Definition     then "definition"
      when InteractiveLspAction::Declaration    then "declaration"
      when InteractiveLspAction::TypeDefinition then "type definition"
      when InteractiveLspAction::Implementation then "implementation"
      when InteractiveLspAction::Hyperclick     then "hyperclick"
      when InteractiveLspAction::CodeAction     then "code actions"
      when InteractiveLspAction::Formatting     then "formatting"
      when InteractiveLspAction::Rename         then "rename"
      when InteractiveLspAction::QuickFix       then "quick fix"
      else                                           action.to_s
      end
    end

    private def publish_hover(request : InteractiveLspRequest, hover : Lsp::Hover?) : Nil
      return unless lsp_action_current?(request)

      if hover
        open_lsp_popup("Hover", wrap_lines(hover.text), 14)
      else
        @status_log.warning("No hover information")
        close_lsp_popup(false)
      end
    end

    private def publish_references(request : InteractiveLspRequest, references : Array(Lsp::Location)) : Nil
      return unless lsp_action_current?(request)

      if references.empty?
        @status_log.warning("No references")
        close_lsp_popup(false)
        return
      end

      lines = references.map_with_index do |location, index|
        if path = uri_to_path(location.uri)
          filename = path.to_s
          "#{index + 1}. #{filename}:#{location.line + 1}:#{location.character + 1}"
        else
          "#{index + 1}. #{location.uri}:#{location.line + 1}:#{location.character + 1}"
        end
      end
      open_lsp_popup("References", lines, 18)
    end

    private def publish_signature(request : InteractiveLspRequest, signature : Lsp::SignatureHelp?) : Nil
      return unless lsp_action_current?(request)

      if signature.nil? || signature.signatures.empty?
        @status_log.warning("No signature help")
        close_lsp_popup(false)
        return
      end

      lines = signature.signatures.each_with_index.to_a.map do |signature_text, index|
        marker = index == signature.active_signature ? "▶" : " "
        "#{marker} #{signature_text}"
      end
      open_lsp_popup("Signature", lines, 14)
    end

    private def publish_completion(request : InteractiveLspRequest, completions : Array(Lsp::CompletionItem)) : Nil
      return unless lsp_action_current?(request)

      if completions.empty?
        @status_log.warning("No completion items")
        close_lsp_popup(false)
        return
      end

      lines = completions.each_with_index.to_a.map do |item, index|
        detail = item.detail ? " - #{sanitize_completion_display(item.detail.not_nil!, 256)}" : ""
        label = sanitize_completion_display(item.label, 512)
        label = "<unnamed>" if label.empty?
        "#{index + 1}. #{label}#{detail}"
      end
      open_completion_popup(request, completions, lines, 20)
    end

    # Completion selection is an authority-bearing mutation, unlike the
    # generic read-only LSP previews. Every check here runs before the editor
    # selection is changed, so malformed or stale results preserve text,
    # history, and the user's current selection.
    private def accept_completion_selection : Nil
      request = @lsp_popup.completion_request
      items = @lsp_popup.completion_items
      unless request && items
        close_lsp_popup(false)
        return
      end

      unless lsp_action_current?(request)
        @status_log.warning("Completion result is stale")
        close_lsp_popup(false)
        return
      end

      if request.selection_present
        # Completion fallback and textEdit ranges are both deliberately
        # anchored to the captured cursor, never an arbitrary pre-existing
        # selection. Keep the popup modal long enough for Enter/Tab to be
        # consumed, then reject without touching text or history.
        @status_log.warning("Completion unavailable with active selection")
        close_lsp_popup(false)
        return
      end

      item = items[@lsp_popup.completion_index]?
      unless item
        @status_log.warning("Completion selection is unavailable")
        close_lsp_popup(false)
        return
      end

      if reason = item.rejection_reason
        @status_log.warning("Completion unavailable: #{reason}")
        close_lsp_popup(false)
        return
      end

      editor = request.editor
      replacement = completion_replacement(editor, request, item)
      unless replacement
        close_lsp_popup(false)
        return
      end

      start_line, start_col, end_line, end_col, text = replacement.not_nil!
      unless valid_completion_insertion?(text)
        @status_log.warning("Completion insertion is too large or malformed")
        close_lsp_popup(false)
        return
      end

      # All validation is complete. TextEditor#insert_text records this
      # select-and-replace as one transaction and emits one ranged change.
      begin
        provider = editor.as?(TextCoordinates::CompletionEditProvider)
        unless provider
          @status_log.warning("Completion unavailable for this editor transaction adapter")
          close_lsp_popup(false)
          return
        end
        provider.apply_completion_edit(start_line, start_col, end_line, end_col, request.line, request.character, text)
      rescue ex : ArgumentError | IndexError
        @status_log.warning("Completion insertion rejected: #{ex.message || ex.class.to_s}")
        close_lsp_popup(false)
        return
      end

      close_lsp_popup(false)
      @status_log.success("Completion inserted")
    end

    private def completion_replacement(
      editor : Tui::TextEditor,
      request : InteractiveLspRequest,
      item : Lsp::CompletionItem,
    ) : Tuple(Int32, Int32, Int32, Int32, String)?
      if text_edit = item.text_edit
        return completion_text_edit_replacement(editor, request, text_edit)
      end

      line_text = completion_line_text(editor, request.line)
      unless line_text
        @status_log.warning("Completion source line is unavailable")
        return nil
      end

      # Plain insertText/label fallback uses the LSP identifier-prefix
      # convention over ASCII identifier characters. Unicode-aware servers
      # should provide textEdit, which is preferred above. Walk only through
      # the requested prefix; do not materialize a second full-line `chars`
      # array for a large source line.
      cursor = request.character
      return nil if cursor < 0
      start_col = 0
      index = 0
      line_text.not_nil!.each_char do |char|
        break if index >= cursor
        if completion_identifier_char?(char)
          # Keep the current run start.
        else
          start_col = index + 1
        end
        index += 1
      end
      return nil unless index == cursor

      text = item.insert_text || item.label
      if text.empty?
        @status_log.warning("Completion has no insertable text")
        return nil
      end
      {request.line, start_col, request.line, cursor, text}
    rescue ex : ArgumentError | IndexError
      @status_log.warning("Completion range rejected: #{ex.message || ex.class.to_s}")
      nil
    end

    private def completion_text_edit_replacement(
      editor : Tui::TextEditor,
      request : InteractiveLspRequest,
      edit : Lsp::CompletionTextEdit,
    ) : Tuple(Int32, Int32, Int32, Int32, String)?
      range = edit.range
      return completion_rejection("negative completion range") if range.start_line < 0 || range.end_line < 0 || range.start_character < 0 || range.end_character < 0
      return completion_rejection("multiline completion range unsupported") unless range.start_line == range.end_line
      return completion_rejection("completion range must contain request") unless range.start_line == request.line

      request_utf16 = TextCoordinates.codepoint_to_utf16(editor, request.line, request.character)
      return completion_rejection("completion range is reversed") if range.end_character < range.start_character
      return completion_rejection("completion range does not contain request") unless range.start_character <= request_utf16 && request_utf16 <= range.end_character

      start_col = TextCoordinates.utf16_to_codepoint(editor, range.start_line, range.start_character, clamp: false)
      end_col = TextCoordinates.utf16_to_codepoint(editor, range.end_line, range.end_character, clamp: false)
      return completion_rejection("completion range is reversed") if end_col < start_col
      {request.line, start_col, request.line, end_col, edit.new_text}
    rescue ex : ArgumentError | IndexError
      completion_rejection("completion range rejected: #{ex.message || ex.class.to_s}")
    end

    private def completion_rejection(message : String) : Tuple(Int32, Int32, Int32, Int32, String)?
      @status_log.warning("Completion unavailable: #{message}")
      nil
    end

    private def completion_line_text(editor : Tui::TextEditor, line : Int32) : String?
      provider = editor.as?(TextCoordinates::LineProvider)
      return nil unless provider
      provider.line_text(line)
    rescue ArgumentError | IndexError
      nil
    end

    private def completion_selection_supported?(editor : Tui::TextEditor) : Bool
      !editor.as?(TextCoordinates::SelectionProvider).nil? &&
        !editor.as?(TextCoordinates::CompletionEditProvider).nil?
    end

    private def completion_identifier_char?(char : Char) : Bool
      char == '_' ||
        ('a'..'z').includes?(char) ||
        ('A'..'Z').includes?(char) ||
        ('0'..'9').includes?(char)
    end

    private def valid_completion_insertion?(text : String) : Bool
      text.valid_encoding? && text.bytesize <= Lsp::COMPLETION_MAX_INSERTION_BYTES
    end

    private def sanitize_completion_display(text : String, max_codepoints : Int32) : String
      builder = String::Builder.new
      count = 0
      text.each_char do |char|
        break if count >= max_codepoints
        # Never pass terminal controls or embedded line breaks to popup text.
        control = char.ord < 0x20 || (0x7f..0x9f).includes?(char.ord)
        builder << (control ? ' ' : char)
        count += 1
      end
      builder.to_s
    end

    private def publish_code_actions(request : InteractiveLspRequest, actions : Array(JSON::Any)) : Nil
      return unless lsp_action_current?(request)

      if actions.empty?
        @status_log.warning("No code actions")
        close_lsp_popup(false)
        return
      end

      lines = actions.each_with_index.to_a.map do |action, index|
        title = action["title"]?.try(&.as_s) || "action #{index + 1}"
        "#{index + 1}. #{title}"
      end
      open_lsp_popup("Code actions", lines, 18)
    end

    # Rename and quick-fix responses are admitted into the mutation path only
    # after they have become a current, same-document SafeDocumentEdits plan.
    # The protocol envelope parser rejects foreign documents and unsupported
    # WorkspaceEdit variants before the editor sees a candidate.
    private def publish_rename(request : InteractiveLspRequest, raw : JSON::Any?) : Nil
      return unless lsp_action_current?(request)

      plan = prepare_refactor_plan(request, raw, "Rename")
      return unless plan
      unless plan.changed? && !plan.preview_lines.empty?
        @status_log.info("Rename produced no document changes")
        close_lsp_popup(false)
        return
      end

      open_refactor_popup(request, plan, "Rename")
    end

    private def publish_quick_fixes(request : InteractiveLspRequest, actions : Array(JSON::Any)) : Nil
      return unless lsp_action_current?(request)

      accepted = [] of JSON::Any
      lines = [] of String
      omitted = 0
      actions.each_with_index do |action, index|
        if accepted.size >= QUICK_FIX_MAX_ITEMS
          # The response is already bounded by the client transport, but do
          # not parse/sanitize an unbounded tail once the visible cap is full.
          omitted += actions.size - index
          break
        end

        title = quick_fix_action_title(action)
        unless title
          omitted += 1
          next
        end

        accepted << action
        lines << "#{accepted.size}. #{title.not_nil!}"
      end

      if accepted.empty?
        detail = omitted > 0 ? " (#{omitted} unavailable or malformed)" : ""
        @status_log.warning("No applicable quick fixes#{detail}")
        close_lsp_popup(false)
        return
      end

      if omitted > 0
        # This row is deliberately not selectable. It makes the omission
        # visible instead of silently pretending the server returned only the
        # first hundred actions.
        lines << "… #{omitted} unavailable or omitted"
      end
      open_quick_fix_popup(request, accepted, lines, omitted)
    end

    # Validate the eager CodeAction subset before displaying it.  A command,
    # disabled marker, explicit non-quickfix kind, or malformed required field
    # makes the whole action unavailable; the edit portion is never salvaged.
    private def quick_fix_action_title(action : JSON::Any) : String?
      object = action.as_h?
      return nil unless object
      allowed = ["title", "kind", "edit", "diagnostics", "isPreferred", "data"]
      object.each_key { |key| return nil unless allowed.includes?(key) }
      return nil if object.has_key?("command") || object.has_key?("disabled")

      raw_title = object["title"]?.try(&.as_s?)
      return nil unless raw_title && raw_title.not_nil!.valid_encoding?
      title = sanitize_quick_fix_title(raw_title.not_nil!)
      return nil if title.strip.empty?

      if kind = object["kind"]?
        kind_text = kind.as_s?
        return nil unless kind_text && !kind_text.not_nil!.empty?
        return nil unless kind_text.not_nil! == "quickfix" || kind_text.not_nil!.starts_with?("quickfix.")
      end

      edit = object["edit"]?
      return nil unless edit && edit.not_nil!.as_h?
      if diagnostics = object["diagnostics"]?
        return nil unless diagnostics.as_a?
      end
      if preferred = object["isPreferred"]?
        return nil unless preferred.as_bool?.nil? == false
      end

      title
    rescue TypeCastError
      nil
    end

    private def sanitize_quick_fix_title(text : String) : String
      # Keep the truncation marker inside the bound and replace terminal
      # controls with spaces.  The marker is visible in the picker, so a user
      # can tell a long server title was shortened rather than misread it.
      builder = String::Builder.new
      payload_limit = [QUICK_FIX_MAX_TITLE_CHARS - 1, 1].max
      count = 0
      truncated = false
      text.each_char do |char|
        if count >= payload_limit
          truncated = true
          break
        end
        control = char.ord < 0x20 || (0x7f..0x9f).includes?(char.ord)
        builder << (control ? ' ' : char)
        count += 1
      end
      builder << '…' if truncated
      builder.to_s
    end

    private def prepare_refactor_plan(
      request : InteractiveLspRequest,
      raw : JSON::Any?,
      label : String,
    ) : SafeDocumentEdits::Plan?
      editor = request.editor.as?(EditingTextEditor)
      unless editor
        @status_log.warning("#{label} unavailable for this editor")
        close_lsp_popup(false)
        return nil
      end

      begin
        edits = WorkspaceDocumentEdits.extract(raw, request.uri, request.version)
        if edits.empty?
          @status_log.warning("#{label} returned no document edits")
          close_lsp_popup(false)
          return nil
        end
        editor.prepare_document_edits(edits)
      rescue ex : ArgumentError | IndexError | TypeCastError
        @status_log.warning("#{label} unavailable: #{ex.message || ex.class.to_s}")
        close_lsp_popup(false)
        nil
      end
    end

    private def accept_quick_fix_selection : Nil
      request = @lsp_popup.quick_fix_request
      actions = @lsp_popup.quick_fix_actions
      unless request && actions
        close_lsp_popup(false)
        return
      end

      unless lsp_action_current?(request)
        @status_log.warning("Quick Fix result is stale")
        close_lsp_popup(false)
        return
      end

      action = actions[@lsp_popup.quick_fix_index]?
      unless action
        @status_log.warning("Quick Fix selection is unavailable")
        close_lsp_popup(false)
        return
      end

      edit = action["edit"]?
      plan = prepare_refactor_plan(request, edit, "Quick Fix")
      return unless plan
      unless plan.changed? && !plan.preview_lines.empty?
        @status_log.info("Quick Fix produced no document changes")
        close_lsp_popup(false)
        return
      end

      open_refactor_popup(request, plan, "Quick Fix")
    end

    private def publish_formatting(request : InteractiveLspRequest, plan : SafeDocumentEdits::Plan) : Nil
      return unless lsp_action_current?(request)

      unless plan.changed?
        @status_log.info("Document is already formatted")
        close_lsp_popup(false)
        return
      end

      if plan.preview_lines.empty?
        @status_log.warning("Formatting preview is unavailable")
        close_lsp_popup(false)
        return
      end

      open_formatting_popup(request, plan)
    end

    private def accept_formatting : Nil
      accept_document_edit_preview
    end

    private def accept_document_edit_preview : Nil
      request = @lsp_popup.formatting_request || @lsp_popup.refactor_request
      plan = @lsp_popup.formatting_plan || @lsp_popup.refactor_plan
      unless request && plan
        close_lsp_popup(false)
        return
      end

      unless lsp_action_current?(request)
        @status_log.warning("#{document_edit_label(request)} result is stale")
        close_lsp_popup(false)
        return
      end

      editor = request.editor.as?(EditingTextEditor)
      unless editor
        @status_log.warning("#{document_edit_label(request)} unavailable for this editor")
        close_lsp_popup(false)
        return
      end

      begin
        applied = editor.apply_document_edits(plan)
      rescue ex : ArgumentError | IndexError
        @status_log.warning("#{document_edit_label(request)} apply rejected: #{ex.message || ex.class.to_s}")
        close_lsp_popup(false)
        return
      end

      unless applied
        @status_log.warning("#{document_edit_label(request)} result is stale")
        close_lsp_popup(false)
        return
      end

      label = document_edit_label(request)
      close_lsp_popup(false)
      @status_log.success("#{label} accepted (#{plan.change_count} edits); not saved · Undo to restore")
    end

    private def document_edit_label(request : InteractiveLspRequest) : String
      case request.action
      when InteractiveLspAction::Formatting then "Formatting"
      when InteractiveLspAction::Rename     then "Rename"
      when InteractiveLspAction::QuickFix   then "Quick Fix"
      else                                       "Document edit"
      end
    end

    private def formatting_options_for(editor : Tui::TextEditor) : Tuple(Int32, Bool)
      if configured = editor.as?(EditingTextEditor)
        tab_size = configured.indent_style == :tab ? configured.tab_size : configured.indent_width
        {tab_size, configured.indent_style != :tab}
      else
        {editor.tab_size, true}
      end
    end

    private def publish_locations(request : InteractiveLspRequest, label : String, locations : Array(Lsp::Location)) : Nil
      return unless lsp_action_current?(request)

      if locations.empty?
        @status_log.warning("No #{label} found")
        return
      end

      jump_to_locations(request, label, locations)
    end

    private def publish_hyperclick(request : InteractiveLspRequest, locations : Array(Lsp::Location)) : Nil
      return unless lsp_action_current?(request)

      if Hyperclick.prefer_references?(request.uri, request.line, locations)
        queue_lsp_followup(request, InteractiveLspAction::References)
      else
        jump_to_locations(request, "definition", locations)
      end
    end

    private def publish_lsp_action_failure(request : InteractiveLspRequest, error : Exception) : Nil
      return unless lsp_action_current?(request)

      detail = error.message || error.class.to_s
      close_lsp_popup(false)
      @status_log.warning("LSP #{lsp_action_label(request.action)} failed: #{detail}")
    end

    private def current_lsp_context : NamedTuple(uri: String, line: Int32, character: Int32)?
      buffer = current_buffer
      editor = current_editor
      return nil if buffer.nil? || editor.nil?
      {uri: buffer.uri, line: editor.cursor_line, character: editor.cursor_col}
    end

    private def lsp_client_or_warning : Adamantine::Lsp::Client?
      if client = @lsp
        return client if client.connected?
      end

      close_lsp_popup
      @status_log.warning("LSP is not connected")
      nil
    end

    private def report_lsp_action_failure(action : String, error : Exception) : Nil
      close_lsp_popup
      detail = error.message || error.class.to_s
      @status_log.warning("LSP #{action} failed: #{detail}")
    end

    # This is deliberately a read-only preflight shared by F1 discovery and
    # context menus.  The request path calls it again immediately before
    # capturing a request, so menu/palette text never becomes authority.
    private def lsp_action_disabled_reason(action : InteractiveLspAction? = nil) : String?
      buffer = current_buffer
      editor = current_editor
      return "No active editor" unless buffer && editor && current_lsp_context

      client = @lsp
      return "LSP is not connected" unless client && client.connected?
      return "LSP is reconnecting; actions are temporarily unavailable" unless lsp_recovery_client_ready?(client)

      case action
      when InteractiveLspAction::Formatting
        return "Document formatting is unavailable" unless client.document_formatting_supported?
      when InteractiveLspAction::Rename
        return "Rename is unavailable" unless client.rename_supported?
      when InteractiveLspAction::QuickFix
        return "Quick Fix is unavailable" unless client.quick_fix_supported?
      when InteractiveLspAction::Completion
        return "Completion unavailable for this editor selection adapter" unless completion_selection_supported?(editor)
      else
      end

      nil
    end

    private def build_lsp_context_menu_actions : Array(LspContextAction)
      [
        lsp_context_action("Go to definition", "lsp.goto_definition", -> { goto_definition }),
        lsp_context_action("Go to declaration", nil, -> { goto_declaration }),
        lsp_context_action("Go to type definition", nil, -> { goto_type_definition }),
        lsp_context_action("Go to implementation", nil, -> { goto_implementation }),
        lsp_context_action("Show hover", "lsp.hover", -> { show_hover_hint }),
        lsp_context_action("Show references", "lsp.references", -> { show_references_hint }),
        lsp_context_action("Show signature", "lsp.signature", -> { show_signature_hint }),
        lsp_context_action("Show completion", nil, -> { show_completion_hint }, InteractiveLspAction::Completion),
        lsp_context_action("Show diagnostics", nil, -> { show_diagnostics_hint }),
        lsp_context_action("Code actions", nil, -> { execute_code_action_hint }),
      ]
    end

    private def lsp_context_action(
      label : String,
      global_action : String?,
      callback : Proc(Nil),
      availability_action : InteractiveLspAction? = nil,
    ) : LspContextAction
      shortcut = if action = global_action
                   hint = configured_key_hint(action, "unbound")
                   hint == "unbound" ? hint : "global: #{hint}"
                 else
                   "unbound"
                 end
      LspContextAction.new(label, shortcut, callback, -> { lsp_action_disabled_reason(availability_action) })
    end

    private def lsp_diagnostic_style(diagnostics : Array(Lsp::Diagnostic), line : Int32, col : Int32, base_style : Tui::Style) : Tui::Style
      selected : Lsp::Diagnostic? = nil
      selected_rank = 99
      diagnostics.each do |diagnostic|
        next unless diagnostic_in_range?(diagnostic, line, col)
        rank = severity_rank(diagnostic.severity)
        if selected.nil? || rank < selected_rank
          selected = diagnostic
          selected_rank = rank
        end
      end

      return base_style unless selected

      Theme::Lsp.diagnostic_style(base_style, selected.severity)
    end

    private def severity_rank(severity : Int32?) : Int32
      case severity
      when 1 then 0
      when 2 then 1
      when 3 then 2
      when 4 then 3
      else        4
      end
    end

    private def diagnostic_in_range?(diagnostic : Lsp::Diagnostic, line : Int32, col : Int32) : Bool
      return false if line < diagnostic.line
      return false if line > diagnostic.end_line

      if diagnostic.line == diagnostic.end_line
        return col >= diagnostic.character && col < diagnostic.end_character
      end

      if line == diagnostic.line
        col >= diagnostic.character
      elsif line == diagnostic.end_line
        col < diagnostic.end_character
      else
        true
      end
    end

    private def connect_lsp_if_requested(command : String?, args : Array(String)) : Nil
      if command.nil?
        if resolved = resolve_default_lsp_command
          lsp_recovery_configure(resolved, [] of String)
          connect_lsp(resolved, [] of String)
        else
          lsp_recovery_configure(nil, [] of String)
          @status_log.warning("LSP disabled: no server found. Pass --lsp COMMAND or set ADAMANTINE_LSP")
          @status_log.warning("Hint: install an LSP server for your language (e.g., gopls, rust-analyzer, pyright)")
        end
        return
      end

      if command.empty?
        lsp_recovery_configure(nil, args)
        return
      end

      lsp_recovery_configure(command, args)
      connect_lsp(command, args)
    end

    private def resolve_default_lsp_command : String?
      env_command = ENV["ADAMANTINE_LSP"]?
      return env_command if env_command && !env_command.empty?
      editor_env = ENV["EDITOR_LSP"]?
      return editor_env if editor_env && !editor_env.empty?
      legacy_env = ENV["CRYSTAL_EDITOR_LSP"]?
      return legacy_env if legacy_env && !legacy_env.empty?

      if adamas_lsp = LspRegistry.find_adamas_lsp(@project_root)
        return adamas_lsp
      end

      if primary_lang = LspRegistry.detect_project_language(@project_root)
        if lsp_path = LspRegistry.find_lsp_for_language(primary_lang)
          return lsp_path
        end
      end

      nil
    end

    private def configure_lsp_callbacks(client : Lsp::Client) : Nil
      # A new client cannot vouch for ranges produced by the previous one.
      # Clear before installing callbacks so a stale modal or Alt-N/Alt-P
      # action cannot navigate old rows after replacement.
      clear_all_buffer_diagnostics
      publish_diagnostics = ->(uri : String, version : Int32?, diagnostics : Array(Lsp::Diagnostic), partial : Bool) : Nil {
        # A notification may arrive after a replacement client has been
        # installed.  Admission and publication both carry the identity guard
        # so a delayed old-client callback cannot overwrite the new session.
        return unless @lsp.same?(client)
        return unless lsp_recovery_diagnostics_admissible?(client, uri)
        return if uri.bytesize > 8192

        bounded = diagnostics.first(ProblemsController::PROBLEMS_MAX_ROWS)
        truncated = partial || diagnostics.size > ProblemsController::PROBLEMS_MAX_ROWS
        targets = [] of {OpenBuffer, UInt64, UInt64, Int32}
        @document_session.open_buffers.each_value do |buffer|
          next unless buffer.uri == uri
          next if version && version != buffer.version
          buffer.diagnostics_notification_generation &+= 1_u64
          targets << {buffer, buffer.diagnostics_notification_generation, buffer.editor.object_id, buffer.version}
        end

        converted_by_buffer = [] of {OpenBuffer, UInt64, UInt64, Int32, Array(Lsp::Diagnostic), Bool}
        targets.each do |target|
          buffer = target[0]
          token = target[1]
          converted = diagnostics_for_editor(buffer.editor, bounded, -> { Fiber.yield })
          converted_partial = truncated || converted.size < bounded.size
          converted_by_buffer << {buffer, token, target[2], target[3], converted, converted_partial}
        end

        # Keep this check after conversion so a yielding converter cannot
        # publish a result admitted for an old client, version, edit, or
        # notification generation.  Each buffer owns its token, so a
        # notification for another URI does not cancel this conversion.
        return unless @lsp.same?(client)
        return unless lsp_recovery_diagnostics_admissible?(client, uri)

        updated = false
        converted_by_buffer.each do |entry|
          buffer = entry[0]
          next unless @document_session.open_buffers[buffer.path.to_s]?.try(&.same?(buffer))
          next if version && version != buffer.version
          next unless buffer.diagnostics_notification_generation == entry[1]
          next unless buffer.editor.object_id == entry[2]
          next unless buffer.version == entry[3]

          buffer.diagnostics = entry[4]
          buffer.diagnostics_partial = entry[5]
          buffer.diagnostics_generation &+= 1_u64
          problems_diagnostics_updated(buffer)
          updated = true
        end
        if updated
          mark_dirty!
          wakeup
        end
      }

      # Client dispatch prefers this versioned callback when available; the
      # legacy callback remains installed for older/test clients without
      # publishing twice when both properties are present.
      client.on_versioned_diagnostics = publish_diagnostics
      client.on_diagnostics = ->(uri : String, diagnostics : Array(Lsp::Diagnostic)) {
        publish_diagnostics.call(uri, nil, diagnostics, false)
      }
      client.on_semantic_tokens_refresh = -> {
        if lsp_recovery_client_ready?(client)
          @document_session.open_buffers.each_value do |buffer|
            schedule_semantic_tokens(buffer, 50.milliseconds)
            schedule_folding_ranges(buffer, 70.milliseconds)
          end
        end
      }
      client.on_warning = ->(message : String) {
        if lsp_recovery_warning_admissible?(client)
          @status_log.warning(message)
          if path = resolve_keymap_path_for_save
            @status_log.warning("LSP settings config: #{path}")
          end
          mark_dirty!
          wakeup
        end
      }
      lsp_recovery_attach(client)
    end

    private def diagnostics_for_editor(
      editor : Tui::TextEditor,
      diagnostics : Array(Lsp::Diagnostic),
      checkpoint : Proc(Nil)? = nil,
    ) : Array(Lsp::Diagnostic)
      converted = [] of Lsp::Diagnostic
      diagnostics.each_with_index do |diagnostic, index|
        checkpoint.call if checkpoint && index > 0 && index % 32 == 0
        begin
          start = TextCoordinates.position(editor, diagnostic.line, diagnostic.character, clamp: true)
          finish = TextCoordinates.position(editor, diagnostic.end_line, diagnostic.end_character, clamp: true)
          next if finish.line < start.line
          next if finish.line == start.line && finish.column < start.column

          converted << Lsp::Diagnostic.new(
            start.line,
            start.column,
            diagnostic.message,
            diagnostic.source,
            diagnostic.severity,
            finish.line,
            finish.column
          )
        rescue ArgumentError
          # Negative lines/columns, missing lines, invalid UTF-16 boundaries,
          # and unsupported test editors are malformed for this consumer. Do
          # not retain a range that would be painted at the wrong cell.
        end
      end
      converted
    end

    private def connect_lsp(command : String, args : Array(String)) : Nil
      client = new_lsp_client(command, @project_root, args)
      client.max_response_bytes = SettingsConfig.max_response_bytes(@settings.max_response_mib)
      @lsp = client
      epoch = lsp_recovery_prepare_initial(client)
      configure_lsp_callbacks(client)

      if client.start && lsp_recovery_initial_connected(client, epoch)
        @status_log.success("LSP connected: #{command}")
        if client.semantic_tokens_supported?
          @status_log.info("LSP semantic highlighting enabled")
        else
          @status_log.info("LSP has no semanticTokensProvider; lexical highlighting remains available for Crystal-family files")
        end
      else
        if lsp_recovery_initial_failed(client, epoch)
          reason = lsp_recovery_failure_reason
          detail = reason ? " Failure detail: #{reason}." : ""
          @status_log.error("LSP failed. Press F1 for Restart LSP or run :lsp restart.#{detail}")
        else
          client.stop
        end
        @lsp = nil if @lsp.try(&.same?(client))
      end
    end

    private def sync_lsp_open(buffer : OpenBuffer) : Nil
      if lsp_recovery_sync_open(buffer)
        return
      end
      return unless client = @lsp
      client.open_text_document(
        uri: buffer.uri,
        language_id: buffer.language_id || "plaintext",
        version: buffer.version,
        text: buffer.editor.text
      )
      schedule_semantic_tokens(buffer, 100.milliseconds)
      schedule_folding_ranges(buffer, 120.milliseconds)
    end

    private def sync_lsp_change(buffer : OpenBuffer, change : Tui::TextEditor::TextChange) : Nil
      if lsp_recovery_sync_change(buffer)
        return
      end
      @lsp.try do |client|
        next unless client.connected?

        if client.incremental_text_sync? && change.incremental?
          start_position = change.start.not_nil!
          finish_position = change.finish.not_nil!
          client.text_change(
            buffer.uri,
            buffer.version,
            Lsp::Range.new(
              start_position.line,
              start_position.utf16_column,
              finish_position.line,
              finish_position.utf16_column
            ),
            change.text
          )
        else
          client.text_change(
            uri: buffer.uri,
            version: buffer.version,
            text: buffer.editor.text
          )
        end
      end
      schedule_semantic_tokens(buffer, 200.milliseconds)
      schedule_folding_ranges(buffer, 220.milliseconds)
    end

    private def schedule_semantic_tokens(buffer : OpenBuffer, delay : Time::Span) : Nil
      client = @lsp
      return unless client
      return unless client.semantic_tokens_supported?
      return unless lsp_recovery_client_ready?(client)

      buffer.semantic_generation += 1
      generation = buffer.semantic_generation
      version = buffer.version
      uri = buffer.uri
      path = buffer.path.to_s
      legend = client.semantic_token_legend
      source = lsp_line_source_for(buffer)

      spawn(name: "semantic-tokens") do
        sleep delay
        next unless lsp_recovery_client_ready?(client)
        next unless buffer.semantic_generation == generation
        next unless buffer.version == version
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.uri == uri
        next unless current.semantic_generation == generation
        next unless current.version == version

        data = client.semantic_tokens_full(uri)
        next if data.nil?
        next unless lsp_recovery_client_ready?(client)
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.semantic_generation == generation
        next unless current.version == version

        overlay = SemanticOverlay.build(data, source, legend)
        next unless lsp_recovery_client_ready?(client)
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.uri == uri
        next unless current.semantic_generation == generation
        next unless current.version == version
        current.semantic_overlay = overlay
        mark_dirty!
        wakeup
      end
    end

    private def schedule_folding_ranges(buffer : OpenBuffer, delay : Time::Span) : Nil
      client = @lsp
      return unless client
      return unless client.folding_ranges_supported?
      return unless lsp_recovery_client_ready?(client)

      buffer.fold_generation += 1
      generation = buffer.fold_generation
      version = buffer.version
      uri = buffer.uri
      path = buffer.path.to_s
      source = lsp_line_source_for(buffer)

      spawn(name: "folding-ranges") do
        sleep delay
        next unless lsp_recovery_client_ready?(client)
        next unless buffer.fold_generation == generation
        next unless buffer.version == version
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.uri == uri
        next unless current.fold_generation == generation
        next unless current.version == version

        ranges = client.folding_ranges(uri)
        next if ranges.nil?
        next unless lsp_recovery_client_ready?(client)
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.fold_generation == generation
        next unless current.version == version

        if current.crystal_family?
          ranges = Folding.merge_crystal_branches(source, ranges)
        end
        next unless lsp_recovery_client_ready?(client)
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.uri == uri
        next unless current.fold_generation == generation
        next unless current.version == version
        current.editor.set_fold_ranges(ranges)
        mark_dirty!
        wakeup
      end
    end

    private def lsp_line_source_for(buffer : OpenBuffer) : BufferLines::Source
      if editor = buffer.editor.as?(EditingTextEditor)
        editor.lsp_line_source
      else
        # Keep the controller compatible with test/minimal editors that do not
        # expose the persistent PieceTreeBuffer adapter yet.
        BufferLines::Source.new(buffer.editor.lines)
      end
    end

    private def sync_lsp_save(buffer : OpenBuffer) : Nil
      return if lsp_recovery_blocks_legacy_sync?
      @lsp.try(&.save_text_document(buffer.uri))
    end

    private def close_lsp_document(uri : String) : Nil
      if lsp_recovery_sync_close(uri)
        return
      end
      @lsp.try(&.close_text_document(uri))
    end

    private def show_lsp_status : Nil
      health = lsp_health_label
      if health == "disabled" && @lsp.nil?
        @status_log.warning("LSP disabled. Configure a server with --lsp COMMAND or ADAMANTINE_LSP.")
        return
      end

      if health.starts_with?("retrying")
        @status_log.warning("LSP reconnecting; automatic retries are enabled (#{health}).")
        return
      end

      if health == "failed"
        reason = lsp_recovery_failure_reason
        detail = reason ? " Failure detail: #{reason}." : ""
        @status_log.error("LSP failed. Press F1 for Restart LSP or run :lsp restart.#{detail}")
        return
      end

      if client = @lsp
        unless lsp_recovery_client_ready?(client)
          @status_log.warning("LSP not connected (#{health})")
          return
        end

        parts = ["LSP connected"]
        parts << "tokens" if client.semantic_tokens_supported?
        parts << "folds" if client.folding_ranges_supported?
        if parts.size == 1
          @status_log.warning("LSP connected, but semantic/fold providers are missing")
        else
          @status_log.success(parts.join(" · "))
        end
      else
        @status_log.warning("LSP not connected (#{health})")
      end
    end

    private def toggle_fold_at_cursor : Nil
      editor = current_editor
      if editor.nil?
        @status_log.warning("No active editor")
        return
      end

      if editor.toggle_fold_at_cursor
        mark_dirty!
      else
        @status_log.info("No fold at cursor")
      end
    end
  end
end
