require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private def with_recovery_preview_ui_workspace(&)
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-recovery-preview-ui-#{Random::Secure.hex(8)}")
  project = root / "project"
  recovery = root / "recovery"
  Dir.mkdir_p(project)
  yield root, project, recovery
ensure
  FileUtils.rm_rf(root) if root
end

private def seed_recovery_preview_ui_checkpoint(
  recovery : Path,
  project : Path,
  source : Path,
  content : String,
) : Nil
  store = Adamantine::RecoveryStore.new(root: recovery, project: project)
  session = store.open_session
  session.write_snapshot(source_path: source, version: 7_i64) do |io|
    io.write(content.to_slice)
  end
  session.close
ensure
  store.try(&.close)
end

private class RecoveryPreviewUiSpecApp < Adamantine::App
  def start_recovery_and_open_menu_public : Nil
    raise "recovery worker did not start" unless @recovery_controller.start(interval: 1.hour)
    open_recovery_menu
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def menu_labels : Array(String)
    @context_menu.actions.map(&.label)
  end

  def choose_menu_prefix(prefix : String) : Nil
    index = menu_labels.index(&.starts_with?(prefix))
    raise "missing menu action #{prefix}: #{menu_labels.inspect}" unless index
    @context_menu.index = index.not_nil!
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def review_active_public? : Bool
    recovery_review_active?
  end

  def review_titles : Array(String)
    @recovery_review_controller.review.not_nil!.views.map(&.title)
  end

  def review_title : String
    @recovery_review_controller.active_title
  end

  def active_rows : Array(String)
    model = @recovery_review_controller.active_view.not_nil!.model.not_nil!
    Array.new(model.row_count) { |index| model.row_at(index).text }
  end

  def dispatch_public(event : Tui::Event) : Bool
    on_capture(event)
  end

  def current_text : String
    current_editor.not_nil!.text
  end

  def replace_current_text_public(text : String) : Nil
    current_editor.not_nil!.text = text
  end

  def buffer_count : Int32
    @document_session.open_buffers.size
  end

  def checkpoint_count : Int32
    @recovery_controller.candidates.size
  end

  def first_checkpoint_path : Path
    @recovery_controller.candidates.first.path
  end

  def recovered_copy_count : Int32
    root = @recovery_controller.root.not_nil! / "recovered"
    return 0 unless Dir.exists?(root)
    Dir.glob((root / "**" / "*").to_s).count { |path| File.file?(path) }
  end

  def render_review_public(width : Int32, height : Int32) : Array(String)
    @editor_tabs.rect = Tui::Rect.new(0, 0, width, height)
    screen = Tui::Buffer.new(width, height)
    render_recovery_review(screen, Tui::Rect.new(0, 0, width, height))
    Array.new(height) do |y|
      String.build do |builder|
        width.times { |x| builder << screen.get(x, y).glyph }
      end
    end
  end

  def stop_recovery_public : Nil
    @recovery_controller.stop(force: true)
  end
end

describe "recovery preview UI" do
  it "keeps review read-only, isolated, captured, and separate from copy/discard" do
    with_recovery_preview_ui_workspace do |root, project, recovery|
      source = project / "draft.txt"
      File.write(source, "disk before\n")
      seed_recovery_preview_ui_checkpoint(recovery, project, source, "checkpoint draft\n")

      app = RecoveryPreviewUiSpecApp.new(project, lsp_command: "", recovery_root: recovery)
      raise "source should open" unless app.open_file_public(source)
      app.replace_current_text_public("editor before\n")
      editor_before = app.current_text
      disk_before = File.read(source)
      app.start_recovery_and_open_menu_public
      frame = app.first_checkpoint_path
      frame_before = File.read(frame)
      app.menu_labels.any?(&.starts_with?("Review draft (read-only)")).should be_true
      app.menu_labels.any?(&.starts_with?("Open recovered copy")).should be_true
      app.menu_labels.any?(&.starts_with?("Discard checkpoint")).should be_true
      app.choose_menu_prefix("Review draft (read-only)")

      app.review_active_public?.should be_true
      app.review_titles.should eq [
        "Editor -> Checkpoint",
        "Disk -> Checkpoint",
        "Editor -> Disk",
        "Checkpoint contents",
      ]
      app.buffer_count.should eq 1
      app.checkpoint_count.should eq 1
      app.recovered_copy_count.should eq 0

      app.dispatch_public(Tui::KeyEvent.new('x')).should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.dispatch_public(Tui::PasteEvent.new("must not edit")).should be_true
      app.dispatch_public(Tui::MouseEvent.new(1, 1)).should be_true
      app.current_text.should eq editor_before
      app.review_active_public?.should be_true

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      app.review_title.should eq "Disk -> Checkpoint"
      captured_rows = app.active_rows
      File.write(source, "disk after\n")
      app.replace_current_text_public("editor after\n")
      app.active_rows.should eq captured_rows

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.review_active_public?.should be_false
      File.read(source).should eq "disk after\n"
      File.read(frame).should eq frame_before
      app.buffer_count.should eq 1
      app.checkpoint_count.should eq 1
      app.recovered_copy_count.should eq 0
    ensure
      app.try(&.stop_recovery_public)
      app.try(&.quit(force: true))
    end
  end

  it "renders a standalone checkpoint without an editor or original file" do
    with_recovery_preview_ui_workspace do |root, project, recovery|
      source = project / "deleted.txt"
      File.write(source, "old disk\n")
      seed_recovery_preview_ui_checkpoint(recovery, project, source, "surviving checkpoint\n")
      File.delete(source)

      app = RecoveryPreviewUiSpecApp.new(project, lsp_command: "", recovery_root: recovery)
      app.start_recovery_and_open_menu_public
      app.choose_menu_prefix("Review draft (read-only)")

      app.review_titles.should eq ["Checkpoint contents"]
      rows = app.render_review_public(48, 5)
      rows.first.should contain "Checkpoint contents"
      rows.join("\n").should contain "surviving checkpoint"
      footer = rows.last
      footer.should contain "Esc"
      footer.should_not contain "Accept"
      footer.should_not contain "Reload"
      footer.should_not contain "Overwrite"
      footer.should_not contain "Discard"

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.review_active_public?.should be_false
      File.exists?(source).should be_false
      app.checkpoint_count.should eq 1
      app.recovered_copy_count.should eq 0
    ensure
      app.try(&.stop_recovery_public)
      app.try(&.quit(force: true))
    end
  end
end
