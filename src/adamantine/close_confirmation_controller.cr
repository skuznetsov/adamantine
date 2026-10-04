require "./document_session"

module Adamantine
  # A decision grants authority over this exact editor revision, not a path
  # which may have been reopened or an active tab which may have changed.
  class CloseTarget
    getter buffer : OpenBuffer
    getter editor : Tui::TextEditor
    getter tab_id : String
    getter version : Int32
    getter conflict_generation : UInt64

    def initialize(@buffer : OpenBuffer)
      @editor = @buffer.editor
      @tab_id = @buffer.path.to_s
      @version = @buffer.version
      @conflict_generation = @buffer.external_conflict_generation
    end

    def current?(session : DocumentSession) : Bool
      session.open_buffers[@tab_id]?.try(&.same?(@buffer)) == true &&
        @buffer.editor.same?(@editor) && @buffer.version == @version &&
        @buffer.external_conflict_generation == @conflict_generation
    end
  end

  module CloseConfirmationController
    @close_target : CloseTarget? = nil
    @close_overlay : Tui::OverlayRenderer? = nil
    @close_choice : Int32 = 2
    @close_message : String = ""
    @close_quit_pending : Bool = false
    @close_project_root_pending : Path? = nil
    @close_quit_committing : Bool = false
    @close_approvals : Hash(String, CloseTarget) = {} of String => CloseTarget
    @close_permit : CloseTarget? = nil

    private def close_confirmation_active? : Bool
      !@close_target.nil?
    end

    private def unsafe_to_close?(buffer : OpenBuffer) : Bool
      buffer.editor.modified? || !buffer.external_conflict.nil?
    end

    private def before_close_tab(tab_id : String) : Bool
      if permit = @close_permit
        @close_permit = nil
        return permit.tab_id == tab_id && permit.current?(@document_session)
      end
      return false if close_confirmation_active?
      buffer = @document_session.open_buffers[tab_id]?
      return true unless buffer && unsafe_to_close?(buffer)
      @close_quit_pending = false
      @close_approvals.clear
      show_close_confirmation(buffer)
      false
    end

    private def request_reviewed_quit : Nil
      return if close_confirmation_active?
      @close_quit_pending = true
      @close_project_root_pending = nil
      @close_approvals.clear
      advance_quit_review
    end

    private def request_reviewed_project_root_change(root : Path) : Nil
      return if close_confirmation_active?
      @close_quit_pending = false
      @close_project_root_pending = Path.new(root.to_s)
      @close_approvals.clear
      advance_quit_review
    end

    private def advance_quit_review : Nil
      # Rescan live buffers, including those opened/edited by a deferred
      # producer while another file was being reviewed. Discards are inert
      # until this complete set has been authorized.
      pending = @document_session.open_buffers.values.find do |buffer|
        approval = @close_approvals[buffer.path.to_s]?
        unsafe_to_close?(buffer) && !(approval && approval.current?(@document_session))
      end
      if pending
        show_close_confirmation(pending)
      else
        pending_root = @close_project_root_pending
        quit_pending = @close_quit_pending
        approvals = @close_approvals.dup
        cancel_close_confirmation
        if pending_root
          request_debug_app_transition(DebugAppTransitionKind::ChangeRoot, pending_root, approvals)
        elsif quit_pending
          request_debug_app_transition(DebugAppTransitionKind::Quit, nil, approvals)
        end
      end
    end

    private def review_app_transition(transition : DebugAppTransition,
                                      approvals : Hash(String, CloseTarget)) : Nil
      @close_quit_pending = transition.kind.quit?
      @close_project_root_pending = transition.root
      @close_approvals = approvals.dup
      advance_quit_review
    end

    private def show_close_confirmation(buffer : OpenBuffer, message : String = "") : Nil
      close_external_review
      close_recovery_review
      close_command_palette
      close_context_menu
      close_lsp_popup
      close_quick_open
      close_problems
      close_git_view
      close_settings_dialog if @settings.open
      close_search_panel if @search.open
      cancel_repeat_search_on_input
      @clipboard_paste_generation &+= 1_u64
      invalidate_lsp_actions
      @close_target = CloseTarget.new(buffer)
      @close_choice = 2
      @close_message = message
      enter_input_mode(InputModeController::InputMode::CloseConfirmation)
      @close_overlay = open_overlay(@close_overlay, ->(screen : Tui::Buffer, clip : Tui::Rect) {
        render_close_confirmation(screen, clip)
      })
      mark_dirty!
    end

    private def cancel_close_confirmation : Nil
      close_overlay(@close_overlay)
      @close_overlay = nil
      @close_target = nil
      @close_approvals.clear
      @close_quit_pending = false
      @close_project_root_pending = nil
      @close_permit = nil
      @clipboard_paste_generation &+= 1_u64
      invalidate_lsp_actions
      exit_input_mode(InputModeController::InputMode::CloseConfirmation)
      mark_dirty!
    end

    private def handle_close_confirmation_input(event : Tui::KeyEvent) : Bool
      case
      when event.matches?("escape"), event.matches?("esc")
        cancel_close_confirmation
      when event.matches?("shift+tab"), event.matches?("left"), event.matches?("up")
        @close_choice = (@close_choice + 2) % 3
        mark_dirty!
      when event.matches?("tab"), event.matches?("right"), event.matches?("down")
        @close_choice = (@close_choice + 1) % 3
        mark_dirty!
      when event.matches?("enter"), event.matches?("return")
        decide_close_confirmation
      end
      true
    end

    private def refresh_stale_close_target(target : CloseTarget) : Nil
      if current = @document_session.open_buffers[target.tab_id]?
        show_close_confirmation(current, "File changed since this question. Review again.")
      else
        cancel_close_confirmation
        @status_log.warning("Close cancelled: target is no longer open")
      end
    end

    private def decide_close_confirmation : Nil
      target = @close_target
      return unless target
      if @close_choice == 2
        cancel_close_confirmation
        return
      end
      unless target.current?(@document_session)
        refresh_stale_close_target(target)
        return
      end

      if @close_choice == 0
        unless @document_orchestrator.save_target(target.buffer)
          refresh = @document_session.open_buffers[target.tab_id]?
          if refresh
            message = refresh.external_conflict ? "External change: Cancel, then Save to review the conflict." : "Save failed. File remains open; see the status log."
            show_close_confirmation(refresh, message)
          else
            cancel_close_confirmation
          end
          return
        end
        # on_save/LSP delivery can yield. Never grant close authority over
        # new edits made by a callback after the saved snapshot.
        unless target.current?(@document_session) && !unsafe_to_close?(target.buffer)
          refresh_stale_close_target(target)
          return
        end
      end

      if @close_quit_pending || @close_project_root_pending
        @close_approvals[target.tab_id] = target
        advance_quit_review
      else
        cancel_close_confirmation
        @close_permit = target
        begin
          editor_tabs_for_path_internal(target.tab_id).try(&.close_tab(target.tab_id))
        ensure
          @close_permit = nil
        end
      end
    end

    private def render_close_confirmation(screen : Tui::Buffer, clip : Tui::Rect) : Nil
      target = @close_target
      return unless target
      bounds = @rect
      return unless bounds.width > 0 && bounds.height > 0
      width = {bounds.width, 96}.min
      height = {bounds.height, 10}.min
      rect = Tui::Rect.new(bounds.x + (bounds.width - width) // 2, bounds.y + (bounds.height - height) // 2, width, height)
      paint_clip = rect.intersect(clip)
      return unless paint_clip
      style = Tui::Style.new(fg: Theme::Popup.text, bg: Theme::Editor.text_bg)
      title = if @close_quit_pending
                "Quit editor — review file"
              elsif @close_project_root_pending
                "Change project root — review file"
              else
                "Close file"
              end
      root_change = !@close_project_root_pending.nil?
      choice_labels = root_change ? ["Save", "Continue without saving", "Cancel"] : ["Save", "Discard", "Cancel"]
      choices = choice_labels.map_with_index { |label, index| index == @close_choice ? "[#{label}]" : " #{label} " }.join("  ")
      path = inline_preview_sanitize(target.tab_id)
      # A long parent path must not hide the filename, even on narrow screens.
      if path.each_grapheme.sum { |glyph| Tui::Unicode.grapheme_width(glyph.to_s) } > width
        tail = [] of String
        remaining = [width - 1, 0].max
        path.each_grapheme.to_a.reverse_each do |glyph|
          text = glyph.to_s
          cells = Tui::Unicode.grapheme_width(text)
          break if cells > remaining
          tail << text
          remaining -= cells
        end
        path = "…#{tail.reverse.join}"
      end
      prompt = root_change ? "Save before changing project root?" : "Save changes before closing?"
      retained_note = "Continue without saving keeps this tab open; disk is unchanged unless Save is chosen."
      explanation = root_change ? retained_note : "Discard leaves disk unchanged; recovery may remain."
      cancel_note = if @close_quit_pending
                      "Cancel keeps all tabs; earlier saves remain saved."
                    elsif root_change
                      "Cancel keeps the current root and all tabs."
                    else
                      ""
                    end
      lines = [title, path, prompt, choices,
               "Tab/Arrows: select   Enter: confirm   Esc: Cancel",
               explanation,
               cancel_note,
               @close_message]
      if height < 8 || width < 50
        selected = choice_labels[@close_choice]
        if root_change
          lines = ["Change root: [#{selected}]", "Enter confirms; Esc cancels", path, "Tabs stay open; Save writes disk.", @close_message]
        else
          lines = ["[#{selected}] Enter", "Esc:Cancel Tab:next", path, @close_message]
        end
      end
      paint_clip.each_cell { |x, y| inline_preview_set_cell(screen, paint_clip, x, y, Tui::Cell.new(' ', style)) }
      lines.first(height).each_with_index do |line, offset|
        draw_inline_preview_text(screen, rect, paint_clip, rect.x, rect.y + offset, line, style, width)
      end
    end
  end
end
