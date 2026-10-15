require "spec"
require "../src/adamantine/chat_frontend"
require "../src/adamantine/editing_text_editor"

describe Adamantine::Chat::SubmissionContext do
  it "defaults to no context and keeps its immutable snapshot private" do
    empty = Adamantine::Chat::SubmissionContext.none
    empty.mode.should eq(Adamantine::Chat::ContextMode::None)
    empty.label.should eq("None")
    empty.text.should be_empty
    empty.buffer_id.should be_nil
    empty.revision.should be_nil

    source = "unsaved selection"
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::Selection,
      "Selection · sample.cr",
      source,
      "buffer-1",
      "revision-1",
      source_path: "src/sample.cr",
      source_range: Adamantine::Chat::SourceRange.new(1, 0, 1, source.size)
    )
    source = "changed after construction"
    context.text.should eq("unsaved selection")

    exposed = context.text
    exposed = "changed after read"
    context.text.should eq("unsaved selection")
  end

  it "rejects oversized direct context instead of silently truncating it" do
    expect_raises(ArgumentError) do
      Adamantine::Chat::SubmissionContext.new(
        Adamantine::Chat::ContextMode::ActiveBuffer,
        "Active buffer",
        "x" * (Adamantine::Chat::MAX_CONTEXT_BYTES + 1),
        "buffer-1",
        "revision-1",
        source_path: "src/sample.cr"
      )
    end
  end

  it "keeps BufferTools and BufferProposals source-free" do
    {
      Adamantine::Chat::ContextMode::BufferTools,
      Adamantine::Chat::ContextMode::BufferProposals,
    }.each do |mode|
      expect_raises(ArgumentError) do
        Adamantine::Chat::SubmissionContext.new(
          mode,
          "Selected buffer",
          "embedded source must not be sent",
          "buffer-1",
          "revision-1",
          source_path: "src/sample.cr"
        )
      end

      context = Adamantine::Chat::SubmissionContext.new(
        mode,
        "Selected buffer",
        "",
        "buffer-1",
        "revision-1",
        source_path: "src/sample.cr"
      )
      context.text.should be_empty
    end
  end

  it "freezes a normalized project-relative path and codepoint selection range" do
    range = Adamantine::Chat::SourceRange.new(2, 3, 4, 0)
    range.to_editor_coordinates.should eq({1, 3, 3, 0})
    range.contains_edit?(2, 3, 2, 3).should be_true
    range.contains_edit?(4, 0, 4, 0).should be_true
    range.contains_edit?(2, 3, 3, 2).should be_true
    range.contains_edit?(2, 2, 2, 3).should be_false
    range.contains_edit?(4, 0, 4, 1).should be_false
    range.contains_edit?(4, 1, 4, 1).should be_false
    range.contains_edit?(3, 2, 3, 1).should be_false

    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::Selection,
      "Selection · src/main.cr",
      "selected text",
      "buffer-1",
      "revision-1",
      source_path: "src/main.cr",
      source_range: range
    )
    context.source_path.should eq("src/main.cr")
    context.source_range.should eq(range)
    exposed_path = context.source_path.not_nil!
    exposed_path = "src/changed.cr"
    context.source_path.should eq("src/main.cr")

    request = Adamantine::Chat::Request.new(1_u64, "explain", context)
    request.context.source_path.should eq("src/main.cr")
    request.context.source_range.should eq(range)
    request.context.should eq(context)
  end

  it "requires canonical relative paths for explicit contexts and forbids metadata on None" do
    [
      "/absolute/main.cr",
      "../outside.cr",
      "src/../main.cr",
      "./main.cr",
      "src//main.cr",
      "src/main.cr/",
      "C:/outside.cr",
      "src\\main.cr",
      "src/\u0085main.cr",
      "src/" + ("x" * 4094),
    ].each do |path|
      expect_raises(ArgumentError) do
        Adamantine::Chat::SubmissionContext.new(
          Adamantine::Chat::ContextMode::ActiveBuffer,
          "Active buffer",
          "",
          "buffer-1",
          "revision-1",
          source_path: path
        )
      end
    end

    expect_raises(ArgumentError) do
      Adamantine::Chat::SubmissionContext.new(
        Adamantine::Chat::ContextMode::BufferTools,
        "Buffer tools",
        "",
        "buffer-1",
        "revision-1"
      )
    end
    expect_raises(ArgumentError) do
      Adamantine::Chat::SubmissionContext.new(
        Adamantine::Chat::ContextMode::None,
        "None",
        source_path: "src/main.cr"
      )
    end
  end

  it "fails closed for an unsupported context mode value" do
    expect_raises(ArgumentError) do
      Adamantine::Chat::SubmissionContext.new(
        Adamantine::Chat::ContextMode.new(99),
        "Unknown",
        "",
        "buffer-1",
        "revision-1",
        source_path: "src/main.cr"
      )
    end
  end

  it "distinguishes read-only selection, selection proposals, and whole-file tools" do
    range = Adamantine::Chat::SourceRange.new(1, 0, 1, 5)
    selection = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::Selection,
      "Selection · src/main.cr",
      "hello",
      "buffer-1",
      "revision-1",
      source_path: "src/main.cr",
      source_range: range
    )
    selected_proposals = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::SelectionProposals,
      "Selection proposals · src/main.cr",
      "hello",
      "buffer-1",
      "revision-1",
      source_path: "src/main.cr",
      source_range: range
    )
    whole_file = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferProposals,
      "Whole-file proposals · src/main.cr",
      "",
      "buffer-1",
      "revision-1",
      source_path: "src/main.cr",
      source_range: range
    )

    Adamantine::Chat::ContextMode::BufferTools.tool_context?.should be_true
    Adamantine::Chat::ContextMode::Selection.tool_context?.should be_false
    Adamantine::Chat::ContextMode::SelectionProposals.tool_context?.should be_true
    selection.mode.proposal_context?.should be_false
    selected_proposals.mode.proposal_context?.should be_true
    whole_file.mode.proposal_context?.should be_true
    whole_file.source_range.should eq(range) # informative, not a scope grant

    lua = Adamantine::Chat::LuaScriptGrant.new(
      "script-1", "reviewed", "a" * 64,
      [Adamantine::EditorTools::Capability::ReadEditor, Adamantine::EditorTools::Capability::ProposeEdits]
    )
    permitted = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::SelectionProposals,
      "Selection proposals · src/main.cr",
      "hello",
      "buffer-1",
      "revision-1",
      lua,
      source_path: "src/main.cr",
      source_range: range
    )
    permitted.lua_script_grant.should eq(lua)
  end

  it "rejects empty and reversed source ranges" do
    [
      {1, 0, 1, 0},
      {2, 0, 1, 9},
      {1, 2, 1, 1},
      {0, 0, 1, 0},
      {1, -1, 1, 0},
    ].each do |coordinates|
      expect_raises(ArgumentError) do
        Adamantine::Chat::SourceRange.new(coordinates[0], coordinates[1], coordinates[2], coordinates[3])
      end
    end
  end
end

describe Adamantine::Chat::Request do
  it "keeps the prior visible transcript and explicit context as defensive copies" do
    prior = [
      Adamantine::Chat::Message.new(Adamantine::Chat::Role::User, "earlier question"),
      Adamantine::Chat::Message.new(Adamantine::Chat::Role::Assistant, "earlier answer"),
    ]
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::Selection,
      "Selection · sample.cr",
      "unsaved text",
      "buffer-1",
      "revision-1",
      source_path: "src/sample.cr",
      source_range: Adamantine::Chat::SourceRange.new(1, 0, 1, 11)
    )
    request = Adamantine::Chat::Request.new(7_u64, "current prompt", context, prior)
    prior.clear

    request.context.mode.should eq(Adamantine::Chat::ContextMode::Selection)
    request.context.text.should eq("unsaved text")
    request.history.map(&.text).should eq(["earlier question", "earlier answer"])
    request.history.clear
    request.history.map(&.text).should eq(["earlier question", "earlier answer"])
  end

  it "preserves the original empty-context request constructor" do
    request = Adamantine::Chat::Request.new(8_u64, "legacy local turn")
    request.context.mode.should eq(Adamantine::Chat::ContextMode::None)
    request.history.should be_empty
  end
end

describe Adamantine::EditingTextEditor do
  it "reports an over-limit selection as over-limit instead of as missing" do
    editor = Adamantine::EditingTextEditor.new("chat-selection-byte-count")
    editor.text = "🙂" * (Adamantine::Chat::MAX_CONTEXT_BYTES // 4 + 1)
    editor.select_range(0, 0, 0, Adamantine::Chat::MAX_CONTEXT_BYTES // 4 + 1)

    editor.chat_selection_byte_length(Adamantine::Chat::MAX_CONTEXT_BYTES)
      .should eq(Adamantine::Chat::MAX_CONTEXT_BYTES + 1)
  end

  it "counts a newline that pushes a bounded selection over the cap" do
    editor = Adamantine::EditingTextEditor.new("chat-selection-multiline-byte-count")
    editor.text = "x" * Adamantine::Chat::MAX_CONTEXT_BYTES + "\ny"
    editor.select_range(0, 0, 1, 0)

    editor.chat_selection_byte_length(Adamantine::Chat::MAX_CONTEXT_BYTES)
      .should eq(Adamantine::Chat::MAX_CONTEXT_BYTES + 1)
  end
end
