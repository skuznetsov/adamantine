require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

def file_uri(path : Path) : String
  "file://#{path.expand.to_s.gsub(" ", "%20")}".gsub("\\", "/")
end

class TestApp < Adamantine::App
  def open_file_public(path : String | Path, line : Int32? = nil, col : Int32? = nil)
    open_file(Path.new(path), line, col)
  end

  def open_command_palette_public
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def open_discovery_palette_public
    open_command_palette("")
  end

  def command_open? : Bool
    @command_palette.open
  end

  def search_open? : Bool
    @search.open
  end

  def search_scope : Adamantine::SearchState::Scope
    @search.scope
  end

  def context_menu_open? : Bool
    @context_menu.open
  end

  def context_menu_title : String
    @context_menu.title
  end

  def settings_open? : Bool
    @settings.open
  end

  def set_key_bindings(bindings : Adamantine::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def run_command(command : String) : Nil
    open_command_palette_public unless @command_palette.open
    command.each_char { |ch| on_capture(Tui::KeyEvent.new(ch)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def cursor : Tuple(Int32, Int32)
    editor = current_editor
    raise "expected active editor" if editor.nil?
    {editor.cursor_line, editor.cursor_col}
  end

  def command_input_text : String
    @command_palette.input
  end

  def command_argument_hint : String
    @command_palette.argument_hint
  end

  def command_candidate_aliases : Array(Array(String))
    @command_palette.candidates.map(&.aliases)
  end

  def insert_text_public(text : String) : Nil
    current_editor.not_nil!.insert_text(text)
  end

  def active_uri : String?
    current_buffer.try(&.uri)
  end

  def editor_text : String
    editor = current_editor
    raise "expected active editor" if editor.nil?
    editor.text
  end
end

def with_temp_workspace(prefix : String = "editor-command-palette-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::App do
  it "opens empty discovery mode with Help as the safe default" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_discovery_palette_public

      raise "discovery mode should start with empty input (#{app.command_input_text.inspect}, open=#{app.command_open?})" unless app.command_input_text == ""
      aliases = app.command_candidate_aliases
      raise "Help should be the first discovery action" unless aliases.first? == ["help", "?"]
      raise "Save should remain the second discovery action" unless aliases[1]? == ["w", "write"]
    end
  end

  it "selects a discovery result with Down and invokes the selected action" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "before\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.insert_text_public("after\n")
      raise "setup edit should remain unsaved" unless File.read(file) == "before\n"

      app.open_discovery_palette_public
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Down))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "Down then Enter should invoke Save" unless File.read(file) == app.editor_text
    end
  end

  it "matches descriptions for human queries instead of treating them as file arguments" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_discovery_palette_public
      "open settings".each_char { |ch| app.on_capture(Tui::KeyEvent.new(ch)) }
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "human settings query should open settings" unless app.settings_open?
      raise "settings query must not open the command palette" if app.command_open?
    end
  end

  it "prepares an argument-required discovery action with a hint on Tab" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_discovery_palette_public
      "open file path".each_char { |ch| app.on_capture(Tui::KeyEvent.new(ch)) }
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))

      raise "Tab should prepare the selected colon command" unless app.command_input_text == ":open "
      raise "open should expose its required path hint" unless app.command_argument_hint == "<path>"
      raise "prepared command should remain modal" unless app.command_open?
    end
  end

  it "keeps a prepared required-argument action open until an argument is entered" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_discovery_palette_public
      "open file path".each_char { |ch| app.on_capture(Tui::KeyEvent.new(ch)) }
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "prepared command without an argument should remain modal" unless app.command_open?
      raise "prepared command should retain its input while waiting" unless app.command_input_text == ":open "
      raise "prepared command should retain its argument hint" unless app.command_argument_hint == "<path>"
    end
  end

  it "keeps no-result Enter inert in discovery mode" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_discovery_palette_public
      "zz-no-such-action".each_char { |ch| app.on_capture(Tui::KeyEvent.new(ch)) }
      before = app.command_input_text
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      raise "no-result Enter should not close discovery mode" unless app.command_open?
      raise "no-result Enter should not rewrite the query" unless app.command_input_text == before
    end
  end

  it "switches discovery to raw mode only for an explicit command prefix" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_discovery_palette_public
      ":w".each_char { |ch| app.on_capture(Tui::KeyEvent.new(ch)) }

      raise "explicit colon should enter raw command mode" unless app.command_input_text == ":w"
    end
  end

  it "retains an argument hint when raw Tab completes a required command" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_discovery_palette_public
      ":op".each_char { |ch| app.on_capture(Tui::KeyEvent.new(ch)) }
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))

      raise "raw Tab should complete the open command" unless app.command_input_text == ":open "
      raise "raw Tab should expose the open path hint" unless app.command_argument_hint == "<path>"

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      raise "completed required command without an argument should remain modal" unless app.command_open?
    end
  end

  it "does not expose force quit in searchable metadata" do
    with_temp_workspace do |tmp_dir|
      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_discovery_palette_public

      if app.command_candidate_aliases.any? { |aliases| aliases.includes?("q!") }
        raise "force quit must remain legacy-only and undiscoverable"
      end
    end
  end

  it "searches forward with / and repeats with n" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\nbeta\nbeta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)

      app.run_command("/beta")
      raise "first forward search should jump to first match" unless app.cursor == {1, 0}

      app.run_command("n")
      raise "n should jump to next match" unless app.cursor == {2, 0}
    end
  end

  it "searches backward with ? and flips direction with N" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "zero\nmatch\none\nmatch\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)

      app.run_command("/match")
      raise "setup forward search should land first match" unless app.cursor == {1, 0}

      app.run_command("?match")
      raise "backward search should wrap to previous match" unless app.cursor == {3, 0}

      app.run_command("N")
      raise "N should repeat backward search direction from last ?" unless app.cursor == {1, 0}
    end
  end

  it "opens quick actions with Shift+Enter" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\nbeta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(Adamantine::KeyConfig.defaults)
      app.open_file_public(file)

      handled = app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter, Tui::Modifiers::Shift))
      raise "Shift+Enter should be handled" unless handled
      raise "quick actions menu should open" unless app.context_menu_open?
      raise "quick actions title expected" unless app.context_menu_title == "Quick Actions"
    end
  end

  it "opens search dialog from quick actions menu" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\nbeta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.set_key_bindings(Adamantine::KeyConfig.defaults)
      app.open_file_public(file)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter, Tui::Modifiers::Shift))

      app.on_capture(Tui::KeyEvent.new('1'))

      raise "search panel should open" unless app.search_open?
      raise "search should start in this-file scope" unless app.search_scope.this_file?
      raise "command palette should stay closed" if app.command_open?
      raise "context menu should close after action" if app.context_menu_open?
    end
  end

  it "blocks :open for symlink paths outside project root" do
    with_temp_workspace do |tmp_dir|
      root = Path.new(tmp_dir, "project")
      Dir.mkdir_p(root)

      safe_file = Path.new(root, "safe.txt")
      File.write(safe_file, "safe\n")

      outside = Path.new(root, "outside")
      File.symlink("/etc", outside)

      app = TestApp.new(project_root: root, lsp_command: "")
      app.open_file_public(safe_file)
      raise "sanity: baseline file should be active" unless app.active_uri == file_uri(safe_file)

      app.run_command("open outside/passwd")
      raise "symlink escape must not change active file" unless app.active_uri == file_uri(safe_file)
    end
  end

  it "allows menu-bound letters in command input" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "sample.cr")
      File.write(file, "alpha\nbeta\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.open_command_palette_public

      "mark x".each_char do |ch|
        app.on_capture(Tui::KeyEvent.new(ch))
      end

      raise "k should remain in command input" unless app.command_input_text == ":mark x"
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
    end
  end

  it "switches to buffer by index via :buf" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      file_c = Path.new(tmp_dir, "c.cr")
      File.write(file_a, "a\n")
      File.write(file_b, "b\n")
      File.write(file_c, "c\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.open_file_public(file_c)
      raise "expected c active before switch" unless app.active_uri == file_uri(file_c)

      app.run_command("buf 2")
      raise "active buffer should be b" unless app.active_uri == file_uri(file_b)

      app.run_command("buf 1")
      raise "active buffer should return to a" unless app.active_uri == file_uri(file_a)
    end
  end

  it "switches to buffer by exact name via :buf" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "alpha.cr")
      file_b = Path.new(tmp_dir, "beta.cr")
      File.write(file_a, "a\n")
      File.write(file_b, "b\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)

      app.run_command("buf alpha.cr")
      raise "active buffer should remain alpha by name" unless app.active_uri == file_uri(file_a)
    end
  end

  it "reuses existing tab when opening the same file with cursor position" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "same.cr")
      File.write(file_a, "line0\nline1\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a, 0, 0)
      app.open_file_public(file_a, 1, 2)

      raise "should move cursor in existing buffer" unless app.cursor == {1, 2}
    end
  end

  it "ignores out-of-range :buf index" do
    with_temp_workspace do |tmp_dir|
      file_a = Path.new(tmp_dir, "a.cr")
      file_b = Path.new(tmp_dir, "b.cr")
      file_c = Path.new(tmp_dir, "c.cr")
      File.write(file_a, "a\n")
      File.write(file_b, "b\n")
      File.write(file_c, "c\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.open_file_public(file_c)
      raise "expected c active before switch" unless app.active_uri == file_uri(file_c)

      app.run_command("buf 99")
      raise "active buffer should remain unchanged on invalid index" unless app.active_uri == file_uri(file_c)
    end
  end

  it "keeps active buffer when :buf match is ambiguous" do
    with_temp_workspace do |tmp_dir|
      nested = Path.new(tmp_dir, "nested")
      other = Path.new(tmp_dir, "other")
      Dir.mkdir_p(nested)
      Dir.mkdir_p(other)

      file_a = Path.new(tmp_dir, "shared.cr")
      file_b = Path.new(nested, "shared.cr")
      file_c = Path.new(other, "shared.cr")
      File.write(file_a, "root\n")
      File.write(file_b, "nested\n")
      File.write(file_c, "other\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file_a)
      app.open_file_public(file_b)
      app.open_file_public(file_c)
      raise "expected other/shared.cr active before switch" unless app.active_uri == file_uri(file_c)

      app.run_command("buf shared.cr")
      raise "active buffer should remain unchanged on ambiguous name" unless app.active_uri == file_uri(file_c)
    end
  end

  it "makes :replace undoable and redoable" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "replace.cr")
      File.write(file, "old old\n")

      app = TestApp.new(project_root: tmp_dir, lsp_command: "")
      app.open_file_public(file)
      app.run_command("r /old/new/g")
      raise "replace should update the active editor" unless app.editor_text == "new new\n"

      app.run_command("undo")
      raise "replace should be undoable" unless app.editor_text == "old old\n"

      app.run_command("redo")
      raise "replace should be redoable" unless app.editor_text == "new new\n"
    end
  end

  it "reloads the custom theme selected through :theme" do
    with_temp_workspace do |tmp_dir|
      theme_file = Path.new(tmp_dir, "custom-theme.json")
      File.write(theme_file.to_s, {
        "editor" => {"text_bg" => "#010203"},
      }.to_json)

      app = TestApp.new(project_root: tmp_dir, lsp_command: "", theme_path: "vscode-dark")
      app.run_command("theme #{theme_file}")
      raise "custom theme should load" unless Adamantine::Theme::Editor.text_bg == Tui::Color.rgb(1, 2, 3)

      File.write(theme_file.to_s, {
        "editor" => {"text_bg" => "#040506"},
      }.to_json)
      app.run_command("open-theme")

      raise "open-theme should reload the selected custom path" unless Adamantine::Theme::Editor.text_bg == Tui::Color.rgb(4, 5, 6)
    end
  end
end
