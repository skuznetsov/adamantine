require "spec"
require "file_utils"
require "../src/adamantine/app"

private class SessionIntegrationApp < Adamantine::App
  def activate_session_public : Nil
    start_session_lifecycle
  end

  def save_session_public : Bool
    save_session_state
  end

  def open_session_public(path : Path) : Adamantine::EditingTextEditor
    raise "fixture open failed: #{path}" unless open_file(path)
    current_editor.as(Adamantine::EditingTextEditor)
  end

  def current_session_public : Adamantine::EditingTextEditor
    current_editor.as(Adamantine::EditingTextEditor)
  end

  def paths_session_public : Array(String)
    @editor_tabs.tabs.map(&.id)
  end

  def root_session_public(path : Path) : Nil
    change_project_root(path.to_s)
  end
end

private def with_session_integration_workspace(&)
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-session-integration-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  state_root = root / "state"
  keymap = root / "config.json"
  File.write(keymap, "{}")
  apps = [] of SessionIntegrationApp
  yield root, state_root, keymap, apps
ensure
  apps.try(&.each { |app| app.quit(force: true) })
  FileUtils.rm_rf(root) if root
end

describe "Session lifecycle integration" do
  it "restores disk text and codepoint cursor/terminal-cell viewport only after activation" do
    with_session_integration_workspace do |root, state_root, keymap, apps|
      project = root / "project"
      path = project / "unicode.cr"
      Dir.mkdir_p(project)
      File.write(path, "🙂\n\ttext")

      first = SessionIntegrationApp.new(
        project,
        keymap_path: keymap.to_s,
        recovery_root: root / "recovery",
        clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
        session_root: state_root,
        session_enabled: true,
      )
      apps << first
      File.exists?(state_root).should be_false
      first.activate_session_public
      editor = first.open_session_public(path)
      editor.set_cursor(0, 1)
      editor.restore_session_view(0, 2)
      first.save_session_public.should be_true
      File.exists?(state_root).should be_true

      second = SessionIntegrationApp.new(
        project,
        keymap_path: keymap.to_s,
        recovery_root: root / "recovery-2",
        clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
        session_root: state_root,
        session_enabled: true,
      )
      apps << second
      second.activate_session_public
      second.paths_session_public.should eq [path.to_s]
      restored = second.current_session_public
      restored.text.should eq "🙂\n\ttext"
      restored.cursor_line.should eq 0
      restored.cursor_col.should eq 1
      restored.session_scroll_y.should eq 0
      restored.session_scroll_x.should eq 2
      restored.modified?.should be_false
    end
  end

  it "filters snapshots at a project switch while retaining existing tabs" do
    with_session_integration_workspace do |root, state_root, keymap, apps|
      alpha = root / "alpha"
      beta = root / "beta"
      alpha_path = alpha / "alpha.cr"
      beta_path = beta / "beta.cr"
      Dir.mkdir_p(alpha)
      Dir.mkdir_p(beta)
      File.write(alpha_path, "alpha")
      File.write(beta_path, "beta")

      app = SessionIntegrationApp.new(
        alpha,
        keymap_path: keymap.to_s,
        recovery_root: root / "recovery",
        clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
        session_root: state_root,
        session_enabled: true,
      )
      apps << app
      app.activate_session_public
      dirty = app.open_session_public(alpha_path)
      dirty.insert_text("dirty")
      app.root_session_public(beta)
      app.paths_session_public.should eq [alpha_path.to_s]
      beta_editor = app.open_session_public(beta_path)
      app.save_session_public.should be_true

      store = Adamantine::SessionStore.new(state_root, enabled: true)
      alpha_state = store.load(alpha).state
      alpha_state.should_not be_nil
      alpha_state.not_nil!.tabs.map(&.path).should eq [alpha_path]
      beta_state = store.load(beta).state
      beta_state.should_not be_nil
      beta_state.not_nil!.tabs.map(&.path).should eq [beta_path]
      dirty.text.should eq "dirtyalpha"
      beta_editor.text.should eq "beta"
    end
  end
end
