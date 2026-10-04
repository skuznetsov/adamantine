require "spec"
require "crystal_tui"

require "../src/adamantine/debug_panel"
require "../src/adamantine/debug_workspace"

private def debug_workspace_buffer_text(buffer : Tui::Buffer, rect : Tui::Rect) : String
  String.build do |text|
    rect.height.times do |dy|
      rect.width.times do |dx|
        text << buffer.get(rect.x + dx, rect.y + dy).glyph
      end
      text << '\n'
    end
  end
end

describe "debug workspace rendering" do
  it "shows bounded sections, active selection, errors, and inferior output in the dock" do
    workspace = Adamantine::DebugWorkspace.new
    workspace.panel.summary = "Stopped · thread 4"
    workspace.panel.error = "Adapter returned an invalid source location"
    workspace.panel.set_lines(Adamantine::DebugPanel::Pane::Stack, ["main at app.cr:7"])
    workspace.panel.set_lines(Adamantine::DebugPanel::Pane::Variables, ["count = 12"])
    workspace.panel.set_lines(Adamantine::DebugPanel::Pane::Output, ["inferior: ready"])
    workspace.panel.selected_pane = Adamantine::DebugPanel::Pane::Output

    rect = Tui::Rect.new(0, 0, 72, 8)
    buffer = Tui::Buffer.new(rect.width, rect.height)
    workspace.rect = rect
    workspace.render(buffer, rect)
    rendered = debug_workspace_buffer_text(buffer, rect)

    rendered.should contain("DEBUG")
    rendered.should contain("Stopped · thread 4")
    rendered.should contain("OUTPUT")
    rendered.should contain("inferior: ready")
    rendered.should contain("invalid source location")
    rendered.should_not contain("main at app.cr:7")
  end

  it "keeps adjacent wide-header pane labels visible when Variables or Breakpoints is active" do
    panel = Adamantine::DebugPanel.new
    rect = Tui::Rect.new(0, 0, 72, 6)
    panel.rect = rect

    panel.selected_pane = Adamantine::DebugPanel::Pane::Variables
    buffer = Tui::Buffer.new(rect.width, rect.height)
    panel.render(buffer, rect)
    variables_header = debug_workspace_buffer_text(buffer, rect).lines.first(2).last
    variables_header.should contain("VARS")
    variables_header.should contain("WATCH")
    variables_header.index("VARS").should eq(15)
    variables_header.index("WATCH").should eq(20)

    panel.selected_pane = Adamantine::DebugPanel::Pane::Breakpoints
    buffer = Tui::Buffer.new(rect.width, rect.height)
    panel.render(buffer, rect)
    breakpoints_header = debug_workspace_buffer_text(buffer, rect).lines.first(2).last
    breakpoints_header.should contain("BP")
    breakpoints_header.should contain("OUTPUT")
    breakpoints_header.should contain("SOURCES")
    breakpoints_header.index("OUTPUT").should eq(29)
    breakpoints_header.index("SOURCES").should eq(36)
  end

  it "uses the displayed compact header extents for mouse pane selection" do
    panel = Adamantine::DebugPanel.new
    rect = Tui::Rect.new(3, 2, 72, 6)
    panel.rect = rect
    panel.focus
    panel.selected_pane = Adamantine::DebugPanel::Pane::Stack

    panel.on_event(Tui::MouseEvent.new(rect.x + 20, rect.y + 1)).should be_true
    panel.selected_pane.should eq(Adamantine::DebugPanel::Pane::Watch)

    panel.on_event(Tui::MouseEvent.new(rect.x + 29, rect.y + 1)).should be_true
    panel.selected_pane.should eq(Adamantine::DebugPanel::Pane::Output)

    panel.on_event(Tui::MouseEvent.new(rect.x + 36, rect.y + 1)).should be_true
    panel.selected_pane.should eq(Adamantine::DebugPanel::Pane::Sources)
  end

  it "owns copied, sanitized rows and clips rendering after resize" do
    workspace = Adamantine::DebugWorkspace.new
    source = ["safe\u0001\u0085 row", "second"]
    workspace.panel.set_lines(Adamantine::DebugPanel::Pane::Watch, source)
    workspace.panel.selected_pane = Adamantine::DebugPanel::Pane::Watch
    source[0] = "mutated outside"
    workspace.panel.lines_for(Adamantine::DebugPanel::Pane::Watch).first.should eq("safe row")

    rect = Tui::Rect.new(2, 1, 18, 3)
    buffer = Tui::Buffer.new(24, 5)
    workspace.rect = rect
    workspace.render(buffer, rect)
    rendered = debug_workspace_buffer_text(buffer, rect)
    rendered.should contain("WATCH")
    rendered.should contain("safe row")
    rendered.should_not contain("mutated")
    rendered.each_line.all? { |line| line.size <= rect.width }.should be_true
  end

  it "sanitizes and bounds untrusted titles and error messages" do
    workspace = Adamantine::DebugWorkspace.new
    workspace.panel.summary = "Stopped\u001b[31m\u0085" + ("x" * 300)
    workspace.panel.error = "bad\u009b31m\u202e" + ("y" * 700)

    workspace.panel.summary.should_not contain('\u001b')
    workspace.panel.summary.should_not contain('\u0085')
    workspace.panel.summary.bytesize.should be <= Adamantine::DebugPanel::MAX_SUMMARY_BYTES
    workspace.panel.error.not_nil!.should_not contain('\u009b')
    workspace.panel.error.not_nil!.should_not contain('\u202e')
    workspace.panel.error.not_nil!.bytesize.should be <= Adamantine::DebugPanel::MAX_ERROR_BYTES
  end

  it "pages through the complete data set while retaining only the requested viewport" do
    panel = Adamantine::DebugPanel.new
    panel.rect = Tui::Rect.new(0, 0, 72, 5)
    panel.selected_pane = Adamantine::DebugPanel::Pane::Stack
    rows = Array.new(200) { |index| "frame #{index}" }
    panel.set_page(Adamantine::DebugPanel::Pane::Stack, 0, rows.size, rows.first(3))

    requested = [] of Tuple(Adamantine::DebugPanel::Pane, Int32, Int32)
    panel.on_viewport_request do |pane, offset, limit|
      requested << {pane, offset, limit}
      panel.set_page(pane, offset, rows.size, rows.skip(offset).first(limit))
    end

    panel.scroll_rows(2).should be_true
    panel.first_visible_row(Adamantine::DebugPanel::Pane::Stack).should eq(2)
    panel.total_rows(Adamantine::DebugPanel::Pane::Stack).should eq(200)
    panel.lines_for(Adamantine::DebugPanel::Pane::Stack).should eq(rows[2, 3])
    requested.last[1].should eq(2)
    requested.last[2].should eq(3)

    panel.scroll_rows(Int32::MAX).should be_true
    panel.first_visible_row(Adamantine::DebugPanel::Pane::Stack).should eq(197)
    panel.lines_for(Adamantine::DebugPanel::Pane::Stack).should eq(rows[197, 3])
    panel.scroll_rows(1).should be_false
  end

  it "shows the viewport range and refuses to silently truncate an unpaged list" do
    panel = Adamantine::DebugPanel.new
    panel.rect = Tui::Rect.new(0, 0, 72, 5)
    rows = Array.new(100) { |index| "frame #{index}" }
    panel.set_page(Adamantine::DebugPanel::Pane::Stack, 20, rows.size, rows.skip(20).first(3))
    panel.selected_pane = Adamantine::DebugPanel::Pane::Stack

    buffer = Tui::Buffer.new(72, 5)
    panel.render(buffer, Tui::Rect.new(0, 0, 72, 5))
    rendered = debug_workspace_buffer_text(buffer, Tui::Rect.new(0, 0, 72, 5))
    rendered.should contain("21-23/100")
    rendered.should contain("frame 22")

    expect_raises(ArgumentError) do
      panel.set_lines(Adamantine::DebugPanel::Pane::Stack, rows)
    end
  end

  it "selects rows, scrolls only at viewport edges, and navigates panes" do
    panel = Adamantine::DebugPanel.new
    panel.rect = Tui::Rect.new(0, 0, 72, 5)
    panel.focus
    rows = Array.new(20) { |index| "row #{index}" }
    panel.set_page(Adamantine::DebugPanel::Pane::Stack, 0, rows.size, rows.first(3))
    panel.on_viewport_request do |pane, offset, limit|
      panel.set_page(pane, offset, rows.size, rows.skip(offset).first(limit))
    end

    panel.on_event(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
    panel.selected_row.should eq(1)
    panel.first_visible_row(Adamantine::DebugPanel::Pane::Stack).should eq(0)
    panel.on_event(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
    panel.selected_row.should eq(2)
    panel.first_visible_row(Adamantine::DebugPanel::Pane::Stack).should eq(0)
    panel.on_event(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
    panel.selected_row.should eq(3)
    panel.first_visible_row(Adamantine::DebugPanel::Pane::Stack).should eq(1)
    panel.lines_for(Adamantine::DebugPanel::Pane::Stack).should eq(rows[1, 3])
    panel.on_event(Tui::KeyEvent.new(Tui::Key::Right)).should be_true
    panel.selected_pane.should eq(Adamantine::DebugPanel::Pane::Threads)
  end

  it "returns Escape from the dock to its caller without stopping navigation state" do
    panel = Adamantine::DebugPanel.new
    panel.focus
    hides = 0
    panel.on_hide { hides += 1 }

    panel.on_event(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
    hides.should eq(1)
  end

  it "re-requests only the visible slice when the dock is resized" do
    panel = Adamantine::DebugPanel.new
    rows = Array.new(200) { |index| "row #{index}" }
    requests = [] of Tuple(Int32, Int32)
    panel.rect = Tui::Rect.new(0, 0, 72, 5)
    panel.on_viewport_request do |pane, offset, limit|
      requests << {offset, limit}
      panel.set_page(pane, offset, rows.size, rows.skip(offset).first(limit))
    end
    requests.last[1].should eq(3)

    panel.rect = Tui::Rect.new(0, 0, 72, 8)
    panel.refresh_viewport
    requests.last[1].should eq(6)
    panel.lines_for(Adamantine::DebugPanel::Pane::Stack).size.should eq(6)
  end
end
