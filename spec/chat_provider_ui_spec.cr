require "spec"
require "file_utils"
require "random/secure"
require "json"
require "crystal_tui"

require "../src/adamantine/app"

private class ChatProviderUiProbeHandle < Adamantine::Chat::Handle
  def cancel : Nil
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    _ = call_id
    _ = result_json
  end
end

private class ChatProviderUiProbeTransport < Adamantine::Chat::Transport
  getter requests : Array(Adamantine::Chat::Request)

  def initialize
    @requests = [] of Adamantine::Chat::Request
  end

  def available? : Bool
    true
  end

  def external? : Bool
    true
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    _ = on_event
    @requests << request
    ChatProviderUiProbeHandle.new
  end
end

private class ChatProviderUiProbeApp < Adamantine::App
  def render_surface_public(width : Int32 = 100, height : Int32 = 30) : Tui::Buffer
    mount_headless(width, height)
    buffer = Tui::Buffer.new(width, height)
    render(buffer, Tui::Rect.new(0, 0, width, height))
    buffer
  end

  def resize_public(width : Int32, height : Int32) : Nil
    self.rect = Tui::Rect.new(0, 0, width, height)
    on_capture(Tui::ResizeEvent.new(width, height))
  end

  def choose_context_public(index : Int32) : Nil
    chat_context_action
    index.times { on_capture(Tui::KeyEvent.new(Tui::Key::Down)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def chat_review_open_public? : Bool
    chat_review_active?
  end

  def chat_settings_open_public? : Bool
    chat_settings_active?
  end

  def safe_editable_input_public(input : Adamantine::EditableInput) : Adamantine::EditableInput
    chat_safe_editable_input(input)
  end

  def close_test_resources : Nil
    quit(force: true)
    Tui::App.clear_overlays
    Tui::Widget.focused_widget = nil
  end
end

private def with_chat_provider_ui_app(
  transport : Adamantine::Chat::Transport = ChatProviderUiProbeTransport.new,
  chat_json : String = %({"enabled":true,"endpoint":"https://example.test/v1/chat/completions","model":"explicit-model","key_env":"CHAT_TEST_KEY","max_completion_tokens":256}),
  &
)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(Dir.tempdir, "adamantine-chat-provider-ui-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config_path = root / "settings.json"
  parsed_config = JSON.parse(chat_json)
  root_config = if parsed_config.as_h?.try(&.has_key?("chat"))
                  parsed_config
                else
                  JSON::Any.new({"chat" => parsed_config})
                end
  File.write(config_path, root_config.to_json)
  app = ChatProviderUiProbeApp.new(
    project_root: root,
    lsp_command: "",
    keymap_path: config_path.to_s,
    session_enabled: false,
    recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    chat_transport: transport
  )
  app.render_surface_public
  yield app, root, config_path
ensure
  app.try &.close_test_resources
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

private def chat_ui_surface_text(buffer : Tui::Buffer) : String
  (0...buffer.height).map do |y|
    (0...buffer.width).map { |x| buffer.get(x, y).glyph }.join
  end.join("\n")
end

describe "Chat provider UI" do
  it "keeps settings save update-only and does not start a provider request" do
    transport = ChatProviderUiProbeTransport.new
    original = {
      "editor" => {"indent_width" => 2, "auto_indent" => false},
      "debug"  => {"max_message_mib" => 7, "dock" => "right"},
      "lsp"    => {"max_response_mib" => 9},
      "custom" => {"retain" => [1, "two"]},
      "chat"   => JSON.parse(%({"enabled":false,"endpoint":"https://example.test/v1/chat/completions","model":"","key_env":"CHAT_TEST_KEY","max_completion_tokens":256})),
    }
    with_chat_provider_ui_app(transport, original.to_json) do |app, _root, config_path|
      app.chat_settings_action.should be_true
      app.chat_settings_open_public?.should be_true
      surface = chat_ui_surface_text(app.render_surface_public)
      surface.should contain("Chat Provider Settings")
      surface.should contain("Credential env var")
      app.on_capture(Tui::KeyEvent.new('s', Tui::Modifiers::Ctrl)).should be_true
      app.chat_settings_open_public?.should be_false

      saved = JSON.parse(File.read(config_path)).as_h
      saved["editor"].should eq(JSON.parse(original["editor"].to_json))
      saved["debug"].should eq(JSON.parse(original["debug"].to_json))
      saved["lsp"].should eq(JSON.parse(original["lsp"].to_json))
      saved["custom"].should eq(JSON.parse(original["custom"].to_json))
      saved["chat"].should eq(original["chat"])
      transport.requests.should be_empty
    end
  end

  it "round-trips the explicit reasoning effort in settings and discloses it in Send review" do
    transport = ChatProviderUiProbeTransport.new
    config = %({"enabled":false,"endpoint":"https://example.test/v1/chat/completions","model":"explicit-model","key_env":"CHAT_TEST_KEY","max_completion_tokens":256,"reasoning_effort":"low"})
    with_chat_provider_ui_app(transport, config) do |app, _root, config_path|
      app.chat_settings_action.should be_true
      surface = chat_ui_surface_text(app.render_surface_public)
      surface.should contain("Reasoning effort")
      surface.should contain("low")
      app.on_capture(Tui::KeyEvent.new('s', Tui::Modifiers::Ctrl)).should be_true

      saved = JSON.parse(File.read(config_path))["chat"]
      saved["reasoning_effort"].as_s.should eq("low")
      transport.requests.should be_empty

      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "review effort"
      app.chat_submit_action.should be_true
      review = chat_ui_surface_text(app.render_surface_public)
      review.should contain("Reasoning effort: low")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      transport.requests.should be_empty
    end
  end

  it "blocks settings edits when height hides fields and restores the draft after resize" do
    transport = ChatProviderUiProbeTransport.new
    config = %({"enabled":false,"endpoint":"https://example.test/v1/chat/completions","model":"explicit-model","key_env":"CHAT_TEST_KEY","max_completion_tokens":256})
    with_chat_provider_ui_app(transport, config) do |app, _root, config_path|
      app.chat_settings_action.should be_true
      5.times { app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)) }
      app.on_capture(Tui::PasteEvent.new("minimal")).should be_true
      original = File.read(config_path)

      app.resize_public(100, 10)
      small = chat_ui_surface_text(app.render_surface_public(100, 10))
      small.should contain("Resize to show all fields")
      app.on_capture(Tui::KeyEvent.new('x')).should be_true
      app.on_capture(Tui::PasteEvent.new("blocked")).should be_true
      app.on_capture(Tui::KeyEvent.new('s', Tui::Modifiers::Ctrl)).should be_true
      app.chat_settings_open_public?.should be_true
      File.read(config_path).should eq(original)
      transport.requests.should be_empty

      app.resize_public(100, 30)
      restored = chat_ui_surface_text(app.render_surface_public)
      ["Enabled", "Endpoint", "Model", "Credential env var", "Max output tokens/round", "Reasoning effort"].each do |label|
        restored.should contain(label)
      end
      restored.should_not contain("Resize to show all fields")
      restored.should contain("minimal")
      app.on_capture(Tui::KeyEvent.new('a', Tui::Modifiers::Ctrl)).should be_true
      app.on_capture(Tui::PasteEvent.new("high")).should be_true
      chat_ui_surface_text(app.render_surface_public).should contain("high")
      app.on_capture(Tui::KeyEvent.new('s', Tui::Modifiers::Ctrl)).should be_true
      app.chat_settings_open_public?.should be_false
      JSON.parse(File.read(config_path))["chat"]["reasoning_effort"].as_s.should eq("high")
      transport.requests.should be_empty

      app.chat_settings_action.should be_true
      app.resize_public(100, 10)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.chat_settings_open_public?.should be_false
      transport.requests.should be_empty
    end
  end

  it "blocks settings edits when width clips the reasoning value and restores it after resize" do
    transport = ChatProviderUiProbeTransport.new
    config = %({"enabled":false,"endpoint":"https://example.test/v1/chat/completions","model":"explicit-model","key_env":"CHAT_TEST_KEY","max_completion_tokens":256})
    with_chat_provider_ui_app(transport, config) do |app, _root, config_path|
      app.chat_settings_action.should be_true
      5.times { app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)) }
      app.on_capture(Tui::PasteEvent.new("minimal")).should be_true
      original = File.read(config_path)

      app.resize_public(58, 30)
      small = chat_ui_surface_text(app.render_surface_public(58, 30))
      small.should contain("Resize to show all fields")
      app.on_capture(Tui::KeyEvent.new('x')).should be_true
      app.on_capture(Tui::PasteEvent.new("blocked")).should be_true
      app.on_capture(Tui::KeyEvent.new('s', Tui::Modifiers::Ctrl)).should be_true
      app.chat_settings_open_public?.should be_true
      File.read(config_path).should eq(original)
      transport.requests.should be_empty

      app.resize_public(60, 30)
      restored = chat_ui_surface_text(app.render_surface_public(60, 30))
      ["Enabled", "Endpoint", "Model", "Credential env var", "Max output tokens/round", "Reasoning effort"].each do |label|
        restored.should contain(label)
      end
      restored.should_not contain("Resize to show all fields")
      restored.should contain("minimal")
      app.on_capture(Tui::KeyEvent.new('s', Tui::Modifiers::Ctrl)).should be_true
      app.chat_settings_open_public?.should be_false
      JSON.parse(File.read(config_path))["chat"]["reasoning_effort"].as_s.should eq("minimal")
      transport.requests.should be_empty
    end
  end

  it "renders sanitized settings values and never echoes persisted endpoint userinfo" do
    malicious = %({"enabled":true,"endpoint":"https://user:ui-secret@example.test/v1/chat/completions","model":"explicit-model","key_env":"CHAT_TEST_KEY","max_completion_tokens":256})
    with_chat_provider_ui_app(chat_json: malicious) do |app, _root, _config_path|
      app.chat_settings_action.should be_true
      surface = chat_ui_surface_text(app.render_surface_public)
      surface.should contain("Chat Provider Settings")
      surface.should_not contain("ui-secret")
      surface.should_not contain("user:")
      surface.should contain("https://api.openai.com/v1/chat/completions")
    end
  end

  it "escapes active field bidi controls and routes paste only to the settings field" do
    with_chat_provider_ui_app do |app, _root, _config_path|
      app.chat_panel.composer.text = "keep composer"
      app.chat_settings_action.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)).should be_true
      app.on_capture(Tui::PasteEvent.new("safe\u202Eevil")).should be_true
      surface = chat_ui_surface_text(app.render_surface_public)
      surface.should contain("safe\\u{202e}evil")
      surface.should_not contain("\u202E")
      app.chat_panel.composer.text.should eq("keep composer")
      app.on_capture(Tui::MouseEvent.new(8, 4)).should be_true
      app.chat_panel.composer.text.should eq("keep composer")

      reverse_selection = Adamantine::EditableInput.new("source")
      reverse_selection.select_range(6, 1)
      projected = app.safe_editable_input_public(reverse_selection)
      projected.cursor.should eq(1)
      projected.selection_range.should eq({1, 6})
    end
  end

  it "shows exact multiline send disclosure and requires Y while Enter cancels" do
    transport = ChatProviderUiProbeTransport.new
    with_chat_provider_ui_app(transport) do |app, _root, _config_path|
      app.chat_focus_action.should be_true
      prompt = "first line\nsecond line"
      app.chat_panel.composer.text = prompt
      app.chat_submit_action.should be_true
      app.chat_review_open_public?.should be_true
      surface = chat_ui_surface_text(app.render_surface_public)
      surface.should contain("Review Chat send")
      surface.should contain("Send this prompt and visible history to explicit-model")
      surface.should contain("Destination: https://example.test/v1/chat/completions")
      surface.should contain("Credential: environment variable CHAT_TEST_KEY (value not shown)")
      surface.should contain("first line")
      surface.should contain("second line")

      app.on_capture(Tui::PasteEvent.new("must not paste")).should be_true
      app.on_capture(Tui::MouseEvent.new(6, 5)).should be_true
      app.chat_panel.composer.text.should eq(prompt)
      transport.requests.should be_empty
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.chat_review_open_public?.should be_false
      app.chat_panel.composer.text.should eq(prompt)
      transport.requests.should be_empty

      app.chat_submit_action.should be_true
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      app.chat_review_open_public?.should be_false
      transport.requests.size.should eq(1)
      transport.requests.first.text.should eq(prompt)
    end
  end

  it "refuses approval when the review is too small to disclose its scope" do
    transport = ChatProviderUiProbeTransport.new
    with_chat_provider_ui_app(transport) do |app, _root, _config_path|
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "small terminal draft"
      app.chat_submit_action.should be_true
      app.chat_review_open_public?.should be_true
      app.resize_public(30, 7)
      surface = chat_ui_surface_text(app.render_surface_public(30, 7))
      surface.should contain("Resize to review")
      surface.should_not contain("Y send")
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      app.chat_review_open_public?.should be_true
      transport.requests.should be_empty
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.chat_review_open_public?.should be_false
      app.chat_panel.composer.text.should eq("small terminal draft")
      transport.requests.should be_empty
    end
  end
end
