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

      app.set_partial_empty_public
      app.accept_public
      app.status_public.should contain("partial")
    end
  end
end
