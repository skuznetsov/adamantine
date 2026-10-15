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

private struct ExternalWriterOutcome
  getter exception : Exception?

  def initialize(@exception : Exception?)
  end
end

private def await_external_writer(outcome : Channel(ExternalWriterOutcome)) : ExternalWriterOutcome
  select
  when result = outcome.receive
    result
  when timeout(2.seconds)
    raise "external test writer did not complete within 2 seconds"
  end
end

private def raise_external_writer_exception(outcome : ExternalWriterOutcome) : Nil
  if exception = outcome.exception
    raise exception
  end
end

private def await_external_partial_write(
  partial_written : Channel(Nil),
  outcome : Channel(ExternalWriterOutcome),
) : ExternalWriterOutcome?
  select
  when partial_written.receive
    nil
  when result = outcome.receive
    result
  when timeout(2.seconds)
    raise "external test writer did not reach its partial-write barrier within 2 seconds"
  end
end

private def take_completed_external_writer(outcome : Channel(ExternalWriterOutcome)) : ExternalWriterOutcome?
  select
  when result = outcome.receive
    result
  else
    nil
  end
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
      split = theirs_two.bytesize // 2
      first_chunk = theirs_two.byte_slice(0, split).not_nil!
      second_chunk = theirs_two.byte_slice(split, theirs_two.bytesize - split).not_nil!
      File.write(file, base)
      harness = ExternalChangeReviewHarness.new
      buffer = harness.open(file)
      File.write(file, theirs_one)
      raise "expected first external conflict" unless harness.orchestrator.poll_external_files == 1
      review = harness.orchestrator.prepare_external_review(buffer).not_nil!

      start_writer = Channel(Nil).new(1)
      writer_started_during_reload = Channel(Bool).new(1)
      partial_written = Channel(Nil).new(1)
      release_writer = Channel(Nil).new(1)
      writer_outcome = Channel(ExternalWriterOutcome).new(1)
      reload_returned = false
      spawn do
        exception : Exception? = nil
        begin
          start_writer.receive
          writer_started_during_reload.send(!reload_returned)
          File.open(file, "w") do |io|
            io.write(first_chunk.to_slice)
            io.flush
            partial_written.send(nil)
            release_writer.receive
            io.write(second_chunk.to_slice)
            io.flush
          end
        rescue ex
          exception = ex
        ensure
          writer_outcome.send(ExternalWriterOutcome.new(exception))
        end
      end

      # The guarded reload yields after its first 64 KiB read. Start the
      # replacement beforehand and record that it reached the writer fiber
      # before apply returns, then hold it incomplete until the guard rejects.
      start_writer.send(nil)
      completed_writer : ExternalWriterOutcome? = nil
      applied = false
      begin
        applied = harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Reload)
        reload_returned = true
        raise "disk change must invalidate the review" if applied
        started_during_reload = select
        when started = writer_started_during_reload.receive
          started
        when timeout(2.seconds)
          raise "external test writer did not report guarded-reload overlap within 2 seconds"
        end
        raise "writer must overlap the guarded reload" unless started_during_reload
        raise "editor must remain OURS/BASE after stale review" unless buffer.editor.text == base

        completed_writer = await_external_partial_write(partial_written, writer_outcome)
        if result = completed_writer
          raise_external_writer_exception(result)
          raise "writer completed before the partial-write barrier"
        end

        completed_writer = take_completed_external_writer(writer_outcome)
        if result = completed_writer
          raise_external_writer_exception(result)
          raise "external writer must remain incomplete until explicitly released"
        end

        raise "partial disk bytes must remain untouched while the writer is paused" unless File.read(file) == first_chunk
      ensure
        # Always unblock the writer before propagating an assertion or timeout.
        release_writer.send(nil)
        completed_writer ||= await_external_writer(writer_outcome)
        raise_external_writer_exception(completed_writer.not_nil!)
      end

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

      writer_outcome = Channel(ExternalWriterOutcome).new(1)
      spawn do
        exception : Exception? = nil
        begin
          File.write(file, later)
        rescue ex
          exception = ex
        ensure
          writer_outcome.send(ExternalWriterOutcome.new(exception))
        end
      end

      applied = false
      begin
        applied = harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Overwrite)
      ensure
        raise_external_writer_exception(await_external_writer(writer_outcome))
      end
      raise "racing disk fingerprint must block overwrite" if applied
      raise "later disk bytes must remain" unless File.read(file) == later
    end
  end

  it "rejects overwrite while a chunked external replacement is still incomplete" do
    with_review_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "overwrite-partial-racing.cr")
      base = "base\n" + ("a" * 131_072)
      theirs = "theirs\n" + ("b" * 131_072)
      later = "later\n" + ("c" * 131_072)
      split = later.bytesize // 2
      first_chunk = later.byte_slice(0, split).not_nil!
      second_chunk = later.byte_slice(split, later.bytesize - split).not_nil!
      File.write(file, base)
      harness = ExternalChangeReviewHarness.new
      buffer = harness.open(file)
      buffer.editor.replace_text("ours\n" + ("d" * 131_072))
      File.write(file, theirs)
      raise "expected external conflict" unless harness.orchestrator.poll_external_files == 1
      review = harness.orchestrator.prepare_external_review(buffer).not_nil!

      start_writer = Channel(Nil).new(1)
      partial_written = Channel(Nil).new(1)
      release_writer = Channel(Nil).new(1)
      writer_outcome = Channel(ExternalWriterOutcome).new(1)
      spawn do
        exception : Exception? = nil
        begin
          start_writer.receive
          File.open(file, "w") do |io|
            io.write(first_chunk.to_slice)
            io.flush
            partial_written.send(nil)
            release_writer.receive
            io.write(second_chunk.to_slice)
            io.flush
          end
        rescue ex
          exception = ex
        ensure
          writer_outcome.send(ExternalWriterOutcome.new(exception))
        end
      end

      # The guarded fingerprint yields after its first 64 KiB read, allowing
      # this writer to replace the path and pause after one flushed chunk.
      start_writer.send(nil)
      completed_writer : ExternalWriterOutcome? = nil
      applied = false
      begin
        applied = harness.orchestrator.apply_external_review(review, Adamantine::ExternalConflictAction::Overwrite)
        raise "racing disk fingerprint must block overwrite" if applied

        completed_writer = await_external_partial_write(partial_written, writer_outcome)
        if result = completed_writer
          raise_external_writer_exception(result)
          raise "writer completed before the partial-write barrier"
        end

        completed_writer = take_completed_external_writer(writer_outcome)
        if result = completed_writer
          raise_external_writer_exception(result)
          raise "external writer must remain incomplete until explicitly released"
        end

        raise "paused external writer should expose only its first chunk" unless File.read(file) == first_chunk
      ensure
        # Always unblock the owned writer before propagating an assertion or
        # timeout, and do not tear down the workspace before it has completed.
        release_writer.send(nil)
        completed_writer ||= await_external_writer(writer_outcome)
        raise_external_writer_exception(completed_writer.not_nil!)
      end

      raise "later disk bytes must remain after writer completion" unless File.read(file) == later
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
