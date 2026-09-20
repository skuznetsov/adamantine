require "spec"
require "file_utils"

require "../src/adamantine/app"

private class QuickOpenUiContractApp < Adamantine::App
  def activate_quick_open_public : Nil
    enter_input_mode(InputMode::QuickOpen)
    @quick_open.open = true
  end

  def set_matches_public(count : Int32) : Nil
    matches = [] of Adamantine::QuickOpenSearch::FilePathMatch
    count.times do |index|
      entry = Adamantine::QuickOpenSearch::FileEntry.new(@project_root / "candidate-#{index}.cr", "candidate-#{index}.cr", 0)
      rank = Adamantine::QuickOpenSearch::Rank.new(0, false, 0, 0, 0, index, 1)
      matches << Adamantine::QuickOpenSearch::FilePathMatch.new(entry, rank)
    end
    @quick_open.matches = matches
  end

  def selected_index_public=(value : Int32) : Int32
    @quick_open.selected_index = value
  end

  def scroll_public=(value : Int32) : Int32
    @quick_open.scroll = value
  end

  def ensure_selection_visible_public(rows : Int32) : Nil
    ensure_quick_open_selection_visible(rows)
  end

  def selected_index_public : Int32
    @quick_open.selected_index
  end

  def scroll_public : Int32
    @quick_open.scroll
  end

  def set_query_public(value : String) : Nil
    @quick_open.query = value
  end

  def query_public : String
    @quick_open.query
  end

  def query_cursor_public : Int32
    @quick_open.query_cursor
  end

  def query_selection_public : {Int32, Int32}?
    @quick_open.query_input.selection_range
  end

  def append_query_public(value : String) : Nil
    append_quick_open_query(value)
  end

  def status_public : String
    @quick_open.status
  end

  def set_partial_empty_public : Nil
    @quick_open.matches = [] of Adamantine::QuickOpenSearch::FilePathMatch
    @quick_open.searching = false
    @quick_open.partial = true
  end

  def accept_public : Nil
    accept_quick_open_selection
  end

  def set_bindings_public(bindings : Adamantine::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def open_document_public : Nil
    path = @project_root / "sample.cr"
    File.write(path, "document\n")
    open_file(path)
  end

  def document_text_public : String
    current_editor.not_nil!.text
  end
end

private def with_quick_open_ui_app(&)
  root = Path.new(Dir.tempdir, "adamantine-quick-open-ui-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  app = QuickOpenUiContractApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")
  yield app
ensure
  app.try &.quit(force: true)
  FileUtils.rm_rf(root) if root
end

describe "quick-open UI contracts" do
  it "keeps the selected row visible in a short viewport" do
    with_quick_open_ui_app do |app|
      app.activate_quick_open_public
      app.set_matches_public(30)
      app.selected_index_public = 29
      app.scroll_public = 0
      app.ensure_selection_visible_public(4)

      app.selected_index_public.should eq(29)
      app.scroll_public.should eq(26)
    end
  end

  it "uses dedicated remappable navigation actions without stealing query keys" do
    with_quick_open_ui_app do |app|
      bindings = Adamantine::KeyConfig.defaults
      bindings["app.quick_open_down"] = ["ctrl+n"]
      app.set_bindings_public(bindings)
      app.activate_quick_open_public
      app.set_matches_public(2)

      app.on_capture(Tui::KeyEvent.new('n', Tui::Modifiers::Ctrl)).should be_true
      app.selected_index_public.should eq(1)
    end
  end

  it "retains explicit query-limit and partial-result status" do
    with_quick_open_ui_app do |app|
      app.activate_quick_open_public
      app.set_query_public("a" * Adamantine::QuickOpenController::QUICK_OPEN_MAX_QUERY_CODEPOINTS)
      app.append_query_public("b")
      app.status_public.should contain("Query too long")
      app.on_capture(Tui::PasteEvent.new("bc")).should be_true
      app.query_public.size.should eq(Adamantine::QuickOpenController::QUICK_OPEN_MAX_QUERY_CODEPOINTS)
      app.status_public.should contain("Query too long")

      app.set_partial_empty_public
      app.accept_public
      app.status_public.should contain("partial")
    end
  end

  it "routes bracketed paste into the query without touching the editor" do
    with_quick_open_ui_app do |app|
      app.open_document_public
      app.activate_quick_open_public
      app.set_query_public("abcd")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Home)).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Right)).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Right, Tui::Modifiers::Shift)).should be_true

      app.on_capture(Tui::PasteEvent.new("X\r\nY")).should be_true

      app.query_public.should eq("aX Ycd")
      app.query_selection_public.should be_nil
      app.document_text_public.should eq("document\n")
    end
  end

  it "silently ignores a paste containing only discarded controls" do
    with_quick_open_ui_app do |app|
      app.activate_quick_open_public

      app.on_capture(Tui::PasteEvent.new("\u0000\u007f")).should be_true

      app.query_public.should eq("")
      app.status_public.should_not contain("Query too long")
    end
  end

  it "supports middle edits, selection, and grapheme-safe deletion" do
    with_quick_open_ui_app do |app|
      app.activate_quick_open_public
      app.set_query_public("abcd")
      app.query_cursor_public.should eq(4)

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Home)).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Right)).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Right, Tui::Modifiers::Shift)).should be_true
      app.query_selection_public.should eq({1, 2})
      app.on_capture(Tui::KeyEvent.new('X')).should be_true
      app.query_public.should eq("aXcd")

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Delete)).should be_true
      app.query_public.should eq("aXd")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Home, Tui::Modifiers::Shift)).should be_true
      app.on_capture(Tui::KeyEvent.new('\u0001')).should be_true
      app.query_selection_public.should eq({0, 3})
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Backspace)).should be_true
      app.query_public.should eq("")

      app.on_capture(Tui::KeyEvent.new('e')).should be_true
      app.on_capture(Tui::KeyEvent.new('\u0301')).should be_true
      app.on_capture(Tui::KeyEvent.new('x')).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Home)).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Right)).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Backspace)).should be_true
      app.query_public.should eq("x")
    end
  end
end
