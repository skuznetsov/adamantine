require "crystal_tui"

module CrystalEditor
  module OverlayController
    private def open_overlay(current : Tui::OverlayRenderer?, renderer : Tui::OverlayRenderer) : Tui::OverlayRenderer
      App.remove_overlay(current) if current
      App.add_overlay(renderer)
      renderer
    end

    private def close_overlay(current : Tui::OverlayRenderer?) : Nil
      App.remove_overlay(current) if current
    end

    private def close_modal(state : ModalState, mode : InputModeController::InputMode) : Nil
      return unless state.open

      close_overlay(state.overlay)
      state.open = false
      state.overlay = nil
      exit_input_mode(mode)
    end
  end
end
