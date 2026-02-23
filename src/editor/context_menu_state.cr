require "crystal_tui"
require "../editor/document_types"
require "../editor/modal_state"

module CrystalEditor
  class ContextMenuState
    include ModalState

    property open : Bool = false
    property title : String = "Actions"
    property actions : Array(LspContextAction) = [] of LspContextAction
    property index : Int32 = 0
    property overlay : Tui::OverlayRenderer? = nil
  end
end
