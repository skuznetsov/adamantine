require "spec"
require "file_utils"
require "crystal_tui"

require "../src/editor/app"

def file_uri(path : Path) : String
  "file://#{path.expand.to_s.gsub(" ", "%20")}".gsub("\\", "/")
end

def with_temp_workspace(prefix : String = "editor-settings-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

class TestApp < CrystalEditor::App
  def open_file_public(path : String | Path, line : Int32? = nil, col : Int32? = nil)
    open_file(Path.new(path), line, col)
  end

  def begin_rebind_for_key(action : String) : Bool
    open_settings_dialog unless @settings.open

    key_action = "key:#{action}"
    index = @settings.actions.index(key_action)
    return false unless index

    set_settings_selection(index)
    execute_selected_settings_action
  end

  def capture(event : Tui::KeyEvent) : Bool
    handle_settings_capture_input(event)
  end

  def confirm(event : Tui::KeyEvent) : Bool
    handle_settings_confirm_input(event)
  end

  def settings_mode : SettingsMode
    @settings.mode
  end

  def conflicting_action : String?
    @settings.conflicting_action
  end

  def bindings(action : String) : Array(String)
    @key_bindings[action]? || [] of String
  end

  def close_settings : Nil
    close_settings_dialog
  end

  def back_history : Array(CrystalEditor::NavigationLocation)
    @document_session.navigation_history
  end

  def forward_history : Array(CrystalEditor::NavigationLocation)
    @document_session.navigation_forward_history
  end

  def active_uri
    current_buffer.try(&.uri)
  end

  def cursor : Tuple(Int32, Int32)
    editor = current_editor
    raise "expected active editor" if editor.nil?
    {editor.cursor_line, editor.cursor_col}
  end
end

describe CrystalEditor::App do
  it "prompts for conflict confirmation when a new binding is already in use" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"
      app.capture(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))

      raise "expected confirm overwrite mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::ConfirmOverwrite
      raise "wrong conflicting action" unless app.conflicting_action == "app.close_tab"

      app.confirm(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "confirm should return to browse mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::Browse
      raise "app.save must be rebound" unless app.bindings("app.save") == ["ctrl+w"]
      raise "app.close_tab binding must be removed" unless app.bindings("app.close_tab").empty?
    end
  end

  it "keeps old bindings when conflict is cancelled" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"
      app.capture(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))
      raise "expected confirm overwrite mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::ConfirmOverwrite

      app.confirm(Tui::KeyEvent.new('n'))

      raise "cancel should return to browse mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::Browse
      raise "app.save must stay on default binding" unless app.bindings("app.save") == ["ctrl+s"]
      raise "app.close_tab must stay bound" unless app.bindings("app.close_tab") == ["ctrl+w"]
      raise "no unintended conflict action" unless app.conflicting_action.nil?
    end
  end

  it "assigns new binding directly when there is no conflict" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"
      app.capture(Tui::KeyEvent.new('e', Tui::Modifiers::Ctrl))

      raise "expected browse mode after successful remap" unless app.settings_mode == CrystalEditor::App::SettingsMode::Browse
      raise "app.save must be rebound" unless app.bindings("app.save") == ["ctrl+e"]
      raise "app.close_tab should keep existing binding" unless app.bindings("app.close_tab") == ["ctrl+w"]
    end
  end

  it "uses remapped jump back binding" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      File.write(file_a, "alpha\n")
      File.write(file_b, "beta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.back_history << CrystalEditor::NavigationLocation.new(file_uri(file_a), 0, 0)

      app.begin_rebind_for_key("app.jump_back") || raise "failed to start rebinding app.jump_back"
      app.capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))

      handled = app.on_capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))
      raise "remapped jump_back should be handled" unless handled
      raise "jump_back should switch to previous location" unless app.active_uri == file_uri(file_a)
      raise "jump_back should move cursor to stored location" unless app.cursor == {0, 0}
      raise "forward history should be populated" unless app.forward_history.any?
    end
  end

  it "uses remapped jump forward binding" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      File.write(file_a, "alpha\n")
      File.write(file_b, "beta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.open_file_public(file_a)
      app.forward_history << CrystalEditor::NavigationLocation.new(file_uri(file_b), 0, 0)

      app.begin_rebind_for_key("app.jump_forward") || raise "failed to start rebinding app.jump_forward"
      app.capture(Tui::KeyEvent.new('k', Tui::Modifiers::Ctrl))

      handled = app.on_capture(Tui::KeyEvent.new('k', Tui::Modifiers::Ctrl))
      raise "remapped jump_forward should be handled" unless handled
      raise "jump_forward should switch to stored location" unless app.active_uri == file_uri(file_b)
      raise "jump_forward should move cursor to stored location" unless app.cursor == {0, 0}
      raise "forward history should be consumed" unless app.forward_history.empty?
      raise "back history should include previous cursor" unless app.back_history.last? == CrystalEditor::NavigationLocation.new(file_uri(file_a), 0, 0)
    end
  end

  it "uses remapped close tab binding" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      File.write(file_a, "first\n")
      File.write(file_b, "second\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      raise "expected b active before remap close" unless app.active_uri == file_uri(file_b)

      app.begin_rebind_for_key("app.close_tab") || raise "failed to start rebinding app.close_tab"
      app.capture(Tui::KeyEvent.new('c', Tui::Modifiers::Ctrl))

      handled = app.on_capture(Tui::KeyEvent.new('c', Tui::Modifiers::Ctrl))
      raise "remapped close_tab should be handled" unless handled
      raise "close_tab should keep one tab open" unless app.active_uri == file_uri(file_a)
      raise "close_tab binding should be replaced" unless app.bindings("app.close_tab") == ["ctrl+c"]
    end
  end

  it "supports remapped jump back/forward cycle" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      File.write(file_a, "first\n")
      File.write(file_b, "second\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.back_history << CrystalEditor::NavigationLocation.new(file_uri(file_a), 0, 0)

      app.begin_rebind_for_key("app.jump_back") || raise "failed to start rebinding app.jump_back"
      app.capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))
      app.begin_rebind_for_key("app.jump_forward") || raise "failed to start rebinding app.jump_forward"
      app.capture(Tui::KeyEvent.new('k', Tui::Modifiers::Ctrl))

      raise "jump_back should now be ctrl+j" unless app.bindings("app.jump_back") == ["ctrl+j"]
      raise "jump_forward should now be ctrl+k" unless app.bindings("app.jump_forward") == ["ctrl+k"]

      handled_back = app.on_capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))
      raise "remapped jump_back should be handled" unless handled_back
      raise "jump_back should move to a" unless app.active_uri == file_uri(file_a)
      raise "forward history should contain b" unless app.forward_history == [CrystalEditor::NavigationLocation.new(file_uri(file_b), 0, 0)]

      handled_forward = app.on_capture(Tui::KeyEvent.new('k', Tui::Modifiers::Ctrl))
      raise "remapped jump_forward should be handled" unless handled_forward
      raise "jump_forward should return to b" unless app.active_uri == file_uri(file_b)
      raise "forward history should be cleared after forward" unless app.forward_history.empty?
    end
  end

  it "resolves jump_back and jump_forward binding conflict during remap" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      File.write(file_a, "first\n")
      File.write(file_b, "second\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.back_history << CrystalEditor::NavigationLocation.new(file_uri(file_a), 0, 0)

      app.begin_rebind_for_key("app.jump_back") || raise "failed to start rebinding app.jump_back"
      app.capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))
      raise "jump_back should now be ctrl+j" unless app.bindings("app.jump_back") == ["ctrl+j"]

      app.begin_rebind_for_key("app.jump_forward") || raise "failed to start rebinding app.jump_forward"
      app.capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))

      raise "expected confirm overwrite mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::ConfirmOverwrite
      raise "conflict action should be jump_back" unless app.conflicting_action == "app.jump_back"

      app.confirm(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "jump_forward should take over ctrl+j" unless app.bindings("app.jump_forward") == ["ctrl+j"]
      raise "jump_back should be unbound after overwrite" unless app.bindings("app.jump_back").empty?
      raise "settings should return to browse mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::Browse
    end
  end

  it "resolves command_palette and settings binding conflict during remap" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      File.write(file_a, "hello\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.open_file_public(file_a)
      app.begin_rebind_for_key("app.command_palette") || raise "failed to start rebinding app.command_palette"
      app.capture(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))

      raise "command_palette should now be ctrl+p" unless app.bindings("app.command_palette") == ["ctrl+p"]

      app.begin_rebind_for_key("app.settings") || raise "failed to start rebinding app.settings"
      app.capture(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))

      raise "expected confirm overwrite mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::ConfirmOverwrite
      raise "conflict action should be app.command_palette" unless app.conflicting_action == "app.command_palette"

      app.confirm(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "settings should take over ctrl+p" unless app.bindings("app.settings") == ["ctrl+p"]
      raise "command_palette should be unbound after overwrite" unless app.bindings("app.command_palette").empty?
      raise "settings should return to browse mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::Browse
    end
  end

  it "returns to browse mode on Esc while capturing a binding" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"

      raise "expected capture mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::Capture
      app.capture(Tui::KeyEvent.new(Tui::Key::Escape))

      raise "escape should return to browse mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::Browse
      raise "capture state should not alter app.save" unless app.bindings("app.save") == ["ctrl+s"]
      raise "capture action should be cleared" unless app.conflicting_action.nil?
    end
  end

  it "returns to browse mode on Esc while confirming overwrite" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"
      app.capture(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))

      raise "expected confirm overwrite mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::ConfirmOverwrite
      app.confirm(Tui::KeyEvent.new(Tui::Key::Escape))

      raise "escape should return to browse mode" unless app.settings_mode == CrystalEditor::App::SettingsMode::Browse
      raise "app.save must stay on default binding" unless app.bindings("app.save") == ["ctrl+s"]
      raise "app.close_tab must stay bound" unless app.bindings("app.close_tab") == ["ctrl+w"]
      raise "no unintended conflict action" unless app.conflicting_action.nil?
    end
  end
end
