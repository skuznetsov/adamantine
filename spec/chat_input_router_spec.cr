require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private class ChatInputRouterSpecApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def editor_public : Tui::TextEditor
    current_editor || raise "expected active editor"
  end

  def set_bindings_public(bindings : Adamantine::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def open_palette_public : Nil
    open_command_palette("")
  end

  def palette_open? : Bool
    @command_palette.open
  end

  def body_split_y_public : Int32
    @body_split.splitter_y
  end

  def body_split_ratio_public : Float64
    @body_split.ratio
  end

  def body_split_public : Adamantine::DebugStatusSplitContainer
    @body_split
  end

  def dispatch_public(event : Tui::Event) : Bool
    handle_event(event)
  end

  def layout_public(width : Int32 = 80, height : Int32 = 24) : Nil
    mount_headless(width, height)
    render(Tui::Buffer.new(width, height), Tui::Rect.new(0, 0, width, height))
  end
end

private def with_chat_input_workspace(&)
  root = Path.new(Dir.tempdir, "chat-input-router-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

describe "Adamantine Chat input routing" do
  it "routes Ctrl+X and Ctrl+Z to the composer, never the editor under it" do
    with_chat_input_workspace do |root|
      path = root / "sample.cr"
      File.write(path, "document text\n")
      app = ChatInputRouterSpecApp.new(
        project_root: root,
        lsp_command: "",
        session_enabled: false,
        clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new
      )
      app.open_file_public(path).should be_true
      app.layout_public

      editor = app.editor_public
      editor.select_all
      original_document = editor.text
      app.chat_focus_action.should be_true

      composer = app.chat_panel.composer
      composer.insert_text("chat draft")
      composer.select_all
      ctrl_x = Tui::KeyEvent.new('x', Tui::Modifiers::Ctrl)
      ctrl_z = Tui::KeyEvent.new('z', Tui::Modifiers::Ctrl)

      app.on_capture(ctrl_x).should be_true
      composer.text.should be_empty
      editor.text.should eq(original_document)

      app.on_capture(ctrl_z).should be_true
      composer.text.should eq("chat draft")
      editor.text.should eq(original_document)
    end
  end

  it "keeps remapped panel actions available while the editor owns focus" do
    with_chat_input_workspace do |root|
      path = root / "sample.cr"
      File.write(path, "document text\n")
      app = ChatInputRouterSpecApp.new(
        project_root: root,
        lsp_command: "",
        session_enabled: false
      )
      app.open_file_public(path).should be_true
      app.layout_public
      app.chat_panel.visible?.should be_true

      bindings = Adamantine::KeyConfig.defaults
      bindings["chat.toggle_panel"] = ["ctrl+shift+t"]
      app.set_bindings_public(bindings)
      app.editor_public.focus

      event = Tui::KeyEvent.new('t', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift)
      app.on_capture(event).should be_true
      app.chat_panel.visible?.should be_false

      app.on_capture(event).should be_true
      app.chat_panel.visible?.should be_true
    end
  end

  it "keeps Chat paste behind an active modal overlay" do
    with_chat_input_workspace do |root|
      path = root / "sample.cr"
      File.write(path, "document text\n")
      app = ChatInputRouterSpecApp.new(
        project_root: root,
        lsp_command: "",
        session_enabled: false
      )
      app.open_file_public(path).should be_true
      app.layout_public
      app.chat_focus_action.should be_true
      app.chat_panel.composer.insert_text("before")
      app.open_palette_public
      app.palette_open?.should be_true

      app.on_capture(Tui::PasteEvent.new("must not paste")).should be_true
      app.chat_panel.composer.text.should eq("before")
      app.editor_public.text.should eq("document text\n")
    end
  end

  it "inserts Tab into the bounded Chat composer instead of invoking editor indentation" do
    with_chat_input_workspace do |root|
      path = root / "sample.cr"
      File.write(path, "document text\n")
      app = ChatInputRouterSpecApp.new(
        project_root: root,
        lsp_command: "",
        session_enabled: false
      )
      app.open_file_public(path).should be_true
      app.layout_public
      app.chat_focus_action.should be_true
      document_text = app.editor_public.text

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      app.chat_panel.composer.text.should eq("\t")
      app.editor_public.text.should eq(document_text)
    end
  end

  it "consumes Undo and Redo while the Log view owns Chat-panel focus" do
    with_chat_input_workspace do |root|
      path = root / "sample.cr"
      File.write(path, "document text\n")
      app = ChatInputRouterSpecApp.new(
        project_root: root,
        lsp_command: "",
        session_enabled: false
      )
      app.open_file_public(path).should be_true
      app.layout_public
      app.chat_focus_action.should be_true

      composer = app.chat_panel.composer
      composer.insert_text("chat draft")
      app.chat_toggle_view_action.should be_true
      app.chat_panel.view.log?.should be_true

      app.on_capture(Tui::KeyEvent.new('z', Tui::Modifiers::Ctrl)).should be_true
      app.on_capture(Tui::KeyEvent.new('y', Tui::Modifiers::Ctrl)).should be_true
      composer.text.should eq("chat draft")
      app.editor_public.text.should eq("document text\n")
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "drags the full-width bottom divider at the PTY smoke coordinates" do
    with_chat_input_workspace do |root|
      path = root / "main.cr"
      File.write(path, "puts \"disk source\"\n")
      app = ChatInputRouterSpecApp.new(
        project_root: root,
        lsp_command: "",
        session_enabled: false
      )
      app.open_file_public(path).should be_true
      editor = app.editor_public
      editor.insert_text("CHAT_UNSAVED_DRAG_MARKER\n")
      app.set_bindings_public(Adamantine::KeyConfig.defaults)
      app.layout_public(112, 30)

      # Match the real workflow before the drag: a dirty editor remains open,
      # and F1 discovery selects Focus Chat before the pointer reaches the
      # full-width outer divider.
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::F1)).should be_true
      "Focus Chat".each_char do |char|
        app.dispatch_public(Tui::KeyEvent.new(char)).should be_true
      end
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.palette_open?.should be_false
      app.chat_panel.composer_focused?.should be_true
      editor.text.should contain("CHAT_UNSAVED_DRAG_MARKER")

      app.body_split_y_public.should eq(22)
      ratio_before = app.body_split_ratio_public

      parser = Tui::InputParser.new
      press = parser.feed("\e[<0;57;23M").first.as(Tui::MouseEvent)
      drag = parser.feed("\e[<32;57;15M").first.as(Tui::MouseEvent)
      release = parser.feed("\e[<0;57;15m").first.as(Tui::MouseEvent)
      {press.x, press.y, press.action}.should eq({56, 22, Tui::MouseAction::Press})
      {drag.x, drag.y, drag.action}.should eq({56, 14, Tui::MouseAction::Drag})
      {release.x, release.y, release.action}.should eq({56, 14, Tui::MouseAction::Release})

      app.dispatch_public(press).should be_true
      Tui::Widget.mouse_capture.should eq(app.body_split_public)
      app.dispatch_public(drag).should be_true
      app.body_split_ratio_public.should be < ratio_before
      app.dispatch_public(release).should be_true
      Tui::Widget.mouse_capture.should be_nil

      app.render(Tui::Buffer.new(112, 30), Tui::Rect.new(0, 0, 112, 30))
      app.body_split_y_public.should eq(14)
    ensure
      Tui::Widget.mouse_capture = nil
      app.try(&.quit(force: true))
    end
  end
end
