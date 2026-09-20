require "crystal_tui"
require "../adamantine/document_types"
require "../adamantine/editable_input"

module Adamantine
  class CommandPaletteState
    enum Mode
      Discovery
      Raw
    end

    property open : Bool = false
    getter input_field : EditableInput = EditableInput.new(":")
    property mode : Mode = Mode::Raw
    property candidates : Array(CommandEntry) = [] of CommandEntry
    property selected_index : Int32 = 0
    property scroll : Int32 = 0
    property argument_hint : String = ""
    property prepared_action : String? = nil
    property history : Array(String) = [] of String
    property history_index : Int32 = -1
    property history_draft : String = ":"
    property last_escape_ms : Int64 = 0_i64
    property overlay : Tui::OverlayRenderer? = nil

    def input : String
      @input_field.value
    end

    def input=(value : String) : String
      @input_field.value = value
    end

    def input_cursor : Int32
      @input_field.cursor
    end

    def input_cursor=(value : Int32) : Int32
      @input_field.cursor = value
    end
  end
end
