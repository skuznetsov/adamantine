require "spec"
require "json"
require "../src/adamantine/safe_document_edits"

private def oracle_edit(sl : Int32, sc : Int32, el : Int32, ec : Int32, text : String) : JSON::Any
  JSON.parse({"range" => {"start" => {"line" => sl, "character" => sc},
                          "end" => {"line" => el, "character" => ec}},
              "newText" => text}.to_json)
end

private def check_inline_projection(original : String, edits : Array(JSON::Any)) : Nil
  editor = Adamantine::EditingTextEditor.new("inline-oracle")
  editor.load_content_as_saved(original, Path.new("inline-oracle"))
  plan = editor.prepare_document_edits(edits)
  preview = plan.inline_preview("Oracle")
  old_lines = [] of String
  new_lines = [] of String
  old_numbers = [] of Int32
  new_numbers = [] of Int32
  preview.row_count.times do |index|
    row = preview.row_at(index)
    if number = row.old_line
      old_lines << row.text
      old_numbers << number
    end
    if number = row.new_line
      new_lines << row.text
      new_numbers << number
    end
  end
  editor.text.should eq(original)
  editor.can_undo?.should be_false
  editor.apply_document_edits(plan)
  expected_old = original.split(/\r\n|\r|\n/, remove_empty: false)
  expected_new = editor.text.split(/\r\n|\r|\n/, remove_empty: false)
  old_lines.should eq(expected_old)
  new_lines.should eq(expected_new)
  old_numbers.should eq((1..expected_old.size).to_a)
  new_numbers.should eq((1..expected_new.size).to_a)
  if plan.changed?
    editor.undo.should be_true
    editor.text.should eq(original)
  end
end

describe "inline projection independent old/new reconstruction oracle" do
  it "bounds escaped controls and does not expose terminal escape sequences" do
    editor = Adamantine::EditingTextEditor.new("inline-controls-oracle")
    original = "\e" * 4096 + "\n"
    editor.load_content_as_saved(original, Path.new("inline-controls-oracle"))
    preview = editor.prepare_document_edits([oracle_edit(0, 0, 0, 4096, "safe")]).inline_preview("Oracle")
    preview.row_count.times do |index|
      row = preview.row_at(index)
      row.text.bytesize.should be <= Adamantine::InlineEditPreview::MAX_ROW_BYTES
      row.text.includes?('\e').should be_false
    end
    editor.text.should eq(original)
  end

  it "keeps its captured display after live edits but cannot apply the stale proposal" do
    editor = Adamantine::EditingTextEditor.new("inline-stale-oracle")
    editor.load_content_as_saved("old\ncontext\n", Path.new("inline-stale-oracle"))
    plan = editor.prepare_document_edits([oracle_edit(0, 0, 0, 3, "new")])
    preview = plan.inline_preview("Oracle")
    before = (0...preview.row_count).map { |index| preview.row_at(index).text }
    editor.insert_text("live ")
    (0...preview.row_count).map { |index| preview.row_at(index).text }.should eq(before)
    editor.apply_document_edits(plan).should be_false
    editor.text.should eq("live old\ncontext\n")
    editor.undo.should be_true
    editor.text.should eq("old\ncontext\n")
    editor.can_undo?.should be_false
  end

  it "reconstructs both sides across randomized multiline replacements and adjacent edits" do
    random = Random.new(891_017_u64)
    replacements = ["", "Z", "new\nlines", "\n", "界🙂", "x\r\ny\r", "\r", "\n\n"]
    1_000.times do |iteration|
      ending = iteration.even? ? "\n" : "\r\n"
      original = (0...8).map { |line| "line#{line}" }.join(ending)
      start_line = random.rand(0..6)
      end_line = random.rand(start_line..7)
      start_col = random.rand(0..5)
      end_col = random.rand((start_line == end_line ? start_col : 0)..5)
      edits = [oracle_edit(start_line, start_col, end_line, end_col, replacements[random.rand(replacements.size)])]
      # The second edit is on a disjoint earlier line and can change its line
      # count. This checks candidate coordinate shifts without using the
      # projection's own span-building algorithm as an oracle.
      edits << oracle_edit(0, 1, 0, 3, "A\nB") if start_line > 1
      check_inline_projection(original, edits)
    end
  end

  it "handles empty documents, final newlines and CRLF formation at an edit boundary" do
    check_inline_projection("", [oracle_edit(0, 0, 0, 0, "new\n")])
    check_inline_projection("a\n", [oracle_edit(0, 0, 1, 0, "")])
    check_inline_projection("a\rX\nb", [oracle_edit(1, 0, 1, 1, "")])
    check_inline_projection("a\r\nb\n", [oracle_edit(0, 0, 2, 0, "a\nb\n")])
    check_inline_projection("same\n", [oracle_edit(0, 0, 0, 4, "same")])
    check_inline_projection("abc\ndef\nghi", [oracle_edit(0, 1, 0, 2, "X"), oracle_edit(0, 2, 1, 1, "Y")])
  end
end
