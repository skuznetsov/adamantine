require "spec"
require "crystal_tui"

require "../src/adamantine/debug_panel"
require "../src/adamantine/debug_inspector_layout"

private class DebugLayoutProbe < Tui::Widget
  getter label : String
  property marker : String

  def initialize(@label : String, @marker : String = "")
    super(@label.downcase)
    @focusable = true
  end

  def render(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
    return unless visible?
    return if @rect.empty?
    @label.each_char_with_index do |char, index|
      x = @rect.x + index
      break if x >= @rect.right
      buffer.set(x, @rect.y, char, Tui::Style.default) if clip.contains?(x, @rect.y)
    end
  end
end

private def debug_layout_text(buffer : Tui::Buffer, rect : Tui::Rect) : String
  String.build do |text|
    rect.height.times do |dy|
      rect.width.times do |dx|
        text << buffer.get(rect.x + dx, rect.y + dy).glyph
      end
      text << '\n'
    end
  end
end

describe "debug inspector layout" do
  it "defaults to a two-column Files/Debug rail and a left inspector" do
    editor = DebugLayoutProbe.new("EDITOR")
    files = DebugLayoutProbe.new("FILES")
    debug = DebugLayoutProbe.new("DEBUG")
    layout = Adamantine::DebugInspectorLayout.new(editor, files, debug)
    layout.rect = Tui::Rect.new(0, 0, 112, 24)

    geometry = layout.geometry
    geometry.dock.should eq(Adamantine::DebugInspectorDock::Left)
    geometry.rail.width.should eq(1)
    geometry.rail_separator_x.should eq(1)
    geometry.inspector.not_nil!.x.should eq(2)
    geometry.inspector.not_nil!.width.should eq(Adamantine::DebugInspectorLayout::DEFAULT_FILES_INSPECTOR_WIDTH)
    geometry.inspector.not_nil!.right.should be < geometry.editor.x
    layout.selected_section.should eq(Adamantine::DebugInspectorSection::Files)

    buffer = Tui::Buffer.new(112, 24)
    layout.render(buffer, Tui::Rect.new(0, 0, 112, 24))
    {"Files", "debug"}.each_with_index do |label, index|
      start_y = index == 0 ? 0 : 6
      label.each_char_with_index do |char, offset|
        expected = index == 0 && offset == 0 ? 'F' : char
        buffer.get(0, start_y + offset).glyph.should eq(expected.to_s)
      end
    end
    24.times { |y| buffer.get(1, y).glyph.should eq('│'.to_s) }
    buffer.get(0, 0).style.bg.should eq(Adamantine::Theme::Popup.active_bg)
    buffer.get(0, 0).style.underline?.should be_true
    buffer.get(0, 0).style.bold?.should be_true
    buffer.get(0, 0).style.reverse?.should be_false
  end

  it "keeps a real Debug variable summary readable at the default sidebar width" do
    debug = Adamantine::DebugPanel.new
    debug.selected_pane = Adamantine::DebugPanel::Pane::Variables
    debug.set_lines(Adamantine::DebugPanel::Pane::Variables, ["sentinel = String \"evidence-value\""])
    layout = Adamantine::DebugInspectorLayout.new(
      DebugLayoutProbe.new("EDITOR"), DebugLayoutProbe.new("FILES"), debug
    )
    layout.rect = Tui::Rect.new(0, 0, 112, 24)
    layout.select_section(Adamantine::DebugInspectorSection::Debug).should be_true
    geometry = layout.geometry
    geometry.inspector.not_nil!.width.should eq(Adamantine::DebugInspectorLayout::DEFAULT_DEBUG_INSPECTOR_WIDTH)

    buffer = Tui::Buffer.new(112, 24)
    layout.render(buffer, Tui::Rect.new(0, 0, 112, 24))
    debug_layout_text(buffer, geometry.inspector.not_nil!).should contain("evidence-value")
  end

  it "renders a real file tree in the compact 11-column Files sidebar" do
    root = Path.new(Dir.tempdir, "adamantine-compact-tree-#{Random::Secure.hex(8)}")
    Dir.mkdir(root.to_s)
    file_path = root / "a.cr"
    File.write(file_path, "")

    begin
      file_panel = Adamantine::DebugSharedEdgeFilePanel.new(root)
      layout = Adamantine::DebugInspectorLayout.new(
        DebugLayoutProbe.new("EDITOR"), file_panel, DebugLayoutProbe.new("DEBUG")
      )
      layout.rect = Tui::Rect.new(0, 0, 34, 20)
      layout.geometry.inspector.not_nil!.width.should eq(11)

      buffer = Tui::Buffer.new(34, 20)
      layout.render(buffer, Tui::Rect.new(0, 0, 34, 20))
      inspector = layout.geometry.inspector.not_nil!
      tree = debug_layout_text(buffer, inspector)
      tree.should contain("a.cr")
      tree.lines.size.should eq(20)
      buffer.get(1, 0).glyph.should eq('│'.to_s)
      buffer.get(13, 0).glyph.should eq('│'.to_s)
      inspector.height.times do |offset|
        y = inspector.y + offset
        buffer.get(inspector.x, y).glyph.should eq(" ")
        buffer.get(inspector.right - 1, y).glyph.should eq(" ")
      end
      inspector.width.times do |offset|
        x = inspector.x + offset
        buffer.get(x, inspector.y).glyph.should_not eq('─'.to_s)
        buffer.get(x, inspector.bottom - 1).glyph.should_not eq('─'.to_s)
      end
      tree.lines.first.should contain(root.basename[-4, 4])
    ensure
      File.delete(file_path) if File.exists?(file_path)
      Dir.delete(root.to_s) if Dir.exists?(root.to_s)
    end
  end

  it "supports Left, Right, and Bottom with one separator and a shared junction" do
    layout = Adamantine::DebugInspectorLayout.new(
      DebugLayoutProbe.new("EDITOR"), DebugLayoutProbe.new("FILES"), DebugLayoutProbe.new("DEBUG")
    )
    rect = Tui::Rect.new(0, 0, 90, 22)
    layout.rect = rect
    # The persisted dock controls Debug only. Files remains the ordinary left
    # sidebar when the activity selection changes.
    layout.debug_dock = Adamantine::DebugInspectorDock::Right
    layout.geometry.dock.should eq(Adamantine::DebugInspectorDock::Left)
    layout.select_section(Adamantine::DebugInspectorSection::Debug).should be_true

    [
      Adamantine::DebugInspectorDock::Left,
      Adamantine::DebugInspectorDock::Right,
    ].each do |dock|
      layout.debug_dock = dock
      geometry = layout.geometry
      geometry.compact?.should be_false
      geometry.inspector.not_nil!.width.should be >= Adamantine::DebugInspectorLayout::MIN_INSPECTOR_WIDTH
      geometry.editor.width.should be >= Adamantine::DebugInspectorLayout::MIN_EDITOR_WIDTH
      geometry.inspector_separator_x.should_not be_nil
      geometry.inspector_separator_y.should be_nil
    end

    layout.debug_dock = Adamantine::DebugInspectorDock::Bottom
    layout.select_section(Adamantine::DebugInspectorSection::Debug).should be_true
    geometry = layout.geometry
    geometry.inspector_separator_x.should be_nil
    geometry.inspector_separator_y.should_not be_nil
    geometry.inspector.not_nil!.y.should be > geometry.editor.y

    buffer = Tui::Buffer.new(rect.width, rect.height)
    layout.render(buffer, rect)
    line_y = geometry.inspector_separator_y.not_nil!
    buffer.get(1, line_y).glyph.should eq('┼'.to_s)
    (2...rect.width).each do |x|
      buffer.get(x, line_y).glyph.should eq('─'.to_s)
    end
  end

  it "keeps Files on the left at compact widths and hides it only when unusable" do
    layout = Adamantine::DebugInspectorLayout.new(
      DebugLayoutProbe.new("EDITOR"), DebugLayoutProbe.new("FILES"), DebugLayoutProbe.new("DEBUG")
    )
    layout.rect = Tui::Rect.new(0, 0, 34, 20)
    geometry = layout.geometry
    geometry.dock.should eq(Adamantine::DebugInspectorDock::Left)
    geometry.effective_dock.should eq(Adamantine::DebugInspectorDock::Left)
    geometry.inspector.not_nil!.width.should eq(11)
    geometry.inspector.not_nil!.x.should eq(2)

    layout.files_panel.focus
    layout.rect = Tui::Rect.new(0, 0, 30, 20)
    geometry = layout.geometry
    geometry.dock.should eq(Adamantine::DebugInspectorDock::Left)
    geometry.effective_dock.should eq(Adamantine::DebugInspectorDock::Left)
    geometry.inspector.should be_nil
    geometry.editor.x.should eq(2)
    layout.files_panel.rect.empty?.should be_true
    layout.files_panel.visible?.should be_true
    Tui::Widget.focused_widget.should_not be(layout.files_panel)
  end

  it "joins a full-height editor-group splitter into the bottom inspector border" do
    groups = Tui::SplitContainer.new(Tui::SplitContainer::Direction::Horizontal, 0.5, "junction-groups")
    groups.show_border = false
    groups.first = DebugLayoutProbe.new("LEFT")
    groups.second = DebugLayoutProbe.new("RIGHT")
    layout = Adamantine::DebugInspectorLayout.new(
      groups, DebugLayoutProbe.new("FILES"), DebugLayoutProbe.new("DEBUG")
    )
    rect = Tui::Rect.new(0, 0, 112, 24)
    layout.rect = rect
    layout.select_section(Adamantine::DebugInspectorSection::Debug).should be_true
    layout.debug_dock = Adamantine::DebugInspectorDock::Bottom

    buffer = Tui::Buffer.new(rect.width, rect.height)
    layout.render(buffer, rect)
    geometry = layout.geometry
    line_y = geometry.inspector_separator_y.not_nil!
    splitter_x = groups.splitter_x

    buffer.get(splitter_x, line_y - 1).glyph.should eq('│'.to_s)
    buffer.get(splitter_x, line_y).glyph.should eq('┴'.to_s)
  end

  it "keeps editor groups and inspector state through selection and relocation without taking editor focus" do
    left_editor = DebugLayoutProbe.new("LEFT")
    right_editor = DebugLayoutProbe.new("RIGHT")
    editor_groups = Tui::SplitContainer.new(Tui::SplitContainer::Direction::Horizontal, 0.5, "editor-groups")
    editor_groups.show_border = false
    editor_groups.first = left_editor
    editor_groups.second = right_editor

    files = DebugLayoutProbe.new("FILES", "expanded file tree")
    debug = DebugLayoutProbe.new("DEBUG", "thread=7; frame=12; expanded=value-3")
    layout = Adamantine::DebugInspectorLayout.new(editor_groups, files, debug)
    layout.rect = Tui::Rect.new(0, 0, 112, 24)
    editor_groups.focus

    layout.select_section(Adamantine::DebugInspectorSection::Debug).should be_true
    layout.debug_dock = Adamantine::DebugInspectorDock::Right
    layout.geometry.inspector.not_nil!.x.should be > layout.geometry.editor.x
    layout.debug_dock = Adamantine::DebugInspectorDock::Bottom

    Tui::Widget.focused_widget.should be(editor_groups)
    editor_groups.first.should be(left_editor)
    editor_groups.second.should be(right_editor)
    files.marker.should eq("expanded file tree")
    debug.marker.should eq("thread=7; frame=12; expanded=value-3")
    debug.visible?.should be_true
    files.visible?.should be_false
  end

  it "collapses a focused Files inspector into the editor and restores it from the rail" do
    editor = DebugLayoutProbe.new("EDITOR")
    files = DebugLayoutProbe.new("FILES", "cursor=4; expanded=src")
    debug = DebugLayoutProbe.new("DEBUG", "thread=7; frame=12")
    layout = Adamantine::DebugInspectorLayout.new(editor, files, debug)
    layout.rect = Tui::Rect.new(0, 0, 112, 24)
    original_editor_width = layout.geometry.editor.width
    files.focus

    layout.hide_files_inspector.should be_true
    layout.geometry.inspector.should be_nil
    layout.geometry.editor.width.should be > original_editor_width
    files.visible?.should be_false
    Tui::Widget.focused_widget.should be(editor)
    files.marker.should eq("cursor=4; expanded=src")

    layout.select_section(Adamantine::DebugInspectorSection::Files).should be_true
    layout.geometry.inspector.should_not be_nil
    files.visible?.should be_true
    files.marker.should eq("cursor=4; expanded=src")
  end

  it "allows mouse and focused-key rail selection without hidden navigation or modal leakage" do
    editor = DebugLayoutProbe.new("EDITOR")
    files = DebugLayoutProbe.new("FILES")
    debug = DebugLayoutProbe.new("DEBUG")
    layout = Adamantine::DebugInspectorLayout.new(editor, files, debug)
    layout.rect = Tui::Rect.new(0, 0, 90, 20)
    layout.render(Tui::Buffer.new(90, 20), Tui::Rect.new(0, 0, 90, 20))
    editor.focus

    layout.handle_event(Tui::MouseEvent.new(0, 13)).should be_false
    layout.selected_section.should eq(Adamantine::DebugInspectorSection::Files)
    (6..10).each do |y|
      layout.handle_event(Tui::MouseEvent.new(0, y)).should be_true
      layout.selected_section.should eq(Adamantine::DebugInspectorSection::Debug)
    end
    layout.selected_section.should eq(Adamantine::DebugInspectorSection::Debug)
    Tui::Widget.focused_widget.should be(editor)
    files.visible?.should be_false
    debug.visible?.should be_true

    layout.handle_event(Tui::MouseEvent.new(0, 2)).should be_true
    layout.selected_section.should eq(Adamantine::DebugInspectorSection::Files)
    (0..4).each do |y|
      layout.handle_event(Tui::MouseEvent.new(0, y)).should be_true
      layout.selected_section.should eq(Adamantine::DebugInspectorSection::Files)
    end
    layout.handle_event(Tui::MouseEvent.new(0, 5)).should be_false
    layout.selected_section.should eq(Adamantine::DebugInspectorSection::Files)
    layout.handle_event(Tui::MouseEvent.new(0, 10)).should be_true
    layout.selected_section.should eq(Adamantine::DebugInspectorSection::Debug)

    layout.on_selection_allowed { false }
    layout.handle_event(Tui::MouseEvent.new(0, 2)).should be_true
    layout.selected_section.should eq(Adamantine::DebugInspectorSection::Debug)
    files.visible?.should be_false
    debug.visible?.should be_true

    layout.activity_rail.focus
    layout.activity_rail.on_event(Tui::KeyEvent.new(Tui::Key::Up)).should be_true
    layout.selected_section.should eq(Adamantine::DebugInspectorSection::Debug)
  end

  it "resizes the active side inspector through its one shared divider" do
    layout = Adamantine::DebugInspectorLayout.new(
      DebugLayoutProbe.new("EDITOR"), DebugLayoutProbe.new("FILES"), DebugLayoutProbe.new("DEBUG")
    )
    rect = Tui::Rect.new(0, 0, 112, 24)
    layout.rect = rect
    layout.geometry.inspector_separator_x.should eq(26)
    layout.handle_event(Tui::MouseEvent.new(26, 3)).should be_true
    layout.handle_event(Tui::MouseEvent.new(32, 3, Tui::MouseButton::Left, Tui::MouseAction::Drag)).should be_true
    layout.handle_event(Tui::MouseEvent.new(32, 3, Tui::MouseButton::Left, Tui::MouseAction::Release)).should be_true
    layout.geometry.inspector.not_nil!.width.should eq(30)

    layout.select_section(Adamantine::DebugInspectorSection::Debug).should be_true
    layout.debug_dock = Adamantine::DebugInspectorDock::Right
    layout.handle_event(Tui::MouseEvent.new(layout.geometry.inspector_separator_x.not_nil!, 3)).should be_true
    layout.handle_event(Tui::MouseEvent.new(70, 3, Tui::MouseButton::Left, Tui::MouseAction::Drag)).should be_true
    layout.handle_event(Tui::MouseEvent.new(70, 3, Tui::MouseButton::Left, Tui::MouseAction::Release)).should be_true
    layout.geometry.inspector.not_nil!.width.should eq(41)
    layout.select_section(Adamantine::DebugInspectorSection::Files).should be_true
    layout.geometry.inspector.not_nil!.width.should eq(30)
  end

  it "uses a marked compact fallback at narrow widths and keeps every rect clipped" do
    layout = Adamantine::DebugInspectorLayout.new(
      DebugLayoutProbe.new("EDITOR"), DebugLayoutProbe.new("FILES"), DebugLayoutProbe.new("DEBUG")
    )
    rect = Tui::Rect.new(0, 0, 24, 5)
    layout.rect = rect
    layout.select_section(Adamantine::DebugInspectorSection::Debug).should be_true
    geometry = layout.geometry
    geometry.compact?.should be_true
    geometry.effective_dock.should eq(Adamantine::DebugInspectorDock::Bottom)
    geometry.inspector.should be_nil
    geometry.editor.height.should eq(rect.height)
    [geometry.rail, geometry.editor].each do |child_rect|
      child_rect.x.should be >= rect.x
      child_rect.y.should be >= rect.y
      child_rect.right.should be <= rect.right
      child_rect.bottom.should be <= rect.bottom
    end

    buffer = Tui::Buffer.new(rect.width, rect.height)
    layout.render(buffer, rect)
    screen = debug_layout_text(buffer, rect)
    screen.lines.all? { |line| line.size == rect.width }.should be_true
    buffer.get(0, 0).glyph.should eq('f'.to_s)
    buffer.get(0, 4).glyph.should eq('D'.to_s)
    buffer.get(0, 4).style.underline?.should be_true
    buffer.get(0, 4).style.bold?.should be_true
    geometry.editor.height.should eq(rect.height)
    geometry.inspector.should be_nil
    layout.debug_panel.rect.empty?.should be_true

    short_layout = Adamantine::DebugInspectorLayout.new(
      DebugLayoutProbe.new("EDITOR"), DebugLayoutProbe.new("FILES"), DebugLayoutProbe.new("DEBUG")
    )
    short_layout.rect = Tui::Rect.new(0, 0, 24, 1)
    short_layout.render(Tui::Buffer.new(24, 1), Tui::Rect.new(0, 0, 24, 1))
    short_layout.handle_event(Tui::MouseEvent.new(0, 0)).should be_true
    short_layout.selected_section.should eq(Adamantine::DebugInspectorSection::Files)
    compact_layout = Adamantine::DebugInspectorLayout.new(
      DebugLayoutProbe.new("EDITOR"), DebugLayoutProbe.new("FILES"), DebugLayoutProbe.new("DEBUG")
    )
    compact_layout.rect = Tui::Rect.new(0, 0, 24, 5)
    compact_layout.handle_event(Tui::MouseEvent.new(0, 0)).should be_true
    compact_layout.selected_section.should eq(Adamantine::DebugInspectorSection::Files)
    compact_layout.handle_event(Tui::MouseEvent.new(0, 2)).should be_false
    compact_layout.handle_event(Tui::MouseEvent.new(0, 4)).should be_true
    compact_layout.selected_section.should eq(Adamantine::DebugInspectorSection::Debug)
  end

  it "preserves the minimum editor height at the 24x9 bottom-dock boundary" do
    layout = Adamantine::DebugInspectorLayout.new(
      DebugLayoutProbe.new("EDITOR"), DebugLayoutProbe.new("FILES"), DebugLayoutProbe.new("DEBUG")
    )
    rect = Tui::Rect.new(0, 0, 24, 9)
    layout.rect = rect
    layout.select_section(Adamantine::DebugInspectorSection::Debug).should be_true

    geometry = layout.geometry
    geometry.effective_dock.should eq(Adamantine::DebugInspectorDock::Bottom)
    geometry.inspector.not_nil!.height.should eq(Adamantine::DebugInspectorLayout::MIN_INSPECTOR_HEIGHT)
    geometry.editor.height.should eq(Adamantine::DebugInspectorLayout::MIN_EDITOR_HEIGHT)
    geometry.inspector_separator_y.should_not be_nil
  end

  it "repairs unusable inspector focus without moving an active modal" do
    editor = DebugLayoutProbe.new("EDITOR")
    files = DebugLayoutProbe.new("FILES")
    debug = DebugLayoutProbe.new("DEBUG")
    layout = Adamantine::DebugInspectorLayout.new(editor, files, debug)
    layout.rect = Tui::Rect.new(0, 0, 90, 20)
    layout.select_section(Adamantine::DebugInspectorSection::Debug).should be_true
    debug.focus

    layout.rect = Tui::Rect.new(0, 0, 90, 1)
    debug.visible?.should be_true
    debug.rect.empty?.should be_true
    Tui::Widget.focused_widget.should be(editor)

    debug.focus
    layout.rect = Tui::Rect.new(0, 0, 90, 0)
    debug.rect.empty?.should be_true
    Tui::Widget.focused_widget.should be(editor)

    modal = DebugLayoutProbe.new("MODAL")
    layout.on_selection_allowed { false }
    modal.focus
    layout.rect = Tui::Rect.new(0, 0, 90, 2)
    Tui::Widget.focused_widget.should be(modal)
  end

  it "clips width and height 0/1/2 rectangles without stale child geometry" do
    [{0, 0}, {1, 1}, {2, 2}, {5, 2}, {2, 5}].each do |dimensions|
      width, height = dimensions
      layout = Adamantine::DebugInspectorLayout.new(
        DebugLayoutProbe.new("EDITOR"), DebugLayoutProbe.new("FILES"), DebugLayoutProbe.new("DEBUG")
      )
      rect = Tui::Rect.new(0, 0, width, height)
      layout.rect = rect
      buffer = Tui::Buffer.new(5, 5)
      layout.render(buffer, rect)
      geometry = layout.geometry
      child_rects = [geometry.rail, geometry.editor]
      child_rects << geometry.inspector.not_nil! if geometry.inspector
      child_rects.each do |child_rect|
        child_rect.x.should be >= rect.x
        child_rect.y.should be >= rect.y
        child_rect.right.should be <= rect.right
        child_rect.bottom.should be <= rect.bottom
      end
    end
  end
end
