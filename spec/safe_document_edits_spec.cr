require "spec"
require "json"

require "../src/adamantine/safe_document_edits"

private def lsp_edit(
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

private class SafeEditsInspectableEditor < Adamantine::EditingTextEditor
  def text : String
    raise "safe document edits must not materialize the document through text"
  end

  def bytes_for_test : String
    io = IO::Memory.new
    @buffer.write_to(io)
    io.to_s
  end

  def preview_line_limit_for_test : Int32
    Adamantine::SafeDocumentEdits::MAX_PREVIEW_LINES
  end

  def preview_string_limit_for_test : Int32
    Adamantine::SafeDocumentEdits::MAX_PREVIEW_STRING_BYTES
  end
end

describe "safe one-document LSP text edits" do
  it "applies mixed UTF-16 edits atomically and restores exact bytes with undo/redo" do
    editor = SafeEditsInspectableEditor.new("safe-edits").tap do |item|
      item.load_content_as_saved("a🙂\r\nb\nc\r", Path.new("safe-edits"))
    end

    edits = [
      lsp_edit(0, 1, 0, 3, "X"),
      lsp_edit(1, 0, 1, 1, "B"),
      lsp_edit(2, 1, 2, 1, "界"),
    ]
    original = editor.bytes_for_test
    plan = editor.prepare_document_edits(edits)

    plan.change_count.should eq 3
    plan.changed?.should be_true
    plan.preview_lines.empty?.should be_false
    editor.bytes_for_test.should eq original

    editor.apply_document_edits(plan).should be_true
    editor.bytes_for_test.should eq "aX\r\nB\nc界\r"
    editor.can_undo?.should be_true
    editor.undo.should be_true
    editor.bytes_for_test.should eq original
    editor.redo.should be_true
    editor.bytes_for_test.should eq "aX\r\nB\nc界\r"
  end

  it "rejects strict UTF-16, unsupported fields, overlap, and late malformed edits before mutation" do
    editor = SafeEditsInspectableEditor.new("safe-invalid").tap do |item|
      item.load_content_as_saved("a🙂\r\nb", Path.new("safe-invalid"))
    end
    original = editor.bytes_for_test

    expect_raises(ArgumentError, /surrogate/) do
      editor.prepare_document_edits([lsp_edit(0, 2, 0, 2, "x")])
    end
    expect_raises(ArgumentError) do
      editor.prepare_document_edits([lsp_edit(0, 0, 9, 0, "x")])
    end
    unsupported = JSON.parse(%({"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"x","annotationId":"a"}))
    expect_raises(ArgumentError, /unsupported/) do
      editor.prepare_document_edits([unsupported])
    end
    overlap = [
      lsp_edit(1, 0, 1, 1, "x"),
      lsp_edit(1, 0, 1, 1, "y"),
    ]
    expect_raises(ArgumentError, /overlap/) { editor.prepare_document_edits(overlap) }
    same_position = [
      lsp_edit(1, 0, 1, 0, "x"),
      lsp_edit(1, 0, 1, 0, "y"),
    ]
    expect_raises(ArgumentError, /position/) { editor.prepare_document_edits(same_position) }

    late_bad = [
      lsp_edit(0, 0, 0, 1, "A"),
      JSON.parse(%({"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}},"newText":17})),
    ]
    expect_raises(ArgumentError) { editor.prepare_document_edits(late_bad) }
    editor.bytes_for_test.should eq original
    editor.can_undo?.should be_false
  end

  it "rejects stale and foreign plans, while no-op plans do not create history" do
    editor = SafeEditsInspectableEditor.new("safe-stale").tap do |item|
      item.load_content_as_saved("abc", Path.new("safe-stale"))
    end
    no_op = editor.prepare_document_edits([lsp_edit(0, 1, 0, 2, "b")])
    no_op.changed?.should be_false
    editor.apply_document_edits(no_op).should be_false
    editor.can_undo?.should be_false

    plan = editor.prepare_document_edits([lsp_edit(0, 0, 0, 1, "A")])
    editor.insert_text("!")
    editor.apply_document_edits(plan).should be_false
    editor.bytes_for_test.should eq "!abc"

    other = SafeEditsInspectableEditor.new("other").tap do |item|
      item.load_content_as_saved("abc", Path.new("other"))
    end
    foreign_plan = other.prepare_document_edits([lsp_edit(0, 0, 0, 1, "O")])
    editor.apply_document_edits(foreign_plan).should be_false
    editor.bytes_for_test.should eq "!abc"
  end

  it "bounds edit batches, output growth, and visibly truncates previews" do
    editor = SafeEditsInspectableEditor.new("safe-limits").tap do |item|
      item.load_content_as_saved("x", Path.new("safe-limits"))
    end
    too_many = Array.new(Adamantine::SafeDocumentEdits::MAX_EDITS + 1) do
      lsp_edit(0, 0, 0, 0, "")
    end
    expect_raises(ArgumentError, /count/) { editor.prepare_document_edits(too_many) }

    too_large = "x" * (Adamantine::SafeDocumentEdits::MAX_REPLACEMENT_BYTES + 1)
    expect_raises(ArgumentError, /replacement/) do
      editor.prepare_document_edits([lsp_edit(0, 0, 0, 0, too_large)])
    end

    preview_text = "y" * (Adamantine::SafeDocumentEdits::MAX_PREVIEW_STRING_BYTES * 2)
    plan = editor.prepare_document_edits([lsp_edit(0, 0, 0, 1, preview_text)])
    plan.changed?.should be_true
    plan.preview_lines.size.should be <= editor.preview_line_limit_for_test
    plan.preview_lines.any?(&.includes?("truncated")).should be_true
    plan.preview_lines.size.should eq 3
    plan.preview_lines[0].should contain("@ 0:0..0:1")
    plan.preview_lines.each do |line|
      line.bytesize.should be <= Adamantine::SafeDocumentEdits::MAX_PREVIEW_LINE_BYTES
    end

    long_unicode = "🙂a" * 20_000
    unicode_editor = SafeEditsInspectableEditor.new("safe-limits-unicode").tap do |item|
      item.load_content_as_saved(long_unicode, Path.new("safe-limits-unicode"))
    end
    unicode_plan = unicode_editor.prepare_document_edits([lsp_edit(0, 0, 0, 60_000, long_unicode)])
    unicode_plan.changed?.should be_false
    unicode_editor.apply_document_edits(unicode_plan).should be_false
    unicode_editor.can_undo?.should be_false
  end

  it "does not use the whole-document text getter" do
    editor = SafeEditsInspectableEditor.new("safe-no-getter").tap do |item|
      item.load_content_as_saved("before\r\nafter", Path.new("safe-no-getter"))
    end
    plan = editor.prepare_document_edits([lsp_edit(0, 0, 0, 6, "changed")])
    editor.apply_document_edits(plan).should be_true
    editor.bytes_for_test.should eq "changed\r\nafter"
  end
end
