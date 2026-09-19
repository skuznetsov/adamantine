require "spec"
require "json"
require "../src/adamantine/workspace_document_edits"
require "../src/adamantine/safe_document_edits"

private class RefactorOracleEditor < Adamantine::EditingTextEditor
  def raw_bytes : String
    output = IO::Memory.new
    @buffer.write_to(output)
    output.to_s
  end
end

private def adversary_refactor_edit(first : Int32, last : Int32, replacement : String) : JSON::Any
  JSON.parse({"range" => {"start" => {"line" => 0, "character" => first},
                          "end" => {"line" => 0, "character" => last}},
              "newText" => replacement}.to_json)
end

describe "Refactoring envelope parent counterexamples" do
  it "keeps original-snapshot Unicode coordinates and one Undo through both envelope variants" do
    uri = "file:///tmp/renamable%20document.cr"
    32.times do |index|
      original = "😀alpha + alpha\r\n"
      name = index.even? ? "🌿name#{index}" : "beta#{index}"
      edits = [adversary_refactor_edit(2, 7, name), adversary_refactor_edit(10, 15, name)]
      raw = if index.even?
              JSON.parse({"changes" => {uri => edits}}.to_json)
            else
              JSON.parse({"documentChanges" => [{"textDocument" => {"uri" => uri, "version" => index}, "edits" => edits}]}.to_json)
            end
      editor = RefactorOracleEditor.new("refactor-oracle")
      editor.load_content_as_saved(original, Path.new("oracle.cr"))
      accepted = Adamantine::WorkspaceDocumentEdits.extract(raw, uri, index)
      editor.apply_document_edits(editor.prepare_document_edits(accepted)).should be_true
      editor.raw_bytes.should eq("😀#{name} + #{name}\r\n")
      editor.undo.should be_true
      editor.raw_bytes.should eq(original)
      editor.can_undo?.should be_false
      editor.redo.should be_true
      editor.raw_bytes.should eq("😀#{name} + #{name}\r\n")
    end
  end

  it "does not reinterpret foreign URI aliases as permission to modify the captured document" do
    uri = "file:///tmp/current.cr"
    edit = adversary_refactor_edit(0, 1, "new")
    ["file:///tmp/./current.cr", "file:///tmp/CURRENT.cr", "untitled:current.cr",
     "file:///tmp/other.cr", "file:///tmp/current.cr#fragment"].each do |foreign|
      [
        JSON.parse({"changes" => {uri => [edit], foreign => [] of JSON::Any}}.to_json),
        JSON.parse({"documentChanges" => [
          {"textDocument" => {"uri" => uri, "version" => 7}, "edits" => [edit]},
          {"textDocument" => {"uri" => foreign, "version" => 7}, "edits" => [] of JSON::Any},
        ]}.to_json),
      ].each do |raw|
        expect_raises(ArgumentError) { Adamantine::WorkspaceDocumentEdits.extract(raw, uri, 7) }
      end
    end
  end
end
