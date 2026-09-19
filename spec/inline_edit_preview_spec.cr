require "spec"
require "json"

require "../src/adamantine/safe_document_edits"

private def inline_edit(
  start_line : Int32,
  start_character : Int32,
  end_line : Int32,
  end_character : Int32,
  new_text : String,
) : JSON::Any
  JSON.parse({
    "range" => {
      "start" => {"line" => start_line, "character" => start_character},
      "end"   => {"line" => end_line, "character" => end_character},
    },
    "newText" => new_text,
  }.to_json)
end

private class InlinePreviewEditor < Adamantine::EditingTextEditor
  def bytes_for_test : String
    io = IO::Memory.new
    @buffer.write_to(io)
    io.to_s
  end
end

describe "bounded inline edit preview" do
  it "captures private roots even when constructed from mutable buffers" do
    original = Tui::PieceTreeBuffer.new("old")
    candidate = original.replace_fork
    candidate.replace_range_atomic(0, 3, "new")
    preview = Adamantine::InlineEditPreview::Model.new(original, candidate,
      [Adamantine::InlineEditPreview::EditSpan.new(0, 1, 0, 1)])
    original.replace_range_atomic(0, 3, "mutated source")
    candidate.replace_range_atomic(0, 3, "mutated candidate")
    preview.row_at(0).text.should eq("old")
    preview.row_at(1).text.should eq("new")
  end

  it "makes all directional controls explicit" do
    controls = "\u{61c}\u{200e}\u{200f}\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}\u{2066}\u{2067}\u{2068}\u{2069}"
    editor = InlinePreviewEditor.new("inline-directions")
    editor.load_content_as_saved(controls, Path.new("inline-directions"))
    preview = editor.prepare_document_edits([inline_edit(0, 0, 0, controls.size, "safe")]).inline_preview
    shown = preview.row_at(0).text
    controls.each_char do |char|
      shown.includes?(char).should be_false
      shown.should contain("\\u{#{char.ord.to_s(16)}}")
    end
  end

  it "projects context, numbered removed/added rows, and keeps the live buffer untouched" do
    editor = InlinePreviewEditor.new("inline-preview").tap do |item|
      item.load_content_as_saved("before\nold\nunchanged\nafter\n", Path.new("inline-preview"))
    end

    plan = editor.prepare_document_edits([
      inline_edit(1, 0, 1, 3, "new"),
    ])
    preview = plan.inline_preview("Rename preview")

    rows = (0...preview.row_count).map { |index| preview.row_at(index) }
    rows.any? { |row| row.prefix == ' ' && row.text == "before" }.should be_true
    rows.any? { |row| row.prefix == '-' && row.old_line == 2 && row.text == "old" }.should be_true
    rows.any? { |row| row.prefix == '+' && row.new_line == 2 && row.text == "new" }.should be_true
    rows.any? { |row| row.prefix == ' ' && row.text == "after" }.should be_true
    editor.bytes_for_test.should eq("before\nold\nunchanged\nafter\n")
    editor.can_undo?.should be_false
  end

  it "bounds long line extraction and visibly discloses truncation" do
    long_line = "🙂" * 10_000
    editor = InlinePreviewEditor.new("inline-preview-long").tap do |item|
      item.load_content_as_saved("#{long_line}\n", Path.new("inline-preview-long"))
    end

    preview = editor.prepare_document_edits([
      inline_edit(0, 0, 0, 20_000, "replacement"),
    ]).inline_preview("Format preview")
    removed = (0...preview.row_count).map { |index| preview.row_at(index) }.find { |row| row.prefix == '-' }.not_nil!
    removed.text.should contain("truncated")
    removed.text.bytesize.should be <= Adamantine::InlineEditPreview::MAX_ROW_BYTES
  end

  it "jumps between distant hunks and wraps without visiting a hunk's added row" do
    lines = Array(String).new(12) { |index| "line#{index}" }
    editor = InlinePreviewEditor.new("inline-preview-navigation").tap do |item|
      item.load_content_as_saved(lines.join("\n"), Path.new("inline-preview-navigation"))
    end

    preview = editor.prepare_document_edits([
      inline_edit(1, 0, 1, 5, "ONE"),
      inline_edit(8, 0, 8, 5, "EIGHT"),
    ]).inline_preview("Rename preview")

    first = preview.first_change_row
    preview.top.should eq(first)
    preview.row_at(first).prefix.should eq('-')
    preview.row_at(first + 1).prefix.should eq('+')

    second = preview.next_change
    second.should be > first + 1
    preview.row_at(second).prefix.should eq('-')
    preview.row_at(second + 1).prefix.should eq('+')

    preview.next_change.should eq(first)
    preview.previous_change.should eq(second)
  end

  it "keeps line-ending changes visible even when line text is unchanged" do
    editor = InlinePreviewEditor.new("inline-preview-eol").tap do |item|
      item.load_content_as_saved("alpha\nbeta\n", Path.new("inline-preview-eol"))
    end

    preview = editor.prepare_document_edits([
      inline_edit(0, 5, 1, 0, "\r\n"),
    ]).inline_preview("Format preview")
    rows = (0...preview.row_count).map { |index| preview.row_at(index) }
    removed = rows.find { |row| row.removed? && row.old_line == 1 }.not_nil!
    added = rows.find { |row| row.added? && row.new_line == 1 }.not_nil!
    removed.text.should eq("alpha")
    added.text.should eq("alpha")
    removed.line_ending.should eq("\n")
    added.line_ending.should eq("\r\n")
  end

  it "retains tabs and escapes terminal and bidi controls in bounded rows" do
    original = "a\t\u{1}\u{202e}"
    editor = InlinePreviewEditor.new("inline-preview-controls").tap do |item|
      item.load_content_as_saved(original, Path.new("inline-preview-controls"))
    end

    preview = editor.prepare_document_edits([
      inline_edit(0, 0, 0, 4, "replacement"),
    ]).inline_preview("Format preview")
    removed = (0...preview.row_count).map { |index| preview.row_at(index) }.find { |row| row.removed? }.not_nil!
    removed.text.should contain("\t")
    removed.text.should contain("\\u{1}")
    removed.text.should contain("\\u{202e}")
    removed.text.should_not contain("\u{1}")
    removed.text.should_not contain("\u{202e}")
  end

  it "projects the maximum edit batch without materializing a row array" do
    edit_count = Adamantine::SafeDocumentEdits::MAX_EDITS
    line_count = edit_count * 4 + 2
    lines = Array(String).new(line_count) { |index| "line#{index}" }
    edits = [] of JSON::Any
    edit_count.times do |index|
      line = (index * 4 + 1).to_i32
      edits << inline_edit(line, 0, line, 5, "changed")
    end
    editor = InlinePreviewEditor.new("inline-preview-many").tap do |item|
      item.load_content_as_saved(lines.join("\n"), Path.new("inline-preview-many"))
    end

    preview = editor.prepare_document_edits(edits).inline_preview("Format preview")
    preview.row_count.should eq((line_count + edit_count).to_i32)
    preview.row_at(preview.first_change_row).removed?.should be_true
    preview.finish
    last_change = preview.previous_change
    preview.row_at(last_change).removed?.should be_true
    preview.row_at(last_change + 1).added?.should be_true
  end
end
