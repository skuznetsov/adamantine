require "spec"
require "file_utils"
require "../src/adamantine/app"

private class TemplateIntegrationApp < Adamantine::App
  def open_public(path : Path) : Bool
    open_file(path)
  end

  def editor_public : Tui::TextEditor
    current_editor.not_nil!
  end

  def run_command_public(command : String) : Nil
    open_command_palette("")
    command.each_char { |char| on_capture(Tui::KeyEvent.new(char)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def dispatch_public(event : Tui::KeyEvent) : Nil
    editor_public.on_event(event) unless on_capture(event)
  end

  def template_menu_open? : Bool
    @context_menu.open && @context_menu.title == "Templates"
  end

  def template_menu_labels : Array(String)
    @context_menu.actions.map(&.label)
  end

  def template_session_active? : Bool
    @template_session.try(&.active?) || false
  end

  def select_template_public(trigger : String) : Nil
    index = @context_menu.actions.index { |action| action.label.includes?(trigger) }
    raise "missing template #{trigger}" unless index
    @context_menu.index = index.not_nil!
    dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
  end
end

private def with_template_integration_app(config : String? = nil, content : String = "", &)
  root = Path.new(Dir.tempdir, "adamantine-template-integration-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  source = root / "sample.cr"
  File.write(source, content)
  keymap = root / "keymap.json"
  File.write(keymap, "{}")
  if config
    Dir.mkdir_p(root / ".adamantine")
    File.write(root / ".adamantine" / "templates.json", config)
  end
  app = TemplateIntegrationApp.new(project_root: root, lsp_command: "", keymap_path: keymap.to_s, session_enabled: false)
  app.open_public(source).should be_true
  yield app
ensure
  FileUtils.rm_rf(root) if root
end

describe "editor templates" do
  it "opens the picker from the F1 action search" do
    with_template_integration_app do |app|
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1)).should be_true
      "insert template".each_char { |char| app.on_capture(Tui::KeyEvent.new(char)) }
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.template_menu_open?.should be_true
    end
  end

  it "opens an explicit picker without LSP and inserts a selected Crystal template" do
    with_template_integration_app do |app|
      app.run_command_public(":template")
      app.template_menu_open?.should be_true
      app.template_menu_labels.any?(&.includes?("def")).should be_true

      app.select_template_public("def")
      app.template_menu_open?.should be_false
      app.editor_public.text.should start_with("def ")
      app.editor_public.undo.should be_true
      app.editor_public.text.should eq("")
    end
  end

  it "does not insert after the cursor moves while the picker is open" do
    with_template_integration_app(content: "unchanged") do |app|
      app.editor_public.set_cursor(0, 0)
      app.run_command_public(":template")
      app.editor_public.set_cursor(0, 9)
      app.select_template_public("def")
      app.editor_public.text.should eq("unchanged")
    end
  end

  it "replaces an explicitly selected trigger as one undoable edit" do
    with_template_integration_app do |app|
      app.editor_public.insert_text("def")
      app.run_command_public(":template def")
      app.editor_public.text.should start_with("def name(args)")
      app.editor_public.undo.should be_true
      app.editor_public.text.should eq("def")
    end
  end

  it "navigates editable fields with Tab and Shift+Tab, then leaves text on Escape" do
    with_template_integration_app do |app|
      app.run_command_public(":template def")
      app.template_session_active?.should be_true
      app.editor_public.insert_text("run")
      app.editor_public.text.should start_with("def run(args)")

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab))
      app.editor_public.insert_text("x")
      app.editor_public.text.should start_with("def run(x)")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift))
      app.editor_public.cursor_line.should eq(0)
      app.editor_public.cursor_col.should eq(7)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.template_session_active?.should be_false
      app.editor_public.text.should contain("def run(x)")
    end
  end

  it "indents multiline templates without moving Unicode field coordinates" do
    with_template_integration_app(content: "  ") do |app|
      app.editor_public.set_cursor(0, 2)
      app.run_command_public(":template def")
      app.editor_public.text.should eq("  def name(args)\n    \n  end")
      app.editor_public.cursor_line.should eq(0)
      app.editor_public.cursor_col.should eq(10)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab))
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab))
      app.editor_public.cursor_line.should eq(1)
      app.editor_public.cursor_col.should eq(4)
    end
  end

  it "loads a project template and keeps its expansion independent of LSP" do
    config = %({"version":1,"templates":[{"trigger":"fn","body":"λ${1:name}($0)","label":"Unicode function","languages":["crystal"]}]})
    with_template_integration_app(config) do |app|
      app.run_command_public(":template")
      app.template_menu_labels.any?(&.includes?("fn")).should be_true
      app.select_template_public("fn")
      app.editor_public.text.should eq("λname()")
      app.editor_public.cursor_col.should eq(5)
    end
  end

  it "does not pass picker paste to the underlying editor" do
    with_template_integration_app do |app|
      app.run_command_public(":template")
      app.on_capture(Tui::PasteEvent.new("unexpected"))
      app.editor_public.text.should eq("")
    end
  end

  it "does not remove a trigger suffix from inside an existing identifier" do
    with_template_integration_app(content: "abcdef") do |app|
      app.editor_public.set_cursor(0, 6)
      app.run_command_public(":template def")
      app.editor_public.text.should start_with("abcdefdef name")
    end
  end

  it "uses a valid project override and retains built-ins if another entry is invalid" do
    config = %({"version":1,"templates":[{"trigger":"def","body":"project ${1:name}$0","languages":["crystal"]},{"trigger":"bad","body":"$TM_FILENAME"}]})
    with_template_integration_app(config) do |app|
      app.run_command_public(":template")
      app.template_menu_labels.any?(&.includes?("class")).should be_true
      app.select_template_public("def")
      app.editor_public.text.should eq("project name")
    end
  end

  it "preserves the source file's CRLF policy while navigating a template" do
    with_template_integration_app(content: "head\r\n  ") do |app|
      app.editor_public.set_cursor(1, 2)
      app.run_command_public(":template def")
      app.editor_public.text.should contain("head\r\n  def name(args)\r\n    \r\n  end")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab))
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab))
      app.editor_public.cursor_line.should eq(2)
      app.editor_public.cursor_col.should eq(4)
    end
  end

  it "fails closed if the target buffer changes before menu acceptance" do
    with_template_integration_app do |app|
      app.run_command_public(":template")
      other = app.editor_public
      other.insert_text("new revision")
      app.select_template_public("def")
      other.text.should eq("new revision")
    end
  end
end
