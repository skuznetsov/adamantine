require "spec"
require "file_utils"

require "../src/adamantine/app"

private class WorkspaceProblemsClient < Adamantine::Lsp::Client
  property result : Adamantine::Lsp::WorkspaceDiagnosticResult = Adamantine::Lsp::WorkspaceDiagnosticResult.new
  property hold : Bool = false
  property fail_request : Bool = false
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)
  getter calls : Int32 = 0

  def initialize(root : Path, supported : Bool = true)
    super("", root)
    self.connected = true
    self.server_capabilities = if supported
                                 JSON.parse(%({"diagnosticProvider":{"identifier":"test","interFileDependencies":true,"workspaceDiagnostics":true}}))
                               else
                                 JSON.parse(%({"diagnosticProvider":false}))
                               end
  end

  def workspace_diagnostics : Adamantine::Lsp::WorkspaceDiagnosticResult
    @calls += 1
    raise "workspace diagnostic failure" if @fail_request
    if @hold
      @entered.send(nil)
      @release.receive
    end
    @result
  end
end

private class WorkspaceProblemsApp < Adamantine::App
  def open_public(path : Path) : Bool
    open_file(path)
  end

  def install_client_public(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def open_problems_public : Nil
    open_problems
  end

  def dispatch_public(event : Tui::Event) : Nil
    current_editor.try(&.on_event(event)) unless on_capture(event)
  end

  def problems_loading_public : Bool
    @problems.loading
  end

  def problems_coverage_public : String
    @problems.coverage.to_s
  end

  def problems_partial_public : Bool
    @problems.partial
  end

  def problems_paths_public : Array(String)
    @problems.rows.map(&.buffer_path)
  end

  def problems_messages_public : Array(String)
    @problems.rows.map(&.diagnostic.message)
  end

  def problems_title_public : String
    problems_title
  end

  def mode_public : String
    active_input_mode.to_s
  end

  def current_path_public : String?
    current_buffer.try(&.path.to_s)
  end

  def current_cursor_public : Tuple(Int32, Int32)
    editor = current_editor.not_nil!
    {editor.cursor_line, editor.cursor_col}
  end

  def current_text_public : String
    current_editor.not_nil!.text
  end

  def problem_count_public : Int32
    @problems.rows.size
  end

  def buffer_open_public?(path : Path) : Bool
    !!@document_session.open_buffers[path.to_s]?
  end

  def set_open_diagnostics_public(path : Path, diagnostics : Array(Adamantine::Lsp::Diagnostic)) : Nil
    buffer = @document_session.open_buffers[path.to_s].not_nil!
    buffer.diagnostics = diagnostics
    buffer.diagnostics_generation &+= 1_u64
  end

  def invalidate_recovery_public : Nil
    lsp_recovery_invalidate
  end

  def wait_for_problems_public(timeout_span : Time::Span = 1.second) : Nil
    deadline = Time.instant + timeout_span
    while @problems.loading
      raise "timed out waiting for workspace Problems" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end
end

private def workspace_problem_document(path : Path, diagnostic : Adamantine::Lsp::Diagnostic)
  Adamantine::Lsp::WorkspaceDiagnosticDocument.new(
    uri: Adamantine::UriCodec.path_to_uri(path),
    version: nil,
    diagnostics: [diagnostic],
    result_id: "result",
    partial: false,
  )
end

private def workspace_problem(line : Int32, character : Int32, message : String, severity : Int32 = 1)
  Adamantine::Lsp::Diagnostic.new(line, character, message, "workspace", severity, line, character)
end

private def with_workspace_problems(&)
  root = Path.new(Dir.tempdir, "adamantine-workspace-problems-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  active = root / "active.cr"
  target = root / "target.cr"
  File.write(active, "active\n")
  File.write(target, "🙂x\n")
  app = WorkspaceProblemsApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")
  app.open_public(active).should be_true
  yield app, root, active, target
ensure
  app.try &.quit(force: true)
  FileUtils.rm_rf(root) if root
end

private def wait_for_workspace_signal(channel : Channel(Nil), timeout_span : Time::Span = 1.second) : Nil
  select
  when channel.receive
  when timeout(timeout_span)
    raise "timed out waiting for workspace diagnostic request"
  end
end

describe "server-workspace Problems" do
  it "opens a responsive loading modal and publishes an unopened server row" do
    with_workspace_problems do |app, root, _active, target|
      client = WorkspaceProblemsClient.new(root)
      client.hold = true
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 2, "target error"))],
        false,
      )
      app.install_client_public(client)

      started = Time.instant
      app.open_problems_public
      (Time.instant - started).should be < 250.milliseconds
      app.mode_public.should eq("Problems")
      app.problems_loading_public.should be_true
      app.problems_title_public.should eq("Problems: Server Workspace (loading)")
      app.buffer_open_public?(target).should be_false

      before = app.current_text_public
      app.dispatch_public(Tui::KeyEvent.new('z'))
      app.dispatch_public(Tui::PasteEvent.new("must not edit"))
      app.current_text_public.should eq(before)

      wait_for_workspace_signal(client.entered)
      client.release.send(nil)
      app.wait_for_problems_public

      app.problems_coverage_public.should eq("ServerWorkspace")
      app.problems_paths_public.should eq([target.to_s])
      app.problems_messages_public.should eq(["target error"])
      app.buffer_open_public?(target).should be_false
    end
  end

  it "opens an unchanged in-root target only on Enter and resolves UTF-16" do
    with_workspace_problems do |app, root, _active, target|
      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 2, "after emoji"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public

      app.buffer_open_public?(target).should be_false
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))

      app.current_path_public.should eq(target.to_s)
      app.current_cursor_public.should eq({0, 1})
      app.mode_public.should eq("Normal")
      File.read(target).should eq("🙂x\n")
    end
  end

  it "keeps live open-buffer diagnostics authoritative without duplicates" do
    with_workspace_problems do |app, root, _active, target|
      app.open_public(target).should be_true
      app.set_open_diagnostics_public(target, [workspace_problem(0, 1, "live unsaved")])
      app.current_cursor_public.should eq({0, 0})

      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 0, "stale workspace"))],
        false,
      )
      app.install_client_public(client)
      # Installing this test client deliberately does not clear the retained
      # live publication; the workspace collector must prefer it by URI.
      app.open_problems_public
      app.wait_for_problems_public

      app.problems_messages_public.should eq(["live unsaved"])
      app.problems_paths_public.should eq([target.to_s])
    end
  end

  it "falls back to the existing open-files snapshot when unsupported" do
    with_workspace_problems do |app, root, active, _target|
      app.set_open_diagnostics_public(active, [workspace_problem(0, 0, "open only")])
      client = WorkspaceProblemsClient.new(root, supported: false)
      app.install_client_public(client)

      app.open_problems_public

      client.calls.should eq(0)
      app.problems_loading_public.should be_false
      app.problems_coverage_public.should eq("OpenFiles")
      app.problems_title_public.should eq("Problems: Open Files")
      app.problems_messages_public.should eq(["open only"])
    end
  end

  it "falls back to open files when a supported workspace request fails" do
    with_workspace_problems do |app, root, active, _target|
      app.set_open_diagnostics_public(active, [workspace_problem(0, 0, "open fallback")])
      client = WorkspaceProblemsClient.new(root)
      client.fail_request = true
      app.install_client_public(client)

      app.open_problems_public
      app.wait_for_problems_public

      client.calls.should eq(1)
      app.problems_coverage_public.should eq("OpenFiles")
      app.problems_messages_public.should eq(["open fallback"])
    end
  end

  it "ignores a late workspace response after Escape" do
    with_workspace_problems do |app, root, _active, target|
      client = WorkspaceProblemsClient.new(root)
      client.hold = true
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 0, "late"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      wait_for_workspace_signal(client.entered)

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.mode_public.should eq("Normal")
      client.release.send(nil)
      sleep 20.milliseconds

      app.mode_public.should eq("Normal")
      app.buffer_open_public?(target).should be_false
    end
  end

  it "closes a workspace snapshot when LSP recovery invalidates its client" do
    with_workspace_problems do |app, root, _active, target|
      client = WorkspaceProblemsClient.new(root)
      client.hold = true
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 0, "late after transport loss"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      wait_for_workspace_signal(client.entered)

      app.invalidate_recovery_public
      app.mode_public.should eq("Normal")
      client.release.send(nil)
      sleep 20.milliseconds

      app.mode_public.should eq("Normal")
      app.buffer_open_public?(target).should be_false
    end
  end

  it "rejects navigation after the unopened target changes" do
    with_workspace_problems do |app, root, active, target|
      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 0, "stale file"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public
      File.write(target, "changed bytes\n")

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))

      app.current_path_public.should eq(active.to_s)
      app.buffer_open_public?(target).should be_false
      app.mode_public.should eq("Normal")
    end
  end

  it "does not commit a non-text workspace target" do
    with_workspace_problems do |app, root, active, target|
      File.write(target, Bytes[0_u8, 1_u8, 2_u8])
      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 0, "binary"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))

      app.current_path_public.should eq(active.to_s)
      app.buffer_open_public?(target).should be_false
      app.mode_public.should eq("Normal")
    end
  end

  it "skips outside-root reports and marks the workspace snapshot partial" do
    with_workspace_problems do |app, root, _active, _target|
      outside = Path.new(Dir.tempdir, "adamantine-outside-problem-#{Random::Secure.hex(8)}.cr")
      File.write(outside, "outside\n")
      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(outside, workspace_problem(0, 0, "outside"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public

      app.problems_paths_public.should be_empty
      app.problems_partial_public.should be_true
      app.buffer_open_public?(outside).should be_false
    ensure
      File.delete(outside) if outside && File.exists?(outside)
    end
  end

  it "rejects malformed file URIs that decode to relative paths" do
    with_workspace_problems do |app, root, _active, _target|
      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [Adamantine::Lsp::WorkspaceDiagnosticDocument.new(
          uri: "file://target.cr",
          version: nil,
          diagnostics: [workspace_problem(0, 0, "relative")],
        )],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public

      app.problems_paths_public.should be_empty
      app.problems_partial_public.should be_true
    end
  end

  it "skips a symlink whose canonical target escapes the project root" do
    with_workspace_problems do |app, root, _active, _target|
      outside = Path.new(Dir.tempdir, "adamantine-symlink-problem-#{Random::Secure.hex(8)}.cr")
      linked = root / "linked.cr"
      File.write(outside, "outside\n")
      File.symlink(outside, linked)
      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(linked, workspace_problem(0, 0, "escaped"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public

      app.problems_paths_public.should be_empty
      app.problems_partial_public.should be_true
      app.buffer_open_public?(linked).should be_false
    ensure
      File.delete(outside) if outside && File.exists?(outside)
    end
  end

  it "rejects a workspace row when the same target opens through an alias" do
    with_workspace_problems do |app, root, active, target|
      alias_path = root / "target-alias.cr"
      File.symlink(target.basename.to_s, alias_path)
      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 0, "aliased"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public
      app.open_public(alias_path).should be_true

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))

      app.current_path_public.should eq(alias_path.to_s)
      app.buffer_open_public?(target).should be_false
      app.mode_public.should eq("Normal")
      File.read(active).should eq("active\n")
    end
  end

  it "keeps a dirty hard-link buffer authoritative over a workspace alias" do
    with_workspace_problems do |app, root, _active, target|
      alias_path = root / "target-hardlink.cr"
      File.link(target, alias_path)
      app.open_public(alias_path).should be_true
      app.set_open_diagnostics_public(alias_path, [workspace_problem(0, 1, "live hard link")])

      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 0, "stale workspace alias"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public

      app.problems_messages_public.should eq(["live hard link"])
      app.problems_paths_public.should eq([alias_path.to_s])
      app.buffer_open_public?(target).should be_false
    end
  end

  it "rejects a workspace row when its hard-link target opens after capture" do
    with_workspace_problems do |app, root, _active, target|
      alias_path = root / "target-hardlink.cr"
      File.link(target, alias_path)
      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [workspace_problem_document(target, workspace_problem(0, 0, "hard-link alias"))],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public
      app.open_public(alias_path).should be_true

      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))

      app.current_path_public.should eq(alias_path.to_s)
      app.buffer_open_public?(target).should be_false
      app.mode_public.should eq("Normal")
    end
  end

  it "bounds retained workspace rows and marks the snapshot partial" do
    with_workspace_problems do |app, root, _active, target|
      diagnostics = Array.new(Adamantine::ProblemsController::PROBLEMS_MAX_ROWS + 1) do |index|
        workspace_problem(0, 0, "problem #{index}")
      end
      client = WorkspaceProblemsClient.new(root)
      client.result = Adamantine::Lsp::WorkspaceDiagnosticResult.new(
        [Adamantine::Lsp::WorkspaceDiagnosticDocument.new(
          uri: Adamantine::UriCodec.path_to_uri(target),
          version: nil,
          diagnostics: diagnostics,
        )],
        false,
      )
      app.install_client_public(client)
      app.open_problems_public
      app.wait_for_problems_public

      app.problem_count_public.should eq(Adamantine::ProblemsController::PROBLEMS_MAX_ROWS)
      app.problems_partial_public.should be_true
    end
  end
end
