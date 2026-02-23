require "spec"
require "file_utils"
require "crystal_tui"

require "../src/editor/app"

class FakeLspClientForModalStack < CrystalEditor::Lsp::Client
  property raise_hover = false
  property hover_calls : Int32 = 0

  def initialize
    super("", Path.new(Dir.current), [] of String)
    self.connected = true
  end

  def hover(uri : String, line : Int32, character : Int32) : CrystalEditor::Lsp::Hover?
    @hover_calls += 1
    raise "hover failure" if @raise_hover
    CrystalEditor::Lsp::Hover.new("value")
  end
end

class ModalStackTestApp < CrystalEditor::App
  def open_settings_dialog_public : Nil
    open_settings_dialog
  end

  def open_context_menu_public : Nil
    open_context_menu(
      "Test",
      [CrystalEditor::LspContextAction.new("noop", "n", -> { nil })]
    )
  end

  def open_file_public(path : Path | String, line : Int32? = nil, column : Int32? = nil) : Nil
    open_file(path.is_a?(Path) ? path : Path.new(path), line, column)
  end

  def set_fake_lsp_client(client : CrystalEditor::Lsp::Client) : Nil
    @lsp = client
  end

  def set_cursor(line : Int32, column : Int32) : Nil
    editor = current_editor
    raise "no active editor" unless editor
    editor.set_cursor(line, column)
  end

  def show_hover_hint_public : Nil
    show_hover_hint
  end

  def open_lsp_popup_public : Nil
    open_lsp_popup("Popup", ["line"])
  end

  def open_fake_lsp_popup_public : Nil
    open_lsp_popup("Popup", ["line"])
  end

  def close_context_menu_public : Nil
    close_context_menu
  end

  def close_lsp_popup_public : Nil
    close_lsp_popup
  end

  def close_settings_dialog_public : Nil
    close_settings_dialog
  end

  def open_command_palette_public : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def close_command_palette_public : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def command_open? : Bool
    @command_open
  end

  def command_last_escape_ms : Int64
    @command_last_escape_ms
  end

  def command_last_escape_ms=(value : Int64) : Int64
    @command_last_escape_ms = value
  end

  def settings_open? : Bool
    @settings_open
  end

  def context_menu_open? : Bool
    @context_menu_open
  end

  def lsp_popup_open? : Bool
    @lsp_popup_open
  end

  def key_bindings : CrystalEditor::KeyConfig::ActionMap
    @key_bindings
  end

  def set_key_bindings(bindings : CrystalEditor::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def open_context_menu_public_with_exception_action : Nil
    open_context_menu(
      "Failing",
      [CrystalEditor::LspContextAction.new("raise", "1", -> { raise "menu action failure" })]
    )
  end

  def open_context_menu_public_with_lsp_hover_action : Nil
    open_context_menu(
      "LSP Hover",
      [CrystalEditor::LspContextAction.new("Show hover", "1", -> { show_hover_hint })]
    )
  end

  private def current_editor : Tui::TextEditor?
    super
  end

  def input_mode_stack_snapshot : Array(CrystalEditor::App::InputMode)
    super()
  end
end

class FailingCommandPaletteApp < ModalStackTestApp
  private def execute_command(raw_input : String) : Nil
    raise "command execution failure"
  end
end

def with_temp_workspace(prefix : String = "editor-modal-stack-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::App do
  it "keeps a strict nested modal stack for settings and overlay transitions" do
    with_temp_workspace do |tmp_dir|
      app = ModalStackTestApp.new(project_root: tmp_dir, lsp_command: "")

      app.open_settings_dialog_public
      raise "settings should open" unless app.settings_open?
      raise "expected settings mode only" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings]

      app.open_context_menu_public
      raise "context menu should open" unless app.context_menu_open?
      raise "settings and context menu modes should stack" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings, CrystalEditor::App::InputMode::ContextMenu]

      app.open_lsp_popup_public
      raise "opening popup should replace context menu but keep settings active" unless app.lsp_popup_open?
      raise "context menu should close when popup opens" if app.context_menu_open?
      raise "expected settings + lsp popup stack" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings, CrystalEditor::App::InputMode::LspPopup]

      app.close_lsp_popup_public
      raise "lsp popup should close" if app.lsp_popup_open?
      raise "settings mode should remain active after popup close" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings]

      app.close_settings_dialog_public
      raise "settings should close" if app.settings_open?
      raise "modal stack should clear after settings close" unless app.input_mode_stack_snapshot.empty?
    end
  end

  it "overrides existing modal stack with command palette and does not restore old overlays" do
    with_temp_workspace do |tmp_dir|
      app = ModalStackTestApp.new(project_root: tmp_dir, lsp_command: "")
      bindings = app.key_bindings
      bindings["app.command_palette"] = ["f10"]
      app.set_key_bindings(bindings)

      app.open_settings_dialog_public
      app.open_context_menu_public
      app.open_lsp_popup_public
      raise "precondition: all non-command modals should be active" unless app.settings_open? && app.lsp_popup_open?
      raise "stack should contain base settings + popup" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings, CrystalEditor::App::InputMode::LspPopup]

      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::F10))
      raise "command palette binding should be handled" unless handled
      raise "command palette should open" unless app.command_open?
      raise "previous modal overlays should be closed by command palette" if app.settings_open? || app.context_menu_open? || app.lsp_popup_open?
      raise "stack should switch to command palette only" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::CommandPalette]

      app.close_command_palette_public
      raise "command palette should close" if app.command_open?
      raise "stack should clear after command palette close" unless app.input_mode_stack_snapshot.empty?
    end
  end

  it "restores previous mode when context menu action raises" do
    with_temp_workspace do |tmp_dir|
      app = ModalStackTestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_settings_dialog_public
      raise "settings should open" unless app.settings_open?

      app.open_context_menu_public_with_exception_action
      raise "context menu should open" unless app.context_menu_open?
      raise "context menu should be stacked above settings" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings, CrystalEditor::App::InputMode::ContextMenu]

      raised = false
      begin
        app.on_capture(Tui::KeyEvent.new('1'))
      rescue
        raised = true
      end

      raise "action exception should surface" unless raised
      raise "context menu should close after action failure" if app.context_menu_open?
      raise "settings should remain active after context action failure" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings]
      raise "settings should still be open after action failure" unless app.settings_open?
    end
  end

  it "restores settings and closes popup when failing LSP context action runs while popup is active" do
    with_temp_workspace do |tmp_dir|
      source = Path.new(tmp_dir, "main.cr")
      File.write(source, "def value\n  1\nend\n")

      app = ModalStackTestApp.new(project_root: tmp_dir, lsp_command: "")
      fake = FakeLspClientForModalStack.new
      fake.raise_hover = true
      app.set_fake_lsp_client(fake)
      app.open_file_public(source)
      app.set_cursor(0, 0)

      app.open_settings_dialog_public
      app.open_lsp_popup_public
      raise "precondition: settings and popup should be open" unless app.settings_open? && app.lsp_popup_open?
      raise "precondition: stack should contain settings + popup" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings, CrystalEditor::App::InputMode::LspPopup]

      app.open_context_menu_public_with_lsp_hover_action
      raise "context menu should replace popup" if app.lsp_popup_open?
      raise "context menu should open over settings" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings, CrystalEditor::App::InputMode::ContextMenu]

      raised = false
      begin
        app.on_capture(Tui::KeyEvent.new('1'))
      rescue
        raised = true
      end

      raise "failing LSP action should surface" unless raised
      raise "context menu should be closed after action exception" if app.context_menu_open?
      raise "popup should not be open after failed context action" if app.lsp_popup_open?
      raise "settings mode should remain active after failed context action" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings]
      raise "settings dialog should remain open after failed context action" unless app.settings_open?
      raise "hover callback should be attempted" unless fake.hover_calls == 1
    end
  end

  it "closes command palette and clears mode stack when a command execution fails" do
    with_temp_workspace do |tmp_dir|
      app = FailingCommandPaletteApp.new(project_root: tmp_dir, lsp_command: "")

      app.open_command_palette_public
      app.on_capture(Tui::KeyEvent.new('x'))

      raised = false
      begin
        app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      rescue
        raised = true
      end

      raise "command execution failure should propagate" unless raised
      raise "command palette should close on execution failure" if app.command_open?
      raise "input mode stack should clear after command failure" unless app.input_mode_stack_snapshot.empty?
    end
  end
end
