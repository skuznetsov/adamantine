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
  end
end
