require "crystal_tui"

require "./external_change_review"

module Adamantine
  # Owns the editor-pane comparison shown for an unresolved external file
  # observation.  The review is deliberately a captured backend object: the
  # controller never reads disk or constructs a new candidate while a choice
  # is selected.
  module ExternalReviewController
    EXTERNAL_REVIEW_TITLE = "- Editor | + Disk"
    EXTERNAL_REVIEW_SCOPE = "external change"

    enum ExternalReviewChoice
      Later
      Reload
      Overwrite
    end

    @external_review : ExternalChangeReview? = nil
    @external_review_overlay : Tui::OverlayRenderer? = nil
    @external_review_choice : ExternalReviewChoice = ExternalReviewChoice::Later
    @external_review_request_generation : UInt64 = 0_u64
    @external_review_loading : Bool = false

    # This is intentionally true while a review is being prepared.  Disk
    # preparation is bounded but may yield in the file reader; reserving the
    # mode first prevents another route from opening a competing modal during
    # that boundary.
    private def external_review_active? : Bool
      @external_review_loading || !@external_review.nil?
    end

    private def external_review_choice : ExternalReviewChoice
      @external_review_choice
    end

    # Open a review for the explicitly supplied buffer, or the current buffer
    # when called by the command/shortcut.  An already-open review is stable:
    # monitor notifications and repeated commands cannot replace its capture
    # or silently reset the selected action.
    private def open_external_review(buffer : OpenBuffer? = nil) : Bool
      return true if external_review_active?

      target = buffer || current_buffer
      unless target
        @status_log.warning("No active editor to review")
        return false
      end

      # Opening is explicit and owns the editor pane.  Existing surfaces are
      # closed before we reserve the new mode; their callbacks cannot retain a
      # clipboard/LSP authority over the pane beneath the comparison.
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

      @external_review_request_generation &+= 1_u64
      request_generation = @external_review_request_generation
      @external_review_loading = true
      @external_review_choice = ExternalReviewChoice::Later
      enter_input_mode(InputModeController::InputMode::ExternalReview)
      mark_dirty!

      review = @document_orchestrator.prepare_external_review(target)

      # The prepare call is a guarded observation.  A lifecycle event may have
      # closed the review while it was reading; in that case, discard the
      # result instead of installing a late overlay for an old buffer.
      unless request_generation == @external_review_request_generation && @external_review_loading
        return false
      end
      @external_review_loading = false

      unless review
        close_external_review
        @status_log.warning("External review is unavailable; conflict remains unresolved")
        return false
      end

      unless external_review_target_current?(review)
        close_external_review
        @status_log.warning("External review cancelled: editor changed while it was prepared")
        return false
      end

      @external_review = review
      begin
        @external_review_overlay = open_overlay(@external_review_overlay, ->(screen : Tui::Buffer, clip : Tui::Rect) {
          render_external_review(screen, clip)
        })
      rescue ex
        close_external_review
        @status_log.warning("External review unavailable: #{ex.message || ex.class}")
        return false
      end
      mark_dirty!
      true
    rescue ex
      # A failed bounded read must not leave a modal mode or stale loading
      # reservation behind.  No action is inferred from the failure.
      close_external_review
      @status_log.warning("External review unavailable: #{ex.message || ex.class}")
      false
    end

    private def close_external_review : Nil
      @external_review_request_generation &+= 1_u64
      @external_review_loading = false
      close_overlay(@external_review_overlay)
      @external_review_overlay = nil
      @external_review = nil
      @external_review_choice = ExternalReviewChoice::Later
      @clipboard_paste_generation &+= 1_u64
      invalidate_lsp_actions
      exit_input_mode(InputModeController::InputMode::ExternalReview)
      mark_dirty!
    end

    # All key events are consumed while the comparison owns the pane.  In
    # particular, printable keys, remapped actions, and unknown navigation
    # keys never reach the editor underneath the overlay.
    private def handle_external_review_input(event : Tui::KeyEvent) : Bool
      return true unless external_review_active?

      # Escape is the one useful event while a bounded preparation is in
      # flight: it cancels the reservation and invalidates the late result.
      # Keep this before the loading guard so a slow disk read cannot make the
      # modal uncancellable.
      if event.matches?("escape") || event.matches?("esc")
        # Escape always means Later, even after the user highlighted an
        # explicit destructive action.
        close_external_review
        return true
      end

      return true if @external_review_loading

      case
      when event.matches?("enter"), event.matches?("return")
        if @external_review_choice == ExternalReviewChoice::Later
          close_external_review
        else
          accept_external_review
        end
      when event.matches?("tab")
        cycle_external_review_choice(1)
      when event.matches?("shift+tab")
        cycle_external_review_choice(-1)
      when event.matches?("up")
        scroll_external_review(-1)
      when event.matches?("down")
        scroll_external_review(1)
      when event.matches?("pageup")
        page_external_review(-1)
      when event.matches?("pagedown")
        page_external_review(1)
      when event.matches?("home")
        home_external_review
      when event.matches?("end")
        end_external_review
      end
      true
    end

    private def cycle_external_review_choice(delta : Int32) : Nil
      review = @external_review
      return unless review

      choices = external_review_choices(review)
      return if choices.size < 2

      current_index = choices.index(@external_review_choice) || 0
      index = (current_index + delta) % choices.size
      index += choices.size if index < 0
      @external_review_choice = choices[index]
      mark_dirty!
    end

    private def accept_external_review : Nil
      review = @external_review
      unless review
        close_external_review
        return
      end

      unless external_review_target_current?(review)
        close_external_review
        @status_log.warning("External review is stale; no action applied")
        return
      end

      action = case @external_review_choice
               when ExternalReviewChoice::Reload    then ExternalConflictAction::Reload
               when ExternalReviewChoice::Overwrite then ExternalConflictAction::Overwrite
               else                                      nil
               end
      unless action
        close_external_review
        return
      end

      applied = begin
        @document_orchestrator.apply_external_review(review, action.not_nil!)
      rescue ex
        @status_log.warning("External review failed: #{ex.message || ex.class}")
        false
      end
      # A failed acceptance is terminal for this captured review.  The backend
      # may have discovered a newer editor or disk observation; retaining the
      # overlay would invite a retry with authority that has already failed.
      close_external_review
      @status_log.warning("External review could not be completed; inspect current state and review again") unless applied
    end

    private def external_review_target_current?(review : ExternalChangeReview) : Bool
      current = current_buffer
      editor = current_editor
      return false unless current && editor
      current.not_nil!.same?(review.buffer) &&
        editor.not_nil!.same?(review.editor) &&
        review.buffer.version == review.version &&
        review.buffer.external_conflict_generation == review.conflict_generation
    end

    private def external_review_preview : InlineEditPreview::Model?
      @external_review.try(&.preview)
    end

    private def scroll_external_review(delta : Int32) : Nil
      preview = external_review_preview
      return unless preview
      preview.scroll_by(delta)
      mark_dirty!
    end

    private def page_external_review(delta : Int32) : Nil
      preview = external_review_preview
      return unless preview
      page_rows = if editor = current_editor
                    [editor.rect.height - 2, 1].max
                  else
                    1
                  end
      preview.scroll_page(delta, page_rows)
      mark_dirty!
    end

    private def home_external_review : Nil
      if preview = external_review_preview
        preview.home
        mark_dirty!
      end
    end

    private def end_external_review : Nil
      if preview = external_review_preview
        preview.finish
        mark_dirty!
      end
    end

    private def render_external_review(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      review = @external_review
      return unless review

      preview = review.preview
      scope = "#{EXTERNAL_REVIEW_SCOPE} · #{inline_preview_sanitize(review.buffer.path.to_s)}"
      controls = external_review_footer_controls(review)
      if preview
        render_inline_edit_preview(
          buffer,
          clip,
          preview.not_nil!,
          EXTERNAL_REVIEW_TITLE,
          scope,
          controls[:full],
          controls[:narrow],
          controls[:compact],
          controls[:tiny]
        )
      else
        reason = external_review_unavailable_reason(review)
        render_inline_preview_message(
          buffer,
          clip,
          EXTERNAL_REVIEW_TITLE,
          reason,
          scope,
          controls[:full],
          controls[:narrow],
          controls[:compact],
          controls[:tiny]
        )
      end
    end

    private def external_review_choices(review : ExternalChangeReview) : Array(ExternalReviewChoice)
      choices = [ExternalReviewChoice::Later]
      if review.current.missing?
        # A missing path has no reload candidate, but overwrite is explicitly
        # allowed to recreate it from the captured editor text.
        choices << ExternalReviewChoice::Overwrite
      elsif review.current.stable? && review.preview_available?
        choices << ExternalReviewChoice::Reload
        choices << ExternalReviewChoice::Overwrite
      end
      choices
    end

    private def external_review_choice_label(choice : ExternalReviewChoice) : String
      case choice
      when ExternalReviewChoice::Later     then "Later"
      when ExternalReviewChoice::Reload    then "Reload"
      when ExternalReviewChoice::Overwrite then "Overwrite"
      else
        "Later"
      end
    end

    private def external_review_footer_controls(
      review : ExternalChangeReview,
    ) : NamedTuple(full: String, narrow: String, compact: String, tiny: String)
      choices = external_review_choices(review)
      # A stale/unsupported disk observation may be reviewable only as an
      # explanation.  Do not advertise an action which the backend must reject.
      if choices.size == 1
        return {
          full:    "Enter [Later] | Esc closes",
          narrow:  "Enter [Later] | Esc closes",
          compact: "Enter [Later] | Esc",
          tiny:    "[Later] Enter | Esc",
        }
      end

      selected = external_review_choice_label(@external_review_choice)
      selected_text = "[#{selected}]"
      selected_index = choices.index(@external_review_choice) || 0
      next_choice = choices[(selected_index + 1) % choices.size]
      previous_choice = choices[(selected_index - 1) % choices.size]
      next_label = external_review_choice_label(next_choice)
      previous_label = external_review_choice_label(previous_choice)
      {
        full: "Enter #{selected_text} | Tab #{next_label} | Shift-Tab #{previous_label}",
        # At narrow widths retain only controls which are true at every
        # selection: Enter activates the bracketed action and Escape means
        # Later.  There are no imaginary one-letter shortcuts.
        narrow:  "Enter #{selected_text} | Esc Later",
        compact: "Enter #{selected_text} | Esc",
        tiny:    "#{selected_text} Enter | Esc",
      }
    end

    private def external_review_unavailable_reason(review : ExternalChangeReview) : String
      if review.current.missing?
        "Disk candidate unavailable (missing); Overwrite recreates it from editor"
      else
        "Disk candidate unavailable: #{inline_preview_sanitize(review.preview_status)}"
      end
    end
  end
end
