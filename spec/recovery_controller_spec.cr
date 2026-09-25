require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private def with_controller_workspace(prefix : String = "adamantine-recovery-controller-spec", &)
  # File.realpath resolves macOS's /var -> /private/var symlink before the
  # store's private-entry checks inspect each recovery-root component.
  tmp_dir = Path.new(File.realpath(Dir.tempdir), "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private class RecoveryControllerHarness
  getter controller : Adamantine::RecoveryController
  getter document_session : Adamantine::DocumentSession
  getter messages : Array(String)

  def initialize(root : Path, project : Path)
    @document_session = Adamantine::DocumentSession.new
    @messages = [] of String
    @controller = Adamantine::RecoveryController.new(
      root: root,
      project: project,
      buffers: -> { @document_session.open_buffers },
      report: ->(message : String) { @messages << message },
      enabled: true,
    )
  end

  def open_buffer(path : Path, content : String) : Adamantine::OpenBuffer
    editor = Tui::TextEditor.new(path.to_s)
    raise "failed to seed editor" unless editor.load_content_as_saved(content, path)
    open_buffer_with_editor(path, editor)
  end

  def open_buffer_with_editor(path : Path, editor : Tui::TextEditor) : Adamantine::OpenBuffer
    buffer = Adamantine::OpenBuffer.new(path, editor, "text", "file://#{path}")
    @document_session.open_buffers[path.to_s] = buffer
    buffer
  end
end

private class BlockingRecoveryEditor < Tui::TextEditor
  getter started : Channel(Nil)
  getter release : Channel(Nil)

  def initialize(path : String, @started : Channel(Nil), @release : Channel(Nil))
    super(path)
  end

  def write_to(io : IO) : Int32
    @started.send(nil)
    @release.receive
    super
  end
end

private def seed_abandoned_checkpoint(
  root : Path,
  project : Path,
  source : Path,
  content : String,
  version : Int64 = 1_i64,
) : Nil
  store = Adamantine::RecoveryStore.new(root: root, project: project)
  session = store.open_session
  session.write_snapshot(
    source_path: source,
    modified: true,
    version: version,
    freshness: -> { true },
  ) do |io|
    io.write(content.to_slice)
  end
  session.close
ensure
  store.try(&.close)
end

private class RecoveryUiSpecApp < Adamantine::App
  def run_command_public(command : String) : Nil
    open_command_palette_public unless @command_palette.open
    command.each_char { |ch| on_capture(Tui::KeyEvent.new(ch)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def open_command_palette_public : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def start_recovery_and_open_menu_public : Nil
    raise "recovery worker did not start" unless @recovery_controller.start(interval: 1.hour)
    open_recovery_menu
  end

  def open_recovery_menu_public : Nil
    open_recovery_menu
  end

  def context_menu_open? : Bool
    @context_menu.open
  end

  def context_menu_title : String
    @context_menu.title
  end

  def context_menu_labels : Array(String)
    @context_menu.actions.map(&.label)
  end

  def choose_context_menu(index : Int32) : Nil
    @context_menu.index = index
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def dismiss_context_menu_public : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def recovery_candidates : Array(Adamantine::RecoveryController::RecoveryCandidate)
    @recovery_controller.candidates
  end

  def stop_recovery_public : Nil
    @recovery_controller.stop(force: true)
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def buffer_count : Int32
    @document_session.open_buffers.size
  end

  def active_path : Path?
    @editor_tabs.active_tab_id.try { |id| Path.new(id) }
  end

  def buffer_text(path : Path) : String
    @document_session.open_buffers[path.to_s].not_nil!.editor.text
  end

  def buffer_modified?(path : Path) : Bool
    @document_session.open_buffers[path.to_s].not_nil!.editor.modified?
  end

  def recovery_initialized? : Bool
    @recovery_controller.initialized?
  end
end

describe Adamantine::RecoveryController do
  it "retains full checkpoint identity and exposes a read-only preview" do
    with_controller_workspace do |tmp_dir|
      project = Path.new(tmp_dir, "project")
      root = Path.new(tmp_dir, "recovery")
      Dir.mkdir_p(project)
      source = Path.new(project, "preview.txt")
      File.write(source, "saved on disk\n")
      seed_abandoned_checkpoint(root, project, source, "checkpoint draft\n", 7_i64)

      harness = RecoveryControllerHarness.new(root, project)
      raise "session initialization should succeed" unless harness.controller.initialize_session
      candidate = harness.controller.candidates.first
      raise "candidate should retain byte count" unless candidate.bytes == "checkpoint draft\n".bytesize
      raise "candidate should retain digest" unless candidate.digest.size == Adamantine::RecoveryStore::DIGEST_HEX_BYTES
      raise "candidate should retain project" unless candidate.project == project.expand.to_s
      raise "candidate should retain frame name" unless candidate.file_name == candidate.path.basename

      frame_before = File.read(candidate.path)
      source_before = File.read(source)
      preview = harness.controller.preview(candidate)
      raise "preview should be available" unless preview
      snapshot = preview.not_nil!
      raise "preview content mismatch" unless snapshot.content == "checkpoint draft\n"
      raise "preview should authorize an in-project source path" unless snapshot.authorized_source_path == source.expand
      raise "preview must not mutate the frame" unless File.read(candidate.path) == frame_before
      raise "preview must not mutate the source" unless File.read(source) == source_before
      raise "preview must not create a recovered-copy directory" if File.exists?(root / "recovered" / candidate.session_id)
    ensure
      harness.try(&.controller.stop(force: true))
    end
  end

  it "fails closed for a replaced checkpoint in preview and recovery actions" do
    with_controller_workspace do |tmp_dir|
      project = Path.new(tmp_dir, "project")
      root = Path.new(tmp_dir, "recovery")
      Dir.mkdir_p(project)
      source = Path.new(project, "replacement.txt")
      seed_abandoned_checkpoint(root, project, source, "original draft\n", 1_i64)

      harness = RecoveryControllerHarness.new(root, project)
      raise "session initialization should succeed" unless harness.controller.initialize_session
      candidate = harness.controller.candidates.first

      replacement = Adamantine::RecoveryStore.new(root: root, project: project)
      replacement_session = replacement.open_session
      replacement_checkpoint = replacement_session.write_snapshot(source_path: source, version: 2_i64) do |io|
        io.write("replacement draft\n".to_slice)
      end
      replacement_session.close
      File.copy(replacement_checkpoint.path.to_s, candidate.path.to_s)

      raise "preview must reject a replacement frame" if harness.controller.preview(candidate)
      raise "recover must reject a replacement frame" if harness.controller.recover(candidate)
      raise "discard must reject a replacement frame" if harness.controller.discard(candidate)
      raise "replacement frame should remain untouched" unless File.exists?(candidate.path)
    ensure
      replacement.try(&.close)
      harness.try(&.controller.stop(force: true))
    end
  end

  it "does not touch its root until the session is explicitly initialized" do
    with_controller_workspace do |tmp_dir|
      root = Path.new(tmp_dir, "recovery")
      project = Path.new(tmp_dir, "project")
      Dir.mkdir_p(project)

      harness = RecoveryControllerHarness.new(root, project)
      raise "constructor must not create recovery state" if File.exists?(root)
      harness.controller.tick
      raise "a tick before initialization must not create recovery state" if File.exists?(root)
    end
  end

  it "honors an explicit opt-out without touching the injected root" do
    with_controller_workspace do |tmp_dir|
      root = Path.new(tmp_dir, "recovery")
      project = Path.new(tmp_dir, "project")
      Dir.mkdir_p(project)
      buffers = {} of String => Adamantine::OpenBuffer
      controller = Adamantine::RecoveryController.new(
        root: root,
        project: project,
        buffers: -> { buffers },
        enabled: false,
      )

      raise "explicit opt-out should disable recovery" if controller.enabled
      raise "opted-out initialization should not start" if controller.initialize_session
      raise "opted-out worker should not start" if controller.start
      raise "opted-out scan should be empty" unless controller.candidates.empty?
      raise "opted-out tick should be inert" unless controller.tick == 0
      raise "opt-out must not create recovery state" if File.exists?(root)
    end
  end

  it "streams a dirty buffer, skips clean buffers, and retires a closed buffer" do
    with_controller_workspace do |tmp_dir|
      project = Path.new(tmp_dir, "project")
      Dir.mkdir_p(project)
      root = Path.new(tmp_dir, "recovery")
      source = Path.new(project, "draft.txt")
      File.write(source, "saved\n")

      harness = RecoveryControllerHarness.new(root, project)
      buffer = harness.open_buffer(source, "saved\n")
      buffer.editor.text = "draft\n"
      buffer.version = 2

      raise "session initialization should succeed" unless harness.controller.initialize_session
      raise "dirty tick should publish" unless harness.controller.tick == 1

      buffer.editor.load_content_as_saved("draft\n", source)
      raise "clean tick should retire the session snapshot" unless harness.controller.tick == 1

      buffer.editor.text = "draft again\n"
      buffer.version = 3
      harness.controller.tick
      harness.document_session.open_buffers.delete(source.to_s)
      raise "closed tick should retire this session snapshot" unless harness.controller.tick == 1
      harness.controller.stop

      reopened = Adamantine::RecoveryStore.new(root: root, project: project.to_s)
      raise "clean/closed checkpoint should be gone" unless reopened.candidates(project: project.to_s).empty?
    ensure
      reopened.try(&.close)
    end
  end

  it "keeps a previous accepted checkpoint when a write becomes stale" do
    with_controller_workspace do |tmp_dir|
      project = Path.new(tmp_dir, "project")
      Dir.mkdir_p(project)
      root = Path.new(tmp_dir, "recovery")
      source = Path.new(project, "stale.txt")
      File.write(source, "saved\n")

      harness = RecoveryControllerHarness.new(root, project)
      buffer = harness.open_buffer(source, "saved\n")
      buffer.editor.text = "first\n"
      buffer.version = 2
      raise "session initialization should succeed" unless harness.controller.initialize_session
      raise "first tick should publish" unless harness.controller.tick == 1

      buffer.editor.text = "second\n"
      buffer.version = 3
      # Keep the shutdown's final pass stale as well; otherwise a later edit
      # (version 4) would be a legitimate newer checkpoint rather than an
      # observation of the prior-frame preservation invariant.
      harness.controller.before_publish = ->(_path : Path) { buffer.version += 1 }
      raise "stale write should be rejected" unless harness.controller.tick == 0

      harness.controller.stop
      reopened = Adamantine::RecoveryStore.new(root: root, project: project.to_s)
      scan = reopened.candidates(project: project.to_s)
      raise "stale write must retain the prior checkpoint" unless scan.size == 1
      checkpoint = reopened.recover(scan.candidates.first)
      raise "prior accepted bytes were replaced" unless checkpoint && File.read(checkpoint.path) == "first\n"
    ensure
      reopened.try(&.close)
    end
  end

  it "finalizes the latest dirty draft on force stop within the controller" do
    with_controller_workspace do |tmp_dir|
      project = Path.new(tmp_dir, "project")
      Dir.mkdir_p(project)
      root = Path.new(tmp_dir, "recovery")
      source = Path.new(project, "latest.txt")
      File.write(source, "saved\n")

      harness = RecoveryControllerHarness.new(root, project)
      buffer = harness.open_buffer(source, "saved\n")
      buffer.editor.text = "latest\n"
      buffer.version = 2
      raise "session initialization should succeed" unless harness.controller.initialize_session
      harness.controller.stop(force: true)

      reopened = Adamantine::RecoveryStore.new(root: root, project: project.to_s)
      scan = reopened.candidates(project: project.to_s)
      raise "force stop must retain the latest draft" unless scan.size == 1
      checkpoint = reopened.recover(scan.candidates.first)
      raise "latest bytes were not checkpointed" unless checkpoint && File.read(checkpoint.path) == "latest\n"
    ensure
      reopened.try(&.close)
    end
  end

  it "does not close an in-flight session before a bounded force-stop wait drains it" do
    with_controller_workspace do |tmp_dir|
      project = Path.new(tmp_dir, "project")
      Dir.mkdir_p(project)
      root = Path.new(tmp_dir, "recovery")
      source = Path.new(project, "blocked.txt")
      File.write(source, "saved\n")

      started = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      editor = BlockingRecoveryEditor.new(source.to_s, started, release)
      raise "failed to seed editor" unless editor.load_content_as_saved("saved\n", source)
      harness = RecoveryControllerHarness.new(root, project)
      buffer = harness.open_buffer_with_editor(source, editor)
      buffer.editor.text = "blocked\n"
      buffer.version = 2
      raise "session initialization should succeed" unless harness.controller.initialize_session

      spawn { harness.controller.tick }
      started.receive
      harness.controller.stop(force: true)
      raise "force stop must not unlock an active writer" unless harness.controller.initialized?

      release.send(nil)
      deadline = Time.instant + 1.second
      while harness.controller.initialized? && Time.instant < deadline
        sleep 10.milliseconds
      end
      raise "session should close after the active writer drains" if harness.controller.initialized?
    end
  end
end

describe "Recovery UI integration" do
  it "does not create user recovery state from App.new" do
    with_controller_workspace("adamantine-recovery-app-constructor-spec") do |tmp_dir|
      project = Path.new(tmp_dir, "project")
      root = Path.new(tmp_dir, "recovery")
      Dir.mkdir_p(project)

      RecoveryUiSpecApp.new(project, lsp_command: "", recovery_root: root)
      raise "App.new must not create recovery state" if File.exists?(root)
    end
  end

  it "keeps App.new inert and paginates startup recovery without implicit discard" do
    with_controller_workspace("adamantine-recovery-ui-spec") do |tmp_dir|
      project = Path.new(tmp_dir, "project")
      root = Path.new(tmp_dir, "recovery")
      Dir.mkdir_p(project)

      4.times do |index|
        source = Path.new(project, "draft-#{index + 1}.txt")
        File.write(source, "disk #{index + 1}\n")
        seed_abandoned_checkpoint(root, project, source, "draft #{index + 1}\n", (index + 1).to_i64)
      end

      root_entries_before_app = Dir.children(root)
      app = RecoveryUiSpecApp.new(project, lsp_command: "", recovery_root: root)
      raise "App.new must not mutate existing recovery state" unless Dir.children(root) == root_entries_before_app

      app.start_recovery_and_open_menu_public
      raise "startup recovery should open its menu" unless app.context_menu_open?
      raise "wrong recovery menu title" unless app.context_menu_title == "Abandoned Recovery Checkpoints"

      first_page = app.context_menu_labels
      raise "recovery page must stay within the visible action budget" if first_page.size > 8
      raise "recovery page should expose navigation" unless first_page.any? { |label| label.starts_with?("Next page") }
      raise "recovery labels should identify the session" unless first_page.any? { |label| label.includes?("session ") }

      next_index = first_page.index { |label| label.starts_with?("Next page") }
      raise "missing next-page action" unless next_index
      app.choose_context_menu(next_index.not_nil!.to_i)
      raise "next page should remain a recovery menu" unless app.context_menu_open?
      second_page = app.context_menu_labels
      raise "next page should expose a previously hidden checkpoint" unless second_page.any? do |label|
                                                                              label.starts_with?("Open recovered copy") && !first_page.includes?(label)
                                                                            end

      app.dismiss_context_menu_public
      raise "dismiss should close the recovery menu" if app.context_menu_open?
      raise "dismiss must keep every checkpoint" unless app.recovery_candidates.size == 4

      app.open_recovery_menu_public
      discard_index = app.context_menu_labels.index { |label| label.starts_with?("Discard checkpoint") }
      raise "recovery menu must provide an explicit discard action: open=#{app.context_menu_open?} candidates=#{app.recovery_candidates.size} labels=#{app.context_menu_labels.inspect}" unless discard_index
      app.choose_context_menu(discard_index.not_nil!.to_i)
      raise "discard should remove only its explicitly selected checkpoint" unless app.recovery_candidates.size == 3
    ensure
      app.try(&.stop_recovery_public)
    end
  end

  it "recovers a deleted source into a private copy while preserving the dirty active buffer" do
    with_controller_workspace("adamantine-recovery-copy-spec") do |tmp_dir|
      project = Path.new(tmp_dir, "project")
      root = Path.new(tmp_dir, "recovery")
      Dir.mkdir_p(project)
      source = Path.new(project, "deleted-original.txt")
      active = Path.new(project, "active.txt")
      File.write(source, "original on disk\n")
      File.write(active, "active saved\n")
      seed_abandoned_checkpoint(root, project, source, "unsaved draft\n", 7_i64)
      File.delete(source)

      app = RecoveryUiSpecApp.new(project, lsp_command: "", recovery_root: root)
      raise "active file should open" unless app.open_file_public(active)
      app.handle_event(Tui::KeyEvent.new('!'))
      active_text = app.buffer_text(active)
      raise "active buffer should be dirty before recovery" unless app.buffer_modified?(active)

      app.run_command_public("recover")
      recover_index = app.context_menu_labels.index { |label| label.starts_with?("Open recovered copy") }
      raise "recovery menu must provide an explicit recover action" unless recover_index
      app.choose_context_menu(recover_index.not_nil!.to_i)

      private_copy = app.active_path
      raise "recovery action should open a copy" unless private_copy
      private_path = private_copy.not_nil!
      raise "recovery copy must not replace the original" if private_path == source
      raise "recovery copy must not replace the active buffer" if private_path == active
      raise "recovery copy should contain checkpoint bytes" unless File.read(private_path) == "unsaved draft\n"
      raise "recovery should add one independent buffer" unless app.buffer_count == 2
      raise "recovery must preserve later edits in the active buffer" unless app.buffer_text(active) == active_text
      raise "recovery must not make the active buffer clean" unless app.buffer_modified?(active)
      raise "recover should retain the checkpoint" unless app.recovery_candidates.size == 1
    ensure
      app.try(&.stop_recovery_public)
    end
  end
end
