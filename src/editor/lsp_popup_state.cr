require "crystal_tui"

module CrystalEditor
  class LspPopupState
    property open : Bool = false
    property title : String = ""
    property lines : Array(String) = [] of String
    property overlay : Tui::OverlayRenderer? = nil
  end
end
