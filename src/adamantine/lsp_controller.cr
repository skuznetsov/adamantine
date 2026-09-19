module Adamantine
  module LspController
    # Lifecycle owners (App and project switching) call this hook to discard
    # a client before replacing the project root or leaving the UI.
    def shutdown_lsp : Nil
      # Invalidate before stopping the client so a response already in flight
      # cannot publish while transport teardown is still running.
      invalidate_lsp_actions
      if client = @lsp
        begin
          client.stop
        rescue
          # LSP cleanup is best effort; never make application shutdown fail.
        end
        @lsp = nil
      end
      close_lsp_popup(false)
    end

    def lsp_project_root_changed : Nil
      shutdown_lsp
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
        commit_reached = false
        opened = open_file(
          path,
          location.line,
          location.character,
          -> { lsp_action_current?(request) },
          -> {
            # The guard sealed the request immediately before the UI commit;
            # this callback runs before sync_open, where transport may yield.
            commit_reached = true
            context = lsp_action_context(request)
            @document_session.navigation_forward_history.clear
            @document_session.navigation_history << NavigationLocation.new(context[:uri], context[:line], context[:character])
            prune_navigation_history
            @status_log.success("Jump to #{path.basename}:#{location.line + 1}:#{location.character + 1}")
          }
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

    # Interactive requests are deliberately funneled through one scheduler:
    # one request may be waiting on the server and one latest request may wait
    # behind it. The queued request is replaced rather than accumulated.
    private def request_lsp_action(action : InteractiveLspAction) : Nil
      close_lsp_popup

      buffer = current_buffer
      editor = current_editor
      context = current_lsp_context
      unless buffer && editor && context
        @status_log.warning("No active editor")
        return
      end

      client = @lsp
      unless client && client.connected?
        @status_log.warning("LSP is not connected")
        return
      end

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
        @lsp_action_generation
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

      case request.action
      when InteractiveLspAction::Hover
        publish_hover(request, request.client.hover(request.uri, request.line, request.character))
      when InteractiveLspAction::Completion
        publish_completion(request, request.client.completion(request.uri, request.line, request.character))
      when InteractiveLspAction::Signature
        publish_signature(request, request.client.signature_help(request.uri, request.line, request.character))
      when InteractiveLspAction::References
        publish_references(request, request.client.references(request.uri, request.line, request.character))
      when InteractiveLspAction::Definition
        publish_locations(request, "definition", request.client.goto_definition(request.uri, request.line, request.character))
      when InteractiveLspAction::Declaration
        publish_locations(request, "declaration", request.client.declaration(request.uri, request.line, request.character))
      when InteractiveLspAction::TypeDefinition
        publish_locations(request, "type definition", request.client.type_definition(request.uri, request.line, request.character))
      when InteractiveLspAction::Implementation
        publish_locations(request, "implementation", request.client.implementation(request.uri, request.line, request.character))
      when InteractiveLspAction::Hyperclick
        locations = request.client.goto_definition(request.uri, request.line, request.character)
        publish_hyperclick(request, locations)
      when InteractiveLspAction::CodeAction
        publish_code_actions(request, request.client.code_action(request.uri, request.line, request.character))
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
        request.generation
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
      return false unless editor && editor.same?(request.buffer.editor)
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
        detail = item.detail ? " - #{item.detail}" : ""
        "#{index + 1}. #{item.label}#{detail}"
      end
      open_lsp_popup("Completion", lines, 20)
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

    private def build_lsp_context_menu_actions : Array(LspContextAction)
      return [] of LspContextAction unless @lsp.try(&.connected?)

      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active cursor for LSP actions")
        return [] of LspContextAction
      end

      _ = context # explicit capture to avoid unused variable warnings on older compilers
      [
        LspContextAction.new("Go to definition", key_hint("lsp.menu_definition"), -> { goto_definition }),
        LspContextAction.new("Go to declaration", key_hint("lsp.menu_declaration"), -> { goto_declaration }),
        LspContextAction.new("Go to type definition", key_hint("lsp.menu_type_definition"), -> { goto_type_definition }),
        LspContextAction.new("Go to implementation", key_hint("lsp.menu_implementation"), -> { goto_implementation }),
        LspContextAction.new("Show hover", key_hint("lsp.menu_hover"), -> { show_hover_hint }),
        LspContextAction.new("Show references", key_hint("lsp.menu_references"), -> { show_references_hint }),
        LspContextAction.new("Show signature", key_hint("lsp.menu_signature"), -> { show_signature_hint }),
        LspContextAction.new("Show completion", key_hint("lsp.menu_completion"), -> { show_completion_hint }),
        LspContextAction.new("Show diagnostics", key_hint("lsp.menu_diagnostics"), -> { show_diagnostics_hint }),
        LspContextAction.new("Code actions", key_hint("lsp.menu_code_actions"), -> { execute_code_action_hint }),
      ]
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
          connect_lsp(resolved, [] of String)
        else
          @status_log.warning("LSP disabled: no server found. Pass --lsp COMMAND or set ADAMANTINE_LSP")
          @status_log.warning("Hint: install an LSP server for your language (e.g., gopls, rust-analyzer, pyright)")
        end
        return
      end

      return if command.empty?

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
      client.on_diagnostics = ->(uri : String, diagnostics : Array(Lsp::Diagnostic)) {
        updated = false
        @document_session.open_buffers.each_value do |buffer|
          if buffer.uri == uri
            buffer.diagnostics = diagnostics
            updated = true
          end
        end
        if updated
          mark_dirty!
          wakeup
        end
      }
      client.on_semantic_tokens_refresh = -> {
        @document_session.open_buffers.each_value do |buffer|
          schedule_semantic_tokens(buffer, 50.milliseconds)
          schedule_folding_ranges(buffer, 70.milliseconds)
        end
      }
      client.on_warning = ->(message : String) {
        if @lsp.same?(client)
          @status_log.warning(message)
          if path = resolve_keymap_path_for_save
            @status_log.warning("LSP settings config: #{path}")
          end
          mark_dirty!
          wakeup
        end
      }
    end

    private def connect_lsp(command : String, args : Array(String)) : Nil
      client = Lsp::Client.new(command, @project_root, args)
      client.max_response_bytes = SettingsConfig.max_response_bytes(@settings.max_response_mib)
      @lsp = client
      configure_lsp_callbacks(client)

      if client.start
        @status_log.success("LSP connected: #{command}")
        if client.semantic_tokens_supported?
          @status_log.info("LSP semantic highlighting enabled")
        else
          @status_log.warning("LSP has no semanticTokensProvider; syntax coloring unavailable")
        end
      else
        @status_log.error("LSP failed: #{command}")
        @lsp = nil
      end
    end

    private def sync_lsp_open(buffer : OpenBuffer) : Nil
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

      buffer.semantic_generation += 1
      generation = buffer.semantic_generation
      version = buffer.version
      uri = buffer.uri
      path = buffer.path.to_s
      legend = client.semantic_token_legend
      crystal_family = buffer.crystal_family?
      source = lsp_line_source_for(buffer)

      spawn(name: "semantic-tokens") do
        sleep delay
        next unless @lsp.same?(client) && client.connected?
        next unless buffer.semantic_generation == generation
        next unless buffer.version == version
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.uri == uri
        next unless current.semantic_generation == generation
        next unless current.version == version

        data = client.semantic_tokens_full(uri)
        next if data.nil?
        next unless @lsp.same?(client) && client.connected?
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.semantic_generation == generation
        next unless current.version == version

        overlay = SemanticOverlay.build(data, source, legend)
        overlay.apply_hash_comments(source) if crystal_family
        next unless @lsp.same?(client) && client.connected?
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

      buffer.fold_generation += 1
      generation = buffer.fold_generation
      version = buffer.version
      uri = buffer.uri
      path = buffer.path.to_s
      source = lsp_line_source_for(buffer)

      spawn(name: "folding-ranges") do
        sleep delay
        next unless @lsp.same?(client) && client.connected?
        next unless buffer.fold_generation == generation
        next unless buffer.version == version
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.uri == uri
        next unless current.fold_generation == generation
        next unless current.version == version

        ranges = client.folding_ranges(uri)
        next if ranges.nil?
        next unless @lsp.same?(client) && client.connected?
        next unless current = @document_session.open_buffers[path]?
        next unless current.same?(buffer)
        next unless current.fold_generation == generation
        next unless current.version == version

        if current.crystal_family?
          ranges = Folding.merge_crystal_branches(source, ranges)
        end
        next unless @lsp.same?(client) && client.connected?
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
      @lsp.try(&.save_text_document(buffer.uri))
    end

    private def close_lsp_document(uri : String) : Nil
      @lsp.try(&.close_text_document(uri))
    end

    private def show_lsp_status : Nil
      if client = @lsp
        unless client.connected?
          @status_log.warning("LSP not connected")
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
        @status_log.warning("LSP not connected")
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
