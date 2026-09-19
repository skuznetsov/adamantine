require "spec"
require "file_utils"

require "crystal_tui"

require "../src/adamantine/app"

private class BufferSearchLifecycleApp < Adamantine::App
  property hold_search_source : Bool = false
  getter search_source_entered = Channel(Nil).new(1)
  getter release_search_source = Channel(Nil).new(1)
  getter search_source_calls : Int32 = 0

  def open_file_public(path : String | Path, line : Int32? = nil, col : Int32? = nil) : Bool
    open_file(Path.new(path), line, col)
  end

  def open_search_public(scope : Adamantine::SearchState::Scope, query : String, ignore_case : Bool? = nil) : Nil
    open_search_panel(scope, query, ignore_case: ignore_case, jump: false)
  end

  def schedule_repeat_public(query : String, forward : Bool = true) : Bool
    @search.query = query
    @search.query_cursor = query.size
    schedule_repeat_search(query, forward)
  end

  def set_cursor_public(line : Int32, col : Int32) : Nil
    editor = current_editor
    raise "expected active editor" unless editor
    editor.set_cursor(line, col)
  end

  def cursor : Tuple(Int32, Int32)
    editor = current_editor
    raise "expected active editor" unless editor
    {editor.cursor_line, editor.cursor_col}
  end

  def close_active_tab_public : Bool
    close_active_tab
  end

  def search_open? : Bool
    @search.open
  end

  def search_scope : Adamantine::SearchState::Scope
    @search.scope
  end

  def search_query : String
    @search.query
  end

  def search_ignore_case? : Bool
    @search.ignore_case
  end

  def search_running? : Bool
    @search.searching
  end

  def search_match_count : Int32
    @search.matches.size
  end

  def search_match_paths : Array(Path)
    @search.matches.map(&.path)
  end

  def buffer_search_running? : Bool
    !@buffer_search_running.nil?
  end

  def buffer_search_pending? : Bool
    !@buffer_search_pending.nil?
  end

  def buffer_search_worker_active? : Bool
    @buffer_search_worker_active
  end

  def cancel_search_workers_public : Nil
    cancel_search_workers
  end

  def wait_for_source_capture(timeout : Time::Span = 1.second) : Nil
    deadline = Time.instant + timeout
    loop do
      select
      when @search_source_entered.receive
        return
      when timeout(5.milliseconds)
        raise "timed out waiting for in-file search worker" if Time.instant >= deadline
      end
    end
  end

  def release_search_source_public : Nil
    @hold_search_source = false
    select
    when @release_search_source.send(nil)
    else
    end
  end

  def cleanup_public : Nil
    # The channel is buffered so cleanup can release a worker even when a
    # preceding assertion failed before it reached the receive point.
    release_search_source_public
    cancel_search_workers

    deadline = Time.instant + 1.second
    while @buffer_search_worker_active && Time.instant < deadline
      sleep 1.millisecond
    end
    @document_orchestrator.stop_external_file_monitor
    @recovery_controller.stop(force: true)
    @clipboard.close
    @header.stop_clock
  end

  protected def search_source_for(editor : Adamantine::EditingTextEditor) : Adamantine::BufferSearch::Source
    @search_source_calls += 1
    source = super
    if @hold_search_source
      @search_source_entered.send(nil)
      @release_search_source.receive
    end
    source
  end
end

private def with_buffer_search_lifecycle_workspace(prefix : String = "buffer-search-lifecycle", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  keymap = tmp_dir / "keymap.json"
  File.write(keymap, "{}")

  app : BufferSearchLifecycleApp? = nil
  begin
    app = BufferSearchLifecycleApp.new(
      project_root: tmp_dir,
      lsp_command: "",
      keymap_path: keymap.to_s,
      recovery_root: tmp_dir / ".recovery",
      clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new
    )
    yield tmp_dir, app.not_nil!
  ensure
    app.try &.cleanup_public
    FileUtils.rm_rf(tmp_dir) if tmp_dir
  end
end

private def wait_for_buffer_running(app : BufferSearchLifecycleApp, timeout : Time::Span = 1.second) : Nil
  deadline = Time.instant + timeout
  until app.buffer_search_running?
    raise "timed out waiting for running in-file request" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

private def wait_for_buffer_pending(app : BufferSearchLifecycleApp, timeout : Time::Span = 1.second) : Nil
  deadline = Time.instant + timeout
  until app.buffer_search_pending?
    raise "timed out waiting for debounced in-file request" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

private def wait_for_lifecycle_idle(app : BufferSearchLifecycleApp, timeout : Time::Span = 2.seconds) : Nil
  deadline = Time.instant + timeout
  while app.search_running? || app.buffer_search_worker_active?
    raise "buffer search did not become idle within #{timeout}" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

private def large_lifecycle_source(token : String) : String
  "prefix\n" + ("x" * 70_000) + "\n#{token}\n"
end

describe "buffer search lifecycle invalidation" do
  it "drops a live result and loading state when the cursor changes during debounce" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      file = tmp_dir / "cursor-before-dispatch.txt"
      File.write(file, large_lifecycle_source("cursor_token"))

      app.open_file_public(file).should be_true
      app.open_search_public(Adamantine::SearchState::Scope::ThisFile, "cursor_token")
      wait_for_buffer_pending(app)
      app.set_cursor_public(1, 0)

      wait_for_lifecycle_idle(app)
      raise "cursor changed during debounce must be preserved" unless app.cursor == {1, 0}
      raise "stale pre-dispatch result must not publish" unless app.search_match_count == 0
      raise "stale pre-dispatch request must release loading" if app.search_running?
    end
  end

  it "publishes the current result when the cursor remains unchanged" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      file = tmp_dir / "cursor-unchanged.txt"
      File.write(file, large_lifecycle_source("stable_cursor_token"))

      app.open_file_public(file).should be_true
      app.open_search_public(Adamantine::SearchState::Scope::ThisFile, "stable_cursor_token")
      wait_for_buffer_pending(app)

      wait_for_lifecycle_idle(app)
      raise "unchanged-cursor live search should publish" unless app.search_match_count == 1
      raise "unchanged-cursor live search should land on its match" unless app.cursor == {2, 0}
      raise "unchanged-cursor live search should not remain loading" if app.search_running?
    end
  end

  it "cancels a repeat on input even when the cursor returns to the same position" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      file = tmp_dir / "repeat-aba.txt"
      File.write(file, ("x" * 70_000) + "needle" + ("y" * 20) + "needle\n")

      app.open_file_public(file).should be_true
      app.hold_search_source = true
      app.schedule_repeat_public("needle").should be_true
      wait_for_buffer_running(app)
      app.wait_for_source_capture

      # A headless App has no terminal dispatch loop, so deliver the input
      # event first (which is the lifecycle boundary) and model the focused
      # editor's movement explicitly.
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Right))
      app.set_cursor_public(0, 1)
      raise "right input should move the cursor" unless app.cursor == {0, 1}
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Left))
      app.set_cursor_public(0, 0)
      raise "left input should return the cursor for the ABA probe" unless app.cursor == {0, 0}

      app.release_search_source_public
      wait_for_lifecycle_idle(app)
      raise "cancelled repeat must not jump after an ABA cursor path" unless app.cursor == {0, 0}
    end
  end

  it "dismisses a held live request without publishing after Escape" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      file = tmp_dir / "dismissed.txt"
      File.write(file, large_lifecycle_source("dismissed_token"))

      app.open_file_public(file).should be_true
      app.set_cursor_public(1, 0)
      app.hold_search_source = true
      app.open_search_public(Adamantine::SearchState::Scope::ThisFile, "dismissed_token")
      wait_for_buffer_running(app)
      app.wait_for_source_capture

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      raise "Escape must dismiss the search panel" if app.search_open?
      raise "dismissed search must release loading immediately" if app.search_running?
      raise "dismissed search must clear unpublished matches" unless app.search_match_count == 0

      app.release_search_source_public
      wait_for_lifecycle_idle(app)
      raise "dismissed worker must not publish after release" unless app.search_match_count == 0
      raise "dismissed worker must not move the cursor" unless app.cursor == {1, 0}
    end
  end

  it "rejects case-toggle ABA results and accepts the latest source" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      file = tmp_dir / "case-aba.txt"
      File.write(file, large_lifecycle_source("Needle"))

      app.open_file_public(file).should be_true
      app.hold_search_source = true
      app.open_search_public(Adamantine::SearchState::Scope::ThisFile, "needle", true)
      wait_for_buffer_running(app)
      app.wait_for_source_capture

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift)).should be_true
      raise "first case toggle must disable ignore-case" if app.search_ignore_case?
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab, Tui::Modifiers::Shift)).should be_true
      raise "second case toggle must restore ignore-case" unless app.search_ignore_case?
      raise "case-toggle ABA must remain loading until the latest request" unless app.search_running?
      raise "case-toggle ABA must clear old matches" unless app.search_match_count == 0

      app.release_search_source_public
      sleep 10.milliseconds
      raise "case-toggle ABA stale result must not publish before debounce" unless app.search_match_count == 0
      raise "case-toggle ABA latest request must remain loading" unless app.search_running?

      wait_for_lifecycle_idle(app)
      raise "case-toggle ABA latest request should publish" unless app.search_match_count == 1
      raise "case-toggle ABA latest request should jump to its match" unless app.cursor == {2, 0}
      raise "case-toggle ABA should capture only the old and latest sources" unless app.search_source_calls == 2
    end
  end

  it "keeps project loading and results alive after a stale in-file worker exits" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      in_file = tmp_dir / "large.txt"
      project_hit = tmp_dir / "project-hit.txt"
      File.write(in_file, large_lifecycle_source("in_file_token"))
      File.write(project_hit, "project_token\n")

      app.open_file_public(in_file).should be_true
      app.hold_search_source = true
      app.open_search_public(Adamantine::SearchState::Scope::ThisFile, "in_file_token")
      wait_for_buffer_running(app)
      app.wait_for_source_capture

      app.open_search_public(Adamantine::SearchState::Scope::Project, "project_token")
      # Repeat the scope switch while the cancelled in-file worker still owns
      # the running slot; its exit must not clear this newer project request.
      app.open_search_public(Adamantine::SearchState::Scope::Project, "project_token")
      raise "project search must remain loading after repeated cancellation" unless app.search_running?

      app.release_search_source_public
      sleep 10.milliseconds
      raise "stale in-file exit must not clear project loading" unless app.search_running?
      raise "project result must stay unpublished while its debounce runs" unless app.search_match_count == 0

      wait_for_lifecycle_idle(app)
      raise "project search should publish its result" unless app.search_match_count == 1
      raise "wrong project match published" unless app.search_match_paths == [project_hit]
    end
  end

  it "cancels and drains in-file workers at the shutdown boundary" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      file = tmp_dir / "shutdown.txt"
      File.write(file, large_lifecycle_source("shutdown_token"))

      app.open_file_public(file).should be_true
      app.hold_search_source = true
      app.open_search_public(Adamantine::SearchState::Scope::ThisFile, "shutdown_token")
      wait_for_buffer_running(app)
      app.wait_for_source_capture

      app.cancel_search_workers_public
      raise "shutdown cancellation must release search loading" if app.search_running?

      app.release_search_source_public
      wait_for_lifecycle_idle(app)
      raise "shutdown cancellation must drain the worker" if app.buffer_search_worker_active?
      raise "shutdown cancellation must not publish a stale result" unless app.search_match_count == 0
    end
  end

  it "rejects an old in-file request after switching away and back" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      file_a = tmp_dir / "tab-a.txt"
      file_b = tmp_dir / "tab-b.txt"
      File.write(file_a, large_lifecycle_source("tab_token"))
      File.write(file_b, large_lifecycle_source("other_token"))

      app.open_file_public(file_a).should be_true
      app.set_cursor_public(1, 0)
      app.hold_search_source = true
      app.open_search_public(Adamantine::SearchState::Scope::ThisFile, "tab_token")
      wait_for_buffer_running(app)
      app.wait_for_source_capture

      app.open_file_public(file_b).should be_true
      app.open_file_public(file_a, 1, 0).should be_true
      app.release_search_source_public

      sleep 10.milliseconds
      raise "tab return should have a fresh loading request" unless app.search_running?
      raise "tab-stale result must not publish before the fresh debounce" unless app.search_match_count == 0
      raise "tab-stale result must not jump the cursor" unless app.cursor == {1, 0}

      wait_for_lifecycle_idle(app)
      raise "fresh tab-A search should publish" unless app.search_match_count == 1
      raise "fresh tab-A search should land on its match" unless app.cursor == {2, 0}
    end
  end

  it "rejects an old in-file request after closing and reopening the file" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      file = tmp_dir / "reopen.txt"
      File.write(file, large_lifecycle_source("reopen_token"))

      app.open_file_public(file).should be_true
      app.hold_search_source = true
      app.open_search_public(Adamantine::SearchState::Scope::ThisFile, "reopen_token")
      wait_for_buffer_running(app)
      app.wait_for_source_capture

      app.close_active_tab_public.should be_true
      app.open_file_public(file, 1, 0).should be_true
      app.release_search_source_public

      sleep 10.milliseconds
      raise "reopen should have a fresh loading request" unless app.search_running?
      raise "reopen-stale result must not publish before the fresh debounce" unless app.search_match_count == 0
      raise "reopen-stale result must not jump the cursor" unless app.cursor == {1, 0}

      wait_for_lifecycle_idle(app)
      raise "fresh reopened search should publish" unless app.search_match_count == 1
      raise "fresh reopened search should land on its match" unless app.cursor == {2, 0}
    end
  end

  it "clears completed in-file results after closing the final tab" do
    with_buffer_search_lifecycle_workspace do |tmp_dir, app|
      file = tmp_dir / "close-completed.txt"
      File.write(file, large_lifecycle_source("close_completed_token"))

      app.open_file_public(file).should be_true
      app.open_search_public(Adamantine::SearchState::Scope::ThisFile, "close_completed_token")
      wait_for_lifecycle_idle(app)
      raise "close guard requires a completed live result" unless app.search_match_count == 1

      app.close_active_tab_public.should be_true
      raise "closing the final tab must clear completed matches" unless app.search_match_count == 0
      raise "closing the final tab must not leave search loading" if app.search_running?
    end
  end
end
