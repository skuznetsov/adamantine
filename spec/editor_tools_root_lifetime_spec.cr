require "spec"
require "file_utils"
require "json"
require "crystal_tui"

require "../src/adamantine/app"

private class EditorToolsRootLifetimeSpecApp < Adamantine::App
  def run_command_public(command : String) : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    command.each_char { |char| on_capture(Tui::KeyEvent.new(char)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def project_root_public : String
    @project_root.to_s
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def dirty_buffer_public(path : Path) : Nil
    buffer = @document_session.open_buffers[path.to_s]? || raise "missing open buffer: #{path}"
    buffer.editor.insert_text("!")
  end
end

private def with_editor_tools_root_lifetime_workspace(&)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  workspace = Path.new(File.realpath(Dir.tempdir), "adamantine-editor-tools-root-lifetime-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(workspace)
  File.write((workspace / "keymap.json").to_s, "{}")
  apps = [] of EditorToolsRootLifetimeSpecApp
  yield workspace, apps
ensure
  apps.try { |open_apps| open_apps.each { |app| app.quit(force: true) } }
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  workspace.try { |path| FileUtils.rm_rf(path) }
end

private def new_editor_tools_root_lifetime_app(
  workspace : Path,
  project_root : Path,
  apps : Array(EditorToolsRootLifetimeSpecApp),
) : EditorToolsRootLifetimeSpecApp
  app = EditorToolsRootLifetimeSpecApp.new(
    project_root: project_root,
    lsp_command: "",
    keymap_path: (workspace / "keymap.json").to_s,
    session_enabled: false,
    recovery_root: workspace / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new
  )
  apps << app
  app
end

private def invoke_editor_tools_root_lifetime(
  session : Adamantine::EditorTools::Session,
  id : String,
) : Adamantine::EditorTools::Result
  session.invoke_json({
    "id"        => id,
    "name"      => "editor.list_buffers",
    "arguments" => {} of String => JSON::Any,
  }.to_json)
end

describe "App editor tool root and shutdown lifetimes" do
  it "retires a session across a committed :cd A to B to A sequence" do
    with_editor_tools_root_lifetime_workspace do |workspace, apps|
      root_a = workspace / "project-a"
      root_b = workspace / "project-b"
      Dir.mkdir_p(root_a)
      Dir.mkdir_p(root_b)
      app = new_editor_tools_root_lifetime_app(workspace, root_a, apps)
      session = app.open_tool_session

      invoke_editor_tools_root_lifetime(session, "cd-start").status.should eq(Adamantine::EditorTools::Status::Ok)
      app.run_command_public("cd #{root_b}")
      app.project_root_public.should eq(File.realpath(root_b.to_s))
      app.run_command_public("cd #{root_a}")
      app.project_root_public.should eq(File.realpath(root_a.to_s))

      invoke_editor_tools_root_lifetime(session, "cd-aba").status.should eq(Adamantine::EditorTools::Status::Stale)
    end
  end

  it "keeps an externally retargeted symlink-root session stale after A to B to A" do
    with_editor_tools_root_lifetime_workspace do |workspace, apps|
      root_a = workspace / "symlink-project-a"
      root_b = workspace / "symlink-project-b"
      root_link = workspace / "project-link"
      Dir.mkdir_p(root_a)
      Dir.mkdir_p(root_b)
      File.symlink(root_a.basename.to_s, root_link.to_s)
      app = new_editor_tools_root_lifetime_app(workspace, root_link, apps)
      session = app.open_tool_session

      invoke_editor_tools_root_lifetime(session, "link-start").status.should eq(Adamantine::EditorTools::Status::Ok)
      File.delete(root_link.to_s)
      File.symlink(root_b.basename.to_s, root_link.to_s)
      invoke_editor_tools_root_lifetime(session, "link-observe-b").status.should eq(Adamantine::EditorTools::Status::Stale)

      File.delete(root_link.to_s)
      File.symlink(root_a.basename.to_s, root_link.to_s)
      invoke_editor_tools_root_lifetime(session, "link-return-a").status.should eq(Adamantine::EditorTools::Status::Stale)
    end
  end

  it "keeps a session stale after its proven root disappears and is recreated" do
    with_editor_tools_root_lifetime_workspace do |workspace, apps|
      root_a = workspace / "recovering-project"
      Dir.mkdir_p(root_a)
      app = new_editor_tools_root_lifetime_app(workspace, root_a, apps)
      session = app.open_tool_session

      invoke_editor_tools_root_lifetime(session, "loss-start").status.should eq(Adamantine::EditorTools::Status::Ok)
      FileUtils.rm_rf(root_a.to_s)
      invoke_editor_tools_root_lifetime(session, "loss-observed").status.should eq(Adamantine::EditorTools::Status::Stale)
      Dir.mkdir_p(root_a)
      invoke_editor_tools_root_lifetime(session, "loss-recovered").status.should eq(Adamantine::EditorTools::Status::Stale)
    end
  end

  it "does not expire sessions for ordinary root-directory changes" do
    with_editor_tools_root_lifetime_workspace do |workspace, apps|
      root = workspace / "stable-project"
      Dir.mkdir_p(root)
      app = new_editor_tools_root_lifetime_app(workspace, root, apps)
      session = app.open_tool_session

      invoke_editor_tools_root_lifetime(session, "mtime-before").status.should eq(Adamantine::EditorTools::Status::Ok)
      File.write((root / "new-file.txt").to_s, "ordinary project change\n")
      invoke_editor_tools_root_lifetime(session, "mtime-after").status.should eq(Adamantine::EditorTools::Status::Ok)
    end
  end

  it "denies new sessions and makes old sessions stale after committed quit" do
    with_editor_tools_root_lifetime_workspace do |workspace, apps|
      root = workspace / "quit-project"
      Dir.mkdir_p(root)
      app = new_editor_tools_root_lifetime_app(workspace, root, apps)
      session = app.open_tool_session

      invoke_editor_tools_root_lifetime(session, "quit-before").status.should eq(Adamantine::EditorTools::Status::Ok)
      app.quit
      invoke_editor_tools_root_lifetime(session, "quit-after").status.should eq(Adamantine::EditorTools::Status::Stale)
      failure = expect_raises(Adamantine::EditorTools::Failure) { app.open_tool_session }
      failure.status.should eq(Adamantine::EditorTools::Status::Unavailable)
    end
  end

  it "retains a valid session when a reviewed quit is cancelled" do
    with_editor_tools_root_lifetime_workspace do |workspace, apps|
      root = workspace / "cancelled-quit-project"
      Dir.mkdir_p(root)
      source = root / "dirty.txt"
      File.write(source.to_s, "clean\n")
      app = new_editor_tools_root_lifetime_app(workspace, root, apps)
      session = app.open_tool_session

      invoke_editor_tools_root_lifetime(session, "cancel-before").status.should eq(Adamantine::EditorTools::Status::Ok)
      app.open_file_public(source)
      app.dirty_buffer_public(source)
      app.quit
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))

      invoke_editor_tools_root_lifetime(session, "cancel-after").status.should eq(Adamantine::EditorTools::Status::Ok)
      app.open_tool_session.should_not be_nil
    end
  end
end
