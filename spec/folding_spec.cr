require "spec"
require "json"
require "crystal_tui"

require "../src/adamantine/folding"

describe Adamantine::Folding do
  it "parses LSP folding ranges" do
    raw = JSON.parse(%([{"startLine":0,"endLine":10},{"startLine":2,"endLine":5,"kind":"region"}]))
    ranges = Adamantine::Folding.parse_ranges(raw)
    raise "expected 2 ranges" unless ranges.size == 2
    raise "wrong start" unless ranges[0].start_line == 0
    raise "wrong end" unless ranges[0].end_line == 10
    raise "nested start" unless ranges[1].start_line == 2
  end

  it "skips invalid ranges" do
    raw = JSON.parse(%([{"startLine":5,"endLine":5},{"startLine":3,"endLine":1},{"endLine":4}]))
    ranges = Adamantine::Folding.parse_ranges(raw)
    raise "invalid ranges should be skipped" unless ranges.empty?
  end

  it "detects foldingRangeProvider" do
    caps = JSON.parse(%({"foldingRangeProvider":true}))
    raise "should be supported" unless Adamantine::Folding.supported?(caps)
    raise "missing provider unsupported" if Adamantine::Folding.supported?(JSON.parse(%({})))
  end

  it "adds else/elsif folds that keep end visible" do
    lines = [
      "def self.root : Path",
      "  if ENV.has_key?(\"JOB_HUNTER_ROOT\")",
      "    Path[ENV[\"JOB_HUNTER_ROOT\"]]",
      "  else",
      "    bin_path = Process.executable_path",
      "    if bin_path",
      "      Path[bin_path].parent",
      "    else",
      "      Path[Dir.current]",
      "    end",
      "  end",
      "end",
    ]
    lsp = [
      Tui::TextEditor::FoldRange.new(0, 11),
      Tui::TextEditor::FoldRange.new(1, 10),
      Tui::TextEditor::FoldRange.new(5, 9),
    ]
    ranges = Adamantine::Folding.merge_crystal_branches(lines, lsp)
    else_outer = ranges.find { |range| range.start_line == 3 }
    else_inner = ranges.find { |range| range.start_line == 7 }
    raise "outer else should fold" unless else_outer
    raise "inner else should fold" unless else_inner
    raise "outer else should hide body, not end" unless else_outer.end_line == 9
    raise "inner else should hide body, not end" unless else_inner.end_line == 8
    raise "if fold should remain" unless ranges.any? { |range| range.start_line == 1 && range.end_line == 10 }
  end

  it "folds elsif/when and ignores commented else" do
    lines = [
      "case x",
      "when 1",
      "  a",
      "  b",
      "when 2",
      "  c",
      "else",
      "  d",
      "end",
      "# else",
    ]
    ranges = Adamantine::Folding.merge_crystal_branches(lines, [] of Tui::TextEditor::FoldRange)
    when1 = ranges.find { |range| range.start_line == 1 }
    when2 = ranges.find { |range| range.start_line == 4 }
    else_branch = ranges.find { |range| range.start_line == 6 }
    raise "when 1 should fold" unless when1 && when1.end_line == 3
    raise "when 2 should fold" unless when2 && when2.end_line == 5
    raise "else should fold" unless else_branch && else_branch.end_line == 7
    raise "commented else should not fold" if ranges.any? { |range| range.start_line == 9 }
  end

  it "folds elsif until the next branch" do
    lines = [
      "if a",
      "  1",
      "elsif b",
      "  2",
      "  3",
      "else",
      "  4",
      "end",
    ]
    ranges = Adamantine::Folding.merge_crystal_branches(lines, [] of Tui::TextEditor::FoldRange)
    elsif_branch = ranges.find { |range| range.start_line == 2 }
    else_branch = ranges.find { |range| range.start_line == 5 }
    raise "elsif should fold" unless elsif_branch && elsif_branch.end_line == 4
    raise "else should fold" unless else_branch && else_branch.end_line == 6
  end
end

describe Tui::TextEditor do
  it "hides inner lines when a fold is collapsed" do
    editor = Tui::TextEditor.new("fold-test")
    editor.text = "module A\n  def x\n    1\n  end\nend\n"
    editor.set_fold_ranges([
      Tui::TextEditor::FoldRange.new(0, 4),
      Tui::TextEditor::FoldRange.new(1, 3),
    ])

    raise "module should show -" unless editor.fold_marker_at(0) == '-'
    raise "def should show -" unless editor.fold_marker_at(1) == '-'

    raise "toggle module should work" unless editor.toggle_fold_at(0)
    raise "module should show +" unless editor.fold_marker_at(0) == '+'
    raise "line 1 should be hidden" unless editor.line_hidden?(1)
    raise "line 4 should be hidden" unless editor.line_hidden?(4)
    raise "header should stay visible" if editor.line_hidden?(0)
    raise "collapsed header should show placeholder" unless editor.fold_placeholder_at(0) == Tui::TextEditor::FOLD_PLACEHOLDER
    raise "expanded inner fold has no placeholder" unless editor.fold_placeholder_at(1).nil?

    raise "expand module should work" unless editor.toggle_fold_at(0)
    raise "placeholder only when collapsed" unless editor.fold_placeholder_at(0).nil?
  end

  it "preserves collapsed state for still-valid fold starts" do
    editor = Tui::TextEditor.new("fold-preserve")
    editor.text = "def a\n  1\nend\n\ndef b\n  2\nend\n"
    editor.set_fold_ranges([
      Tui::TextEditor::FoldRange.new(0, 2),
      Tui::TextEditor::FoldRange.new(4, 6),
    ])
    editor.toggle_fold_at(0)
    editor.set_fold_ranges([
      Tui::TextEditor::FoldRange.new(0, 2),
      Tui::TextEditor::FoldRange.new(4, 6),
    ])
    raise "collapsed fold should remain collapsed" unless editor.fold_marker_at(0) == '+'
    raise "other fold should stay expanded" unless editor.fold_marker_at(4) == '-'
  end

  it "skips hidden lines when moving down" do
    editor = Tui::TextEditor.new("fold-nav")
    editor.text = "def a\n  1\n  2\nend\nnext\n"
    editor.set_fold_ranges([Tui::TextEditor::FoldRange.new(0, 3)])
    editor.toggle_fold_at(0)
    editor.set_cursor(0, 0)
    editor.move_down
    raise "cursor should jump to first visible after fold" unless editor.cursor_line == 4
  end

  it "expands when clicking the {...} placeholder" do
    editor = Tui::TextEditor.new("fold-placeholder-click")
    editor.text = "def a\n  1\nend\n"
    editor.set_fold_ranges([Tui::TextEditor::FoldRange.new(0, 2)])
    editor.toggle_fold_at(0)

    header_len = editor.lines[0].size
    raise "miss before placeholder" if editor.expand_fold_at_placeholder?(0, header_len - 1)
    raise "miss past placeholder" if editor.expand_fold_at_placeholder?(0, header_len + Tui::TextEditor::FOLD_PLACEHOLDER.size)
    raise "still collapsed after misses" unless editor.fold_marker_at(0) == '+'
    raise "hit on {...} should expand" unless editor.expand_fold_at_placeholder?(0, header_len + 1)
    raise "should be expanded" unless editor.fold_marker_at(0) == '-'
    raise "placeholder gone" unless editor.fold_placeholder_at(0).nil?
  end
end
