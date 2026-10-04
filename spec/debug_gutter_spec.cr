require "spec"

require "../src/adamantine/editing_text_editor"

describe "debug editor gutter lanes" do
  it "keeps breakpoint and execution markers independent of line-number and fold gutters" do
    editor = Adamantine::EditingTextEditor.new("debug-gutter-lanes")
    editor.load_content_as_saved("alpha\nbeta", Path.new("debug-gutter-lanes.cr"))
    editor.show_line_numbers = false
    editor.show_fold_gutter = false
    editor.show_scrollbar = false
    editor.debug_breakpoint_lines = Set{0, 1}
    editor.debug_execution_line = 1
    editor.rect = Tui::Rect.new(0, 0, 12, 2)

    buffer = Tui::Buffer.new(12, 2)
    clip = Tui::Rect.new(0, 0, 12, 2)
    editor.render(buffer, clip)

    buffer.get(0, 0).glyph.should eq("●")
    buffer.get(1, 0).glyph.should eq(" ")
    buffer.get(2, 0).glyph.should eq("a")
    buffer.get(0, 1).glyph.should eq("●")
    buffer.get(1, 1).glyph.should eq("▶")
    buffer.get(1, 1).style.fg.should eq(Tui::Color.yellow)
    buffer.get(2, 1).glyph.should eq("b")
  end

  it "co-displays Git change markers beside debug lanes when numbering is on" do
    editor = Adamantine::EditingTextEditor.new("debug-git-gutter-lanes")
    editor.load_content_as_saved("alpha\nbeta", Path.new("debug-git-gutter-lanes.cr"))
    editor.show_line_numbers = true
    editor.show_fold_gutter = false
    editor.show_scrollbar = false
    editor.debug_breakpoint_lines = Set{0}
    editor.debug_execution_line = 0
    editor.line_change_markers = {1 => '+'}
    editor.rect = Tui::Rect.new(0, 0, 12, 2)

    buffer = Tui::Buffer.new(12, 2)
    editor.render(buffer, Tui::Rect.new(0, 0, 12, 2))

    buffer.get(0, 0).glyph.should eq("●")
    buffer.get(1, 0).glyph.should eq("▶")
    buffer.get(2, 0).glyph.should eq("1")
    buffer.get(3, 0).glyph.should eq("+")
    buffer.get(4, 0).glyph.should eq("a")
  end

  it "uses a muted hollow marker for inactive or unverified breakpoints" do
    editor = Adamantine::EditingTextEditor.new("debug-gutter-breakpoint-status")
    editor.load_content_as_saved("verified\npending\noutdated", Path.new("debug-gutter-breakpoint-status.cr"))
    editor.show_line_numbers = false
    editor.show_fold_gutter = false
    editor.show_scrollbar = false
    editor.debug_breakpoint_lines = Set{0}
    editor.debug_inactive_breakpoint_lines = Set{1, 2}
    editor.rect = Tui::Rect.new(0, 0, 12, 3)

    buffer = Tui::Buffer.new(12, 3)
    editor.render(buffer, Tui::Rect.new(0, 0, 12, 3))

    buffer.get(0, 0).glyph.should eq("●")
    buffer.get(0, 1).glyph.should eq("o")
    buffer.get(0, 2).glyph.should eq("o")
    buffer.get(0, 1).style.fg.should eq(Tui::Color.palette(8))
  end

  it "keeps a selected historical frame distinct from the stopped execution arrow" do
    editor = Adamantine::EditingTextEditor.new("debug-history-gutter")
    editor.load_content_as_saved("stopped\ncaller", Path.new("debug-history-gutter.cr"))
    editor.show_line_numbers = false
    editor.show_fold_gutter = false
    editor.show_scrollbar = false
    editor.debug_gutter_enabled = true
    editor.debug_execution_line = 0
    editor.debug_inspection_line = 1
    editor.rect = Tui::Rect.new(0, 0, 12, 2)

    buffer = Tui::Buffer.new(12, 2)
    editor.render(buffer, Tui::Rect.new(0, 0, 12, 2))

    buffer.get(1, 0).glyph.should eq("▶")
    buffer.get(1, 1).glyph.should eq("◇")
    buffer.get(1, 0).style.fg.should eq(Tui::Color.yellow)
    buffer.get(1, 1).style.fg.should eq(Tui::Color.cyan)
    buffer.get(2, 0).glyph.should eq("s")
    buffer.get(2, 1).glyph.should eq("c")

    editor.debug_inactive_breakpoint_lines = Set{0, 1}
    inactive_buffer = Tui::Buffer.new(12, 2)
    editor.render(inactive_buffer, Tui::Rect.new(0, 0, 12, 2))
    inactive_buffer.get(1, 0).style.fg.should eq(Tui::Color.yellow)
    inactive_buffer.get(1, 1).style.fg.should eq(Tui::Color.cyan)

    editor.debug_breakpoint_lines = Set{0, 1}
    active_buffer = Tui::Buffer.new(12, 2)
    editor.render(active_buffer, Tui::Rect.new(0, 0, 12, 2))
    active_buffer.get(1, 0).style.fg.should eq(Tui::Color.yellow)
    active_buffer.get(1, 1).style.fg.should eq(Tui::Color.cyan)
  end

  it "retains the fold hit lane and sends breakpoint-lane clicks to its callback" do
    editor = Adamantine::EditingTextEditor.new("debug-gutter-hit")
    editor.load_content_as_saved("head\nbody\nend", Path.new("debug-gutter-hit.cr"))
    editor.show_line_numbers = false
    editor.show_fold_gutter = true
    editor.show_scrollbar = false
    editor.debug_gutter_enabled = true
    editor.set_fold_ranges([Tui::TextEditor::FoldRange.new(0, 2)])
    editor.rect = Tui::Rect.new(0, 0, 12, 3)
    toggled_line : Int32? = nil
    editor.on_debug_breakpoint_toggle { |line| toggled_line = line }

    editor.on_event(Tui::MouseEvent.new(1, 0)).should be_true
    toggled_line.should eq(0)
    editor.on_event(Tui::MouseEvent.new(0, 0)).should be_true
    editor.fold_marker_at(0).should eq('+')
  end

  it "never paints any gutter lane outside a narrow widget when the clip is wider" do
    {1, 2}.each do |width|
      editor = Adamantine::EditingTextEditor.new("debug-gutter-narrow-#{width}")
      editor.load_content_as_saved("x", Path.new("debug-gutter-narrow-#{width}.cr"))
      editor.show_line_numbers = true
      editor.show_fold_gutter = true
      editor.show_scrollbar = false
      editor.debug_gutter_enabled = true
      editor.debug_breakpoint_lines = Set{0}
      editor.debug_execution_line = 0
      editor.set_fold_ranges([Tui::TextEditor::FoldRange.new(0, 0)])
      editor.rect = Tui::Rect.new(1, 0, width, 1)

      buffer = Tui::Buffer.new(8, 1)
      buffer.set(0, 0, "L", Tui::Style.new)
      buffer.set(1 + width, 0, "R", Tui::Style.new)
      editor.render(buffer, Tui::Rect.new(0, 0, 8, 1))

      buffer.get(0, 0).glyph.should eq("L")
      buffer.get(1 + width, 0).glyph.should eq("R")
    end
  end
end
