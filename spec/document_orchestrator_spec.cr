require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/document_orchestrator"
require "../src/adamantine/document_session"
require "../src/adamantine/document_types"
require "../src/adamantine/lsp_client"
require "../src/adamantine/uri_codec"

private class DocumentOrchestratorHarness
  getter orchestrator : Adamantine::DocumentOrchestrator
  getter document_session : Adamantine::DocumentSession
  getter editor_tabs : Tui::TabbedPanel
  getter focus_calls : Int32
  getter sync_open_calls : Int32
  getter sync_change_calls : Int32
  getter sync_save_calls : Int32
  getter sync_changes : Array(Tui::TextEditor::TextChange)
  getter closed_lsp_uris : Array(String)
  getter header_calls : Int32
  getter status_log : Tui::Log
  getter sync_open_callback : Proc(Adamantine::OpenBuffer, Nil)
  getter sync_change_callback : Proc(Adamantine::OpenBuffer, Tui::TextEditor::TextChange, Nil)
  getter sync_save_callback : Proc(Adamantine::OpenBuffer, Nil)
  getter close_lsp_document_callback : Proc(String, Nil)
  getter style_callback : Proc(Tui::TextEditor, Adamantine::OpenBuffer?, Nil)
  getter configure_style_callback : Proc(Tui::TextEditor, Adamantine::OpenBuffer, Nil)
  getter external_conflicts : Array(Adamantine::ExternalFileConflict)

  def initialize(
    @sync_open_callback : Proc(Adamantine::OpenBuffer, Nil) = ->(_buffer : Adamantine::OpenBuffer) { },
    @sync_change_callback : Proc(Adamantine::OpenBuffer, Tui::TextEditor::TextChange, Nil) = ->(_buffer : Adamantine::OpenBuffer, _change : Tui::TextEditor::TextChange) { },
    @sync_save_callback : Proc(Adamantine::OpenBuffer, Nil) = ->(_buffer : Adamantine::OpenBuffer) { },
    @close_lsp_document_callback : Proc(String, Nil) = ->(_uri : String) { },
    @style_callback : Proc(Tui::TextEditor, Adamantine::OpenBuffer?, Nil) = ->(_editor : Tui::TextEditor, _buffer : Adamantine::OpenBuffer?) { },
    @configure_style_callback : Proc(Tui::TextEditor, Adamantine::OpenBuffer, Nil) = ->(_editor : Tui::TextEditor, _buffer : Adamantine::OpenBuffer) { },
  )
    @document_session = Adamantine::DocumentSession.new
    @editor_tabs = Tui::TabbedPanel.new("tabs")
    @status_log = Tui::Log.new("status")
    @focus_calls = 0
    @sync_open_calls = 0
    @sync_change_calls = 0
    @sync_save_calls = 0
    @sync_changes = [] of Tui::TextEditor::TextChange
    @closed_lsp_uris = [] of String
    @external_conflicts = [] of Adamantine::ExternalFileConflict
    @header_calls = 0

    @orchestrator = Adamantine::DocumentOrchestrator.new(
      @document_session,
      @editor_tabs,
      @status_log,
      ->(_editor : Tui::TextEditor) { @focus_calls += 1 },
      @style_callback,
      @configure_style_callback,
      ->(path : Path) { path.extension == ".cr" ? "crystal" : "text" },
      ->(path : Path) { Adamantine::UriCodec.path_to_uri(path) },
      ->(uri : String) { Adamantine::UriCodec.uri_to_path(uri) },
      -> { @header_calls += 1 },
      ->(buffer : Adamantine::OpenBuffer) do
        @sync_open_calls += 1
        @sync_open_callback.call(buffer)
      end,
      ->(buffer : Adamantine::OpenBuffer, change : Tui::TextEditor::TextChange) do
        @sync_change_calls += 1
        @sync_changes << change
        @sync_change_callback.call(buffer, change)
      end,
      ->(buffer : Adamantine::OpenBuffer) do
        @sync_save_calls += 1
        @sync_save_callback.call(buffer)
      end,
      ->(uri : String) do
        @closed_lsp_uris << uri
        @close_lsp_document_callback.call(uri)
      end,
      -> { nil.as(Adamantine::DocumentOrchestrator::CurrentLspContext) },
      ->(_buffer : Adamantine::OpenBuffer, conflict : Adamantine::ExternalFileConflict) do
        @external_conflicts << conflict
      end
    )

    @editor_tabs.on_tab_close do |tab_id|
      @orchestrator.close_tab(tab_id)
    end
  end

  def active_uri : String?
    @orchestrator.current_buffer.try(&.uri)
  end

  def cursor : Tuple(Int32, Int32)
    editor = @orchestrator.current_editor
    raise "expected active editor" unless editor
    {editor.cursor_line, editor.cursor_col}
  end

  def open_file(path : Path, line : Int32? = nil, col : Int32? = nil) : Bool
    @orchestrator.open_file(path, line, col)
  end

  def active_tab_label : String?
    tab_id = @editor_tabs.active_tab_id
    return nil unless tab_id
    tab = @editor_tabs.tabs.find { |item| item.id == tab_id }
    tab.nil? ? nil : tab.label
  end

  def editor_for_active : Tui::TextEditor?
    @orchestrator.current_editor
  end

  def warning_messages : Array(String)
    @status_log.entries.select do |entry|
      entry.level == Tui::Log::Level::Warning
    end.map(&.message)
  end

  def current_conflict : Adamantine::ExternalFileConflict?
    @orchestrator.current_buffer.try(&.external_conflict)
  end
end

private def file_uri(path : Path) : String
  Adamantine::UriCodec.path_to_uri(path)
end

private def with_temp_workspace(prefix : String = "editor-orchestrator-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::DocumentOrchestrator do
  it "reuses an existing tab and restores cursor when opening the same file" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "reuse.cr")
      File.write(file, "alpha\nbeta\n")

      harness = DocumentOrchestratorHarness.new
      opened = harness.open_file(file, 0, 1)
      raise "expected open_file to succeed" unless opened
      raise "first open should create one buffer" unless harness.document_session.open_buffers.size == 1
      raise "first open should focus editor" unless harness.focus_calls == 1
      raise "first open should sync once" unless harness.sync_open_calls == 1
      raise "wrong active uri" unless harness.active_uri == file_uri(file)
      raise "cursor mismatch after first open" unless harness.cursor == {0, 1}

      reopened = harness.open_file(file, 1, 0)
      raise "expected existing file open to succeed" unless reopened
      raise "second open should reuse existing tab" unless harness.document_session.open_buffers.size == 1
      raise "second open should keep open count at one tab" unless harness.editor_tabs.tabs.size == 1
      raise "second open should restore cursor" unless harness.cursor == {1, 0}
      raise "second open should not re-sync open" unless harness.sync_open_calls == 1
      raise "cursor reopen should keep uri active" unless harness.active_uri == file_uri(file)
      raise "second open should focus again" unless harness.focus_calls == 2
    end
  end

  it "removes tab from both session and widget when close_tab is called" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      File.write(file_a, "one\n")
      File.write(file_b, "two\n")

      harness = DocumentOrchestratorHarness.new
      harness.open_file(file_a)
      harness.open_file(file_b)
      raise "two buffers expected" unless harness.document_session.open_buffers.size == 2
      raise "two tabs expected" unless harness.editor_tabs.tabs.size == 2
      raise "active should be file b" unless harness.active_uri == file_uri(file_b)

      harness.editor_tabs.close_tab(file_a.to_s)
      raise "should remove closed buffer" unless harness.document_session.open_buffers.size == 1
      raise "should remove closed tab" unless harness.editor_tabs.tabs.none? { |tab| tab.id == file_a.to_s }
      raise "wrong close callback" unless harness.closed_lsp_uris == [file_uri(file_a)]
      raise "active should remain file b" unless harness.active_uri == file_uri(file_b)
      harness.editor_tabs.close_tab(file_b.to_s)
      raise "close should be idempotent for existing open buffer" unless harness.closed_lsp_uris == [file_uri(file_a), file_uri(file_b)]
      raise "all buffers should be closed" unless harness.document_session.open_buffers.empty?
      raise "all tabs should be closed" unless harness.editor_tabs.tabs.empty?
    end
  end

  it "refreshes header at least once when active tab is closed and no buffers remain" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "single.cr")
      File.write(file, "single\n")

      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      raise "initial header update expected" unless harness.header_calls > 0

      harness.orchestrator.close_active_tab
      raise "all open buffers should be cleared" unless harness.document_session.open_buffers.empty?
      raise "all tabs should be closed" unless harness.editor_tabs.tabs.empty?
      raise "lsp close callback expected" unless harness.closed_lsp_uris == [file_uri(file)]
      raise "expected extra header updates after close" unless harness.header_calls > 1
    end
  end

  it "returns false when open_file points to a missing path" do
    with_temp_workspace do |tmp_dir|
      missing = Path.new(tmp_dir, "missing.cr")
      harness = DocumentOrchestratorHarness.new
      opened = harness.open_file(missing)

      raise "expected open_file to fail for missing file" unless opened == false
      raise "should not create session state for missing file" unless harness.document_session.open_buffers.empty?
      raise "should not sync missing file open" unless harness.sync_open_calls == 0
    end
  end

  it "calls change handler and marks tab when content is edited" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "edit.cr")
      File.write(file, "hello\n")

      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      raise "active tab label should start clean" unless harness.active_tab_label == "edit.cr"
      raise "sync_change should not be called yet" unless harness.sync_change_calls == 0

      editor = harness.editor_for_active
      raise "expected active editor" if editor.nil?
      editor.not_nil!.insert_char('!')

      raise "sync_change should be triggered after edit" unless harness.sync_change_calls == 1
      raise "buffer version should advance after edit" unless harness.orchestrator.current_buffer.try(&.version) == 2
      raise "active tab label should mark modified" unless harness.active_tab_label == "edit.cr*"
      change = harness.sync_changes.first
      raise "change should be incremental" unless change.incremental?
      raise "wrong change range" unless change.start == Tui::TextEditor::TextPosition.new(0, 0, 0) && change.finish == Tui::TextEditor::TextPosition.new(0, 0, 0)
      raise "wrong replacement text" unless change.text == "!"
    end
  end

  it "calls save handler and clears modified marker on save" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "save.cr")
      File.write(file, "line1\n")

      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)

      editor = harness.editor_for_active
      raise "expected active editor" if editor.nil?
      editor.not_nil!.insert_char('!')
      raise "modified marker expected after edit" unless harness.active_tab_label == "save.cr*"

      raise "orchestrated save should succeed" unless harness.orchestrator.save_active

      raise "sync_save should be called after save" unless harness.sync_save_calls == 1
      raise "modified marker should clear after save" unless harness.active_tab_label == "save.cr"
    end
  end

  it "returns false and logs a failure when the active file cannot be saved" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "save-failure.cr")
      File.write(file, "start\n")

      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      editor = harness.editor_for_active
      raise "expected active editor" if editor.nil?
      editor.not_nil!.insert_char('!')

      File.delete(file.to_s)
      Dir.mkdir(file.to_s)

      saved = harness.orchestrator.save_active
      raise "save_active should report failed save" unless saved == false
      raise "failed save should leave buffer dirty" unless editor.not_nil!.modified?
      raise "failed save should be logged" unless harness.warning_messages.any? { |msg| msg.includes?("Failed to save") }
    end
  end

  it "contains sync_open callback failures after local buffer creation" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "open-failure.cr")
      File.write(file, "start\n")

      harness = DocumentOrchestratorHarness.new(
        sync_open_callback: ->(_buffer : Adamantine::OpenBuffer) { raise "sync open failed" }
      )
      opened = harness.open_file(file)

      raise "local open should succeed when sync_open fails" unless opened
      raise "local buffer should remain usable after sync_open failure" unless harness.document_session.open_buffers.size == 1
      raise "sync_open failure should be logged" unless harness.warning_messages.any? { |msg| msg.includes?("sync_open") && msg.includes?("failed") }
    end
  end

  it "keeps editing path safe if sync_change callback fails" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "callback-fail.cr")
      File.write(file, "start\n")

      harness = DocumentOrchestratorHarness.new(
        sync_change_callback: ->(_buffer : Adamantine::OpenBuffer, _change : Tui::TextEditor::TextChange) { raise "sync change failed" }
      )
      harness.open_file(file)

      editor = harness.editor_for_active
      raise "expected active editor" if editor.nil?
      editor.not_nil!.insert_char('x')

      raise "exception should be swallowed by orchestrator" unless harness.warning_messages.any? { |msg| msg.includes?("sync_change") && msg.includes?("failed") }
      raise "open and change should still update version" unless harness.orchestrator.current_buffer.try(&.version) == 2
      raise "change callback counter still increments" unless harness.sync_change_calls == 1
    end
  end

  it "keeps save path safe if sync_save callback fails" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "save-fail.cr")
      File.write(file, "start\n")

      harness = DocumentOrchestratorHarness.new(
        sync_save_callback: ->(_buffer : Adamantine::OpenBuffer) { raise "sync save failed" }
      )
      harness.open_file(file)

      editor = harness.editor_for_active
      raise "expected active editor" if editor.nil?
      editor.not_nil!.insert_char('!')
      raise "orchestrated save should succeed" unless harness.orchestrator.save_active

      raise "exception should be swallowed by orchestrator" unless harness.warning_messages.any? { |msg| msg.includes?("sync_save") && msg.includes?("failed") }
      raise "save should still clear modified indicator" unless harness.active_tab_label == "save-fail.cr"
      raise "save callback counter should increment despite failure" unless harness.sync_save_calls == 1
    end
  end

  it "keeps tab cleanup safe if close_lsp callback fails" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "close-fail.cr")
      File.write(file, "line\n")

      harness = DocumentOrchestratorHarness.new(
        close_lsp_document_callback: ->(_uri : String) { raise "close lsp failed" }
      )
      harness.open_file(file)
      harness.orchestrator.close_active_tab

      raise "buffer should be removed despite callback failure" unless harness.document_session.open_buffers.empty?
      raise "tabs should be removed despite callback failure" unless harness.editor_tabs.tabs.empty?
      raise "warning should be recorded" unless harness.warning_messages.any? { |msg| msg.includes?("close_lsp_document") && msg.includes?("failed") }
    end
  end

  it "detects an external edit without changing the in-memory buffer" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "external.cr")
      File.write(file, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)

      File.write(file, "theirs\n")
      raise "one external event expected" unless harness.orchestrator.poll_external_files == 1

      conflict = harness.current_conflict
      raise "conflict should be retained" unless conflict
      raise "event should be changed" unless conflict.not_nil!.event.changed?
      raise "editor bytes must remain BASE" unless harness.editor_for_active.try(&.text) == "base\n"
      raise "tab should expose conflict" unless harness.active_tab_label == "external.cr!"
      raise "UI callback should run once" unless harness.external_conflicts.size == 1
    end
  end

  it "keeps OURS without writing and leaves the conflict unresolved" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "keep.cr")
      File.write(file, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      editor = harness.editor_for_active.not_nil!
      editor.insert_text("ours-")
      File.write(file, "theirs\n")
      harness.orchestrator.poll_external_files
      conflict = harness.current_conflict.not_nil!

      kept = harness.orchestrator.resolve_external_conflict(
        file.to_s,
        conflict.watch_token,
        conflict.generation,
        Adamantine::ExternalConflictAction::Keep
      )

      raise "keep should accept the current generation" unless kept
      raise "keep must not write OURS" unless File.read(file) == "theirs\n"
      raise "keep must preserve OURS" unless editor.text == "ours-base\n"
      raise "keep must leave conflict visible" unless harness.current_conflict
      raise "unresolved conflict must block close" if harness.orchestrator.can_close_tab?(file.to_s)
    end
  end

  it "clears a kept conflict when the disk returns to the accepted revision" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "reverted-conflict.cr")
      File.write(file, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)

      File.write(file, "theirs\n")
      harness.orchestrator.poll_external_files
      stale = harness.current_conflict.not_nil!
      harness.orchestrator.resolve_external_conflict(
        file.to_s,
        stale.watch_token,
        stale.generation,
        Adamantine::ExternalConflictAction::Keep
      ).should be_true

      File.write(file, "base\n")
      raise "reversion should still be observed" unless harness.orchestrator.poll_external_files == 1
      raise "accepted BASE reversion should clear the conflict" if harness.current_conflict
      raise "clean editor bytes should remain unchanged" unless harness.editor_for_active.try(&.text) == "base\n"
      raise "tab should no longer show a conflict" unless harness.active_tab_label == "reverted-conflict.cr"
      raise "old dialog action must be invalid after reversion" if harness.orchestrator.resolve_external_conflict(
                                                                     file.to_s,
                                                                     stale.watch_token,
                                                                     stale.generation,
                                                                     Adamantine::ExternalConflictAction::Overwrite
                                                                   )
      raise "stale action must not change disk" unless File.read(file) == "base\n"
    end
  end

  it "reloads THEIRS as clean and retains OURS as structural undo history" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "reload.cr")
      File.write(file, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      editor = harness.editor_for_active.not_nil!
      editor.insert_text("ours-")
      File.write(file, "theirs\n")
      harness.orchestrator.poll_external_files
      conflict = harness.current_conflict.not_nil!
      changes_before = harness.sync_changes.size

      reloaded = harness.orchestrator.resolve_external_conflict(
        file.to_s,
        conflict.watch_token,
        conflict.generation,
        Adamantine::ExternalConflictAction::Reload
      )

      raise "reload should accept the current generation" unless reloaded
      raise "THEIRS should become the editor text" unless editor.text == "theirs\n"
      raise "THEIRS should be clean" if editor.modified?
      raise "reload should clear conflict" if harness.current_conflict
      raise "reload should emit one LSP change" unless harness.sync_changes.size == changes_before + 1
      raise "reload LSP change must be full" unless harness.sync_changes.last.full?
      raise "undo should restore OURS" unless editor.undo
      raise "OURS bytes were not retained" unless editor.text == "ours-base\n"
      raise "restored OURS must be dirty" unless editor.modified?
      raise "redo should restore THEIRS" unless editor.redo
      raise "redo did not restore THEIRS" unless editor.text == "theirs\n"
      raise "redone THEIRS must be clean" if editor.modified?
      raise "accepted reload must not self-notify" unless harness.orchestrator.poll_external_files == 0
    end
  end

  it "accepts a same-content replacement without creating duplicate undo history" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "same-content-replacement.cr")
      replacement = Path.new(tmp_dir, "replacement.cr")
      File.write(file, "base\n")
      File.write(replacement, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      editor = harness.editor_for_active.not_nil!
      changes_before = harness.sync_changes.size

      File.rename(replacement, file)
      harness.orchestrator.poll_external_files
      conflict = harness.current_conflict.not_nil!
      raise "same-content inode change should be replacement" unless conflict.event.replaced?

      harness.orchestrator.resolve_external_conflict(
        file.to_s,
        conflict.watch_token,
        conflict.generation,
        Adamantine::ExternalConflictAction::Reload
      ).should be_true

      raise "same bytes should remain clean" if editor.modified?
      raise "same bytes should not create an undo entry" if editor.can_undo?
      raise "same bytes should not emit an LSP change" unless harness.sync_changes.size == changes_before
      raise "accepted replacement should clear conflict" if harness.current_conflict
    end
  end

  it "refuses an ordinary save when disk no longer matches BASE" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "guarded-save.cr")
      File.write(file, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      editor = harness.editor_for_active.not_nil!
      editor.insert_text("ours-")
      File.write(file, "theirs\n")

      raise "stale save must fail" if harness.orchestrator.save_active
      raise "stale save overwrote THEIRS" unless File.read(file) == "theirs\n"
      raise "failed save must preserve OURS" unless editor.text == "ours-base\n"
      raise "failed save must remain dirty" unless editor.modified?
      raise "save mismatch should become a conflict" unless harness.current_conflict
    end
  end

  it "refuses an ordinary save when changed content has the same size and restored mtime" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "same-stamp-save.cr")
      File.write(file, "base\n")
      baseline_mtime = File.info(file).modification_time
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      editor = harness.editor_for_active.not_nil!
      editor.insert_text("ours-")

      File.write(file, "evil\n")
      File.utime(baseline_mtime, baseline_mtime, file)
      raise "test must restore the cheap stamp" unless harness.orchestrator.poll_external_files == 0

      raise "mandatory save-time digest must reject stale BASE" if harness.orchestrator.save_active
      raise "stale save overwrote same-stamp THEIRS" unless File.read(file) == "evil\n"
      raise "failed save must preserve OURS" unless editor.text == "ours-base\n"
      raise "same-stamp mismatch should become a conflict" unless harness.current_conflict
    end
  end

  it "overwrites only the current external generation and suppresses its own save" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "overwrite.cr")
      File.write(file, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      editor = harness.editor_for_active.not_nil!
      editor.insert_text("ours-")
      File.write(file, "theirs\n")
      harness.orchestrator.poll_external_files
      conflict = harness.current_conflict.not_nil!

      overwritten = harness.orchestrator.resolve_external_conflict(
        file.to_s,
        conflict.watch_token,
        conflict.generation,
        Adamantine::ExternalConflictAction::Overwrite
      )

      raise "overwrite should accept the current generation" unless overwritten
      raise "overwrite did not persist OURS" unless File.read(file) == "ours-base\n"
      raise "successful overwrite should be clean" if editor.modified?
      raise "successful overwrite should clear conflict" if harness.current_conflict
      raise "own atomic replacement must not self-notify" unless harness.orchestrator.poll_external_files == 0
    end
  end

  it "stays dirty when an external writer wins during post-rename validation" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "post-rename-race.cr")
      File.write(file, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)
      editor = harness.editor_for_active.not_nil!
      editor.insert_text("ours-")
      writer_finished = Channel(Nil).new

      spawn do
        loop do
          if File.read(file) == "ours-base\n"
            File.write(file, "external-after-rename\n")
            writer_finished.send(nil)
            break
          end
          Fiber.yield
        end
      end

      Fiber.yield
      raise "post-rename mismatch must fail the save" if harness.orchestrator.save_active
      writer_finished.receive
      raise "external winner must remain on disk" unless File.read(file) == "external-after-rename\n"
      raise "post-rename mismatch must leave OURS dirty" unless editor.modified?
      raise "failed post-validation must suppress sync_save" unless harness.sync_save_calls == 0
      raise "post-rename mismatch should become a conflict" unless harness.current_conflict
    end
  end

  it "rejects an action captured from an older external generation" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "stale-action.cr")
      File.write(file, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)

      File.write(file, "theirs-one\n")
      harness.orchestrator.poll_external_files
      first = harness.current_conflict.not_nil!
      File.write(file, "theirs-two\n")
      harness.orchestrator.poll_external_files
      second = harness.current_conflict.not_nil!
      raise "external generation must advance" unless second.generation > first.generation

      stale = harness.orchestrator.resolve_external_conflict(
        file.to_s,
        first.watch_token,
        first.generation,
        Adamantine::ExternalConflictAction::Reload
      )
      raise "stale action must fail" if stale
      raise "stale action changed editor" unless harness.editor_for_active.try(&.text) == "base\n"
      raise "latest conflict must remain" unless harness.current_conflict.try(&.generation) == second.generation
    end
  end

  it "rejects a stale dialog action after the same path is closed and reopened" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "reopened-action.cr")
      File.write(file, "base\n")
      harness = DocumentOrchestratorHarness.new
      harness.open_file(file)

      File.write(file, "candidate\n")
      harness.orchestrator.poll_external_files
      stale = harness.current_conflict.not_nil!
      harness.orchestrator.close_tab(file.to_s)
      File.write(file, "reopened\n")
      harness.open_file(file)

      raise "reopened buffer should use current disk bytes" unless harness.editor_for_active.try(&.text) == "reopened\n"
      raise "old watch token must not target reopened buffer" if harness.orchestrator.resolve_external_conflict(
                                                                   file.to_s,
                                                                   stale.watch_token,
                                                                   stale.generation,
                                                                   Adamantine::ExternalConflictAction::Overwrite
                                                                 )
      raise "stale action must not write the reopened file" unless File.read(file) == "reopened\n"
      raise "stale action must not create a new conflict" if harness.current_conflict
    end
  end
end
