require "crystal_tui"
require "./debug_panel"

module Adamantine
  # The debugger dock is an ordinary full-width widget below the editor
  # groups. Its error line stays inside the dock while editor diagnostics keep
  # their independent status-log surface in App's nested bottom split.
  class DebugWorkspace < Tui::Widget
    getter panel : DebugPanel

    def initialize(id : String = "debug-workspace")
      super(id)
      @panel = DebugPanel.new("debug-panel")
      add_child(@panel)
    end

    def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
      return unless visible?
      return if @rect.empty?
      previous_width = @panel.rect.width
      previous_height = @panel.rect.height
      @panel.rect = @rect
      if previous_width != @rect.width || previous_height != @rect.height
        # The viewport provider only projects the latest cached controller
        # snapshot. Refresh after SplitContainer has assigned real geometry so
        # the initial hidden-dock page is not permanently empty.
        @panel.refresh_viewport
      end
      @panel.render(buffer, clip)
    end
  end
end
