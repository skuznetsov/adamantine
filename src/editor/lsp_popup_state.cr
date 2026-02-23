require "crystal_tui"
require "../editor/modal_state"

module CrystalEditor
  class LspPopupState
    include ModalState

    property open : Bool = false
    property title : String = ""
    property lines : Array(String) = [] of String
    property overlay : Tui::OverlayRenderer? = nil
  end
end
