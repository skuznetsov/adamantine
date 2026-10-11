require "spec"
require "file_utils"
require "random/secure"
require "crystal_tui"

require "../src/adamantine/app"

private class ChatEditAppProbeHandle < Adamantine::Chat::Handle
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

private class ChatEditAppProbeTransport < Adamantine::Chat::Transport
  def available? : Bool
    true
  end

  def external? : Bool
    true
  end

  getter requests : Array(Adamantine::Chat::Request)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))
  getter handles : Array(ChatEditAppProbeHandle)

  def initialize
    @requests = [] of Adamantine::Chat::Request
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
    @handles = [] of ChatEditAppProbeHandle
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    @requests << request
    @callbacks << on_event
    handle = ChatEditAppProbeHandle.new
    @handles << handle
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private class ChatEditAppProbe < Adamantine::App
  def render_surface_public(width : Int32 = 100, height : Int32 = 30) : Tui::Buffer
    mount_headless(width, height)
    buffer = Tui::Buffer.new(width, height)
    render(buffer, Tui::Rect.new(0, 0, width, height))
    buffer
  end

  def open_chat_context_public : Bool
    chat_context_action
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def split_editor_right_public : Bool
    split_editor_right
  end

  def activate_group_public(group : Int32) : Nil
    panel = group == 1 ? @right_editor_tabs : @editor_tabs
    raise "requested editor group is unavailable" unless panel
    activate_editor_group_internal(panel.not_nil!)
  end

  def activate_path_public(path : Path) : Nil
    active_editor_tabs.switch_to(path.to_s)
  end

  def choose_chat_context_public(index : Int32) : Nil
    raise "Chat context action was not handled" unless chat_context_action
    index.times do
      raise "Chat context navigation was not handled" unless on_capture(Tui::KeyEvent.new(Tui::Key::Down))
    end
    raise "Chat context selection was not handled" unless on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def chat_review_active_public? : Bool
    chat_review_active?
  end

  def chat_submit_public : Bool
    chat_submit_action
  end

  def project_root_public : Path
    @project_root
  end

  def chat_proposal_open_public? : Bool
    @lsp_popup.chat_proposal_open?
  end

  def chat_popup_title_public : String
    @lsp_popup.title
  end

  def input_mode_public : String
    active_input_mode.to_s
  end

  def editor_public(path : Path) : Adamantine::EditingTextEditor
    editor = @document_session.open_buffers[path.to_s]?.try(&.editor.as?(Adamantine::EditingTextEditor))
    editor || raise "missing editor for #{path}"
  end

  def active_editor_public : Adamantine::EditingTextEditor?
    active_editor_internal.as?(Adamantine::EditingTextEditor)
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

private def with_chat_edit_app(
  transport : ChatEditAppProbeTransport = ChatEditAppProbeTransport.new,
  chat_enabled : Bool = false,
  &
)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(Dir.tempdir, "adamantine-chat-edit-ui-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config_path = root / "settings.json"
  chat_json = if chat_enabled
                %({"chat":{"enabled":true,"endpoint":"https://example.test/v1/chat/completions","model":"explicit-test-model","key_env":"CHAT_EDIT_TEST_KEY","max_completion_tokens":256}})
              else
                %({"chat":{"enabled":false}})
              end
  File.write(config_path, chat_json)
  app = ChatEditAppProbe.new(
    project_root: root,
    lsp_command: "",
    keymap_path: config_path.to_s,
    session_enabled: false,
    recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    chat_transport: transport
  )
  app.render_surface_public
  yield app
ensure
  app.try &.close_test_resources
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

private def chat_edit_ui_surface_text(buffer : Tui::Buffer) : String
  (0...buffer.height).map do |y|
    (0...buffer.width).map { |x| buffer.get(x, y).glyph }.join
  end.join("\n")
end

private def start_chat_edit_turn(
  app : ChatEditAppProbe,
  transport : ChatEditAppProbeTransport,
  source : Path,
  prompt : String = "replace the selected number",
  split_right : Bool = false,
) : Adamantine::EditingTextEditor
  app.open_file_public(source).should be_true
  if split_right
    app.split_editor_right_public.should be_true
    app.open_file_public(source).should be_true
    app.render_surface_public
    selected_view = app.active_editor_public || raise "right-group editor is not active"
    selected_view.same?(app.editor_public(source)).should be_false
  end
  app.chat_focus_action.should be_true
  app.choose_chat_context_public(4)
  app.chat_focus_action.should be_true
  app.chat_panel.composer.text = prompt
  app.chat_submit_public.should be_true
  app.chat_review_active_public?.should be_true
  app.render_surface_public
  app.on_capture(Tui::KeyEvent.new('y')).should be_true
  app.chat_review_active_public?.should be_false
  transport.requests.size.should eq(1)
  transport.requests.first.context.mode.should eq(Adamantine::Chat::ContextMode::BufferProposals)
  app.editor_public(source)
end

private def chat_edit_proposal_request(
  call_id : String,
  request : Adamantine::Chat::Request,
  start_column : Int32 = 14,
  end_column : Int32 = 15,
  replacement : String = "42",
) : String
  context = request.context
  raise "approved proposal context omitted buffer identity" unless context.buffer_id && context.revision
  {
    "id"        => call_id,
    "name"      => "editor.propose_edits",
    "arguments" => {
      "buffer_id" => context.buffer_id.not_nil!,
      "revision"  => context.revision.not_nil!,
      "edits"     => [{
        "start_line"   => 1,
        "start_column" => start_column,
        "end_line"     => 1,
        "end_column"   => end_column,
        "new_text"     => replacement,
      }],
    },
  }.to_json
end

private def submit_chat_edit_proposal(
  app : ChatEditAppProbe,
  transport : ChatEditAppProbeTransport,
  call_id : String,
  request_json : String,
) : JSON::Any
  transport.emit(0, Adamantine::Chat::Event.tool_request(call_id, request_json))
  app.on_capture(Tui::WakeupEvent.new).should be_true
  result = transport.handles.first.tool_results.last
  result[0].should eq(call_id)
  JSON.parse(result[1])
end

describe "Chat edit proposal UI" do
  it "offers a separately named read-and-propose buffer context" do
    with_chat_edit_app do |app|
      app.open_chat_context_public.should be_true
      surface = chat_edit_ui_surface_text(app.render_surface_public)

      surface.should contain("Buffer proposals (read + propose)")
    end
  end

  it "discloses the one-attempt and 8 KiB boundary before provider approval" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      app.open_file_public(source).should be_true
      app.chat_focus_action.should be_true
      app.choose_chat_context_public(4)
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "replace the number only"
      app.chat_submit_public.should be_true

      surface = chat_edit_ui_surface_text(app.render_surface_public)
      surface.should contain("One proposal attempt")
      surface.should contain("32 edits / 8 KiB tool request")
      surface.should contain("manual review only")
      surface.should contain("never auto-")
      surface.should contain("applied/saved")
      transport.requests.should be_empty
    end
  end

  it "stages privately, then accepts the proposal as one undoable unsaved edit from a split view" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      editor = start_chat_edit_turn(app, transport, source, split_right: true)

      result = submit_chat_edit_proposal(app, transport, "proposal-1",
        chat_edit_proposal_request("proposal-1", transport.requests.first))
      result["status"].as_s.should eq("ok")
      result["data"]["status"].as_s.should eq("pending_review")
      result["data"]["applied"].as_bool.should be_false
      result["data"]["buffer_id"].as_s.should eq(transport.requests.first.context.buffer_id.not_nil!)
      result["data"]["revision"].as_s.should eq(transport.requests.first.context.revision.not_nil!)
      editor.text.should eq(original)
      app.chat_proposal_open_public?.should be_false

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true
      app.chat_popup_title_public.should eq("Chat proposed edits · manual review")
      app.input_mode_public.should eq("LspPopup")
      chat_edit_ui_surface_text(app.render_surface_public).should contain("fixture.cr")
      editor.text.should eq(original)
      File.read(source).should eq(original)

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      editor.text.should eq("const value = 42;\n")
      File.read(source).should eq(original)
      app.chat_proposal_open_public?.should be_false
      app.input_mode_public.should eq("Normal")

      app.on_capture(Tui::KeyEvent.new('z', Tui::Modifiers::Ctrl)).should be_true
      editor.text.should eq(original)
      editor.undo.should be_false
      File.read(source).should eq(original)
    end
  end

  it "keeps the source identity and unsaved state on the 112x30 preview header" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      File.write(source, "const value = 1;\n")
      start_chat_edit_turn(app, transport, source)
      submit_chat_edit_proposal(app, transport, "proposal-header",
        chat_edit_proposal_request("proposal-header", transport.requests.first))
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true

      surface = chat_edit_ui_surface_text(app.render_surface_public(112, 30))
      review_header = surface.lines.find { |line| line.includes?("Chat proposed edits") }
      review_header.should_not be_nil
      review_header.not_nil!.should contain("fixture.cr")
      review_header.not_nil!.should contain("not saved")
      surface.should contain("Apply selected")
      surface.should contain("Esc Reject")
    end
  end

  it "spends the single typed proposal attempt even when its first range is invalid" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      editor = start_chat_edit_turn(app, transport, source)
      request = transport.requests.first

      invalid = submit_chat_edit_proposal(app, transport, "invalid-range",
        chat_edit_proposal_request("invalid-range", request, start_column: 999, end_column: 1000))
      invalid["status"].as_s.should eq("invalid_request")
      editor.text.should eq(original)

      second = submit_chat_edit_proposal(app, transport, "second-attempt",
        chat_edit_proposal_request("second-attempt", request))
      second["status"].as_s.should eq("denied")
      second["message"].as_s.should contain("only one proposal")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_false
      editor.text.should eq(original)
    end
  end

  it "closes the shared popup input mode on explicit rejection" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      editor = start_chat_edit_turn(app, transport, source)
      submit_chat_edit_proposal(app, transport, "proposal-escape",
        chat_edit_proposal_request("proposal-escape", transport.requests.first))
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.chat_proposal_open_public?.should be_false
      app.input_mode_public.should eq("Normal")
      editor.text.should eq(original)

      # A subsequent shared modal can open only if LspPopup mode was fully
      # unwound along with the proposal overlay.
      app.open_chat_context_public.should be_true
    end
  end
end
