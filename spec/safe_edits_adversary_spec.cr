require "spec"
require "json"
require "../src/adamantine/safe_document_edits"

private def adversary_edit(start_col : Int32, end_col : Int32, text : String) : JSON::Any
  JSON.parse({range: {start: {line: 0, character: start_col}, end: {line: 0, character: end_col}}, newText: text}.to_json)
end

private class SafeEditsOracleEditor < Adamantine::EditingTextEditor
  def raw_bytes : String
    output = IO::Memory.new
    @buffer.write_to(output)
    output.to_s
  end
end

private class SafeEditsNoMaterializer < SafeEditsOracleEditor
  def text : String
    raise "whole-document text getter used"
  end

  def lines : Array(String)
    raise "whole-document lines getter used"
  end
end

describe "parent safe-edit counterexamples" do
  it "matches a separate string oracle for shuffled Unicode ranges and one Undo" do
    random = Random.new(917)
    80.times do |iteration|
      chars = Array(Char).new(40) { ['a', 'b', '界', '🙂', 'é'][random.rand(5)] }
      original = chars.join
      first_start = random.rand(0..5)
      first_end = random.rand(6..12)
      second_start = random.rand(17..22)
      second_end = random.rand(24..35)
      first_text = ["hello", "🙂", "", "\r\n"][random.rand(4)]
      second_text = ["界", "bye", "", "\n"][random.rand(4)]
      units = ->(index : Int32) { chars.first(index).sum { |char| char.ord > 0xffff ? 2 : 1 } }
      edits = [adversary_edit(units.call(first_start), units.call(first_end), first_text),
               adversary_edit(units.call(second_start), units.call(second_end), second_text)]
      edits.reverse! if iteration.odd?
      expected = chars.first(first_start).join + first_text + chars[first_end...second_start].join + second_text + chars[second_end..].join
      editor = SafeEditsOracleEditor.new("oracle")
      editor.load_content_as_saved(original, Path.new("oracle.cr"))
      editor.apply_document_edits(editor.prepare_document_edits(edits)).should be_true
      editor.raw_bytes.should eq(expected)
      editor.undo.should be_true
      editor.raw_bytes.should eq(original)
      editor.can_undo?.should be_false
      editor.redo.should be_true
      editor.raw_bytes.should eq(expected)
    end
  end

  it "rejects a valid early edit followed by a surrogate-splitting edit" do
    editor = SafeEditsOracleEditor.new("late-invalid")
    editor.load_content_as_saved("a🙂b", Path.new("late.cr"))
    expect_raises(ArgumentError) do
      editor.prepare_document_edits([adversary_edit(0, 1, "A"), adversary_edit(2, 3, "X")])
    end
    editor.raw_bytes.should eq("a🙂b")
    editor.can_undo?.should be_false
  end

  it "does not let a preview caller change the candidate by editing returned rows" do
    editor = SafeEditsOracleEditor.new("opaque")
    editor.load_content_as_saved("abc", Path.new("opaque.cr"))
    plan = editor.prepare_document_edits([adversary_edit(0, 3, "safe")])
    plan.preview_lines.clear
    plan.preview_lines.empty?.should be_false
    editor.apply_document_edits(plan).should be_true
    editor.raw_bytes.should eq("safe")
    editor.undo
    editor.apply_document_edits(plan).should be_false
    editor.raw_bytes.should eq("abc")
  end

  it "edits the tail of a multi-megabyte Unicode line without compatibility materializers" do
    source = "🙂" * 600_000 + "tail"
    editor = SafeEditsNoMaterializer.new("large-oracle")
    editor.load_content_as_saved(source, Path.new("large.cr"))
    plan = editor.prepare_document_edits([adversary_edit(1_200_000, 1_200_004, "END")])
    editor.apply_document_edits(plan).should be_true
    editor.raw_bytes.should eq("🙂" * 600_000 + "END")
    editor.undo.should be_true
    editor.raw_bytes.should eq(source)
  end
end
