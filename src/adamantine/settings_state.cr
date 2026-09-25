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
      ConfirmUnbind
    end

    property open : Bool = false
    property mode : Mode = Mode::Browse
    property overlay : Tui::OverlayRenderer? = nil
    property actions : Array(String) = [] of String
    property selected_index : Int32 = 0
    property capture_action : String? = nil
    property capture_binding : String = ""
    property conflicting_action : String? = nil
    # Keep every owner so a remap cannot silently discard the second and
    # subsequent action sharing a binding.  conflicting_action remains as a
    # compatibility/display shortcut for older callers.
    property conflicting_actions : Array(String) = [] of String
    property max_response_mib : Int32 = SettingsConfig::DEFAULT_MAX_RESPONSE_MIB
    property indent_width : Int32 = EditingSettings::DEFAULT_INDENT_WIDTH
    property auto_indent : Bool = EditingSettings::DEFAULT_AUTO_INDENT

    def reset_capture : Nil
      @mode = Mode::Browse
      @capture_action = nil
      @capture_binding = ""
      @conflicting_action = nil
      @conflicting_actions.clear
    end
  end
end
