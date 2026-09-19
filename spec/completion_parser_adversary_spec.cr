require "spec"
require "../src/adamantine/app"

private class CompletionParserAdversaryClient < Adamantine::Lsp::Client
  def initialize
    super("", Path.new(Dir.current))
  end

  def parse_public(value : JSON::Any)
    parse_completion_items(value)
  end
end

describe "parent malformed completion parser checks" do
  it "rejects malformed standard ranges without numeric coercion or exceptions" do
    client = CompletionParserAdversaryClient.new
    ["null", "true", "1.5", "\"3\"", "[]", "{}", Int64::MAX.to_s].each do |atom|
      ["line", "character"].each do |coordinate|
        ["start", "end"].each do |endpoint|
          raw = JSON.parse(%([{"label":"candidate","textEdit":{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"x"}}]))
          raw[0]["textEdit"]["range"][endpoint].as_h[coordinate] = JSON.parse(atom)
          items = client.parse_public(raw)
          items.size.should eq(1)
          items[0].rejection_reason.should_not be_nil
          items[0].text_edit.should be_nil
        end
      end
    end
  end

  it "keeps top-level scalar results non-executable" do
    client = CompletionParserAdversaryClient.new
    ["null", "true", "42", "\"completion\""].each do |json|
      client.parse_public(JSON.parse(json)).should be_empty
    end
  end

  it "does not retain oversized newText through a malformed-edit compatibility fallback" do
    raw = JSON.parse(%([{"label":"candidate","textEdit":{"newText":""}}]))
    raw[0]["textEdit"].as_h["newText"] = JSON::Any.new("x" * (Adamantine::Lsp::Client::MAX_COMPLETION_INSERTION_BYTES + 1))
    item = CompletionParserAdversaryClient.new.parse_public(raw).first
    item.rejection_reason.should_not be_nil
    item.insert_text.nil?.should be_true
    item.text_edit.should be_nil
  end
end
