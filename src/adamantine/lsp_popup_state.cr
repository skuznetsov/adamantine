require "crystal_tui"
require "../adamantine/modal_state"

module Adamantine
  class LspPopupState
    include ModalState

    property open : Bool = false
    property title : String = ""
    property lines : Array(String) = [] of String
    property overlay : Tui::OverlayRenderer? = nil
  end
end
