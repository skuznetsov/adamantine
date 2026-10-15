require "spec"
require "json"
require "file_utils"
require "random/secure"

require "../src/adamantine/chat_frontend"
require "../src/adamantine/app"

private class ChatEditAdversaryBackend < Adamantine::EditorTools::Backend
  getter requests : Array(Adamantine::EditorTools::Request)

  def initialize
    @context = Adamantine::EditorTools::Context.new("/project", "chat-edit-adversary")
    @requests = [] of Adamantine::EditorTools::Request
  end

  def context : Adamantine::EditorTools::Context
    @context
  end

  def execute(request : Adamantine::EditorTools::Request,
              permit : Adamantine::EditorTools::ExecutionPermit) : JSON::Any
    @requests << request
    JSON.parse({"observed" => request.class.name}.to_json)
  end
end

private def chat_edit_proposal_capability : Adamantine::EditorTools::Capability
  capability = Adamantine::EditorTools::Capability.values.find do |item|
    item.to_s == "ProposeEdits"
  end
  capability || raise "the separately granted ProposeEdits capability is not present"
end

private def chat_edit_wire_call(
  id : String,
  name : String,
  arguments : Hash(String, JSON::Any),
) : String
  {"id" => id, "name" => name, "arguments" => arguments}.to_json
end

private def chat_edit_json_args(values : Hash(String, T)) : Hash(String, JSON::Any) forall T
  values.transform_values { |value| JSON::Any.new(value) }
end

private def chat_edit_status(result : Adamantine::EditorTools::Result) : String
  JSON.parse(result.to_json)["status"].as_s
end

private class ChatEditGateBackend < Adamantine::EditorTools::Backend
  getter requests : Array(Adamantine::EditorTools::Request)

  def initialize
    @requests = [] of Adamantine::EditorTools::Request
  end

  def context : Adamantine::EditorTools::Context
    Adamantine::EditorTools::Context.new("/project", "chat-edit-gate")
  end

  def execute(request : Adamantine::EditorTools::Request,
              permit : Adamantine::EditorTools::ExecutionPermit) : JSON::Any
    @requests << request
    JSON.parse({"observed" => request.class.name}.to_json)
  end
end

private class ChatEditGateHandle < Adamantine::Chat::Handle
  getter tool_results : Array({String, String})

  def initialize
    @tool_results = [] of {String, String}
  end

  def cancel : Nil
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    @tool_results << {call_id, result_json}
  end
end

private class ChatEditGateTransport < Adamantine::Chat::Transport
  getter handles : Array(ChatEditGateHandle)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))

  def initialize
    @handles = [] of ChatEditGateHandle
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
  end

  def external? : Bool
    true
  end

  def available? : Bool
    true
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    _ = request
    @callbacks << on_event
    handle = ChatEditGateHandle.new
    @handles << handle
    handle
  end

  def emit(event : Adamantine::Chat::Event) : Nil
    @callbacks.last.call(event)
  end
end

private def chat_edit_gate_tool_call(id : String, name : String, arguments : String) : String
  {"id" => id, "name" => name, "arguments" => JSON.parse(arguments)}.to_json
end

private def chat_edit_gate_result_status(result_json : String) : String
  JSON.parse(result_json)["status"].as_s
end

private class ChatEditLifecycleHandle < Adamantine::Chat::Handle
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

private class ChatEditLifecycleTransport < Adamantine::Chat::Transport
  getter requests : Array(Adamantine::Chat::Request)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))
  getter handles : Array(ChatEditLifecycleHandle)

  def initialize
    @requests = [] of Adamantine::Chat::Request
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
    @handles = [] of ChatEditLifecycleHandle
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
    handle = ChatEditLifecycleHandle.new
    @handles << handle
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private class ChatEditLifecycleApp < Adamantine::App
  def layout_public(width : Int32 = 100, height : Int32 = 30) : Nil
    mount_headless(width, height)
    rect = Tui::Rect.new(0, 0, width, height)
    self.rect = rect
    refresh
    render(Tui::Buffer.new(width, height), rect)
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

  def choose_proposal_context_public : Nil
    raise "Chat context action was not handled" unless chat_context_action
    index = @context_menu.actions.index { |action| action.label == "Whole-file proposals" } ||
            raise "Whole-file proposals action was not available"
    index.times do
      raise "Chat context navigation was not handled" unless on_capture(Tui::KeyEvent.new(Tui::Key::Down))
    end
    raise "Buffer proposals context was not selected" unless on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def review_active_public? : Bool
    chat_review_active?
  end

  def proposal_open_public? : Bool
    @lsp_popup.chat_proposal_open?
  end

  def proposal_receipt_public : Adamantine::ChatEditProposalReceipt?
    @lsp_popup.chat_proposal_receipt
  end

  def proposal_selected_count_public : Int32
    @lsp_popup.chat_proposal_preview.try(&.selected_group_count) || 0
  end

  def editor_rect_public : Tui::Rect
    active_editor_internal.try(&.rect) || Tui::Rect.new(0, 0, 0, 0)
  end

  def editor_public(path : Path) : Adamantine::EditingTextEditor
    buffer = @document_session.open_buffers[path.to_s]? || raise "missing buffer for #{path}"
    buffer.editor.as(Adamantine::EditingTextEditor)
  end

  def owner_public(path : Path) : Adamantine::OpenBuffer
    @document_session.open_buffers[path.to_s]? || raise "missing buffer owner for #{path}"
  end

  def project_root_public : Path
    @project_root
  end

  def change_provider_public(model : String = "changed-synthetic-model") : Nil
    chat_provider_transport_changed(Adamantine::Chat::ProviderConfig.new(
      enabled: true,
      endpoint: "https://fixture.invalid/v1/chat/completions",
      model: model,
      key_env: "CHAT_EDIT_SYNTHETIC_KEY",
      max_completion_tokens: 64
    ))
  end

  def commit_project_root_public(path : Path) : Nil
    commit_project_root_change(path)
  end

  def close_path_public(path : Path) : Bool
    @editor_tabs.close_tab(path.to_s)
  end

  def split_right_public : Bool
    split_editor_right
  end

  def activate_group_public(group : Int32) : Nil
    panel = group == 1 ? @right_editor_tabs : @editor_tabs
    raise "requested editor group is unavailable" unless panel
    activate_editor_group_internal(panel.not_nil!)
  end

  def input_mode_public : String
    active_input_mode.to_s
  end

  def status_text_public : String
    @status_log.entries.map(&.message).join("\n")
  end

  def close_test_resources : Nil
    quit(force: true)
    Tui::App.clear_overlays
    Tui::Widget.focused_widget = nil
  end
end

private def with_chat_edit_lifecycle_app(&)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(Dir.tempdir, "adamantine-chat-edit-life-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config = root / "settings.json"
  File.write(config, %({"chat":{"enabled":true,"endpoint":"https://fixture.invalid/v1/chat/completions","model":"synthetic-model","key_env":"CHAT_EDIT_SYNTHETIC_KEY","max_completion_tokens":64}}))
  transport = ChatEditLifecycleTransport.new
  app = ChatEditLifecycleApp.new(
    project_root: root,
    lsp_command: "",
    keymap_path: config.to_s,
    session_enabled: false,
    recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    chat_transport: transport
  )
  app.layout_public
  yield app, transport, root
ensure
  app.try &.close_test_resources
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

private def chat_edit_lifecycle_start(
  app : ChatEditLifecycleApp,
  transport : ChatEditLifecycleTransport,
  source : Path,
  prompt : String = "propose a narrow local correction",
) : Adamantine::EditingTextEditor
  chat_edit_lifecycle_open_review(app, source, prompt)
  chat_edit_lifecycle_approve(app, transport)
  app.editor_public(source)
end

private def chat_edit_lifecycle_open_review(
  app : ChatEditLifecycleApp,
  source : Path,
  prompt : String = "propose a narrow local correction",
) : Nil
  app.open_file_public(source).should be_true
  app.layout_public
  app.chat_focus_action.should be_true
  app.choose_proposal_context_public
  app.chat_focus_action.should be_true
  app.chat_panel.composer.text = prompt
  app.chat_submit_action.should be_true
  app.review_active_public?.should be_true
end

private def chat_edit_lifecycle_approve(
  app : ChatEditLifecycleApp,
  transport : ChatEditLifecycleTransport,
) : Nil
  transport.requests.should be_empty
  app.on_capture(Tui::KeyEvent.new('y')).should be_true
  app.review_active_public?.should be_false
  transport.requests.size.should eq(1)
  transport.requests.first.context.mode.should eq(Adamantine::Chat::ContextMode::BufferProposals)
end

private def chat_edit_lifecycle_proposal_call(
  id : String,
  buffer_id : String,
  revision : String,
  start_line : Int32 = 1,
  start_column : Int32 = 6,
  end_line : Int32 = 1,
  end_column : Int32 = 7,
  new_text : String = "42",
) : String
  {
    "id"        => id,
    "name"      => "editor.propose_edits",
    "arguments" => {
      "buffer_id" => buffer_id,
      "revision"  => revision,
      "edits"     => [{
        "start_line"   => start_line,
        "start_column" => start_column,
        "end_line"     => end_line,
        "end_column"   => end_column,
        "new_text"     => new_text,
      }],
    },
  }.to_json
end

private def chat_edit_lifecycle_proposal_call_with_edits(
  id : String,
  buffer_id : String,
  revision : String,
  edits : Array(Adamantine::EditorTools::ProposeEdit),
) : String
  {
    "id"        => id,
    "name"      => "editor.propose_edits",
    "arguments" => {
      "buffer_id" => buffer_id,
      "revision"  => revision,
      "edits"     => edits.map do |edit|
        {
          "start_line"   => edit.start_line,
          "start_column" => edit.start_column,
          "end_line"     => edit.end_line,
          "end_column"   => edit.end_column,
          "new_text"     => edit.new_text,
        }
      end,
    },
  }.to_json
end

private def chat_edit_lifecycle_submit_proposal(
  app : ChatEditLifecycleApp,
  transport : ChatEditLifecycleTransport,
  id : String,
  request_json : String,
) : JSON::Any
  transport.emit(0, Adamantine::Chat::Event.tool_request(id, request_json))
  app.on_capture(Tui::WakeupEvent.new).should be_true
  handle = transport.handles.last
  result = handle.tool_results.last
  result[0].should eq(id)
  JSON.parse(result[1])
end

private def chat_edit_lifecycle_propose(
  app : ChatEditLifecycleApp,
  transport : ChatEditLifecycleTransport,
  id : String = "proposal-1",
) : JSON::Any
  request = transport.requests.last
  context = request.context
  raise "approved proposal context omitted buffer identity" unless context.buffer_id && context.revision
  chat_edit_lifecycle_submit_proposal(
    app,
    transport,
    id,
    chat_edit_lifecycle_proposal_call(id, context.buffer_id.not_nil!, context.revision.not_nil!)
  )
end

describe "CHAT-3 proposal boundary adversaries" do
  # Intentional first red: this runs against CHAT-2 and proves the current
  # catalog has not yet admitted a separate proposal capability.
  it "has a distinct ProposeEdits capability before any proposal grant is issued" do
    Adamantine::EditorTools::Capability.values.map(&.to_s).should contain("ProposeEdits")
  end

  it "keeps BufferTools read-only even when the model forges a proposal call" do
    backend = ChatEditAdversaryBackend.new
    read_only = Adamantine::EditorTools::Host.new(backend).open_session(
      Adamantine::EditorTools::Consumer::Chat,
      [Adamantine::EditorTools::Capability::ReadEditor]
    )

    proposal = chat_edit_wire_call("forged-proposal", "editor.propose_edits", {
      "buffer_id" => JSON::Any.new("buffer-1"),
      "revision"  => JSON::Any.new("revision-1"),
      "edits"     => JSON.parse(%([{"start_line":1,"start_column":0,"end_line":1,"end_column":0,"new_text":"intrusion"}])),
    } of String => JSON::Any)
    result = read_only.invoke_json(proposal)

    result.ok?.should be_false
    chat_edit_status(result).should eq("denied")
    backend.requests.should be_empty
  end

  it "keeps the proposal grant distinct from ReadEditor, navigation, and debugger tools" do
    backend = ChatEditAdversaryBackend.new
    session = Adamantine::EditorTools::Host.new(backend).open_session(
      Adamantine::EditorTools::Consumer::Chat,
      [chat_edit_proposal_capability]
    )

    names = session.definitions.map(&.name)
    names.should eq(["editor.propose_edits"])
    names.should_not contain("editor.list_buffers")
    names.should_not contain("editor.find_files")
    names.should_not contain("editor.open_file")
    names.should_not contain("editor.focus_buffer")
    names.should_not contain("debug.snapshot")
  end

  it "parses one bounded, typed Unicode proposal without applying it in the protocol layer" do
    backend = ChatEditAdversaryBackend.new
    session = Adamantine::EditorTools::Host.new(backend).open_session(
      Adamantine::EditorTools::Consumer::Chat,
      [chat_edit_proposal_capability]
    )
    arguments = {
      "buffer_id" => JSON::Any.new("buffer-1"),
      "revision"  => JSON::Any.new("revision-1"),
      "edits"     => JSON.parse(%([{"start_line":1,"start_column":1,"end_line":1,"end_column":2,"new_text":"界🙂"}])),
    } of String => JSON::Any

    result = session.invoke_json(chat_edit_wire_call("unicode-proposal", "editor.propose_edits", arguments))

    result.ok?.should be_true
    backend.requests.size.should eq(1)
    backend.requests.first.class.name.should contain("ProposeEditsRequest")
    # This fake backend only records the typed request. The protocol layer must
    # not be mistaken for the App's pending-review/no-apply guarantee.
    result.ok?.should be_true
  end

  it "keeps proposal identifiers, coordinates, and replacement text immutable to callers" do
    backend = ChatEditAdversaryBackend.new
    session = Adamantine::EditorTools::Host.new(backend).open_session(
      Adamantine::EditorTools::Consumer::Chat,
      [chat_edit_proposal_capability]
    )
    raw = chat_edit_wire_call("immutable", "editor.propose_edits", {
      "buffer_id" => JSON::Any.new("buffer-1"),
      "revision"  => JSON::Any.new("revision-1"),
      "edits"     => JSON.parse(%([{"start_line":1,"start_column":1,"end_line":1,"end_column":2,"new_text":"🙂"}])),
    } of String => JSON::Any)

    session.invoke_json(raw).ok?.should be_true
    request = backend.requests.first.as(Adamantine::EditorTools::ProposeEditsRequest)
    returned_id = request.buffer_id + "-tampered"
    returned_revision = request.revision + "-tampered"
    returned_edits = request.edits
    returned_edits.clear
    returned_text = request.edits.first.new_text + "tampered"

    returned_id.should eq("buffer-1-tampered")
    returned_revision.should eq("revision-1-tampered")
    returned_text.should eq("🙂tampered")
    request.buffer_id.should eq("buffer-1")
    request.revision.should eq("revision-1")
    request.edits.size.should eq(1)
    request.edits.first.start_line.should eq(1)
    request.edits.first.start_column.should eq(1)
    request.edits.first.end_column.should eq(2)
    request.edits.first.new_text.should eq("🙂")
  end

  it "rejects duplicate, oversized, over-count, and extra-field proposal envelopes before backend execution" do
    backend = ChatEditAdversaryBackend.new
    session = Adamantine::EditorTools::Host.new(backend).open_session(
      Adamantine::EditorTools::Consumer::Chat,
      [chat_edit_proposal_capability]
    )
    valid_edit = {"start_line" => 1, "start_column" => 0, "end_line" => 1,
                  "end_column" => 0, "new_text" => "x"}
    too_many = Array.new(33, valid_edit)
    invalid = [
      %({"id":"duplicate","name":"editor.propose_edits","arguments":{"buffer_id":"b","revision":"r","edits":[] ,"edits":[]}}),
      chat_edit_wire_call("extra", "editor.propose_edits", {
        "buffer_id" => JSON::Any.new("b"), "revision" => JSON::Any.new("r"),
        "edits" => JSON.parse("[]"), "path" => JSON::Any.new("private.cr"),
      } of String => JSON::Any),
      chat_edit_wire_call("count", "editor.propose_edits", {
        "buffer_id" => JSON::Any.new("b"), "revision" => JSON::Any.new("r"),
        "edits" => JSON.parse(too_many.to_json),
      } of String => JSON::Any),
      # Required model coordinates/text may never inherit parser defaults.
      %({"id":"null-start-line","name":"editor.propose_edits","arguments":{"buffer_id":"b","revision":"r","edits":[{"start_line":null,"start_column":0,"end_line":1,"end_column":1,"new_text":"x"}]}}),
      %({"id":"null-start-column","name":"editor.propose_edits","arguments":{"buffer_id":"b","revision":"r","edits":[{"start_line":1,"start_column":null,"end_line":1,"end_column":1,"new_text":"x"}]}}),
      %({"id":"null-end-line","name":"editor.propose_edits","arguments":{"buffer_id":"b","revision":"r","edits":[{"start_line":1,"start_column":0,"end_line":null,"end_column":1,"new_text":"x"}]}}),
      %({"id":"null-end-column","name":"editor.propose_edits","arguments":{"buffer_id":"b","revision":"r","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":null,"new_text":"x"}]}}),
      %({"id":"null-new-text","name":"editor.propose_edits","arguments":{"buffer_id":"b","revision":"r","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":1,"new_text":null}]}}),
      %({"id":"negative-line","name":"editor.propose_edits","arguments":{"buffer_id":"b","revision":"r","edits":[{"start_line":0,"start_column":0,"end_line":1,"end_column":1,"new_text":"x"}]}}),
      %({"id":"negative-column","name":"editor.propose_edits","arguments":{"buffer_id":"b","revision":"r","edits":[{"start_line":1,"start_column":-1,"end_line":1,"end_column":1,"new_text":"x"}]}}),
      %({"id":"coordinate-overflow","name":"editor.propose_edits","arguments":{"buffer_id":"b","revision":"r","edits":[{"start_line":2147483648,"start_column":0,"end_line":2147483648,"end_column":1,"new_text":"x"}]}}),
      " " * (Adamantine::EditorTools::MAX_REQUEST_BYTES + 1),
    ]

    invalid.each do |raw|
      session.invoke_json(raw).ok?.should be_false
    end
    backend.requests.should be_empty
  end

  it "enforces BufferProposals as an exact selected-buffer read-and-propose allowlist" do
    transport = ChatEditGateTransport.new
    backend = ChatEditGateBackend.new
    host = Adamantine::EditorTools::Host.new(backend)
    factory : Adamantine::Chat::Frontend::ContextSessionFactory = ->(_context : Adamantine::Chat::SubmissionContext) : Adamantine::EditorTools::Session {
      host.open_session(
        Adamantine::EditorTools::Consumer::Chat,
        [Adamantine::EditorTools::Capability::ReadEditor, chat_edit_proposal_capability]
      )
    }
    frontend = Adamantine::Chat::Frontend.new(transport, context_session_factory: factory)
    context = Adamantine::Chat::SubmissionContext.new(
      Adamantine::Chat::ContextMode::BufferProposals,
      "Selected buffer read + proposals",
      "",
      "buffer-7",
      "revision-9",
      source_path: "fixture.cr"
    )
    frontend.set_draft("propose a local correction").should be_true
    frontend.submit(context).should be_true

    calls = [
      {"list", "editor.list_buffers", %({})},
      {"find", "editor.find_files", %({"query":"private"})},
      {"read-wrong-id", "editor.read_buffer", %({"buffer_id":"buffer-8","revision":"revision-9"})},
      {"read-wrong-rev", "editor.read_buffer", %({"buffer_id":"buffer-7","revision":"revision-10"})},
      {"proposal-wrong-id", "editor.propose_edits", %({"buffer_id":"buffer-8","revision":"revision-9","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":0,"new_text":"x"}]})},
      {"proposal-wrong-rev", "editor.propose_edits", %({"buffer_id":"buffer-7","revision":"revision-10","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":0,"new_text":"x"}]})},
      {"proposal-valid", "editor.propose_edits", %({"buffer_id":"buffer-7","revision":"revision-9","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":0,"new_text":"x"}]})},
      {"proposal-second", "editor.propose_edits", %({"buffer_id":"buffer-7","revision":"revision-9","edits":[{"start_line":1,"start_column":0,"end_line":1,"end_column":0,"new_text":"y"}]})},
      {"read-valid", "editor.read_buffer", %({"buffer_id":"buffer-7","revision":"revision-9","start_line":1,"line_count":1,"start_column":0,"max_columns":64})},
    ]
    calls.each do |(id, name, arguments)|
      transport.emit(Adamantine::Chat::Event.tool_request(id, chat_edit_gate_tool_call(id, name, arguments)))
    end
    frontend.drain

    statuses = transport.handles.first.tool_results.map { |entry| chat_edit_gate_result_status(entry[1]) }
    statuses.should eq(["denied", "denied", "denied", "denied", "denied", "denied", "ok", "denied", "ok"])
    backend.requests.size.should eq(2)
    backend.requests.count(&.is_a?(Adamantine::EditorTools::ProposeEditsRequest)).should eq(1)
    backend.requests.count(&.is_a?(Adamantine::EditorTools::ReadBufferRequest)).should eq(1)
    backend.requests.each do |request|
      case request
      when Adamantine::EditorTools::ReadBufferRequest
        read = request.as(Adamantine::EditorTools::ReadBufferRequest)
        read.buffer_id.should eq("buffer-7")
        read.revision.should eq("revision-9")
      when Adamantine::EditorTools::ProposeEditsRequest
        proposal = request.as(Adamantine::EditorTools::ProposeEditsRequest)
        proposal.buffer_id.should eq("buffer-7")
        proposal.revision.should eq("revision-9")
      else
        fail "only exact selected-buffer reads and proposals may reach the backend"
      end
    end
    frontend.cancel.should be_true
  end
end

describe "CHAT-3 App proposal lifetime adversaries" do
  it "keeps a proposal private until Complete, then requires manual accept and creates one Undo without saving" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "main.cr"
      original = "alpha=1\r\nbeta=2\r\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      approved = transport.requests.first.context
      buffer_id = approved.buffer_id.not_nil!
      revision = approved.revision.not_nil!

      result = chat_edit_lifecycle_propose(app, transport)
      result["status"].as_s.should eq("ok")
      data = result["data"]
      data["status"].as_s.should eq("pending_review")
      data["applied"].as_bool.should be_false
      data["buffer_id"].as_s.should eq(buffer_id)
      data["revision"].as_s.should eq(revision)
      editor.text.should eq(original)
      app.proposal_open_public?.should be_false
      File.read(source).should eq(original)

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_true
      app.proposal_receipt_public.not_nil!.buffer_id.should eq(buffer_id)
      editor.text.should eq(original)
      File.read(source).should eq(original)

      app.input_mode_public.should eq("LspPopup")
      app.proposal_selected_count_public.should be > 0
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      if app.proposal_open_public?
        raise "Enter did not accept (mode=#{app.input_mode_public}, selected=#{app.proposal_selected_count_public}, rect=#{app.editor_rect_public}, status=#{app.status_text_public})"
      end
      app.proposal_open_public?.should be_false
      editor.text.should eq("alpha=42\r\nbeta=2\r\n")
      File.read(source).should eq(original)
      editor.undo.should be_true
      editor.text.should eq(original)
      editor.undo.should be_false
      File.read(source).should eq(original)
    end
  end

  it "revokes a staged proposal after source edit then Undo restores the exact snapshot" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "aba.cr"
      original = "alpha=1\r\nbeta=2\r\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)

      result = chat_edit_lifecycle_propose(app, transport)
      result["status"].as_s.should eq("ok")
      app.proposal_open_public?.should be_false
      editor.insert_text("temporary mutation")
      editor.undo.should be_true
      editor.text.should eq(original)

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_false
      editor.text.should eq(original)
      app.status_text_public.should contain("source buffer changed")
    end
  end

  it "does not revive a staged proposal after an A-to-B-to-A editor-group switch" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "grouped.cr"
      original = "alpha=1\nbeta=2\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      chat_edit_lifecycle_propose(app, transport)["status"].as_s.should eq("ok")
      app.proposal_open_public?.should be_false

      app.split_right_public.should be_true
      app.activate_group_public(0)
      app.activate_group_public(1)
      app.activate_group_public(0)
      app.input_mode_public.should_not eq("LspPopup")

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_false
      editor.text.should eq(original)
    end
  end

  it "does not revive a staged proposal after closing and reopening the same path" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "reopened.cr"
      original = "alpha=1\nbeta=2\n"
      File.write(source, original)
      editor_before_close = chat_edit_lifecycle_start(app, transport, source)
      chat_edit_lifecycle_propose(app, transport)["status"].as_s.should eq("ok")
      app.proposal_open_public?.should be_false

      app.close_path_public(source).should be_true
      app.open_file_public(source).should be_true
      editor_after_reopen = app.editor_public(source)
      editor_after_reopen.same?(editor_before_close).should be_false
      editor_after_reopen.text.should eq(original)

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_false
      editor_after_reopen.text.should eq(original)
    end
  end

  it "discards the candidate rather than replacing a context modal at Complete" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "modal.cr"
      original = "alpha=1\nbeta=2\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      chat_edit_lifecycle_propose(app, transport)["status"].as_s.should eq("ok")
      app.proposal_open_public?.should be_false

      app.chat_context_action.should be_true
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_false
      editor.text.should eq(original)
      app.input_mode_public.should_not eq("LspPopup")
    end
  end

  it "ignores a late Complete after explicit cancellation of a staged proposal" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "cancelled.cr"
      original = "alpha=1\nbeta=2\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      chat_edit_lifecycle_propose(app, transport)["status"].as_s.should eq("ok")
      app.proposal_open_public?.should be_false

      app.chat_cancel_action.should be_true
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_false
      editor.text.should eq(original)
    end
  end

  it "converts astral codepoint columns to the right UTF-16 range before applying" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "astral.cr"
      original = "α🙂x=1\r\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      context = transport.requests.first.context
      call = chat_edit_lifecycle_proposal_call_with_edits(
        "astral-proposal",
        context.buffer_id.not_nil!,
        context.revision.not_nil!,
        [Adamantine::EditorTools::ProposeEdit.new(1, 4, 1, 5, "2")]
      )

      result = chat_edit_lifecycle_submit_proposal(app, transport, "astral-proposal", call)
      result["status"].as_s.should eq("ok")
      result["data"]["applied"].as_bool.should be_false
      editor.text.should eq(original)

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      editor.text.should eq("α🙂x=2\r\n")
      editor.undo.should be_true
      editor.text.should eq(original)
      editor.undo.should be_false
    end
  end

  it "refuses Enter on a compact terminal and still lets Escape cleanly reject" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "compact.cr"
      original = "alpha=1\nbeta=2\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      chat_edit_lifecycle_propose(app, transport)["status"].as_s.should eq("ok")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_true

      # Keep the enclosing TUI footer within its supported width while
      # making the editor pane too short to expose a source row and footer.
      app.resize_public(30, 5)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      unless app.proposal_open_public?
        rect = app.editor_rect_public
        raise "compact preview was accepted at #{rect.width}x#{rect.height}: #{app.status_text_public}"
      end
      editor.text.should eq(original)
      app.status_text_public.should contain("Resize the editor to inspect proposed changes")

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.proposal_open_public?.should be_false
      app.input_mode_public.should eq("Normal")
      editor.text.should eq(original)
    end
  end

  it "rejects the entire invalid batch without applying an earlier valid edit" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "atomic.cr"
      original = "alpha=1\r\nbeta=2\r\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      context = transport.requests.first.context
      call = chat_edit_lifecycle_proposal_call_with_edits(
        "invalid-batch",
        context.buffer_id.not_nil!,
        context.revision.not_nil!,
        [
          Adamantine::EditorTools::ProposeEdit.new(1, 6, 1, 7, "42"),
          Adamantine::EditorTools::ProposeEdit.new(2, 999, 2, 1000, "99"),
        ]
      )

      result = chat_edit_lifecycle_submit_proposal(app, transport, "invalid-batch", call)
      result["status"].as_s.should eq("invalid_request")
      editor.text.should eq(original)
      app.proposal_open_public?.should be_false
      File.read(source).should eq(original)

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_false
      editor.text.should eq(original)
      File.read(source).should eq(original)
    end
  end

  it "selectively accepts one separated proposal group as exactly one Undo without saving" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "selective.cr"
      original = "a=1\n" + ("\n" * 8) + "b=2\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      context = transport.requests.first.context
      call = chat_edit_lifecycle_proposal_call_with_edits(
        "selective-proposal",
        context.buffer_id.not_nil!,
        context.revision.not_nil!,
        [
          Adamantine::EditorTools::ProposeEdit.new(1, 2, 1, 3, "9"),
          Adamantine::EditorTools::ProposeEdit.new(10, 2, 10, 3, "8"),
        ]
      )

      result = chat_edit_lifecycle_submit_proposal(app, transport, "selective-proposal", call)
      result["status"].as_s.should eq("ok")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_true
      app.proposal_selected_count_public.should eq(2)

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Space)).should be_true
      app.proposal_selected_count_public.should eq(1)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      accepted = "a=1\n" + ("\n" * 8) + "b=8\n"
      editor.text.should eq(accepted)
      File.read(source).should eq(original)
      editor.undo.should be_true
      editor.text.should eq(original)
      editor.undo.should be_false
      File.read(source).should eq(original)
    end
  end

  it "revokes a published proposal when the configured provider changes" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "provider-change.cr"
      original = "alpha=1\nbeta=2\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      chat_edit_lifecycle_propose(app, transport)["status"].as_s.should eq("ok")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_true

      app.change_provider_public
      app.proposal_open_public?.should be_false
      app.input_mode_public.should eq("Normal")
      editor.text.should eq(original)
      File.read(source).should eq(original)
    end
  end

  it "revokes a staged proposal across an approved project-root change" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "root-change.cr"
      original = "alpha=1\nbeta=2\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      chat_edit_lifecycle_propose(app, transport)["status"].as_s.should eq("ok")
      app.proposal_open_public?.should be_false

      other_root = root / "other-project"
      Dir.mkdir_p(other_root)
      app.commit_project_root_public(other_root)
      app.project_root_public.should eq(Path.new(File.realpath(other_root.to_s)))
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_false
      editor.text.should eq(original)
      File.read(source).should eq(original)
      app.status_text_public.should contain("project root changed")
    end
  end

  it "revokes a published proposal when a new conversation starts" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "new-turn.cr"
      original = "alpha=1\nbeta=2\n"
      File.write(source, original)
      editor = chat_edit_lifecycle_start(app, transport, source)
      chat_edit_lifecycle_propose(app, transport)["status"].as_s.should eq("ok")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.proposal_open_public?.should be_true

      app.chat_new_conversation_action.should be_true
      app.proposal_open_public?.should be_false
      app.input_mode_public.should eq("Normal")
      editor.text.should eq(original)
      File.read(source).should eq(original)
    end
  end

  it "refuses proposal-session capture when the owner version is exhausted" do
    with_chat_edit_lifecycle_app do |app, transport, root|
      source = root / "exhausted-version.cr"
      original = "alpha=1\nbeta=2\n"
      File.write(source, original)
      app.open_file_public(source).should be_true
      app.layout_public
      owner = app.owner_public(source)
      owner.version = Int32::MAX
      app.chat_focus_action.should be_true
      app.choose_proposal_context_public
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "keep this draft after exhausted source version"
      app.chat_submit_action.should be_true
      app.review_active_public?.should be_true

      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      app.review_active_public?.should be_false
      transport.requests.should be_empty
      app.chat_panel.composer.text.should eq("keep this draft after exhausted source version")
      app.status_text_public.should contain("Chat provider could not start the approved request")
      app.editor_public(source).text.should eq(original)
      File.read(source).should eq(original)
    end
  end
end
