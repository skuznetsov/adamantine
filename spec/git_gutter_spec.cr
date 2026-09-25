require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private class GitGutterApp < Adamantine::App
  def open_public(path : Path) : Bool
    open_file(path)
  end

  def save_public : Bool
    save_active
  end

  def editor_public : Adamantine::EditingTextEditor
    current_editor.as(Adamantine::EditingTextEditor)
  end

  def active_buffer_public : Adamantine::OpenBuffer
    current_buffer.not_nil!
  end

  def deny_next_close_stale_public(buffer : Adamantine::OpenBuffer) : Nil
    @close_permit = Adamantine::CloseTarget.new(buffer)
    buffer.version += 1
  end

  def close_active_public : Bool
    @editor_tabs.close_active_tab
  end

  def wait_gutter_public : Nil
    deadline = Time.instant + 10.seconds
    while @git_gutter.worker_active
      raise "Git gutter timed out" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  def cleanup_public : Nil
    git_gutter_shutdown
    shutdown_lsp
  end
end

private def with_git_gutter_app(&block : Path, GitGutterApp ->)
  root = Path.new(Dir.tempdir, "adamantine-git-gutter-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  Process.run("git", ["init", "--quiet", root.to_s]).success?.should be_true
  Process.run("git", ["config", "user.name", "Adamantine Spec"], chdir: root.to_s).success?.should be_true
  Process.run("git", ["config", "user.email", "adamantine-spec@example.invalid"], chdir: root.to_s).success?.should be_true
  app = GitGutterApp.new(project_root: root, lsp_command: "")
  yield root, app
ensure
  app.try &.cleanup_public
  FileUtils.rm_rf(root) if root
end

private def git_gutter_git!(root : Path, *args : String) : Nil
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("git", args.to_a, chdir: root.to_s, output: output, error: error)
  raise "git #{args.join(' ')} failed: #{error}" unless status.success?
end

describe "Git line-change gutter" do
  it "uses the existing trailing number cell without moving folds or text" do
    editor = Adamantine::EditingTextEditor.new("git-gutter-render")
    editor.load_content_as_saved("def A\n  x\nend\n", Path.new("git-gutter-render.cr"))
    editor.show_line_numbers = true
    editor.show_fold_gutter = true
    editor.show_scrollbar = false
    editor.set_fold_ranges([Tui::TextEditor::FoldRange.new(0, 2)])
    editor.line_change_markers = {2 => '~'}
    editor.rect = Tui::Rect.new(0, 0, 8, 3)

    buffer = Tui::Buffer.new(8, 3)
    clip = Tui::Rect.new(0, 0, 8, 3)
    editor.render(buffer, clip)

    buffer.get(0, 0).glyph.should eq("-")
    buffer.get(2, 1).glyph.should eq("~")
    buffer.get(3, 1).glyph.should eq(" ")

    editor.line_change_markers.clear
    clipped = Tui::Buffer.new(3, 3)
    editor.rect = Tui::Rect.new(0, 0, 3, 3)
    editor.render(clipped, Tui::Rect.new(0, 0, 3, 3))
    clipped.get(2, 1).glyph.should eq(" ")
  end

  it "clears markers immediately on edit and refreshes after save" do
    with_git_gutter_app do |root, app|
      path = root / "sample.cr"
      File.write(path, "puts 1\n")
      git_gutter_git!(root, "add", "--", "sample.cr")
      git_gutter_git!(root, "commit", "--quiet", "-m", "base")
      File.write(path, "puts 2\n")

      app.open_public(path).should be_true
      app.wait_gutter_public
      editor = app.editor_public
      editor.line_change_markers.should eq({1 => '~'})

      editor.insert_text("# unsaved\n")
      editor.modified?.should be_true
      editor.line_change_markers.should be_empty

      app.save_public.should be_true
      app.wait_gutter_public
      editor.modified?.should be_false
      editor.line_change_markers.should eq({1 => '~', 2 => '+'})
    end
  end

  it "clears the old editor and only publishes the latest tab request" do
    with_git_gutter_app do |root, app|
      first = root / "first.cr"
      second = root / "second.cr"
      File.write(first, "puts 1\n")
      File.write(second, "puts 2\n")
      git_gutter_git!(root, "add", "--", "first.cr", "second.cr")
      git_gutter_git!(root, "commit", "--quiet", "-m", "base")
      File.write(first, "puts 10\n")
      File.write(second, "puts 20\n")

      app.open_public(first).should be_true
      old_editor = app.editor_public
      app.open_public(second).should be_true
      app.wait_gutter_public

      old_editor.line_change_markers.should be_empty
      app.editor_public.line_change_markers.should eq({1 => '~'})
    end
  end

  it "keeps markers when a stale close permit denies tab closure" do
    with_git_gutter_app do |root, app|
      path = root / "sample.cr"
      File.write(path, "puts 1\n")
      git_gutter_git!(root, "add", "--", "sample.cr")
      git_gutter_git!(root, "commit", "--quiet", "-m", "base")
      File.write(path, "puts 2\n")

      app.open_public(path).should be_true
      app.wait_gutter_public
      editor = app.editor_public
      buffer = app.active_buffer_public
      editor.line_change_markers.should eq({1 => '~'})

      app.deny_next_close_stale_public(buffer)
      app.close_active_public.should be_false
      editor.line_change_markers.should eq({1 => '~'})
    end
  end

  it "does not publish markers for disk bytes newer than the open editor revision" do
    with_git_gutter_app do |root, app|
      path = root / "sample.cr"
      File.write(path, "one\nold\ntail\n")
      git_gutter_git!(root, "add", "--", "sample.cr")
      git_gutter_git!(root, "commit", "--quiet", "-m", "base")
      File.write(path, "one\nnew\ntail\n")

      app.open_public(path).should be_true
      # The gutter worker is queued cooperatively. Replace disk bytes before
      # yielding so Git reads a newer revision than the editor opened.
      File.write(path, "inserted\none\nnew\ntail\n")
      app.wait_gutter_public

      app.editor_public.line_text(0).should eq("one")
      app.editor_public.line_text(1).should eq("new")
      app.editor_public.line_text(2).should eq("tail")
      app.editor_public.line_change_markers.should be_empty
    end
  end

  it "suppresses markers for dirty buffers and unsupported external files" do
    with_git_gutter_app do |root, app|
      path = root / "sample.cr"
      File.write(path, "puts 1\n")
      git_gutter_git!(root, "add", "--", "sample.cr")
      git_gutter_git!(root, "commit", "--quiet", "-m", "base")
      File.write(path, "puts 2\n")
      external = Path.new(Dir.tempdir, "adamantine-git-gutter-external-#{Random::Secure.hex(8)}.cr")
      File.write(external, "puts 3\n")

      app.open_public(path).should be_true
      app.wait_gutter_public
      editor = app.editor_public
      editor.line_change_markers.should eq({1 => '~'})

      app.open_public(external).should be_true
      app.wait_gutter_public
      editor.line_change_markers.should be_empty
    ensure
      File.delete(external) if external && File.exists?(external)
    end
  end

  it "uses the canonical tracked file through an in-project directory symlink" do
    with_git_gutter_app do |root, app|
      real_dir = root / "real"
      Dir.mkdir(real_dir)
      path = real_dir / "sample.cr"
      File.write(path, "puts 1\n")
      git_gutter_git!(root, "add", "--", "real/sample.cr")
      git_gutter_git!(root, "commit", "--quiet", "-m", "base")
      File.write(path, "puts 2\n")
      File.symlink("real", (root / "alias").to_s)

      app.open_public(root / "alias" / "sample.cr").should be_true
      app.wait_gutter_public
      app.editor_public.line_change_markers.should eq({1 => '~'})
    end
  end
end
