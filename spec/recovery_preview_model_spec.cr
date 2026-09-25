require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/editing_text_editor"
require "../src/adamantine/recovery_controller"
require "../src/adamantine/recovery_review"
require "../src/adamantine/recovery_review_controller"

private def with_recovery_preview_workspace(prefix : String = "adamantine-recovery-preview", &)
  root = Path.new(File.realpath(Dir.tempdir), "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def recovery_preview(
  project : Path,
  source : Path,
  content : String,
  authorized_source_path : Path? = source,
) : Adamantine::RecoveryController::RecoveryPreview
  candidate = Adamantine::RecoveryController::RecoveryCandidate.new(
    source_path: source,
    path: project / "checkpoint.frame",
    version: 7_i64,
    session_id: "session-preview",
    captured_at: Time.utc,
    file_name: "checkpoint.frame",
    project: project.expand.to_s,
    modified: true,
    bytes: content.bytesize.to_i64,
    digest: "digest",
  )
  Adamantine::RecoveryController::RecoveryPreview.new(candidate, content, authorized_source_path)
end

private def editing_buffer(path : Path, content : String) : Adamantine::OpenBuffer
  editor = Adamantine::EditingTextEditor.new(path.to_s)
  raise "failed to seed editor" unless editor.load_content_as_saved(content, path)
  Adamantine::OpenBuffer.new(path, editor, "text", "file://#{path}")
end

describe Adamantine::RecoveryReview do
  it "orders captured pair views and retains the standalone checkpoint view" do
    with_recovery_preview_workspace do |root|
      project = root / "project"
      Dir.mkdir_p(project)
      source = project / "draft.txt"
      File.write(source, "disk line\n")
      editor_buffer = editing_buffer(source, "editor line\n")
      buffers = {source.to_s => editor_buffer} of String => Adamantine::OpenBuffer
      controller = Adamantine::RecoveryReviewController.new(project, -> { buffers })

      review = controller.build(recovery_preview(project, source, "checkpoint line\n"))

      review.views.map(&.title).should eq [
        "Editor -> Checkpoint",
        "Disk -> Checkpoint",
        "Editor -> Disk",
        "Checkpoint contents",
      ]
      review.active_view.title.should eq "Editor -> Checkpoint"
      review.scope.should contain "Editor: available"
      review.scope.should contain "Disk: available"
      review.scope.should contain "Checkpoint: available"
      review.views.all?(&.available?).should be_true
    end
  end

  it "keeps a checkpoint-only view when the source is deleted and no editor is open" do
    with_recovery_preview_workspace do |root|
      project = root / "project"
      Dir.mkdir_p(project)
      source = project / "deleted.txt"
      File.write(source, "old disk\n")
      File.delete(source)
      buffers = {} of String => Adamantine::OpenBuffer
      controller = Adamantine::RecoveryReviewController.new(project, -> { buffers })

      review = controller.build(recovery_preview(project, source, "checkpoint survives\n"))

      review.views.map(&.title).should eq ["Checkpoint contents"]
      review.active_view.model.should_not be_nil
      review.scope.should contain "Editor: unavailable: source is not open"
      review.scope.should contain "Disk: unavailable: missing"
      review.scope.should contain "Checkpoint: available"
    end
  end

  it "fails closed for nil, outside-project, symlink, and non-regular disk paths" do
    with_recovery_preview_workspace do |root|
      project = root / "project"
      Dir.mkdir_p(project)
      source = project / "source.txt"
      outside = root / "outside.txt"
      File.write(source, "inside\n")
      File.write(outside, "must never be read\n")
      linked = project / "linked.txt"
      File.symlink(outside, linked)
      directory = project / "directory"
      Dir.mkdir_p(directory)
      buffers = {} of String => Adamantine::OpenBuffer
      controller = Adamantine::RecoveryReviewController.new(project, -> { buffers })

      nil_review = controller.build(recovery_preview(project, source, "checkpoint\n", nil))
      nil_review.disk.root.should be_nil
      nil_review.disk.status.should contain "not authorized"

      outside_review = controller.build(recovery_preview(project, source, "checkpoint\n", outside))
      outside_review.disk.root.should be_nil
      outside_review.disk.status.should contain "outside authorized project"
      outside_review.scope.should_not contain outside.to_s
      outside_review.scope.should_not contain "must never be read"

      # Even if an outside buffer happens to be open, editor capture must use
      # the backend's authorized path field rather than candidate metadata.
      buffers[outside.to_s] = editing_buffer(outside, "outside editor\n")
      outside_editor_review = controller.build(recovery_preview(project, outside, "checkpoint\n", nil))
      outside_editor_review.editor.root.should be_nil
      outside_editor_review.editor.status.should contain "not authorized"

      symlink_review = controller.build(recovery_preview(project, source, "checkpoint\n", linked))
      symlink_review.disk.root.should be_nil
      symlink_review.disk.status.should contain "symlink"

      directory_review = controller.build(recovery_preview(project, source, "checkpoint\n", directory))
      directory_review.disk.root.should be_nil
      directory_review.disk.status.should contain "non-regular"
    end
  end

  it "detaches source snapshots and consumes every modal input" do
    with_recovery_preview_workspace do |root|
      project = root / "project"
      Dir.mkdir_p(project)
      source = project / "stable.txt"
      File.write(source, "disk before\n")
      editor_buffer = editing_buffer(source, "editor before\n")
      editor = editor_buffer.editor.as(Adamantine::EditingTextEditor)
      buffers = {source.to_s => editor_buffer} of String => Adamantine::OpenBuffer
      controller = Adamantine::RecoveryReviewController.new(project, -> { buffers })
      review = controller.open(recovery_preview(project, source, "checkpoint before\n"))
      initial_title = review.active_view.title
      initial_text = review.active_view.model.not_nil!.row_at(0).text
      editor.text = "editor after\n"
      File.write(source, "disk after\n")

      review.active_view.model.not_nil!.row_at(0).text.should eq initial_text
      controller.handle_input(Tui::KeyEvent.new('x')).should be_true
      controller.handle_input(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      controller.handle_input(Tui::PasteEvent.new("paste must be ignored")).should be_true
      controller.handle_input(Tui::MouseEvent.new(1, 1)).should be_true
      controller.active?.should be_true
      controller.active_title.should eq initial_title

      controller.handle_input(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      controller.active_title.should eq "Disk -> Checkpoint"
      controller.handle_input(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift)).should be_true
      controller.active_title.should eq initial_title
      controller.handle_input(Tui::KeyEvent.new(Tui::Key::Down), 4).should be_true
      controller.handle_input(Tui::KeyEvent.new(Tui::Key::PageDown), 4).should be_true
      controller.handle_input(Tui::KeyEvent.new(Tui::Key::Home), 4).should be_true
      controller.handle_input(Tui::KeyEvent.new(Tui::Key::End), 4).should be_true
      controller.handle_input(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      controller.active?.should be_false
      editor.text.should eq "editor after\n"
      File.read(source).should eq "disk after\n"
    end
  end

  it "exposes renderer state and safe compact controls without false verbs" do
    with_recovery_preview_workspace do |root|
      project = root / "project"
      Dir.mkdir_p(project)
      source = project / "controls.txt"
      File.write(source, "disk\n")
      buffers = {} of String => Adamantine::OpenBuffer
      controller = Adamantine::RecoveryReviewController.new(project, -> { buffers })
      controller.open(recovery_preview(project, source, "checkpoint\n"))

      state = controller.render_state
      state.title.should eq "Disk -> Checkpoint"
      state.scope.should contain "Editor: unavailable"
      controller.footer_controls.values.each do |footer|
        footer.should_not contain("Accept")
        footer.should_not contain("Reload")
        footer.should_not contain("Overwrite")
        footer.should_not contain("Discard")
      end
      controller.footer_controls[:tiny].should eq "Esc close"
    end
  end
end
