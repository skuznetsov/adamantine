require "crystal_tui"

require "./recovery_review_controller"

module Adamantine
  # Owns the modal lifecycle for a detached recovery comparison. The builder
  # has observation authority only; this layer never recovers, discards, saves,
  # reloads, or otherwise mutates a document.
  module RecoveryReviewControllerUi
    @recovery_review_overlay : Tui::OverlayRenderer? = nil
    @recovery_review_loading : Bool = false
    @recovery_review_request_generation : UInt64 = 0_u64

    private def recovery_review_active? : Bool
      @recovery_review_loading || @recovery_review_controller.active?
    end

    private def open_recovery_review(candidate : RecoveryController::RecoveryCandidate) : Bool
      return true if recovery_review_active?

      close_external_review
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

      @recovery_review_request_generation &+= 1_u64
      request_generation = @recovery_review_request_generation
      @recovery_review_loading = true
      enter_input_mode(InputModeController::InputMode::RecoveryReview)
      mark_dirty!

      preview = @recovery_controller.preview(candidate)
      unless request_generation == @recovery_review_request_generation && @recovery_review_loading
        return false
      end
      unless preview
        close_recovery_review
        @status_log.warning("Recovery review unavailable; checkpoint changed or disappeared")
        return false
      end

      @recovery_review_controller.open(preview.not_nil!)
      unless request_generation == @recovery_review_request_generation && @recovery_review_loading
        @recovery_review_controller.close
        return false
      end
      @recovery_review_loading = false

      begin
        @recovery_review_overlay = open_overlay(@recovery_review_overlay, ->(screen : Tui::Buffer, clip : Tui::Rect) {
          render_recovery_review(screen, clip)
        })
      rescue ex
        close_recovery_review
        @status_log.warning("Recovery review unavailable: #{ex.message || ex.class}")
        return false
      end
      mark_dirty!
      true
    rescue ex
      close_recovery_review
      @status_log.warning("Recovery review unavailable: #{ex.message || ex.class}")
      false
    end

    private def close_recovery_review : Nil
      @recovery_review_request_generation &+= 1_u64
      @recovery_review_loading = false
      close_overlay(@recovery_review_overlay)
      @recovery_review_overlay = nil
      @recovery_review_controller.close
      @clipboard_paste_generation &+= 1_u64
      invalidate_lsp_actions
      exit_input_mode(InputModeController::InputMode::RecoveryReview)
      mark_dirty!
    end

    # All events are consumed while this mode is reserved, including paste,
    # mouse, printable keys, remapped actions, and Enter. Escape is the only
    # event that acts while the bounded capture is still in flight.
    private def handle_recovery_review_input(event : Tui::Event) : Bool
      return true unless recovery_review_active?

      if event.is_a?(Tui::KeyEvent) && (event.matches?("escape") || event.matches?("esc"))
        close_recovery_review
        return true
      end
      return true if @recovery_review_loading

      @recovery_review_controller.handle_input(event, recovery_review_page_rows)
      if @recovery_review_controller.active?
        mark_dirty!
      else
        close_recovery_review
      end
      true
    end

    private def recovery_review_page_rows : Int32
      [recovery_review_target_rect.height - 2, 1].max
    end

    private def recovery_review_target_rect : Tui::Rect
      current_editor.try(&.rect) || @editor_tabs.rect
    end

    private def render_recovery_review(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return if @recovery_review_loading

      state = @recovery_review_controller.render_state
      controls = @recovery_review_controller.footer_controls
      target = recovery_review_target_rect
      tab_size = current_editor.try(&.tab_size) || 4
      if preview = state.model
        render_inline_edit_preview(
          buffer,
          clip,
          preview,
          state.title,
          state.scope,
          controls[:full],
          controls[:narrow],
          controls[:compact],
          controls[:tiny],
          target,
          tab_size
        )
      else
        render_inline_preview_message(
          buffer,
          clip,
          state.title,
          state.message || "Recovery review unavailable",
          state.scope,
          controls[:full],
          controls[:narrow],
          controls[:compact],
          controls[:tiny],
          target,
          tab_size
        )
      end
    end
  end
end
