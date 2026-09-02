require "crystal_tui"
require "../adamantine/document_types"

module Adamantine
  class CommandPaletteState
    property open : Bool = false
    property input : String = ":"
    property candidates : Array(CommandEntry) = [] of CommandEntry
    property history : Array(String) = [] of String
    property history_index : Int32 = -1
    property last_escape_ms : Int64 = 0_i64
    property overlay : Tui::OverlayRenderer? = nil
  end
end
