require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

def file_uri(path : Path) : String
  "file://#{path.expand.to_s.gsub(" ", "%20")}".gsub("\\", "/")
end

class SearchSpecApp < Adamantine::App
  def open_file_public(path : String | Path, line : Int32? = nil, col : Int32? = nil)
    open_file(Path.new(path), line, col)
  end

  def open_command_palette_public
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def run_command(command : String) : Nil
    open_command_palette_public unless @command_palette.open
    command.each_char { |ch| on_capture(Tui::KeyEvent.new(ch)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def command_open? : Bool
    @command_palette.open
  end

  def command_input_text : String
    @command_palette.input
  end

  def search_open? : Bool
    @search.open
  end

  def search_query : String
    @search.query
  end

  def search_query_cursor : Int32
    @search.query_cursor
  end

  def search_query_selection : {Int32, Int32}?
    @search.query_input.selection_range
  end

  getter search_query_change_calls : Int32 = 0

  def reset_search_query_change_calls : Nil
    @search_query_change_calls = 0
  end

  def search_scope : Adamantine::SearchState::Scope
    @search.scope
  end

  def search_match_count : Int32
    @search.matches.size
  end

  def search_running? : Bool
    @search.searching
  end

  def search_match_paths : Array(Path)
    @search.matches.map(&.path)
  end

  def replace_search_query(query : String) : Nil
    @search.query = query
    @search.query_cursor = query.size
    on_search_query_changed
  end

  def context_menu_open? : Bool
    @context_menu.open
  end

  def context_menu_title : String
    @context_menu.title
  end

  def set_key_bindings(bindings : Adamantine::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def cursor : Tuple(Int32, Int32)
    editor = current_editor
    raise "expected active editor" if editor.nil?
    {editor.cursor_line, editor.cursor_col}
  end

  def active_uri : String?
    current_buffer.try(&.uri)
  end

  def editor_text : String
    current_editor.not_nil!.text
  end

  def warning_messages : Array(String)
    @status_log.entries.select do |entry|
      entry.level == Tui::Log::Level::Warning
    end.map(&.message)
  end

  private def on_search_query_changed : Nil
    @search_query_change_calls += 1
    super
  end
end

def wait_for_project_search(app : SearchSpecApp, timeout : Time::Span = 2.seconds) : Nil
  deadline = Time.instant + timeout
  while app.search_running? && Time.instant < deadline
    sleep 1.millisecond
  end
  raise "project search did not finish within #{timeout}" if app.search_running?
end

def with_search_spec_workspace(prefix : String = "editor-search-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::App do
  it "opens in-file search from Ctrl+F" do
    with_search_spec_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\n")

      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(Adamantine::KeyConfig.defaults)
      app.open_file_public(file)

      handled = app.handle_event(Tui::KeyEvent.new('\u0006'))
      raise "Ctrl+F should be handled" unless handled
      raise "find should open search panel" unless app.search_open?
      raise "find should stay in this-file scope" unless app.search_scope.this_file?
      raise "find must not open the command palette" if app.command_open?
    end
  end

  it "opens project search from macOS Option+F composed character" do
    with_search_spec_workspace do |tmp_dir|
      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(Adamantine::KeyConfig.defaults)

      handled = app.handle_event(Tui::KeyEvent.new('ƒ'))
      raise "macOS Option+F (ƒ) should be handled" unless handled
      raise "project find should open search panel" unless app.search_open?
      raise "project find should use project scope" unless app.search_scope.project?
      raise "project find must not open the command palette" if app.command_open?
    end
  end

  it "still opens project search from Ctrl+Shift+F" do
    with_search_spec_workspace do |tmp_dir|
      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(Adamantine::KeyConfig.defaults)

      handled = app.handle_event(Tui::KeyEvent.new('f', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift))
      raise "Ctrl+Shift+F should be handled" unless handled
      raise "project find should open search panel" unless app.search_open?
      raise "project find should use project scope" unless app.search_scope.project?
      raise "project find must not open the command palette" if app.command_open?
    end
  end

  it "jumps live while typing in the current file" do
    with_search_spec_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\nbeta\nbeta\n")

      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(Adamantine::KeyConfig.defaults)
      app.open_file_public(file)
      app.handle_event(Tui::KeyEvent.new('\u0006'))

      "beta".each_char { |ch| app.handle_event(Tui::KeyEvent.new(ch)) }
      raise "typed query should be kept" unless app.search_query == "beta"
      raise "live find should land on the first match" unless app.cursor == {1, 0}

      app.handle_event(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "Enter should go to the next match" unless app.cursor == {2, 0}
      raise "panel should stay open after next-match" unless app.search_open?
    end
  end

  it "edits the search query in the middle with grapheme-safe selection" do
    with_search_spec_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "abcdef\n")

      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(Adamantine::KeyConfig.defaults)
      app.open_file_public(file)
      app.handle_event(Tui::KeyEvent.new('\u0006'))
      "abcd".each_char { |char| app.handle_event(Tui::KeyEvent.new(char)) }
      app.reset_search_query_change_calls

      app.handle_event(Tui::KeyEvent.new(Tui::Key::Home))
      app.handle_event(Tui::KeyEvent.new(Tui::Key::Right))
      app.handle_event(Tui::KeyEvent.new(Tui::Key::Right, Tui::Modifiers::Shift))
      raise "shift-right should select one grapheme" unless app.search_query_selection == {1, 2}
      app.handle_event(Tui::KeyEvent.new('X'))
      raise "selection replacement should be a middle edit" unless app.search_query == "aXcd"
      raise "selection replacement should invoke search once" unless app.search_query_change_calls == 1

      app.handle_event(Tui::KeyEvent.new(Tui::Key::Delete))
      raise "delete should remove the middle grapheme" unless app.search_query == "aXd"
      raise "delete should invoke search once" unless app.search_query_change_calls == 2

      app.handle_event(Tui::KeyEvent.new(Tui::Key::Home, Tui::Modifiers::Shift))
      raise "shift-home should select to the beginning" unless app.search_query_selection == {0, 2}
      app.handle_event(Tui::KeyEvent.new('\u0001'))
      raise "ctrl+a should select all" unless app.search_query_selection == {0, 3}
      app.handle_event(Tui::KeyEvent.new(Tui::Key::Backspace))
      raise "backspace should delete the selected query" unless app.search_query.empty?
      raise "selected deletion should invoke search once" unless app.search_query_change_calls == 3

      app.handle_event(Tui::KeyEvent.new('e'))
      app.handle_event(Tui::KeyEvent.new('\u0301'))
      app.handle_event(Tui::KeyEvent.new('x'))
      app.handle_event(Tui::KeyEvent.new(Tui::Key::Home))
      app.handle_event(Tui::KeyEvent.new(Tui::Key::Right))
      app.handle_event(Tui::KeyEvent.new(Tui::Key::Backspace))
      raise "backspace should remove one extended grapheme" unless app.search_query == "x"
      raise "grapheme deletion should invoke search once" unless app.search_query_change_calls == 7
    end
  end

  it "routes bracketed paste into search without editing the document" do
    with_search_spec_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "document\n")

      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(Adamantine::KeyConfig.defaults)
      app.open_file_public(file)
      app.handle_event(Tui::KeyEvent.new('\u0006'))
      "abcd".each_char { |char| app.handle_event(Tui::KeyEvent.new(char)) }
      app.handle_event(Tui::KeyEvent.new(Tui::Key::Home))
      app.handle_event(Tui::KeyEvent.new(Tui::Key::Right))
      app.handle_event(Tui::KeyEvent.new(Tui::Key::Right, Tui::Modifiers::Shift))

      app.handle_event(Tui::PasteEvent.new("X\nY"))

      app.search_query.should eq("aX Ycd")
      app.search_query_selection.should be_nil
      app.editor_text.should eq("document\n")
    end
  end

  it "greps the project, jumps on Enter, and keeps the panel open" do
    with_search_spec_workspace do |tmp_dir|
      hit = Path.new(tmp_dir, "src")
      Dir.mkdir_p(hit)
      file_a = hit / "hit.cr"
      file_b = Path.new(tmp_dir, "other.cr")
      File.write(file_a, "prefix\nunique_grep_token here\n")
      File.write(file_b, "nope\n")

      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_b)
      app.run_command("grep unique_grep_token")

      raise "grep should open the search panel, not a menu" unless app.search_open?
      raise "grep must not open a results menu" if app.context_menu_open?
      raise "grep should use project scope" unless app.search_scope.project?
      raise "grep should keep the query" unless app.search_query == "unique_grep_token"
      raise "grep should return control while project search is running" unless app.search_running?
      raise "project results should not be published synchronously" unless app.search_match_count == 0

      wait_for_project_search(app)
      raise "grep should find the project hit" unless app.search_match_count == 1

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "selecting a grep hit should open the file" unless app.active_uri == file_uri(file_a)
      raise "cursor should land on the match line" unless app.cursor == {1, 0}
      raise "project search should stay open after a jump" unless app.search_open?
    end
  end

  it "does not select the active editor when a project match becomes stale" do
    with_search_spec_workspace do |tmp_dir|
      hit = Path.new(tmp_dir, "hit.cr")
      current = Path.new(tmp_dir, "current.cr")
      File.write(hit, "prefix\nstale_project_token\n")
      File.write(current, "current\n")

      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(current, 0, 2)
      app.run_command("grep stale_project_token")
      wait_for_project_search(app)
      raise "precondition: project match should be present" unless app.search_match_count == 1

      File.delete(hit)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "stale match must not switch the active file" unless app.active_uri == file_uri(current)
      raise "stale match must not select the current editor" unless app.cursor == {0, 2}
      raise "stale match should report a warning" unless app.warning_messages.any? { |message| message.includes?("Failed to open search match") }
    end
  end

  it "does not apply current-file matches after the active file changes" do
    with_search_spec_workspace do |tmp_dir|
      source = Path.new(tmp_dir, "source.cr")
      current = Path.new(tmp_dir, "current.cr")
      File.write(source, "stale_file_token\n")
      File.write(current, "current\n")

      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(source)
      app.run_command("search stale_file_token")
      raise "precondition: current-file match should be present" unless app.search_match_count == 1

      app.open_file_public(current, 0, 2)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "stale file match must not switch the active file" unless app.active_uri == file_uri(current)
      raise "stale file match must not move the active cursor" unless app.cursor == {0, 2}
      raise "stale file match should report a warning" unless app.warning_messages.any? { |message| message.includes?("stale") }
    end
  end

  it "keeps the project panel open when there are no matches" do
    with_search_spec_workspace do |tmp_dir|
      File.write(tmp_dir / "a.txt", "hello\n")
      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.run_command("grep definitely_missing_token_zz")
      wait_for_project_search(app)
      raise "palette should close after a completed grep" if app.command_open?
      raise "empty grep must not open a results menu" if app.context_menu_open?
      raise "empty grep should still open the search panel" unless app.search_open?
      raise "empty grep should report zero matches" unless app.search_match_count == 0
    end
  end

  it "does not report incomplete zero-match project search as definitive" do
    with_search_spec_workspace do |tmp_dir|
      oversized = "definitely_missing_token_zz" + ("x" * Adamantine::ProjectSearch::MAX_FILE_BYTES)
      File.write(tmp_dir / "oversized.txt", oversized)

      app = SearchSpecApp.new(
        project_root: tmp_dir,
        lsp_command: "",
        clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new
      )
      app.run_command("grep definitely_missing_token_zz")
      wait_for_project_search(app)
      raise "precondition: incomplete search should have no returned matches" unless app.search_match_count == 0

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      warnings = app.warning_messages
      raise "incomplete search should explain that results are partial: #{warnings.inspect}" unless warnings.any? { |message| message.downcase.includes?("partial") }
      raise "incomplete search must not claim definitive no matches: #{warnings.inspect}" if warnings.any? { |message| message == "No matches for \"definitely_missing_token_zz\"" }
    end
  end

  it "publishes only the newest project-search query" do
    with_search_spec_workspace do |tmp_dir|
      old_file = tmp_dir / "old.txt"
      new_file = tmp_dir / "new.txt"
      File.write(old_file, "old_search_token\n")
      File.write(new_file, "new_search_token\n")

      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.run_command("grep old_search_token")
      raise "first project search should be running" unless app.search_running?

      app.replace_search_query("new_search_token")
      wait_for_project_search(app)

      raise "new query should remain active" unless app.search_query == "new_search_token"
      raise "only the newest result should be published" unless app.search_match_paths == [new_file]
    end
  end
  it "discards a pending project search when the panel closes" do
    with_search_spec_workspace do |tmp_dir|
      File.write(tmp_dir / "hit.txt", "close_search_token\n")

      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.run_command("grep close_search_token")
      raise "project search should be running" unless app.search_running?

      app.handle_event(Tui::KeyEvent.new(Tui::Key::Escape))
      sleep 100.milliseconds

      raise "panel should stay closed" if app.search_open?
      raise "closed panel must not remain in a searching state" if app.search_running?
      raise "closed panel must not receive late search results" unless app.search_match_count == 0
    end
  end

  it "closes the search panel on Escape" do
    with_search_spec_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\n")
      app = SearchSpecApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(Adamantine::KeyConfig.defaults)
      app.open_file_public(file)
      app.handle_event(Tui::KeyEvent.new('\u0006'))
      raise "precondition: search panel open" unless app.search_open?

      handled = app.handle_event(Tui::KeyEvent.new(Tui::Key::Escape))
      raise "Escape should be handled" unless handled
      raise "Escape should close the search panel" if app.search_open?
    end
  end
end
