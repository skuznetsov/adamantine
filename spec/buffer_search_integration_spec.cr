require "spec"
require "file_utils"

require "../src/adamantine/app"

private class GuardedBufferSearchEditor < Adamantine::EditingTextEditor
  def text : String
    raise "in-file search must not materialize the complete document"
  end

  def lines : Array(String)
    raise "in-file search must not materialize every line"
  end

  def replace_text(content : String) : Bool
    raise "in-file search must not replace the complete document"
  end

  private def line_at(index : Int32) : String
    raise "in-file search must not materialize a complete logical line"
  end
end

private class InspectableBufferSearchEditor < Adamantine::EditingTextEditor
  def selection_for_test : Tui::TextEditor::Selection?
    @selection
  end
end

private class BufferSearchIntegrationApp < Adamantine::App
  property fail_search_source : Bool = false
  getter search_source_calls : Int32 = 0

  def open_file_public(path : String | Path, line : Int32? = nil, col : Int32? = nil) : Bool
    open_file(Path.new(path), line, col)
  end

  def run_command(command : String) : Nil
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape)) unless @command_palette.open
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape)) unless @command_palette.open
    command.each_char { |ch| on_capture(Tui::KeyEvent.new(ch)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def cursor : Tuple(Int32, Int32)
    editor = current_editor
    raise "expected active editor" unless editor
    {editor.cursor_line, editor.cursor_col}
  end

  def set_cursor(line : Int32, col : Int32) : Nil
    editor = current_editor
    raise "expected active editor" unless editor
    editor.set_cursor(line, col)
  end

  def current_editor_for_test : Adamantine::EditingTextEditor
    current_editor.as?(Adamantine::EditingTextEditor).not_nil!
  end

  def install_guarded_editor : Nil
    buffer = current_buffer.not_nil!
    current = current_editor_for_test
    guarded = GuardedBufferSearchEditor.new(buffer.path.to_s, buffer.editor.document)
    guarded.set_cursor(current.cursor_line, current.cursor_col)
    replace_active_editor_view(buffer, guarded)
  end

  def install_inspectable_editor : InspectableBufferSearchEditor
    buffer = current_buffer.not_nil!
    current = current_editor_for_test
    inspectable = InspectableBufferSearchEditor.new(buffer.path.to_s, buffer.editor.document)
    inspectable.set_cursor(current.cursor_line, current.cursor_col)
    replace_active_editor_view(buffer, inspectable)
    inspectable
  end

  private def replace_active_editor_view(buffer : Adamantine::OpenBuffer, replacement : Tui::TextEditor) : Nil
    tabs = @editor_tabs
    index = tabs.tabs.index { |tab| tab.id == buffer.path.to_s }.not_nil!
    tab = tabs.tabs[index]
    old_view = tab.content.as(Tui::TextEditor)

    buffer.editor = replacement
    tabs.remove_child(old_view)
    tabs.tabs[index] = Tui::TabbedPanel::Tab.new(tab.id, tab.label, tab.tooltip, replacement, tab.closable)
    tabs.add_child(replacement)
    old_view.detach
    tabs.mark_dirty!
  end

  def open_search_public(query : String, ignore_case : Bool = false) : Nil
    open_search_panel(Adamantine::SearchState::Scope::ThisFile, query, ignore_case: ignore_case)
  end

  def search_open? : Bool
    @search.open
  end

  def search_running? : Bool
    @search.searching
  end

  def search_match_count : Int32
    @search.matches.size
  end

  def search_truncated? : Bool
    @search.truncated
  end

  def search_query : String
    @search.query
  end

  def replace_search_query(query : String) : Nil
    @search.query = query
    @search.query_cursor = query.size
    on_search_query_changed
  end

  def warning_messages : Array(String)
    @status_log.entries.select { |entry| entry.level == Tui::Log::Level::Warning }.map(&.message)
  end

  def cleanup_public : Nil
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
    raise "injected search source failure" if @fail_search_source
    super
  end
end

private def with_buffer_search_workspace(prefix : String = "buffer-search-integration", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  app : BufferSearchIntegrationApp? = nil
  begin
    app = new_buffer_search_app(tmp_dir)
    yield tmp_dir, app.not_nil!
  ensure
    app.try &.cleanup_public
    FileUtils.rm_rf(tmp_dir) if tmp_dir
  end
end

private def new_buffer_search_app(tmp_dir : Path) : BufferSearchIntegrationApp
  config = tmp_dir / "config.json"
  File.write(config, "{}")
  BufferSearchIntegrationApp.new(
    project_root: tmp_dir,
    lsp_command: "",
    keymap_path: config.to_s,
    recovery_root: tmp_dir / ".recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new
  )
end

private def wait_for_buffer_search(app : BufferSearchIntegrationApp, timeout : Time::Span = 3.seconds) : Nil
  deadline = Time.instant + timeout
  while app.search_running? && Time.instant < deadline
    sleep 1.millisecond
  end
  raise "buffer search did not finish within #{timeout}" if app.search_running?
end

describe "buffer search integration" do
  it "does not route live or repeat searches through full-text getters" do
    with_buffer_search_workspace do |tmp_dir, app|
      file = tmp_dir / "guarded.txt"
      File.write(file, "x\n")

      app.open_file_public(file).should be_true
      app.install_guarded_editor
      editor = app.current_editor_for_test
      original_bytes = editor.search_byte_length
      editor.modified?.should be_false
      editor.can_undo?.should be_false
      app.run_command("/x")
      app.search_match_count.should eq 1

      app.run_command("n")
      app.search_match_count.should eq 1
      editor.search_byte_length.should eq original_bytes
      editor.modified?.should be_false
      editor.can_undo?.should be_false
    end
  end

  it "keeps Unicode coordinates and original match spans through the live panel" do
    with_buffer_search_workspace do |tmp_dir, app|
      file = tmp_dir / "unicode.txt"
      File.write(file, "éx🙂x\nİ\n")

      app.open_file_public(file).should be_true
      app.run_command("/x")

      raise "small live search should finish synchronously" if app.search_running?
      app.search_match_count.should eq 2
      app.cursor.should eq({0, 1})

      editor = app.install_inspectable_editor
      app.open_search_public("i", ignore_case: true)
      app.search_match_count.should eq 1
      selection = editor.selection_for_test.not_nil!
      {selection.start_line, selection.start_col}.should eq({1, 0})
      {selection.end_line, selection.end_col}.should eq({1, 1})
    end
  end

  it "debounces large live search and retains the capped partial signal" do
    with_buffer_search_workspace do |tmp_dir, app|
      file = tmp_dir / "large.txt"
      File.write(file, ("a" * 70_000) + "\n" + ("needle\n" * 205))

      app.open_file_public(file).should be_true
      app.run_command("/needle")

      raise "large live search must be accepted as pending" unless app.search_running?
      raise "pending live search must not publish a false empty result" unless app.search_match_count == 0

      wait_for_buffer_search(app)
      app.search_match_count.should eq 200
      app.search_truncated?.should be_true
      app.cursor.should eq({1, 0})
    end
  end

  it "keeps rapid query replacement to one bounded latest source capture" do
    with_buffer_search_workspace do |tmp_dir, app|
      file = tmp_dir / "query-churn.txt"
      suffix = (0...20).map { |index| "needle#{index}\n" }.join
      File.write(file, ("a" * 70_000) + "\n" + suffix)

      app.open_file_public(file).should be_true
      app.run_command("/needle")
      20.times do |index|
        app.replace_search_query("needle#{index}")
      end

      # Debounce keeps all superseded requests source-free until dispatch.
      app.search_source_calls.should eq 0
      wait_for_buffer_search(app)
      raise "latest query must win" unless app.search_query == "needle19"
      app.search_source_calls.should eq 1
      app.search_match_count.should eq 1
      app.cursor.should eq({20, 0})
    end
  end

  it "repeats beyond the live result cap and wraps in both directions" do
    with_buffer_search_workspace do |tmp_dir, app|
      file = tmp_dir / "repeat.txt"
      File.write(file, ("a" * 70_000) + "\n" + ("needle\n" * 205))

      app.open_file_public(file).should be_true
      app.run_command("/needle")
      wait_for_buffer_search(app)

      # The live list stops at line 200 (zero-based line 200 is the last
      # retained result), while repeat search must still reach later matches.
      app.set_cursor(200, 0)
      app.run_command("n")
      wait_for_buffer_search(app)
      app.cursor.should eq({201, 0})

      app.run_command("N")
      wait_for_buffer_search(app)
      app.cursor.should eq({200, 0})

      app.set_cursor(1, 0)
      app.run_command("N")
      wait_for_buffer_search(app)
      app.cursor.should eq({205, 0})

      app.run_command("n")
      wait_for_buffer_search(app)
      app.cursor.should eq({1, 0})
    end
  end

  it "discards an edited document's in-flight result and refreshes later" do
    with_buffer_search_workspace do |tmp_dir, app|
      file = tmp_dir / "edit.txt"
      File.write(file, ("a" * 70_000) + "\nold_token\n")

      app.open_file_public(file).should be_true
      app.run_command("/old_token")
      raise "precondition: large live search should be pending" unless app.search_running?

      app.set_cursor(1, 0)
      editor = app.current_editor_for_test
      editor.select_range(1, 0, 1, 9, cursor_at_end: false)
      editor.insert_text("new_token")
      wait_for_buffer_search(app)

      raise "old query should not retain an edited stale result" unless app.search_match_count == 0
      app.run_command("/new_token")
      wait_for_buffer_search(app)
      app.search_match_count.should eq 1
    end
  end

  it "recovers from source failures for both synchronous and asynchronous paths" do
    with_buffer_search_workspace do |tmp_dir, app|
      small = tmp_dir / "small.txt"
      large = tmp_dir / "large.txt"
      File.write(small, "small_token\n")
      File.write(large, ("a" * 70_000) + "\nlarge_token\n")

      app.open_file_public(small).should be_true
      app.fail_search_source = true
      app.run_command("/small_token")
      raise "small source failure must release loading state" if app.search_running?
      app.warning_messages.any? { |message| message.includes?("In-file search failed") }.should be_true

      app.fail_search_source = false
      app.run_command("/small_token")
      app.search_match_count.should eq 1

      app.open_file_public(large).should be_true
      app.fail_search_source = true
      app.run_command("/large_token")
      wait_for_buffer_search(app)
      raise "async source failure must be visible" unless app.warning_messages.any? { |message| message.includes?("In-file search failed") }

      app.fail_search_source = false
      app.run_command("/large_token")
      wait_for_buffer_search(app)
      app.search_match_count.should eq 1
    end
  end
end
