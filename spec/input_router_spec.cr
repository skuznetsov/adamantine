require "spec"
require "file_utils"
require "crystal_tui"

require "../src/editor/app"

class TestApp < CrystalEditor::App
  def open_command_palette_public
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def command_open? : Bool
    @command_open
  end

  def command_input_text : String
    @command_input
  end

  def command_palette_open? : Bool
    @command_open
  end

  def settings_open? : Bool
    @settings_open
  end

  def settings_selected_index : Int32
    @settings_selected_index
  end

  def context_menu_open? : Bool
    @context_menu_open
  end

  def context_menu_title : String
    @context_menu_title
  end

  def lsp_popup_open? : Bool
    @lsp_popup_open
  end

  def open_fake_lsp_popup : Nil
    open_lsp_popup("Popup", ["line"])
  end

  def open_settings_dialog_public : Nil
    open_settings_dialog
  end

  def key_bindings : CrystalEditor::KeyConfig::ActionMap
    @key_bindings
  end

  def set_key_bindings(bindings : CrystalEditor::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def command_last_escape_ms=(value : Int64) : Int64
    @command_last_escape_ms = value
  end

  def open_context_menu_public : Nil
    open_context_menu(
      "Test",
      [CrystalEditor::LspContextAction.new("noop", "n", -> { nil })]
    )
  end

  def close_context_menu_public : Nil
    close_context_menu
  end

  def open_lsp_popup_public : Nil
    open_lsp_popup("LSP", ["line"])
  end

  def close_lsp_popup_public : Nil
    close_lsp_popup
  end

  def close_settings_dialog_public : Nil
    close_settings_dialog
  end

  def input_mode_stack_snapshot : Array(CrystalEditor::App::InputMode)
    @input_mode_stack.dup
  end
end

def with_temp_workspace(prefix : String = "editor-input-router-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::App do
  it "routes mapped global actions to app handlers" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::F10))
      raise "app action should be handled" unless handled
      raise "settings should open" unless app.settings_open?
    end
  end

  it "keeps command palette active while typing" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_command_palette_public

      raise "command palette should be open" unless app.command_open?
      handled = app.on_capture(Tui::KeyEvent.new('f'))
      raise "command palette input should be handled" unless handled
      raise "command palette should stay open" unless app.command_open?
      raise "character should go into palette input" unless app.command_input_text == ":f"
    end
  end

  it "handles settings-specific keys before global bindings" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F10))
      raise "settings should be open" unless app.settings_open?

      handled = app.on_capture(Tui::KeyEvent.new('j'))
      raise "settings navigation should be handled" unless handled
      raise "settings selection should move down" unless app.settings_selected_index == 1
    end
  end

  it "opens quick actions and closes it with escape" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      handled_open = app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter, Tui::Modifiers::Shift))
      raise "quick actions should be handled" unless handled_open
      raise "context menu should be open" unless app.context_menu_open?
      raise "quick actions title expected" unless app.context_menu_title == "Quick Actions"

      handled_close = app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      raise "close context key should be handled" unless handled_close
      raise "context menu should close" if app.context_menu_open?
    end
  end

  it "keeps command palette above global handlers" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_command_palette_public
      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::F10))

      raise "command palette input should be handled" unless handled
      raise "command palette must stay open" unless app.command_palette_open?
      raise "settings must stay closed while palette is active" if app.settings_open?
    end
  end

  it "routes context menu actions before global handlers" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter, Tui::Modifiers::Shift))

      raise "context menu should be open" unless app.context_menu_open?

      handled = app.on_capture(Tui::KeyEvent.new('1'))
      raise "context menu numeric action should be handled" unless handled
      raise "context menu should close after menu action" if app.context_menu_open?
      raise "context action should open command palette" unless app.command_palette_open?
    end
  end

  it "routes popup close action before global handlers" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_fake_lsp_popup

      raise "lsp popup should be open" unless app.lsp_popup_open?
      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))

      raise "escape should be handled by popup" unless handled
      raise "popup should close" if app.lsp_popup_open?
    end
  end

  it "prefers the first matching global action when keys conflict" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      bindings = app.key_bindings
      bindings["app.quick_actions"] = ["f12"]
      bindings["lsp.goto_definition"] = ["f12"]
      app.set_key_bindings(bindings)

      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::F12))
      raise "f12 should be handled" unless handled
      raise "quick actions should win over goto definition" unless app.context_menu_open?
      raise "wrong context menu title" unless app.context_menu_title == "Quick Actions"
    end
  end

  it "opens command palette on double escape within configured window" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.command_last_escape_ms = Time.utc.to_unix_ms - 100
      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      raise "double escape should be handled" unless handled
      raise "command palette should open" unless app.command_open?
    end
  end

  it "keeps command palette closed when escape gap is too long" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.command_last_escape_ms = Time.utc.to_unix_ms - 1000
      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      raise "single or stale escape should not open palette" if app.command_open?
      raise "stale escape should be forwarded" if handled
    end
  end

  it "restores previous mode after nested overlay close" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_settings_dialog_public
      raise "settings should be active mode" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings]

      app.open_context_menu_public
      raise "context menu should be nested on settings mode" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings, CrystalEditor::App::InputMode::ContextMenu]

      app.close_context_menu_public
      raise "settings should be restored after context close" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings]

      app.open_lsp_popup_public
      raise "lsp popup should be nested on settings mode" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings, CrystalEditor::App::InputMode::LspPopup]

      app.close_lsp_popup_public
      raise "settings should still be active after popup close" unless app.input_mode_stack_snapshot == [CrystalEditor::App::InputMode::Settings]

      app.close_settings_dialog_public
      raise "input modes should clear after settings close" unless app.input_mode_stack_snapshot.empty?
    end
  end
end
