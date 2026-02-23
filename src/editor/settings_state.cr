require "crystal_tui"

module CrystalEditor
  class SettingsState
    enum Mode
      Browse
      Capture
      ConfirmOverwrite
    end

    property open : Bool = false
    property mode : Mode = Mode::Browse
    property overlay : Tui::OverlayRenderer? = nil
    property actions : Array(String) = [] of String
    property selected_index : Int32 = 0
    property capture_action : String? = nil
    property capture_binding : String = ""
    property conflicting_action : String? = nil

    def reset_capture : Nil
      @mode = Mode::Browse
      @capture_action = nil
      @capture_binding = ""
      @conflicting_action = nil
    end
  end
end
