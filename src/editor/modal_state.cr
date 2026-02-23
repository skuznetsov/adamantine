require "crystal_tui"

module CrystalEditor
  module ModalState
    abstract def open : Bool
    abstract def open=(open : Bool)
    abstract def overlay : Tui::OverlayRenderer?
    abstract def overlay=(overlay : Tui::OverlayRenderer?)
  end
end
