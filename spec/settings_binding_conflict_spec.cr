require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

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

class TestApp < Adamantine::App
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

  def browse(event : Tui::KeyEvent) : Bool
    handle_settings_browse_input(event)
  end

  def confirm(event : Tui::KeyEvent) : Bool
    if @settings.mode == Adamantine::App::SettingsMode::ConfirmUnbind
      handle_settings_unbind_confirm_input(event)
    else
      handle_settings_confirm_input(event)
    end
  end

  def settings_mode : SettingsMode
    @settings.mode
  end

  def conflicting_action : String?
    @settings.conflicting_action
  end

  def conflicting_actions : Array(String)
    @settings.conflicting_actions
  end

  def settings_open? : Bool
    @settings.open
  end

  def binding_display(action : String) : String
    settings_display_value("key:#{action}")
  end

  def bindings(action : String) : Array(String)
    @key_bindings[action]? || [] of String
  end

  def select_key(action : String) : Bool
    open_settings_dialog unless @settings.open
    key_action = "key:#{action}"
    index = @settings.actions.index(key_action)
    return false unless index
    set_settings_selection(index)
    true
  end

  def set_bindings(action : String, bindings : Array(String)) : Nil
    @key_bindings[action] = bindings
  end

  def close_settings : Nil
    close_settings_dialog
  end

  def back_history : Array(Adamantine::NavigationLocation)
    @document_session.navigation_history
  end

  def forward_history : Array(Adamantine::NavigationLocation)
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

describe Adamantine::App do
  it "prompts for conflict confirmation when a new binding is already in use" do
    with_temp_workspace do |tmp_dir|
      path = (tmp_dir / "keymap.json").to_s
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: path)
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"
      app.capture(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))

      raise "expected confirm overwrite mode" unless app.settings_mode == Adamantine::App::SettingsMode::ConfirmOverwrite
      raise "wrong conflicting action" unless app.conflicting_action == "app.close_tab"

      app.confirm(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "confirm should return to browse mode" unless app.settings_mode == Adamantine::App::SettingsMode::Browse
      raise "app.save must be rebound" unless app.bindings("app.save") == ["ctrl+w"]
      raise "app.close_tab binding must be removed" unless app.bindings("app.close_tab").empty?

      reloaded = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: path)
      raise "reloaded app.save lost the transferred key" unless reloaded.bindings("app.save") == ["ctrl+w"]
      raise "reloaded app.close_tab resurrected its default" unless reloaded.bindings("app.close_tab").empty?
    end
  end

  it "keeps physical Escape as a Settings recovery key" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.select_key("app.save") || raise "failed to open Settings"
      app.set_bindings("app.menu_close", [] of String)

      raise "physical Escape should close Settings" unless app.browse(Tui::KeyEvent.new(Tui::Key::Escape))
      raise "Settings remained open after physical Escape" if app.settings_open?
    end
  end

  it "owns unrelated keys while Settings is open" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.select_key("app.save") || raise "failed to open Settings"

      raise "Settings leaked an unrelated key" unless app.browse(Tui::KeyEvent.new('x'))
      raise "Settings unexpectedly closed" unless app.settings_open?
    end
  end

  it "keeps old bindings when conflict is cancelled" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"
      app.capture(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))
      raise "expected confirm overwrite mode" unless app.settings_mode == Adamantine::App::SettingsMode::ConfirmOverwrite

      app.confirm(Tui::KeyEvent.new('n'))

      raise "cancel should return to browse mode" unless app.settings_mode == Adamantine::App::SettingsMode::Browse
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

      raise "expected browse mode after successful remap" unless app.settings_mode == Adamantine::App::SettingsMode::Browse
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
      app.back_history << Adamantine::NavigationLocation.new(file_uri(file_a), 0, 0)

      app.begin_rebind_for_key("app.jump_back") || raise "failed to start rebinding app.jump_back"
      app.capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))
      app.close_settings

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
      app.forward_history << Adamantine::NavigationLocation.new(file_uri(file_b), 0, 0)

      app.begin_rebind_for_key("app.jump_forward") || raise "failed to start rebinding app.jump_forward"
      app.capture(Tui::KeyEvent.new('k', Tui::Modifiers::Ctrl))
      app.close_settings

      handled = app.on_capture(Tui::KeyEvent.new('k', Tui::Modifiers::Ctrl))
      raise "remapped jump_forward should be handled" unless handled
      raise "jump_forward should switch to stored location" unless app.active_uri == file_uri(file_b)
      raise "jump_forward should move cursor to stored location" unless app.cursor == {0, 0}
      raise "forward history should be consumed" unless app.forward_history.empty?
      raise "back history should include previous cursor" unless app.back_history.last? == Adamantine::NavigationLocation.new(file_uri(file_a), 0, 0)
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
      app.conflicting_action.should eq "app.copy"
      app.confirm(Tui::KeyEvent.new(Tui::Key::Enter))
      app.bindings("app.copy").should be_empty
      app.close_settings

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
      app.back_history << Adamantine::NavigationLocation.new(file_uri(file_a), 0, 0)

      app.begin_rebind_for_key("app.jump_back") || raise "failed to start rebinding app.jump_back"
      app.capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))
      app.begin_rebind_for_key("app.jump_forward") || raise "failed to start rebinding app.jump_forward"
      app.capture(Tui::KeyEvent.new('k', Tui::Modifiers::Ctrl))
      app.close_settings

      raise "jump_back should now be ctrl+j" unless app.bindings("app.jump_back") == ["ctrl+j"]
      raise "jump_forward should now be ctrl+k" unless app.bindings("app.jump_forward") == ["ctrl+k"]

      handled_back = app.on_capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))
      raise "remapped jump_back should be handled" unless handled_back
      raise "jump_back should move to a" unless app.active_uri == file_uri(file_a)
      raise "forward history should contain b" unless app.forward_history == [Adamantine::NavigationLocation.new(file_uri(file_b), 0, 0)]

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
      app.back_history << Adamantine::NavigationLocation.new(file_uri(file_a), 0, 0)

      app.begin_rebind_for_key("app.jump_back") || raise "failed to start rebinding app.jump_back"
      app.capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))
      raise "jump_back should now be ctrl+j" unless app.bindings("app.jump_back") == ["ctrl+j"]

      app.begin_rebind_for_key("app.jump_forward") || raise "failed to start rebinding app.jump_forward"
      app.capture(Tui::KeyEvent.new('j', Tui::Modifiers::Ctrl))

      raise "expected confirm overwrite mode" unless app.settings_mode == Adamantine::App::SettingsMode::ConfirmOverwrite
      raise "conflict action should be jump_back" unless app.conflicting_action == "app.jump_back"

      app.confirm(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "jump_forward should take over ctrl+j" unless app.bindings("app.jump_forward") == ["ctrl+j"]
      raise "jump_back should be unbound after overwrite" unless app.bindings("app.jump_back").empty?
      raise "settings should return to browse mode" unless app.settings_mode == Adamantine::App::SettingsMode::Browse
    end
  end

  it "resolves command_palette and settings binding conflict during remap" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      File.write(file_a, "hello\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.open_file_public(file_a)
      app.begin_rebind_for_key("app.command_palette") || raise "failed to start rebinding app.command_palette"
      app.capture(Tui::KeyEvent.new('o', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift))

      raise "command_palette should now be ctrl+shift+o" unless app.bindings("app.command_palette") == ["ctrl+shift+o"]

      app.begin_rebind_for_key("app.settings") || raise "failed to start rebinding app.settings"
      app.capture(Tui::KeyEvent.new('o', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift))

      raise "expected confirm overwrite mode" unless app.settings_mode == Adamantine::App::SettingsMode::ConfirmOverwrite
      raise "conflict action should be app.command_palette" unless app.conflicting_action == "app.command_palette"

      app.confirm(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "settings should take over ctrl+shift+o" unless app.bindings("app.settings") == ["ctrl+shift+o"]
      raise "command_palette should be unbound after overwrite" unless app.bindings("app.command_palette").empty?
      raise "settings should return to browse mode" unless app.settings_mode == Adamantine::App::SettingsMode::Browse
    end
  end

  it "returns to browse mode on Esc while capturing a binding" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"

      raise "expected capture mode" unless app.settings_mode == Adamantine::App::SettingsMode::Capture
      app.capture(Tui::KeyEvent.new(Tui::Key::Escape))

      raise "escape should return to browse mode" unless app.settings_mode == Adamantine::App::SettingsMode::Browse
      raise "capture state should not alter app.save" unless app.bindings("app.save") == ["ctrl+s"]
      raise "capture action should be cleared" unless app.conflicting_action.nil?
    end
  end

  it "returns to browse mode on Esc while confirming overwrite" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"
      app.capture(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))

      raise "expected confirm overwrite mode" unless app.settings_mode == Adamantine::App::SettingsMode::ConfirmOverwrite
      app.confirm(Tui::KeyEvent.new(Tui::Key::Escape))

      raise "escape should return to browse mode" unless app.settings_mode == Adamantine::App::SettingsMode::Browse
      raise "app.save must stay on default binding" unless app.bindings("app.save") == ["ctrl+s"]
      raise "app.close_tab must stay bound" unless app.bindings("app.close_tab") == ["ctrl+w"]
      raise "no unintended conflict action" unless app.conflicting_action.nil?
    end
  end

  it "gives physical N and Y precedence over remapped confirmation actions" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.set_bindings("app.menu_select", ["n"])
      app.set_bindings("app.menu_close", ["y"])

      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"
      app.capture(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))
      raise "expected confirm overwrite mode" unless app.settings_mode == Adamantine::App::SettingsMode::ConfirmOverwrite
      app.confirm(Tui::KeyEvent.new('n'))
      raise "physical N must cancel overwrite" unless app.bindings("app.save") == ["ctrl+s"]
      raise "physical N must preserve conflicting owner" unless app.bindings("app.close_tab") == ["ctrl+w"]

      app.begin_rebind_for_key("app.save") || raise "failed to restart rebinding app.save"
      app.capture(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))
      app.confirm(Tui::KeyEvent.new('y'))
      raise "physical Y must confirm overwrite" unless app.bindings("app.save") == ["ctrl+w"]
      raise "physical Y must remove conflicting owner" unless app.bindings("app.close_tab").empty?
    end
  end

  it "confirms or cancels a physical Delete/Backspace unbind and reloads it" do
    with_temp_workspace do |tmp_dir|
      path = (tmp_dir / "keymap.json").to_s
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: path)
      app.set_bindings("app.menu_select", ["n"])
      app.set_bindings("app.menu_close", ["y"])
      app.select_key("app.save") || raise "failed to select app.save"

      app.browse(Tui::KeyEvent.new(Tui::Key::Backspace))
      raise "expected unbind confirmation" unless app.settings_mode == Adamantine::App::SettingsMode::ConfirmUnbind
      app.confirm(Tui::KeyEvent.new('n'))
      raise "cancelled unbind changed binding" unless app.bindings("app.save") == ["ctrl+s"]

      app.browse(Tui::KeyEvent.new(Tui::Key::Delete))
      raise "expected Delete confirmation" unless app.settings_mode == Adamantine::App::SettingsMode::ConfirmUnbind
      app.confirm(Tui::KeyEvent.new('y'))
      raise "confirmed unbind did not clear binding" unless app.bindings("app.save").empty?

      saved = JSON.parse(File.read(path))
      raise "explicit empty override was not saved" unless saved["keymap"]["app.save"].as_a.empty?

      reloaded = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: path)
      raise "explicit unbind did not survive reload" unless reloaded.bindings("app.save").empty?
    end
  end

  it "lists every same-context conflict owner before overwrite" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.set_bindings("app.close_tab", ["ctrl+w"])
      app.set_bindings("app.undo", ["ctrl+w"])
      app.begin_rebind_for_key("app.save") || raise "failed to start rebinding app.save"
      app.capture(Tui::KeyEvent.new('w', Tui::Modifiers::Ctrl))

      raise "expected overwrite confirmation" unless app.settings_mode == Adamantine::App::SettingsMode::ConfirmOverwrite
      raise "all owners were not retained" unless app.conflicting_actions == ["app.close_tab", "app.undo"]
      app.confirm(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "first conflict owner remained bound" unless app.bindings("app.close_tab").empty?
      raise "second conflict owner remained bound" unless app.bindings("app.undo").empty?
    end
  end

  it "marks a binding conflict exactly once in Settings" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "", keymap_path: (tmp_dir / "keymap.json").to_s)
      app.set_bindings("app.save", ["ctrl+x"])
      app.set_bindings("app.undo", ["ctrl+x"])

      value = app.binding_display("app.save")
      expected = "ctrl+x (conflicts: app.cut, app.undo)"
      raise "wrong effective conflict hint: #{value}" unless value == expected
    end
  end
end
