require "spec"
require "file_utils"
require "crystal_tui"
require "json"

require "../src/adamantine/editing_text_editor"
require "../src/adamantine/safe_document_edits"
require "../src/adamantine/inline_preview_renderer"
require "../src/adamantine/app"

private class ExternalReviewRendererHarness
  include Adamantine::InlinePreviewRenderer

  getter editor : Adamantine::EditingTextEditor

  def initialize(width : Int32, height : Int32)
    @editor = Adamantine::EditingTextEditor.new("external-review-renderer")
    @editor.rect = Tui::Rect.new(0, 0, width, height)
    @editor.load_content_as_saved("editor line\n", Path.new("external-review-renderer"))
  end

  def current_editor : Tui::TextEditor?
    @editor
  end

  def render_external(buffer : Tui::Buffer, clip : Tui::Rect, preview : Adamantine::InlineEditPreview::Model) : Nil
    render_inline_edit_preview(
      buffer,
      clip,
      preview,
      "- Editor | + Disk",
      "external conflict",
      "Enter [Later] | Tab Reload | Shift-Tab Overwrite",
      "Enter [Later] | Esc Later",
      "Enter [Later] | Esc",
      "[Later] Enter | Esc"
    )
  end

  def row_text(buffer : Tui::Buffer, y : Int32) : String
    String.build do |builder|
      buffer.width.times { |x| builder << buffer.get(x, y).glyph }
    end
  end
end

private class ExternalReviewUiApp < Adamantine::App
  def open_public(path : Path) : Adamantine::OpenBuffer
    raise "fixture open failed" unless open_file(path)
    current_buffer.not_nil!
  end

  def poll_public : Nil
    @document_orchestrator.poll_external_files
  end

  def open_review_public : Bool
    open_external_review
  end

  def review_open_public? : Bool
    external_review_active?
  end

  def review_choice_public : String
    external_review_choice.to_s
  end

  def send_public(event : Tui::KeyEvent) : Bool
    on_capture(event)
  end
end

private def with_external_review_workspace(prefix : String = "external-review-ui", &)
  root = Path.new(File.realpath(Dir.tempdir), "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config = root / "config.json"
  File.write(config, "{}")
  app = ExternalReviewUiApp.new(
    root,
    lsp_command: "",
    keymap_path: config.to_s,
    session_enabled: false,
    recovery_root: root / "recovery"
  )
  yield root, app
ensure
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

private def external_review_preview : Adamantine::InlineEditPreview::Model
  editor = Adamantine::EditingTextEditor.new("external-review-preview")
  editor.load_content_as_saved("editor line\n", Path.new("external-review-preview"))
  edit = {
    "range" => {
      "start" => {"line" => 0, "character" => 0},
      "end"   => {"line" => 0, "character" => 11},
    },
    "newText" => "disk line",
  }
  plan = editor.prepare_document_edits([JSON.parse(edit.to_json)])
  plan.inline_preview("- Editor | + Disk")
end

describe "external-change inline review UI" do
  it "supports source labels and custom controls without advertising edit acceptance" do
    harness = ExternalReviewRendererHarness.new(80, 6)
    buffer = Tui::Buffer.new(80, 6)
    harness.render_external(buffer, Tui::Rect.new(0, 0, 80, 6), external_review_preview)

    harness.row_text(buffer, 0).should contain("- Editor | + Disk")
    harness.row_text(buffer, 5).should contain("Enter [Later]")
    harness.row_text(buffer, 5).should contain("Tab Reload")
    harness.row_text(buffer, 5).should contain("Shift-Tab Overwrite")
    harness.row_text(buffer, 5).should_not contain("Accept")
  end

  it "keeps custom controls legible in a compact editor pane" do
    harness = ExternalReviewRendererHarness.new(28, 4)
    buffer = Tui::Buffer.new(28, 4)
    harness.render_external(buffer, Tui::Rect.new(0, 0, 28, 4), external_review_preview)

    footer = harness.row_text(buffer, 3)
    footer.should_not contain("Accept")
    footer.should_not contain("Reject")
    footer.should contain("Enter [Later]")
    footer.strip.empty?.should be_false
  end

  it "keeps Later as the safe default and leaves the conflict unresolved" do
    with_external_review_workspace do |root, app|
      path = root / "later.cr"
      File.write(path, "editor\n")
      buffer = app.open_public(path)
      File.write(path, "disk\n")
      app.poll_public

      app.open_review_public.should be_true
      app.review_open_public?.should be_true
      app.review_choice_public.should eq "Later"
      app.send_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true

      app.review_open_public?.should be_false
      buffer.editor.text.should eq "editor\n"
      File.read(path).should eq "disk\n"
      buffer.external_conflict.should_not be_nil
    end
  end

  it "applies explicit Reload and Overwrite choices only after cycling" do
    with_external_review_workspace do |root, app|
      path = root / "actions.cr"
      File.write(path, "editor\n")
      buffer = app.open_public(path)

      File.write(path, "reloaded\n")
      app.poll_public
      app.open_review_public.should be_true
      app.send_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      app.review_choice_public.should eq "Reload"
      app.send_public(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift)).should be_true
      app.review_choice_public.should eq "Later"
      app.send_public(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift)).should be_true
      app.review_choice_public.should eq "Overwrite"
      app.send_public(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift)).should be_true
      app.review_choice_public.should eq "Reload"
      app.send_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      buffer.editor.text.should eq "reloaded\n"
      buffer.external_conflict.should be_nil

      buffer.editor.replace_text("ours\n")
      File.write(path, "overwrite-target\n")
      app.poll_public
      app.open_review_public.should be_true
      app.send_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      app.send_public(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      app.review_choice_public.should eq "Overwrite"
      app.send_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true

      app.review_open_public?.should be_false
      File.read(path).should eq "ours\n"
      buffer.external_conflict.should be_nil
    end
  end
end
