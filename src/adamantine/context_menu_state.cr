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
    # The first visible action row. Rendering clamps this against the current
    # clip height so a resize cannot leave the selected row outside the menu.
    property scroll : Int32 = 0
    # Kept as state so keyboard navigation can preserve visibility between
    # redraws; rendering recomputes it whenever the viewport changes.
    property visible_rows : Int32 = 0
    property overlay : Tui::OverlayRenderer? = nil
  end
end
