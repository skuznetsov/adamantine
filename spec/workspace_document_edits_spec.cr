require "spec"
require "json"

require "../src/adamantine/workspace_document_edits"

private def workspace_edit_json(source : String) : JSON::Any
  JSON.parse(source)
end

private def expect_workspace_rejection(raw : JSON::Any, uri : String = "file:///current.cr", version : Int32 = 7) : Nil
  expect_raises(ArgumentError) do
    Adamantine::WorkspaceDocumentEdits.extract(raw, uri, version)
  end
end

CURRENT_WORKSPACE_URI     = "file:///current.cr"
CURRENT_WORKSPACE_VERSION = 7

describe Adamantine::WorkspaceDocumentEdits do
  it "treats nil, null, and empty envelopes as no edits" do
    Adamantine::WorkspaceDocumentEdits.extract(nil, CURRENT_WORKSPACE_URI, CURRENT_WORKSPACE_VERSION).should be_empty
    Adamantine::WorkspaceDocumentEdits.extract(JSON::Any.new(nil), CURRENT_WORKSPACE_URI, CURRENT_WORKSPACE_VERSION).should be_empty
    Adamantine::WorkspaceDocumentEdits.extract(workspace_edit_json(%({})), CURRENT_WORKSPACE_URI, CURRENT_WORKSPACE_VERSION).should be_empty
  end

  it "extracts current-document changes and preserves plain TextEdit payloads" do
    edit = workspace_edit_json(%({"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"x"}))
    raw = workspace_edit_json({"changes" => {CURRENT_WORKSPACE_URI => [edit]}}.to_json)

    result = Adamantine::WorkspaceDocumentEdits.extract(raw, CURRENT_WORKSPACE_URI, CURRENT_WORKSPACE_VERSION)
    result.size.should eq 1
    result[0].to_json.should eq edit.to_json
  end

  it "extracts one current-document TextDocumentEdit with a matching version" do
    edit = workspace_edit_json(%({"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":2}},"newText":"!"}))
    raw = workspace_edit_json({
      "documentChanges" => [{
        "textDocument" => {"uri" => CURRENT_WORKSPACE_URI, "version" => CURRENT_WORKSPACE_VERSION},
        "edits"        => [edit],
      }],
    }.to_json)

    result = Adamantine::WorkspaceDocumentEdits.extract(raw, CURRENT_WORKSPACE_URI, CURRENT_WORKSPACE_VERSION)
    result.size.should eq 1
    result[0].to_json.should eq edit.to_json
  end

  it "allows an explicit null document version" do
    raw = workspace_edit_json(%({"documentChanges":[{"textDocument":{"uri":"file:///current.cr","version":null},"edits":[]}]}))
    Adamantine::WorkspaceDocumentEdits.extract(raw, CURRENT_WORKSPACE_URI, CURRENT_WORKSPACE_VERSION).should be_empty
  end

  it "rejects both edit forms even when one is empty" do
    raw = workspace_edit_json({
      "changes"         => {CURRENT_WORKSPACE_URI => [] of String},
      "documentChanges" => [] of String,
    }.to_json)
    expect_workspace_rejection(raw)
  end

  it "rejects foreign URIs including empty edit lists" do
    expect_workspace_rejection(workspace_edit_json(%({"changes":{"file:///other.cr":[]}})))
    expect_workspace_rejection(workspace_edit_json(%({"documentChanges":[{"textDocument":{"uri":"file:///other.cr","version":7},"edits":[]}]})))
  end

  it "rejects missing, mismatched, and noninteger document versions" do
    [
      %({"documentChanges":[{"textDocument":{"uri":"file:///current.cr"},"edits":[]}]}),
      %({"documentChanges":[{"textDocument":{"uri":"file:///current.cr","version":8},"edits":[]}]}),
      %({"documentChanges":[{"textDocument":{"uri":"file:///current.cr","version":"7"},"edits":[]}]}),
      %({"documentChanges":[{"textDocument":{"uri":"file:///current.cr","version":7.0},"edits":[]}]}),
    ].each do |source|
      expect_workspace_rejection(workspace_edit_json(source))
    end
  end

  it "rejects duplicate document entries" do
    raw = workspace_edit_json(%({"documentChanges":[
      {"textDocument":{"uri":"file:///current.cr","version":7},"edits":[]},
      {"textDocument":{"uri":"file:///current.cr","version":7},"edits":[]}
    ]}))
    expect_workspace_rejection(raw)
  end

  it "rejects resource operations and unsupported annotation fields" do
    expect_workspace_rejection(workspace_edit_json(%({"documentChanges":[{"kind":"create","uri":"file:///new.cr"}]})))
    expect_workspace_rejection(workspace_edit_json(%({"changes":{},"changeAnnotations":{}})))
    expect_workspace_rejection(workspace_edit_json(%({"documentChanges":[{"textDocument":{"uri":"file:///current.cr","version":7},"edits":[],"annotationId":"a"}]})))
    expect_workspace_rejection(workspace_edit_json(%({"documentChanges":[{"textDocument":{"uri":"file:///current.cr","version":7,"extra":true},"edits":[]}]})))
  end

  it "rejects malformed envelope and document entry shapes" do
    [
      %({"changes":[]}),
      %({"changes":{"file:///current.cr":null}}),
      %({"documentChanges":{}}),
      %({"documentChanges":[null]}),
      %({"documentChanges":[{"textDocument":{},"edits":[]}]}),
      %({"documentChanges":[{"textDocument":{"uri":"file:///current.cr","version":7},"edits":{}}]}),
      %({"unsupported":true}),
    ].each do |source|
      expect_workspace_rejection(workspace_edit_json(source))
    end
  end

  it "rejects an edit batch above the shared SafeDocumentEdits bound" do
    raw_edits = Array.new(Adamantine::SafeDocumentEdits::MAX_EDITS + 1) do
      workspace_edit_json(%({"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":""}))
    end
    raw = workspace_edit_json({"changes" => {CURRENT_WORKSPACE_URI => raw_edits}}.to_json)
    expect_workspace_rejection(raw)
  end
end
