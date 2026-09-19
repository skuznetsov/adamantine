require "spec"
require "file_utils"
require "json"

require "../src/adamantine/app"

private class RefactorUiTestClient < Adamantine::Lsp::Client
  getter rename_calls = [] of Tuple(String, Int32, Int32, String)
  property rename_result : JSON::Any? = nil
  property block_rename : Bool = false
  getter rename_entered = Channel(Nil).new(1)
  getter rename_release = Channel(Nil).new(1)
  getter quick_fix_calls = [] of Tuple(String, Int32, Int32)
  property quick_fix_actions : Array(JSON::Any) = [] of JSON::Any
  property block_quick_fix : Bool = false
  getter quick_fix_entered = Channel(Nil).new(1)
  getter quick_fix_release = Channel(Nil).new(1)
  property rename_available : Bool = true
  property quick_fix_available : Bool = true

  def initialize(root : Path)
    super("", root)
    self.connected = true
    self.server_capabilities = JSON.parse(%({"renameProvider": true, "codeActionProvider": true}))
  end

  def rename_supported? : Bool
    @rename_available
  end

  def rename(uri : String, line : Int32, character : Int32, new_name : String) : JSON::Any?
    @rename_calls << {uri, line, character, new_name}
    if @block_rename
      @rename_entered.send(nil)
      @rename_release.receive
    end
    @rename_result
  end

  def quick_fix_supported? : Bool
    @quick_fix_available
  end

  def quick_fix(uri : String, line : Int32, character : Int32) : Array(JSON::Any)
    @quick_fix_calls << {uri, line, character}
    if @block_quick_fix
      @quick_fix_entered.send(nil)
      @quick_fix_release.receive
    end
    @quick_fix_actions
  end
end

private class RefactorUiTestApp < Adamantine::App
  def open_public(path : Path) : Bool
    open_file(path)
  end

  def set_client_public(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def key_bindings_public=(bindings : Adamantine::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def execute_command_public(command : String) : Nil
    execute_command(command)
  end

  def dispatch_public(event : Tui::Event) : Nil
    current_editor.not_nil!.on_event(event) unless on_capture(event)
  end

  def editor_public : Adamantine::EditingTextEditor
    current_editor.as(Adamantine::EditingTextEditor)
  end

  def uri_public : String
    current_buffer.not_nil!.uri
  end

  def popup_open_public? : Bool
    @lsp_popup.open
  end

  def popup_title_public : String
    @lsp_popup.title
  end

  def popup_lines_public : Array(String)
    @lsp_popup.lines
  end

  def quick_fix_open_public? : Bool
    @lsp_popup.quick_fix_open?
  end

  def edit_preview_open_public? : Bool
    @lsp_popup.edit_preview_open?
  end

  def rename_preview_title_public : String
    @lsp_popup.refactor_title
  end

  def render_popup_public(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
    @lsp_popup.overlay.not_nil!.call(buffer, clip)
  end

  def wait_for_action_public(timeout_span : Time::Span = 2.seconds) : Nil
    deadline = Time.instant + timeout_span
    while @lsp_action_running
      raise "timed out waiting for refactor action" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end
end

private def with_refactor_ui_app(&)
  root = Path.new(Dir.tempdir, "adamantine-refactor-ui-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = root / "sample.cr"
  File.write(path, "old = old\n")
  app = RefactorUiTestApp.new(project_root: root, lsp_command: "")
  app.open_public(path).should be_true
  yield app, root
ensure
  app.try &.shutdown_lsp
  FileUtils.rm_rf(root) if root
end

private def text_edit(start_character : Int32, end_character : Int32, new_text : String) : JSON::Any
  JSON.parse({
    "range" => {
      "start" => {"line" => 0, "character" => start_character},
      "end"   => {"line" => 0, "character" => end_character},
    },
    "newText" => new_text,
  }.to_json)
end

private def rename_changes(uri : String, replacement : String = "fresh", foreign : Bool = false) : JSON::Any
  edits = [text_edit(0, 3, replacement), text_edit(6, 9, replacement)]
  changes = {uri => edits}
  changes["#{uri}.foreign"] = [text_edit(0, 0, "forbidden")] if foreign
  JSON.parse({"changes" => changes}.to_json)
end

private def quick_fix_action(uri : String, title : String = "Use safe name", replacement : String = "safe") : JSON::Any
  edits = [text_edit(0, 3, replacement), text_edit(6, 9, replacement)]
  JSON.parse({
    "title" => title,
    "kind"  => "quickfix",
    "edit"  => {
      "documentChanges" => [{
        "textDocument" => {"uri" => uri, "version" => nil},
        "edits"        => edits,
      }],
    },
  }.to_json)
end

describe "current-document refactor UI" do
  it "dispatches :rename NAME through the asynchronous LSP action path" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      app.set_client_public(client)
      client.rename_result = rename_changes(app.uri_public, "fresh")

      app.execute_command_public(":rename renamed")
      app.wait_for_action_public

      client.rename_calls.size.should eq(1)
      client.rename_calls.first[3].should eq("renamed")
    end
  end

  it "keeps rename as a hard preview until Enter and applies one undoable batch" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      app.set_client_public(client)
      client.rename_result = rename_changes(app.uri_public, "fresh")

      app.execute_command_public(":rename fresh")
      app.wait_for_action_public
      app.edit_preview_open_public?.should be_true
      app.rename_preview_title_public.should contain("Enter apply")
      app.editor_public.text.should eq("old = old\n")

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab))
      app.editor_public.text.should eq("old = old\n")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("fresh = fresh\n")
      app.editor_public.can_undo?.should be_true
      app.editor_public.undo.should be_true
      app.editor_public.text.should eq("old = old\n")
      app.editor_public.can_undo?.should be_false
    end
  end

  it "cancels rename without changing text or history and rejects a foreign URI batch" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      app.set_client_public(client)
      client.rename_result = rename_changes(app.uri_public, "fresh")

      app.execute_command_public(":rename fresh")
      app.wait_for_action_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.editor_public.text.should eq("old = old\n")
      app.editor_public.can_undo?.should be_false

      client.rename_result = rename_changes(app.uri_public, "foreign", true)
      app.execute_command_public(":rename foreign")
      app.wait_for_action_public
      app.popup_open_public?.should be_false
      app.editor_public.text.should eq("old = old\n")
      app.editor_public.can_undo?.should be_false
    end
  end

  it "uses Unicode wire coordinates while preserving the captured editor columns" do
    root = Path.new(Dir.tempdir, "adamantine-refactor-unicode-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    path = root / "sample.cr"
    File.write(path, "😀old = old\n")
    app = RefactorUiTestApp.new(project_root: root, lsp_command: "")
    app.open_public(path).should be_true
    client = RefactorUiTestClient.new(root)
    app.set_client_public(client)
    client.rename_result = JSON.parse({
      "changes" => {app.uri_public => [text_edit(2, 5, "new"), text_edit(8, 11, "new")]},
    }.to_json)
    app.editor_public.set_cursor(0, 1)

    app.execute_command_public(":rename new")
    app.wait_for_action_public
    client.rename_calls.first[2].should eq(2)
    app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
    app.editor_public.text.should eq("😀new = new\n")
  ensure
    app.try &.shutdown_lsp
    FileUtils.rm_rf(root) if root
  end

  it "keeps quick fix picker and preview modal, including Tab isolation" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      app.set_client_public(client)
      client.quick_fix_actions = [quick_fix_action(app.uri_public)]

      app.execute_command_public(":quickfix")
      app.wait_for_action_public
      app.quick_fix_open_public?.should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.edit_preview_open_public?.should be_true
      app.editor_public.text.should eq("old = old\n")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab))
      app.editor_public.text.should eq("old = old\n")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("safe = safe\n")
      app.editor_public.undo.should be_true
      app.editor_public.text.should eq("old = old\n")
      app.editor_public.can_undo?.should be_false
    end
  end

  it "fails closed when capabilities are absent or an action contains a command" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      client.rename_available = false
      client.quick_fix_available = false
      app.set_client_public(client)

      app.execute_command_public(":rename fresh")
      client.rename_calls.should be_empty
      app.execute_command_public(":quickfix")
      client.quick_fix_calls.should be_empty

      client.quick_fix_available = true
      client.quick_fix_actions = [JSON.parse({
        "title"   => "Unsafe command",
        "kind"    => "quickfix",
        "edit"    => {"changes" => {app.uri_public => [text_edit(0, 3, "safe")]}},
        "command" => {"command" => "workspace/executeCommand"},
      }.to_json)]
      app.execute_command_public(":quickfix")
      app.wait_for_action_public
      app.popup_open_public?.should be_false
      app.editor_public.text.should eq("old = old\n")
      app.editor_public.can_undo?.should be_false
    end
  end

  it "keeps quick-fix omission counts visible and marks clipped long titles" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      app.set_client_public(client)
      client.quick_fix_actions = Array(JSON::Any).new(101) do |index|
        quick_fix_action(app.uri_public, "Fix #{index} " + ("x" * 180))
      end

      app.execute_command_public(":quickfix")
      app.wait_for_action_public
      app.popup_title_public.should contain("1 unavailable/omitted")
      app.popup_lines_public.size.should eq(101)

      buffer = Tui::Buffer.new(32, 10)
      app.editor_public.rect = Tui::Rect.new(0, 0, 32, 10)
      app.render_popup_public(buffer, Tui::Rect.new(0, 0, 32, 10))
      rendered = (0...buffer.height).map do |y|
        (0...buffer.width).map { |x| buffer.get(x, y).glyph }.join
      end.join("\n")
      rendered.includes?("…").should be_true
      rendered.should contain("1 unavailable/omitted")
    end
  end

  it "renders the quick-fix omission count in a wide popup with short rows" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      app.set_client_public(client)
      client.quick_fix_actions = Array(JSON::Any).new(101) do |index|
        quick_fix_action(app.uri_public, "Fix #{index}")
      end

      app.execute_command_public(":quickfix")
      app.wait_for_action_public

      buffer = Tui::Buffer.new(100, 10)
      app.editor_public.rect = Tui::Rect.new(0, 0, 100, 10)
      app.render_popup_public(buffer, Tui::Rect.new(0, 0, 100, 10))
      rendered = (0...buffer.height).map do |y|
        (0...buffer.width).map { |x| buffer.get(x, y).glyph }.join
      end.join("\n")
      rendered.should contain("1 unavailable/omitted")
    end
  end

  it "reserves raw Enter and Escape when completion navigation is remapped" do
    with_refactor_ui_app do |app, root|
      bindings = Adamantine::KeyConfig.defaults
      bindings["lsp.completion_up"] = ["enter"]
      bindings["lsp.completion_down"] = ["escape"]
      app.key_bindings_public = bindings

      client = RefactorUiTestClient.new(root)
      client.rename_result = rename_changes(app.uri_public, "fresh")
      app.set_client_public(client)

      app.execute_command_public(":rename fresh")
      app.wait_for_action_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("fresh = fresh\n")
      app.popup_open_public?.should be_false
      app.editor_public.undo.should be_true

      app.execute_command_public(":rename fresh")
      app.wait_for_action_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.editor_public.text.should eq("old = old\n")
      app.popup_open_public?.should be_false
    end
  end

  it "drops a rename response that arrives after the captured document changes" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      client.block_rename = true
      client.rename_result = rename_changes(app.uri_public, "fresh")
      app.set_client_public(client)

      app.execute_command_public(":rename fresh")
      client.rename_entered.receive
      app.editor_public.insert_text("# changed\n")
      client.rename_release.send(nil)
      app.wait_for_action_public

      app.popup_open_public?.should be_false
      app.editor_public.text.should contain("# changed")
      app.editor_public.text.should contain("old = old")
    end
  end

  it "drops a quick-fix response that arrives after the captured document changes" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      client.block_quick_fix = true
      client.quick_fix_actions = [quick_fix_action(app.uri_public)]
      app.set_client_public(client)

      app.execute_command_public(":quickfix")
      client.quick_fix_entered.receive
      app.editor_public.insert_text("# changed\n")
      client.quick_fix_release.send(nil)
      app.wait_for_action_public

      app.popup_open_public?.should be_false
      app.editor_public.text.should contain("# changed")
      app.editor_public.text.should contain("old = old")
    end
  end

  it "rejects a rename preview after the editor version changes" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      client.rename_result = rename_changes(app.uri_public, "fresh")
      app.set_client_public(client)

      app.execute_command_public(":rename fresh")
      app.wait_for_action_public
      app.editor_public.insert_text("# changed\n")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))

      app.popup_open_public?.should be_false
      app.editor_public.text.should contain("# changed")
      app.editor_public.text.should contain("old = old")
    end
  end

  it "rejects a quick-fix preview after the editor version changes" do
    with_refactor_ui_app do |app, root|
      client = RefactorUiTestClient.new(root)
      client.quick_fix_actions = [quick_fix_action(app.uri_public)]
      app.set_client_public(client)

      app.execute_command_public(":quickfix")
      app.wait_for_action_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.edit_preview_open_public?.should be_true
      app.editor_public.insert_text("# changed\n")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))

      app.popup_open_public?.should be_false
      app.editor_public.text.should contain("# changed")
      app.editor_public.text.should contain("old = old")
    end
  end
end
