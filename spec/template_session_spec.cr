require "spec"
require "../src/adamantine/snippet_parser"
require "../src/adamantine/template_session"

private def template_session_parse(source : String) : Adamantine::Snippet::ParseResult
  outcome = Adamantine::Snippet::Parser.parse(source)
  raise "expected snippet parse success, got #{outcome.error}" unless parsed = outcome.result
  parsed
end

private def template_session_insert(
  parsed : Adamantine::Snippet::ParseResult,
  initial_text : String = "",
  insertion_line : Int32 = 0,
  insertion_col : Int32 = 0,
) : Tuple(Tui::TextEditor, Adamantine::TemplateSession)
  editor = Tui::TextEditor.new
  editor.text = initial_text
  editor.set_cursor(insertion_line, insertion_col)
  line = editor.cursor_line
  column = editor.cursor_col
  editor.insert_text(parsed.text)
  {editor, Adamantine::TemplateSession.new(editor, line, column, parsed)}
end

describe "completion template sessions" do
  it "navigates stops by numeric order and moves to the final cursor stop" do
    parsed = template_session_parse("λ${2:βeta}-$1-$0")
    editor, session = template_session_insert(parsed)

    session.active?.should be_true
    session.select_first.should be_true
    editor.cursor_line.should eq(0)
    editor.cursor_col.should eq(6)

    session.next.should be_true
    editor.cursor_col.should eq(5)
    session.previous.should be_true
    editor.cursor_col.should eq(6)
    session.next.should be_true
    editor.cursor_col.should eq(5)
    session.next.should be_true
    editor.cursor_col.should eq(7)
    session.active?.should be_false
    session.next.should be_false
  end

  it "tracks later stops when the selected placeholder is replaced with Unicode text" do
    parsed = template_session_parse("${1:foo}-${2:bar}-$0")
    editor, session = template_session_insert(parsed)
    changes = [] of Tui::TextEditor::TextChange
    editor.on_text_change { |change| changes << change }

    session.select_first.should be_true
    editor.insert_text("🙂x")
    changes.size.should eq(1)
    changes.last.incremental?.should be_true
    session.apply_change(changes.last).should be_true

    session.next.should be_true
    editor.cursor_line.should eq(0)
    editor.cursor_col.should eq(6)
    editor.insert_text("λ")
    session.apply_change(changes.last).should be_true
    session.next.should be_true
    editor.cursor_col.should eq(5)
    session.active?.should be_false
  end

  it "tracks a later stop after insertion inside the current field" do
    parsed = template_session_parse("🙂${1:cat}-$2-$0")
    editor, session = template_session_insert(parsed)
    changes = [] of Tui::TextEditor::TextChange
    editor.on_text_change { |change| changes << change }

    session.select_first.should be_true
    editor.set_cursor(0, 2)
    editor.insert_text("🙂")
    session.apply_change(changes.last).should be_true

    session.next.should be_true
    editor.cursor_col.should eq(6)
  end

  it "tracks later stops across inserted CRLF and Unicode line content" do
    parsed = template_session_parse("${1:cat}-${2:bar}-$0")
    editor, session = template_session_insert(parsed, "head\r\n", 1, 0)
    changes = [] of Tui::TextEditor::TextChange
    editor.on_text_change { |change| changes << change }
    session.select_first.should be_true

    editor.set_cursor(1, 1)
    editor.insert_text("\r\nλ")
    changes.last.text.should eq("\r\nλ")
    session.apply_change(changes.last).should be_true

    session.next.should be_true
    editor.cursor_line.should eq(2)
    editor.cursor_col.should eq(7)
  end

  it "maps tabstop offsets across lines using codepoint columns" do
    parsed = template_session_parse("${1:🙂}\n${2:é}$0")
    editor, session = template_session_insert(parsed, "head\n", 1, 0)

    session.select_first.should be_true
    editor.cursor_line.should eq(1)
    editor.cursor_col.should eq(1)
    session.next.should be_true
    editor.cursor_line.should eq(2)
    editor.cursor_col.should eq(1)
    session.next.should be_true
    editor.cursor_line.should eq(2)
    editor.cursor_col.should eq(1)
    session.active?.should be_false
  end

  it "keeps the session only for edits contained by the active placeholder" do
    parsed = template_session_parse("${1:foo}-${2:bar}-$0")
    editor, session = template_session_insert(parsed)
    changes = [] of Tui::TextEditor::TextChange
    editor.on_text_change { |change| changes << change }
    session.select_first.should be_true

    editor.set_cursor(0, 8)
    editor.insert_text("x")
    session.apply_change(changes.last).should be_false
    session.active?.should be_false
  end

  it "cancels when an edit overlaps the active field boundary or is full-document" do
    parsed = template_session_parse("${1:foo}-${2:bar}-$0")
    editor, session = template_session_insert(parsed)
    changes = [] of Tui::TextEditor::TextChange
    editor.on_text_change { |change| changes << change }
    session.select_first.should be_true

    editor.select_range(0, 2, 0, 5)
    editor.insert_text("x")
    session.apply_change(changes.last).should be_false

    _, full_change_session = template_session_insert(parsed)
    full_change_session.select_first.should be_true
    full_change_session.apply_change(Tui::TextEditor::TextChange.full).should be_false
    full_change_session.active?.should be_false
  end

  it "places the cursor at the final stop for a final-only template" do
    parsed = template_session_parse("finish$0")
    editor, session = template_session_insert(parsed)

    session.select_first.should be_true
    editor.cursor_col.should eq(6)
    session.active?.should be_false
  end

  it "reports whether the cursor remains within the selected placeholder" do
    parsed = template_session_parse("${1:abc}-$0")
    editor, session = template_session_insert(parsed)

    session.select_first.should be_true
    session.contains_cursor?.should be_true
    editor.set_cursor(0, 4)
    session.contains_cursor?.should be_false
  end

  it "rejects more spans than its bounded storage" do
    stops = Array(Adamantine::Snippet::Tabstop).new(65) do |index|
      Adamantine::Snippet::Tabstop.new(index + 1, 0, 0)
    end
    parsed = Adamantine::Snippet::ParseResult.new("", stops, false)
    editor = Tui::TextEditor.new

    expect_raises(ArgumentError) do
      Adamantine::TemplateSession.new(editor, 0, 0, parsed)
    end
  end

  it "cancels rather than overflowing codepoint or line coordinates" do
    parsed = template_session_parse("$1")
    editor = Tui::TextEditor.new
    column_session = Adamantine::TemplateSession.new(editor, 0, Int32::MAX, parsed)
    column_session.select_first.should be_true
    max_column = Tui::TextEditor::TextPosition.new(0, Int32::MAX, Int32::MAX)
    column_change = Tui::TextEditor::TextChange.new(max_column, max_column, "λ")
    column_session.apply_change(column_change).should be_false
    column_session.active?.should be_false

    line_session = Adamantine::TemplateSession.new(editor, Int32::MAX, 0, parsed)
    line_session.select_first.should be_true
    max_line = Tui::TextEditor::TextPosition.new(Int32::MAX, 0, 0)
    line_change = Tui::TextEditor::TextChange.new(max_line, max_line, "\n")
    line_session.apply_change(line_change).should be_false
    line_session.active?.should be_false
  end
end
