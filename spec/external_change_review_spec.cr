require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/document_orchestrator"
require "../src/adamantine/document_session"
require "../src/adamantine/lsp_client"
require "../src/adamantine/document_types"
require "../src/adamantine/uri_codec"

private class ExternalChangeReviewHarness
  getter orchestrator : Adamantine::DocumentOrchestrator
  getter session : Adamantine::DocumentSession

  def initialize(
    sync_change : Proc(Adamantine::OpenBuffer, Tui::TextEditor::TextChange, Nil) = ->(_buffer : Adamantine::OpenBuffer, _change : Tui::TextEditor::TextChange) { },
  )
    @session = Adamantine::DocumentSession.new
    tabs = Tui::TabbedPanel.new("tabs")
    log = Tui::Log.new("status")
    @orchestrator = Adamantine::DocumentOrchestrator.new(
      @session,
      tabs,
      log,
      ->(_editor : Tui::TextEditor) { },
      ->(_editor : Tui::TextEditor, _buffer : Adamantine::OpenBuffer?) { },
      ->(_editor : Tui::TextEditor, _buffer : Adamantine::OpenBuffer) { },
      ->(_path : Path) { "text" },
      ->(path : Path) { Adamantine::UriCodec.path_to_uri(path) },
      ->(uri : String) { Adamantine::UriCodec.uri_to_path(uri) },
      -> { },
      ->(_buffer : Adamantine::OpenBuffer) { },
      sync_change,
      ->(_buffer : Adamantine::OpenBuffer) { },
      ->(_uri : String) { },
      -> { nil.as(Adamantine::DocumentOrchestrator::CurrentLspContext) },
    )
  end

  def open(path : Path) : Adamantine::OpenBuffer
    raise "failed to open test file" unless @orchestrator.open_file(path)
    @session.open_buffers[path.to_s].not_nil!
  end
end

private def with_review_workspace(prefix : String = "external-review-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::ExternalChangeReview do
  it "captures an immutable OURS/THEIRS inline review from a conflict" do
    with_review_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "review.cr")
      File.write(file, "base\n")
      harness = ExternalChangeReviewHarness.new
      buffer = harness.open(file)

      File.write(file, "theirs\n")
      raise "expected an external conflict" unless harness.orchestrator.poll_external_files == 1
      conflict = buffer.external_conflict.not_nil!
      review = harness.orchestrator.prepare_external_review(buffer)
      raise "expected a review" unless review
      review = review.not_nil!

      raise "review should capture the exact buffer" unless review.buffer.same?(buffer)
      raise "review should capture the exact editor" unless review.editor.same?(buffer.editor)
      raise "review should capture the editor version" unless review.version == buffer.version
      raise "review should capture the watch token" unless review.watch_token == conflict.watch_token
      raise "review should capture the conflict generation" unless review.conflict_generation == conflict.generation
      raise "stable THEIRS should provide a preview" unless review.preview
      raise "stable THEIRS should be available" unless review.preview_available?
      raise "preview should show the original bytes" unless review.preview.not_nil!.row_at(review.preview.not_nil!.first_change_row).text == "base"
      raise "preview should show the external bytes" unless review.preview.not_nil!.row_at(review.preview.not_nil!.first_change_row + 1).text == "theirs"

      buffer.editor.insert_text("ours-")
      raise "captured preview must retain OURS" unless review.preview.not_nil!.row_at(review.preview.not_nil!.first_change_row).text == "base"
      raise "stale editor review must not apply" if harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Reload)
      raise "stale review must not replace editor bytes" unless buffer.editor.text == "ours-base\n"
      raise "stale review must leave disk untouched" unless File.read(file) == "theirs\n"
    end
  end

  it "returns an explicit unavailable review for a deleted candidate" do
    with_review_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "deleted.cr")
      File.write(file, "base\n")
      harness = ExternalChangeReviewHarness.new
      buffer = harness.open(file)
      File.delete(file.to_s)
      raise "expected a deletion conflict" unless harness.orchestrator.poll_external_files == 1

      review = harness.orchestrator.prepare_external_review(buffer)
      raise "expected an unavailable review" unless review
      review = review.not_nil!
      raise "deleted review should have no preview" unless review.preview.nil?
      raise "deleted review should expose its status" unless review.status_label == "missing"
      raise "deleted review should mark preview unavailable" if review.preview_available?
      raise "reload of deleted candidate must fail" if harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Reload)
      raise "explicit missing recreate should succeed" unless harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Overwrite)
      raise "recreate should restore the editor bytes" unless File.read(file) == "base\n"
    end
  end

  it "refuses a missing-path recreate after the path reappears" do
    with_review_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "reappeared.cr")
      File.write(file, "base\n")
      harness = ExternalChangeReviewHarness.new
      buffer = harness.open(file)
      File.delete(file.to_s)
      raise "expected a deletion conflict" unless harness.orchestrator.poll_external_files == 1
      review = harness.orchestrator.prepare_external_review(buffer).not_nil!

      File.write(file, "intruder\n")
      applied = harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Overwrite)
      raise "reappeared path must invalidate recreate" if applied
      raise "reappeared bytes must remain" unless File.read(file) == "intruder\n"
    end
  end

  it "rejects a review after the disk candidate changes during the guarded read" do
    with_review_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "racing.cr")
      base = "base\n" + ("a" * 131_072)
      theirs_one = "theirs-one\n" + ("b" * 131_072)
      theirs_two = "theirs-two-different\n" + ("c" * 131_072)
      File.write(file, base)
      harness = ExternalChangeReviewHarness.new
      buffer = harness.open(file)
      File.write(file, theirs_one)
      raise "expected first external conflict" unless harness.orchestrator.poll_external_files == 1
      review = harness.orchestrator.prepare_external_review(buffer).not_nil!

      spawn { File.write(file, theirs_two) }
      applied = harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Reload)
      raise "disk change must invalidate the review" if applied
      raise "editor must remain OURS/BASE after stale review" unless buffer.editor.text == base
      raise "new disk bytes must remain untouched" unless File.read(file) == theirs_two
    end
  end

  it "rejects an editor mutation which races the yielding review capture" do
    with_review_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "editor-racing.cr")
      base = "base\n" + ("a" * 131_072)
      theirs = "theirs\n" + ("b" * 131_072)
      File.write(file, base)
      harness = ExternalChangeReviewHarness.new
      buffer = harness.open(file)
      File.write(file, theirs)
      raise "expected external conflict" unless harness.orchestrator.poll_external_files == 1

      spawn { buffer.editor.insert_text("raced-") }
      review = harness.orchestrator.prepare_external_review(buffer).not_nil!
      raise "editor race must invalidate the captured action" if harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Reload)
      raise "racing editor bytes must remain" unless buffer.editor.text.starts_with?("raced-")
    end
  end

  it "rejects an editor mutation during the guarded reload and overwrite reads" do
    with_review_workspace do |tmp_dir|
      [
        Adamantine::ExternalConflictAction::Reload,
        Adamantine::ExternalConflictAction::Overwrite,
      ].each do |action|
        file = Path.new(tmp_dir, "apply-editor-racing-#{action.to_s.downcase}.cr")
        base = "base\n" + ("a" * 131_072)
        theirs = "theirs\n" + ("b" * 131_072)
        File.write(file, base)
        harness = ExternalChangeReviewHarness.new
        buffer = harness.open(file)
        if action == Adamantine::ExternalConflictAction::Overwrite
          buffer.editor.replace_text("ours\n" + ("d" * 131_072))
        end
        File.write(file, theirs)
        raise "expected external conflict for #{action}" unless harness.orchestrator.poll_external_files == 1
        review = harness.orchestrator.prepare_external_review(buffer).not_nil!

        spawn { buffer.editor.insert_text("raced-") }
        applied = harness.orchestrator.apply_external_review(review, action)
        raise "#{action} must reject an editor mutation during its guarded read" if applied
        raise "#{action} editor mutation must remain" unless buffer.editor.text.starts_with?("raced-")
        raise "#{action} must not replace disk bytes" unless File.read(file) == theirs
      end
    end
  end

  it "rejects overwrite when its yielding pre-rename fingerprint races" do
    with_review_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "overwrite-racing.cr")
      base = "base\n" + ("a" * 131_072)
      theirs = "theirs\n" + ("b" * 131_072)
      later = "later\n" + ("c" * 131_072)
      File.write(file, base)
      harness = ExternalChangeReviewHarness.new
      buffer = harness.open(file)
      buffer.editor.replace_text("ours\n" + ("d" * 131_072))
      File.write(file, theirs)
      raise "expected external conflict" unless harness.orchestrator.poll_external_files == 1
      review = harness.orchestrator.prepare_external_review(buffer).not_nil!

      spawn { File.write(file, later) }
      applied = harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Overwrite)
      raise "racing disk fingerprint must block overwrite" if applied
      raise "later disk bytes must remain" unless File.read(file) == later
    end
  end

  it "does not overwrite a stable non-text candidate without a preview" do
    with_review_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "binary.cr")
      File.write(file, "base\n")
      harness = ExternalChangeReviewHarness.new
      buffer = harness.open(file)
      binary = "\0\xff\n"
      File.write(file, binary.to_slice)
      raise "expected binary conflict" unless harness.orchestrator.poll_external_files == 1
      review = harness.orchestrator.prepare_external_review(buffer).not_nil!
      raise "binary candidate must have no preview" if review.preview_available?
      raise "binary overwrite must fail closed" if harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Overwrite)
      raise "binary disk bytes must remain" unless File.read(file) == binary
    end
  end

  it "retains a newer conflict raised by a yielding reload callback" do
    with_review_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "reload-callback-racing.cr")
      base = "base\n"
      theirs = "theirs\n"
      later = "later\n"
      File.write(file, base)
      race_callback_enabled = true
      harness_ref : ExternalChangeReviewHarness? = nil
      sync_change = ->(_buffer : Adamantine::OpenBuffer, _change : Tui::TextEditor::TextChange) do
        if race_callback_enabled
          race_callback_enabled = false
          File.write(file, later)
          harness_ref.not_nil!.orchestrator.poll_external_files
        end
      end
      harness = ExternalChangeReviewHarness.new(sync_change)
      harness_ref = harness
      buffer = harness.open(file)
      File.write(file, theirs)
      raise "expected external conflict" unless harness.orchestrator.poll_external_files == 1
      review = harness.orchestrator.prepare_external_review(buffer).not_nil!

      applied = harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Reload)
      raise "reload with newer callback conflict must fail" if applied
      newer = buffer.external_conflict
      raise "newer callback conflict must remain visible" unless newer
      raise "newer conflict should describe latest disk bytes" unless newer.not_nil!.event.current.digest == Adamantine::FileRevision.capture(file).digest
      raise "latest disk bytes must remain" unless File.read(file) == later
    end
  end
end
