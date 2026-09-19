require "crystal_tui"
require "../adamantine/document_types"

module Adamantine
  class CommandPaletteState
    enum Mode
      Discovery
      Raw
    end

    property open : Bool = false
    property input : String = ":"
    property mode : Mode = Mode::Raw
    property candidates : Array(CommandEntry) = [] of CommandEntry
    property selected_index : Int32 = 0
    property scroll : Int32 = 0
    property argument_hint : String = ""
    property prepared_action : String? = nil
    property history : Array(String) = [] of String
    property history_index : Int32 = -1
    property last_escape_ms : Int64 = 0_i64
    property overlay : Tui::OverlayRenderer? = nil
  end
end
