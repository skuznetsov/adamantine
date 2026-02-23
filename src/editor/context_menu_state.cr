require "crystal_tui"
require "../editor/document_types"

module CrystalEditor
  class ContextMenuState
    property open : Bool = false
    property title : String = "Actions"
    property actions : Array(LspContextAction) = [] of LspContextAction
    property index : Int32 = 0
    property overlay : Tui::OverlayRenderer? = nil
  end
end
