require "crystal_tui"

module CrystalEditor
  module KeyboardModeEngine
    private struct KeyModeRoute
      getter activate : Proc(Tui::KeyEvent, Bool)
      getter handle : Proc(Tui::KeyEvent, Bool)

      def initialize(@activate : Proc(Tui::KeyEvent, Bool), @handle : Proc(Tui::KeyEvent, Bool))
      end
    end

    private def route_key_modes(event : Tui::KeyEvent, routes : Array(KeyModeRoute)) : Bool
      routes.each do |route|
        next unless route.activate.call(event)
        handled = route.handle.call(event)
        return true if handled
      end
      false
    end
  end
end
