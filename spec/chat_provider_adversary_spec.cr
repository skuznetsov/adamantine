require "spec"
require "file_utils"
require "random/secure"
require "json"
require "../src/adamantine/app"
require "../src/adamantine/chat_frontend"

private class ChatProviderAdversaryHandle < Adamantine::Chat::Handle
  getter cancelled : Bool
  getter tool_results : Array({String, String})

  def initialize
    @cancelled = false
    @tool_results = [] of {String, String}
  end

  def cancel : Nil
    @cancelled = true
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    @tool_results << {call_id, result_json}
  end
end

private class ChatProviderAdversaryTransport < Adamantine::Chat::Transport
  getter requests : Array(Adamantine::Chat::Request)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))
  getter handles : Array(ChatProviderAdversaryHandle)

  def initialize
    @requests = [] of Adamantine::Chat::Request
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
    @handles = [] of ChatProviderAdversaryHandle
  end

  def available? : Bool
    true
  end

  def external? : Bool
    true
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    @requests << request
    @callbacks << on_event
    handle = ChatProviderAdversaryHandle.new
    @handles << handle
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private class ChatProviderAdversaryBackend < Adamantine::EditorTools::Backend
  getter calls : Array(Adamantine::EditorTools::Request)

  def initialize
    @calls = [] of Adamantine::EditorTools::Request
  end

  def context : Adamantine::EditorTools::Context
    Adamantine::EditorTools::Context.new("/project", "chat-provider-adversary")
  end

  def execute(request : Adamantine::EditorTools::Request,
              permit : Adamantine::EditorTools::ExecutionPermit) : JSON::Any
    @calls << request
    JSON.parse({"executed" => request.is_a?(Adamantine::EditorTools::ReadBufferRequest)}.to_json)
  end
end

private def adversary_read_buffer_call(
  id : String,
  buffer_id : String,
  revision : String,
  name : String = "editor.read_buffer",
) : String
  {
    "id"        => id,
    "name"      => name,
    "arguments" => {"buffer_id" => buffer_id, "revision" => revision},
  }.to_json
end

private def adversary_tool_call(id : String, name : String,
                                arguments : Hash(String, JSON::Any) = {} of String => JSON::Any) : String
  {"id" => id, "name" => name, "arguments" => arguments}.to_json
end

private class ChatProviderAdversaryApp < Adamantine::App
  def layout_public(width : Int32 = 100, height : Int32 = 30) : Nil
    mount_headless(width, height)
    render(Tui::Buffer.new(width, height), Tui::Rect.new(0, 0, width, height))
  end

  def resize_public(width : Int32, height : Int32) : Nil
    rect = Tui::Rect.new(0, 0, width, height)
    self.rect = rect
    refresh
    render(Tui::Buffer.new(width, height), rect)
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def buffer_public(path : Path) : Adamantine::OpenBuffer
    @document_session.open_buffers[path.to_s]? || raise "missing open buffer: #{path}"
  end

  def choose_chat_context_public(index : Int32) : Nil
    raise "Chat context action was not handled" unless chat_context_action
    index.times do
      raise "Chat context navigation was not handled" unless on_capture(Tui::KeyEvent.new(Tui::Key::Down))
    end
    raise "Chat context selection was not handled" unless on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def chat_context_mode_public : Adamantine::Chat::ContextMode
    @chat_context_mode
  end

  def chat_review_active_public? : Bool
    chat_review_active?
  end
end

private def with_chat_provider_adversary_app(
  transport : Adamantine::Chat::Transport = Adamantine::Chat::UnavailableTransport.new,
  &
)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(Dir.tempdir, "adamantine-chat-provider-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  app = ChatProviderAdversaryApp.new(
    project_root: root,
    lsp_command: "",
    session_enabled: false,
    recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    chat_transport: transport
  )
  yield app, root
ensure
  app.try &.quit(force: true)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

describe "chat provider disclosure and approval adversaries" do
  it "approves only the exact captured prompt, history, context, and revisions" do
    captured_context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::Selection,
      "Selection · main.cr",
      "selected source",
      "buffer-17",
      "revision-4"
    )
    captured_history = [
      Adamantine::Chat::Message.new(Adamantine::Chat::Role::User, "earlier question"),
      Adamantine::Chat::Message.new(Adamantine::Chat::Role::Assistant, "earlier answer"),
    ]
    captured = Adamantine::Chat::Request.new(
      23_u64,
      "explain this selection",
      captured_context,
      captured_history
    )
    review = Adamantine::Chat::SubmissionReview.new(captured, 9_u64, "/project-a", 31_u64)

    review.matches?(captured, 9_u64, "/project-a", 31_u64).should be_true

    altered_requests = [
      Adamantine::Chat::Request.new(23_u64, "send a different prompt", captured_context, captured_history),
      Adamantine::Chat::Request.new(23_u64, "explain this selection", Adamantine::Chat::SubmissionContext.none, captured_history),
      Adamantine::Chat::Request.new(23_u64, "explain this selection", captured_context, [
        Adamantine::Chat::Message.new(Adamantine::Chat::Role::User, "different prior turn"),
      ]),
    ]

    altered_requests.each do |altered|
      review.matches?(altered, 9_u64, "/project-a", 31_u64).should be_false
    end
    review.matches?(captured, 10_u64, "/project-a", 31_u64).should be_false
    review.matches?(captured, 9_u64, "/project-b", 31_u64).should be_false
    review.matches?(captured, 9_u64, "/project-a", 32_u64).should be_false
  end

  it "allows an explicitly selected zero-byte active buffer" do
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::ActiveBuffer,
      "Active buffer · empty.cr",
      "",
      "buffer-empty",
      "revision-1"
    )

    context.mode.should eq(Adamantine::Chat::ContextMode::ActiveBuffer)
    context.text.should be_empty
    context.buffer_id.should eq("buffer-empty")
    context.revision.should eq("revision-1")
  end

  it "invalidates a frozen buffer revision after edit then undo restores identical text" do
    with_chat_provider_adversary_app do |app, root|
      path = root / "aba.cr"
      File.write(path, "same text\n")
      app.open_file_public(path).should be_true
      buffer = app.buffer_public(path)
      reference = Adamantine::EditorToolsController::BufferReference.new(buffer)
      captured_revision = reference.revision

      buffer.editor.insert_text("temporary edit")
      buffer.editor.undo.should be_true
      buffer.editor.document.buffer.text.should eq("same text\n")

      reference.refresh_revision!
      reference.revision.should_not eq(captured_revision)
    end
  end

  it "admits only editor.read_buffer for the exact selected buffer and revision" do
    transport = ChatProviderAdversaryTransport.new
    backend = ChatProviderAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    factory_contexts = [] of Adamantine::Chat::SubmissionContext
    factory : Adamantine::Chat::Frontend::ContextSessionFactory = ->(context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      factory_contexts << context
      host.open_session(
        Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor]
      )
    }
    frontend = Adamantine::Chat::Frontend.new(transport, context_session_factory: factory)
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferTools,
      "Selected buffer tools · main.cr",
      "",
      "buffer-17",
      "revision-4"
    )
    frontend.set_draft("read only this buffer")
    frontend.submit(context).should be_true
    factory_contexts.should eq([context])

    list_args = {} of String => JSON::Any
    find_args = {"query" => JSON::Any.new(".")} of String => JSON::Any
    open_args = {"path" => JSON::Any.new("secret.cr")} of String => JSON::Any
    transport.emit(0, Adamantine::Chat::Event.tool_request("list", adversary_tool_call("list", "editor.list_buffers", list_args)))
    transport.emit(0, Adamantine::Chat::Event.tool_request("find", adversary_tool_call("find", "editor.find_files", find_args)))
    transport.emit(0, Adamantine::Chat::Event.tool_request("open", adversary_tool_call("open", "editor.open_file", open_args)))
    transport.emit(0, Adamantine::Chat::Event.tool_request("wrong-buffer", adversary_read_buffer_call("wrong-buffer", "buffer-18", "revision-4")))
    transport.emit(0, Adamantine::Chat::Event.tool_request("wrong-revision", adversary_read_buffer_call("wrong-revision", "buffer-17", "revision-5")))
    transport.emit(0, Adamantine::Chat::Event.tool_request("event-id", adversary_read_buffer_call("payload-id", "buffer-17", "revision-4")))
    transport.emit(0, Adamantine::Chat::Event.tool_request("allowed", adversary_read_buffer_call("allowed", "buffer-17", "revision-4")))
    frontend.drain

    backend.calls.size.should eq(1)
    backend.calls.first.should be_a(Adamantine::EditorTools::ReadBufferRequest)
    results = transport.handles.first.tool_results.map { |entry| JSON.parse(entry[1]) }
    results.map { |result| result["status"].as_s }.should eq([
      "denied", "denied", "denied", "denied", "denied", "invalid_request", "ok",
    ])
    frontend.cancel
  end

  it "opens no tool session for None, Selection, or ActiveBuffer and counts denied attempts" do
    transport = ChatProviderAdversaryTransport.new
    backend = ChatProviderAdversaryBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    factory_contexts = [] of Adamantine::Chat::SubmissionContext
    factory : Adamantine::Chat::Frontend::ContextSessionFactory = ->(context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      factory_contexts << context
      host.open_session(
        Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor]
      )
    }
    contexts = [
      Adamantine::Chat::SubmissionContext.none,
      Adamantine::Chat::SubmissionContext.new(
        Adamantine::Chat::ContextMode::Selection,
        "Selection · main.cr",
        "explicit selection",
        "buffer-17",
        "revision-4"
      ),
      Adamantine::Chat::SubmissionContext.new(
        Adamantine::Chat::ContextMode::ActiveBuffer,
        "Active buffer · main.cr",
        "whole active buffer",
        "buffer-17",
        "revision-4"
      ),
    ]

    contexts.each_with_index do |context, index|
      frontend = Adamantine::Chat::Frontend.new(transport, context_session_factory: factory)
      frontend.set_draft("context mode #{index}")
      frontend.submit(context).should be_true
      transport.emit(index, Adamantine::Chat::Event.tool_request(
        "no-tools-#{index}", adversary_read_buffer_call("no-tools-#{index}", "buffer-17", "revision-4")
      ))
      frontend.drain
      result = JSON.parse(transport.handles[index].tool_results.first[1])
      result["status"].as_s.should eq("denied")
      backend.calls.should be_empty
      frontend.cancel
    end
    factory_contexts.should be_empty

    budget_transport = ChatProviderAdversaryTransport.new
    budget_frontend = Adamantine::Chat::Frontend.new(budget_transport, context_session_factory: factory)
    budget_frontend.set_draft("bounded attempts")
    budget_frontend.submit.should be_true
    (0..Adamantine::Chat::MAX_TOOL_ATTEMPTS).each do |index|
      id = "attempt-#{index}"
      budget_transport.emit(0, Adamantine::Chat::Event.tool_request(
        id, adversary_read_buffer_call(id, "buffer-17", "revision-4")
      ))
    end
    budget_frontend.drain

    budget_frontend.state.should eq(Adamantine::Chat::TurnState::Failed)
    budget_frontend.status.should contain("tool-attempt limit")
    budget_transport.handles.first.cancelled.should be_true
    budget_transport.handles.first.tool_results.size.should eq(Adamantine::Chat::MAX_TOOL_ATTEMPTS)
    backend.calls.should be_empty
    factory_contexts.should be_empty
  end

  it "does not send a changed draft under an already-open Send approval" do
    transport = ChatProviderAdversaryTransport.new
    with_chat_provider_adversary_app(transport) do |app, _root|
      app.layout_public
      app.chat_focus_action.should be_true
      composer = app.chat_panel.composer
      composer.text = "approved draft"

      app.chat_submit_action.should be_true
      app.chat_review_active_public?.should be_true
      transport.requests.should be_empty

      composer.insert_text(" with a changed suffix")
      changed_draft = composer.text
      app.on_capture(Tui::KeyEvent.new('y')).should be_true

      transport.requests.should be_empty
      app.chat_frontend.active?.should be_false
      composer.text.should eq(changed_draft)
      app.chat_review_active_public?.should be_false
    end
  end

  it "requires the full review surface to fit before Y can approve" do
    transport = ChatProviderAdversaryTransport.new
    with_chat_provider_adversary_app(transport) do |app, _root|
      app.layout_public
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "small-terminal review"
      app.chat_submit_action.should be_true
      app.chat_review_active_public?.should be_true
      transport.requests.should be_empty

      app.resize_public(35, 7)
      app.on_capture(Tui::KeyEvent.new('y')).should be_true

      transport.requests.should be_empty
      app.chat_frontend.active?.should be_false
      app.chat_review_active_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.chat_review_active_public?.should be_false
      transport.requests.should be_empty
    end
  end

  it "rejects selected-buffer Send approval after edit then undo restores identical text" do
    transport = ChatProviderAdversaryTransport.new
    with_chat_provider_adversary_app(transport) do |app, root|
      path = root / "selected.cr"
      File.write(path, "selected source\n")
      app.open_file_public(path).should be_true
      app.layout_public
      app.chat_focus_action.should be_true
      app.choose_chat_context_public(2) # Active buffer
      app.chat_context_mode_public.should eq(Adamantine::Chat::ContextMode::ActiveBuffer)
      app.chat_focus_action.should be_true
      composer = app.chat_panel.composer
      composer.text = "explain selected source"

      app.chat_submit_action.should be_true
      app.chat_review_active_public?.should be_true
      transport.requests.should be_empty
      editor = app.buffer_public(path).editor
      approved_text = editor.text

      editor.insert_text("temporary edit")
      editor.undo.should be_true
      editor.text.should eq(approved_text)
      app.on_capture(Tui::KeyEvent.new('y')).should be_true

      transport.requests.should be_empty
      app.chat_frontend.active?.should be_false
      composer.text.should eq("explain selected source")
      app.chat_review_active_public?.should be_false
    end
  end

  it "rejects Send approval after the project root at the same path is replaced" do
    transport = ChatProviderAdversaryTransport.new
    old_root = nil.as(Path?)
    with_chat_provider_adversary_app(transport) do |app, root|
      app.layout_public
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "question for this project"

      app.chat_submit_action.should be_true
      app.chat_review_active_public?.should be_true
      transport.requests.should be_empty

      retired_root = root.parent / "#{root.basename}.retired-#{Random::Secure.hex(4)}"
      File.rename(root.to_s, retired_root.to_s)
      old_root = retired_root
      Dir.mkdir_p(root)
      app.on_capture(Tui::KeyEvent.new('y')).should be_true

      transport.requests.should be_empty
      app.chat_frontend.active?.should be_false
      app.chat_panel.composer.text.should eq("question for this project")
      app.chat_review_active_public?.should be_false
    end
  ensure
    FileUtils.rm_rf(old_root.to_s) if old_root
  end
end
