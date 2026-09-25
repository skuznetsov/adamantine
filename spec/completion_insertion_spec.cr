require "spec"
require "file_utils"
require "../src/adamantine/app"

private class CompletionInsertionClient < Adamantine::Lsp::Client
  property items : Array(Adamantine::Lsp::CompletionItem) = [] of Adamantine::Lsp::CompletionItem

  def initialize(root : Path)
    super("", root)
    self.connected = true
  end

  def completion(uri : String, line : Int32, character : Int32, max_items : Int32 = 30) : Array(Adamantine::Lsp::CompletionItem)
    @items.first([@items.size, max_items].min)
  end

  def stop : Nil
    self.connected = false
  end
end

private class CompletionInsertionApp < Adamantine::App
  def open_public(path : Path) : Bool
    open_file(path)
  end

  def client_public=(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def editor_public : Tui::TextEditor
    current_editor.not_nil!
  end

  def client_items_public=(items : Array(Adamantine::Lsp::CompletionItem)) : Nil
    @lsp.as(CompletionInsertionClient).items = items
  end

  def key_bindings_public=(bindings : Adamantine::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def complete_public : Nil
    show_completion_hint
    deadline = Time.instant + 2.seconds
    while @lsp_action_running
      raise "completion timeout" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  def dispatch_public(event : Tui::Event) : Nil
    editor_public.on_event(event) unless on_capture(event)
  end

  def popup_lines_public : Array(String)
    @lsp_popup.lines
  end

  def popup_index_public : Int32
    @lsp_popup.completion_index
  end

  def popup_top_public : Int32
    @lsp_popup.completion_top
  end

  def popup_open_public? : Bool
    @lsp_popup.open
  end

  def render_popup_public(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
    @lsp_popup.overlay.not_nil!.call(buffer, clip)
  end

  def close_public : Nil
    shutdown_lsp
  end
end

private def with_completion_insertion_app(&)
  root = Path.new(Dir.tempdir, "adamantine-completion-insertion-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = root / "sample.cr"
  File.write(path, "🙂 pr")
  app = CompletionInsertionApp.new(project_root: root, lsp_command: "")
  app.client_public = CompletionInsertionClient.new(root)
  app.open_public(path).should be_true
  app.editor_public.set_cursor(0, 4)
  yield app
ensure
  app.try &.close_public
  FileUtils.rm_rf(root) if root
end

describe "completion popup insertion" do
  it "keeps the selected row visible while moving through bounded results" do
    with_completion_insertion_app do |app|
      app.client_items_public = Array(Adamantine::Lsp::CompletionItem).new(25) do |index|
        Adamantine::Lsp::CompletionItem.new("candidate#{index}")
      end
      app.complete_public

      22.times { app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Down)) }
      app.popup_index_public.should eq(22)
      app.popup_top_public.should be > 0
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 candidate22")
    end
  end

  it "keeps the selected row visible after a short viewport clips the popup" do
    with_completion_insertion_app do |app|
      app.client_items_public = Array(Adamantine::Lsp::CompletionItem).new(25) do |index|
        Adamantine::Lsp::CompletionItem.new("candidate#{index}")
      end
      app.complete_public

      22.times { app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Down)) }
      buffer = Tui::Buffer.new(60, 10)
      app.editor_public.rect = Tui::Rect.new(0, 0, 60, 10)
      app.render_popup_public(buffer, Tui::Rect.new(0, 0, 60, 10))
      app.popup_top_public.should be >= 17
      (app.popup_top_public + 6).should be > app.popup_index_public
    end
  end

  it "routes remapped completion navigation through the modal" do
    with_completion_insertion_app do |app|
      bindings = Adamantine::KeyConfig.defaults
      bindings["lsp.completion_down"] = ["j"]
      app.key_bindings_public = bindings
      app.client_items_public = [
        Adamantine::Lsp::CompletionItem.new("first"),
        Adamantine::Lsp::CompletionItem.new("second"),
      ]
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new('j'))
      app.popup_index_public.should eq(1)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 second")
    end
  end

  it "keeps physical completion recovery keys after actions are unbound" do
    with_completion_insertion_app do |app|
      bindings = Adamantine::KeyConfig.defaults
      bindings["lsp.completion_up"] = [] of String
      bindings["lsp.completion_down"] = [] of String
      bindings["lsp.completion_accept"] = [] of String
      bindings["lsp.completion_cancel"] = [] of String
      app.key_bindings_public = bindings
      app.client_items_public = [
        Adamantine::Lsp::CompletionItem.new("first"),
        Adamantine::Lsp::CompletionItem.new("second"),
      ]

      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Down))
      app.popup_index_public.should eq(1)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Up))
      app.popup_index_public.should eq(0)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.popup_open_public?.should be_false

      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Down))
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.popup_open_public?.should be_false
      app.editor_public.text.should eq("🙂 second")
    end
  end

  it "cancels without changing text or history" do
    with_completion_insertion_app do |app|
      app.client_items_public = [Adamantine::Lsp::CompletionItem.new("print")]
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.popup_open_public?.should be_false
      app.editor_public.text.should eq("🙂 pr")
      app.editor_public.undo.should be_false
    end
  end

  it "sanitizes popup display text without changing the insertion payload" do
    with_completion_insertion_app do |app|
      item = Adamantine::Lsp::CompletionItem.new("pr\e[31m\nint", detail: "line\n\e[0m")
      app.client_items_public = [item]
      app.complete_public
      app.popup_lines_public.first.should_not contain("\e")
      app.popup_lines_public.first.should_not contain("\n")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 pr\e[31m\nint")
    end
  end

  it "rejects an explicitly unsupported item before changing history" do
    with_completion_insertion_app do |app|
      item = Adamantine::Lsp::CompletionItem.new(
        "snippet",
        insert_text: "danger",
        rejection_reason: Adamantine::Lsp::COMPLETION_REJECTION_SNIPPET
      )
      app.client_items_public = [item]
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 pr")
      app.editor_public.undo.should be_false
    end
  end

  it "rejects an initially active selection without mutating it" do
    with_completion_insertion_app do |app|
      app.editor_public.select_range(0, 2, 0, 4, cursor_at_end: false)
      selected_before = app.editor_public.copy
      app.client_items_public = [Adamantine::Lsp::CompletionItem.new("print")]
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 pr")
      app.editor_public.copy.should eq(selected_before)
      app.editor_public.undo.should be_false
      app.popup_open_public?.should be_false
    end
  end
end
