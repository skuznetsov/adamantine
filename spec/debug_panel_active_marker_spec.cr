require "spec"
require "crystal_tui"

require "../src/adamantine/debug_panel"

describe "debug panel active pane marker" do
  it "renders a textual marker immediately before the selected wide-header pane" do
    panel = Adamantine::DebugPanel.new
    rect = Tui::Rect.new(2, 1, 110, 6)
    panel.rect = rect

    {
      {Adamantine::DebugPanel::Pane::Stack, 1, "STACK"},
      {Adamantine::DebugPanel::Pane::Threads, 7, "THREADS"},
      {Adamantine::DebugPanel::Pane::Variables, 15, "VARS"},
      {Adamantine::DebugPanel::Pane::Watch, 20, "WATCH"},
      {Adamantine::DebugPanel::Pane::Breakpoints, 26, "BP"},
      {Adamantine::DebugPanel::Pane::Output, 29, "OUTPUT"},
      {Adamantine::DebugPanel::Pane::Sources, 36, "SOURCES"},
    }.each do |pane, offset, label|
      panel.selected_pane = pane
      buffer = Tui::Buffer.new(112, 8)
      panel.render(buffer, rect)
      header_y = rect.y + 1
      buffer.get(rect.x + offset - 1, header_y).glyph.should eq("▶")
      buffer.get(rect.x + offset, header_y).glyph.should eq(label[0].to_s)
      (rect.x...rect.right).count { |x| buffer.get(x, header_y).glyph == "▶" }.should eq(1)
    end
  end

  it "keeps wide-header click targets aligned at both ends after selection changes" do
    panel = Adamantine::DebugPanel.new
    rect = Tui::Rect.new(2, 1, 110, 6)
    panel.rect = rect
    panel.focus

    # Select a middle tab first so its marker is visible while clicking the
    # first tab. Both the leading and trailing cell of each edge label remain
    # inside that label's original hitbox.
    panel.selected_pane = Adamantine::DebugPanel::Pane::Output
    {1, 5}.each do |offset|
      panel.on_event(Tui::MouseEvent.new(rect.x + offset, rect.y + 1)).should be_true
      panel.selected_pane.should eq(Adamantine::DebugPanel::Pane::Stack)
    end

    # Move selection away from the final tab and verify its visible label is
    # still clickable through its last character, not its preceding marker.
    panel.selected_pane = Adamantine::DebugPanel::Pane::Stack
    {36, 42}.each do |offset|
      panel.on_event(Tui::MouseEvent.new(rect.x + offset, rect.y + 1)).should be_true
      panel.selected_pane.should eq(Adamantine::DebugPanel::Pane::Sources)
    end
  end
end
