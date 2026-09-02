module Adamantine
  module LspController
    # Lifecycle owners (App and project switching) call this hook to discard
    # a client before replacing the project root or leaving the UI.
    def shutdown_lsp : Nil
      if client = @lsp
        begin
          client.stop
        rescue
          # LSP cleanup is best effort; never make application shutdown fail.
        end
        @lsp = nil
      end
      close_lsp_popup
    end

    def lsp_project_root_changed : Nil
      shutdown_lsp
    end

    private def goto_definition : Nil
      goto_lsp_location("definition") do |client, context|
        client.goto_definition(context[:uri], context[:line], context[:character])
      end
    end

    private def goto_declaration : Nil
      goto_lsp_location("declaration") do |client, context|
        client.declaration(context[:uri], context[:line], context[:character])
      end
    end

    private def goto_type_definition : Nil
      goto_lsp_location("type definition") do |client, context|
        client.type_definition(context[:uri], context[:line], context[:character])
      end
    end

    private def goto_implementation : Nil
      goto_lsp_location("implementation") do |client, context|
        client.implementation(context[:uri], context[:line], context[:character])
      end
    end

    private def goto_lsp_location(
      label : String,
      &block : (Lsp::Client, NamedTuple(uri: String, line: Int32, character: Int32) -> Array(Lsp::Location))
    ) : Nil
      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active editor position for #{label}")
        return
      end

      client = @lsp
      if client.nil?
        @status_log.warning("LSP is not connected")
        return
      end

      locations = begin
        block.call(client, context)
      rescue ex
        report_lsp_action_failure(label, ex)
        return
      end
      if locations.empty?
        @status_log.warning("No #{label} found")
        return
      end

      jump_to_locations(label, context, locations)
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
      context = current_lsp_context
      if context.nil?
        @status_log.warning("No active editor position for hyperclick")
        return
      end

      client = lsp_client_or_warning
      return unless client

      locations = begin
        client.goto_definition(context[:uri], context[:line], context[:character])
      rescue ex
        report_lsp_action_failure("definition", ex)
        return
      end
      if Hyperclick.prefer_references?(context[:uri], context[:line], locations)
        show_references_hint
        return
      end

      jump_to_locations("definition", context, locations)
    end

    private def jump_to_locations(
      _label : String,
      context : NamedTuple(uri: String, line: Int32, character: Int32),
      locations : Array(Lsp::Location),
    ) : Nil
      return if locations.empty?

      @document_session.navigation_forward_history.clear
      @document_session.navigation_history << NavigationLocation.new(context[:uri], context[:line], context[:character])
      prune_navigation_history

      location = locations.first
      uri_to_path(location.uri).try do |path|
        if !open_file(path, location.line, location.character)
          @document_session.navigation_history.pop?
          @status_log.error("Failed to jump to #{path}")
        else
          @status_log.success("Jump to #{path.basename}:#{location.line + 1}:#{location.character + 1}")
        end
      end
    end

    private def show_hover_hint : Nil
      context = current_lsp_context
      if context.nil?
        close_lsp_popup
        @status_log.warning("No active editor")
        return
      end

      client = lsp_client_or_warning
      return unless client

      begin
        hover = client.hover(context[:uri], context[:line], context[:character])
        if hover.nil?
          @status_log.warning("No hover information")
          close_lsp_popup
          return
        end

        open_lsp_popup("Hover", wrap_lines(hover.text), 14)
      rescue ex
        report_lsp_action_failure("hover", ex)
      end
    end

    private def show_references_hint : Nil
      context = current_lsp_context
      if context.nil?
        close_lsp_popup
        @status_log.warning("No active editor")
        return
      end

      client = lsp_client_or_warning
      return unless client

      begin
        references = client.references(context[:uri], context[:line], context[:character])
        if references.empty?
          @status_log.warning("No references")
          close_lsp_popup
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
      rescue ex
        report_lsp_action_failure("references", ex)
      end
    end

    private def show_signature_hint : Nil
      context = current_lsp_context
      if context.nil?
        close_lsp_popup
        @status_log.warning("No active editor")
        return
      end

      client = lsp_client_or_warning
      return unless client

      begin
        signature = client.signature_help(context[:uri], context[:line], context[:character])
        if signature.nil? || signature.signatures.empty?
          @status_log.warning("No signature help")
          close_lsp_popup
          return
        end

        lines = signature.signatures.each_with_index.to_a.map do |signature_text, index|
          marker = index == signature.active_signature ? "▶" : " "
          "#{marker} #{signature_text}"
        end
        open_lsp_popup("Signature", lines, 14)
      rescue ex
        report_lsp_action_failure("signature", ex)
      end
    end

    private def show_completion_hint : Nil
      context = current_lsp_context
      if context.nil?
        close_lsp_popup
        @status_log.warning("No active editor")
        return
      end

      client = lsp_client_or_warning
      return unless client

      begin
        completions = client.completion(context[:uri], context[:line], context[:character])
        if completions.empty?
          @status_log.warning("No completion items")
          close_lsp_popup
          return
        end

        lines = completions.each_with_index.to_a.map do |item, index|
          detail = item.detail ? " - #{item.detail}" : ""
          "#{index + 1}. #{item.label}#{detail}"
        end
        open_lsp_popup("Completion", lines, 20)
      rescue ex
        report_lsp_action_failure("completion", ex)
      end
    end

    private def show_diagnostics_hint : Nil
      buffer = current_buffer
      editor = current_editor
      if buffer.nil? || editor.nil?
        close_lsp_popup
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
      context = current_lsp_context
      if context.nil?
        close_lsp_popup
        @status_log.warning("No active editor")
        return
      end

      client = lsp_client_or_warning
      return unless client

      begin
        actions = client.code_action(context[:uri], context[:line], context[:character])
        if actions.empty?
          @status_log.warning("No code actions")
          close_lsp_popup
          return
        end

        lines = actions.each_with_index.to_a.map do |action, index|
          title = action["title"]?.try(&.as_s) || "action #{index + 1}"
          "#{index + 1}. #{title}"
        end
        open_lsp_popup("Code actions", lines, 18)
      rescue ex
        report_lsp_action_failure("code actions", ex)
      end
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

    private def connect_lsp(command : String, args : Array(String)) : Nil
      @lsp = Lsp::Client.new(command, @project_root, args)
      @lsp.try do |client|
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
      end

      if @lsp.try(&.start)
        @status_log.success("LSP connected: #{command}")
        if @lsp.try(&.semantic_tokens_supported?)
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

    private def sync_lsp_change(buffer : OpenBuffer) : Nil
      @lsp.try do |client|
        client.text_change(
          uri: buffer.uri,
          version: buffer.version,
          text: buffer.editor.text
        )
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
      uri = buffer.uri
      path = buffer.path.to_s
      legend = client.semantic_token_legend
      crystal_family = buffer.crystal_family?

      spawn(name: "semantic-tokens") do
        sleep delay
        next unless @lsp.same?(client) && client.connected?
        next unless buffer.semantic_generation == generation
        next unless current = @document_session.open_buffers[path]?
        next unless current.uri == uri
        next unless current.semantic_generation == generation

        data = client.semantic_tokens_full(uri)
        next if data.nil?
        next unless @lsp.same?(client) && client.connected?
        next unless current.semantic_generation == generation

        overlay = SemanticOverlay.build(data, current.editor.lines, legend)
        overlay.apply_hash_comments(current.editor.lines) if crystal_family
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
      uri = buffer.uri
      path = buffer.path.to_s

      spawn(name: "folding-ranges") do
        sleep delay
        next unless @lsp.same?(client) && client.connected?
        next unless buffer.fold_generation == generation
        next unless current = @document_session.open_buffers[path]?
        next unless current.uri == uri
        next unless current.fold_generation == generation

        ranges = client.folding_ranges(uri)
        next if ranges.nil?
        next unless @lsp.same?(client) && client.connected?
        next unless current.fold_generation == generation

        if current.crystal_family?
          ranges = Folding.merge_crystal_branches(current.editor.lines, ranges)
        end
        current.editor.set_fold_ranges(ranges)
        mark_dirty!
        wakeup
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
