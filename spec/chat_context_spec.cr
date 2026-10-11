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
      "revision-1"
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
        "revision-1"
      )
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
      "revision-1"
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
