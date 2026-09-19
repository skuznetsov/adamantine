require "spec"
require "file_utils"
require "../src/adamantine/app"

private class GitControllerApp < Adamantine::App
  def open_public(path : Path)
    open_file(path)
  end

  def git_public
    open_git_view
  end

  def git_open_public?
    git_view_active?
  end

  def git_wait_public
    deadline = Time.instant + 10.seconds
    while @git_view.worker_active
      raise "Git view timed out" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  def git_state_public
    @git_view
  end

  def editor_public
    current_editor.not_nil!
  end

  def git_render_public(buffer : Tui::Buffer, clip : Tui::Rect)
    render_git_view(buffer, clip)
  end

  def cleanup_public
    close_git_view
    shutdown_lsp
  end

  def root_public=(root : Path)
    change_project_root(root.to_s)
  end

  def command_public(text : String)
    execute_command(text)
  end
end

private def with_git_controller_app(&)
  root = Path.new(Dir.tempdir, "adamantine-git-controller-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  Process.run("git", ["init", "--quiet", root.to_s]).success?.should be_true
  path = root / "sample.cr"
  File.write(path, "puts 1\n")
  app = GitControllerApp.new(project_root: root, lsp_command: "")
  app.open_public(path).should be_true
  yield app, root
ensure
  app.try &.cleanup_public
  app.try &.git_wait_public
  FileUtils.rm_rf(root) if root
end

describe "read-only Git modal" do
  it "loads the current repo and isolates editing keys, paste and mouse" do
    with_git_controller_app do |app, root|
      original = app.editor_public.text
      app.git_public
      app.git_wait_public
      app.git_open_public?.should be_true
      app.git_state_public.snapshot.not_nil!.root.should eq(Path.new(File.realpath(root)))
      app.git_state_public.snapshot.not_nil!.files.any? { |file| file.path == "sample.cr" }.should be_true
      app.on_capture(Tui::KeyEvent.new('x')).should be_true
      app.on_capture(Tui::PasteEvent.new("MUTATION")).should be_true
      app.on_capture(Tui::MouseEvent.new(2, 0)).should be_true
      app.editor_public.text.should eq(original)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.git_open_public?.should be_false
    end
  end

  it "does not publish after closing an in-flight load" do
    with_git_controller_app do |app, root|
      app.git_public
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      app.git_wait_public
      app.git_open_public?.should be_false
      app.git_state_public.snapshot.should be_nil
    end
  end

  it "renders safely at narrow terminal sizes" do
    with_git_controller_app do |app, root|
      app.git_public
      app.git_wait_public
      [1, 2, 8, 30, 100].each do |width|
        buffer = Tui::Buffer.new(width, 8)
        app.git_render_public(buffer, Tui::Rect.new(0, 0, width, 8))
      end
    end
  end

  it "closes and discards pending results on project switch" do
    with_git_controller_app do |app, root|
      nested = root / "nested"
      Dir.mkdir(nested)
      app.git_public
      app.root_public = nested
      app.git_wait_public
      app.git_open_public?.should be_false
      app.git_state_public.snapshot.should be_nil
    end
  end

  it "supports a fresh open immediately after cancelling the old worker" do
    with_git_controller_app do |app, root|
      app.git_public
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      app.git_public
      app.git_wait_public
      app.git_open_public?.should be_true
      app.git_state_public.snapshot.not_nil!.root.should eq(Path.new(File.realpath(root)))
      app.git_state_public.loading.should be_false
    end
  end

  it "routes the palette command and does not let a paste change the file" do
    with_git_controller_app do |app, root|
      app.command_public("git")
      app.git_wait_public
      app.git_open_public?.should be_true
      app.on_capture(Tui::PasteEvent.new("changed")).should be_true
      app.editor_public.text.should eq("puts 1\n")
    end
  end
end
