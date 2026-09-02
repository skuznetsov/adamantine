require "crystal_tui"
require "../adamantine/document_types"
require "../adamantine/modal_state"

module Adamantine
  class ContextMenuState
    include ModalState

    property open : Bool = false
    property title : String = "Actions"
    property actions : Array(LspContextAction) = [] of LspContextAction
    property index : Int32 = 0
    property overlay : Tui::OverlayRenderer? = nil
  end
end
