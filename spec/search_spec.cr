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

  def search_scope : Adamantine::SearchState::Scope
    @search.scope
  end

  def search_match_count : Int32
    @search.matches.size
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

  def warning_messages : Array(String)
    @status_log.entries.select do |entry|
      entry.level == Tui::Log::Level::Warning
    end.map(&.message)
  end
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
      raise "palette should close after a completed grep" if app.command_open?
      raise "empty grep must not open a results menu" if app.context_menu_open?
      raise "empty grep should still open the search panel" unless app.search_open?
      raise "empty grep should report zero matches" unless app.search_match_count == 0
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
