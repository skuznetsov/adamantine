require "crystal_tui"
require "../adamantine/modal_state"
require "./settings_config"

module Adamantine
  class SettingsState
    include ModalState
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
    property max_response_mib : Int32 = SettingsConfig::DEFAULT_MAX_RESPONSE_MIB

    def reset_capture : Nil
      @mode = Mode::Browse
      @capture_action = nil
      @capture_binding = ""
      @conflicting_action = nil
    end
  end
end
