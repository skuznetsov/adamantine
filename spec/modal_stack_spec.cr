require "spec"
require "file_utils"
require "crystal_tui"

require "../src/editor/app"

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

  def input_mode_stack_snapshot : Array(CrystalEditor::App::InputMode)
    super()
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
end
