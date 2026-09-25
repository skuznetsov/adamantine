require "spec"
require "file_utils"
require "../src/adamantine/app"

private class CompletionAdversaryClient < Adamantine::Lsp::Client
  property items = [Adamantine::Lsp::CompletionItem.new("print"), Adamantine::Lsp::CompletionItem.new("printf")]
  getter changes = [] of Tuple(Adamantine::Lsp::Range, String)

  def incremental_text_sync? : Bool
    true
  end

  def text_change(uri : String, version : Int32, range : Adamantine::Lsp::Range, text : String) : Nil
    @changes << {range, text}
  end

  def initialize(root : Path)
    super("", root)
    self.connected = true
  end

  def completion(uri : String, line : Int32, character : Int32, max_items : Int32 = 30) : Array(Adamantine::Lsp::CompletionItem)
    @items
  end

  def stop : Nil
    self.connected = false
  end
end

private class NoSelectionCopyCompletionEditor < Adamantine::EditingTextEditor
  def copy : String?
    raise "completion guards must not materialize selected text"
  end
end

private class CompletionAdversaryApp < Adamantine::App
  def open_public(path : Path)
    open_file(path)
  end

  def client_public=(client : Adamantine::Lsp::Client)
    @lsp = client
  end

  def editor_public : Tui::TextEditor
    current_editor.not_nil!
  end

  def complete_public
    show_completion_hint
    deadline = Time.instant + 2.seconds
    while @lsp_action_running
      raise "completion timeout" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  def items_public=(items : Array(Adamantine::Lsp::CompletionItem))
    @lsp.as(CompletionAdversaryClient).items = items
  end

  def dispatch_public(event : Tui::Event)
    editor_public.on_event(event) unless on_capture(event)
  end

  def close_public
    shutdown_lsp
  end

  def replace_editor_public
    buffer = current_buffer.not_nil!
    current = current_editor.not_nil!
    replacement = Adamantine::EditingTextEditor.new("replacement", buffer.editor.document)
    replacement.set_cursor(current.cursor_line, current.cursor_col)
    replace_active_editor_view(buffer, replacement)
  end

  def forbid_selection_copy_public
    buffer = current_buffer.not_nil!
    current = current_editor.not_nil!
    replacement = NoSelectionCopyCompletionEditor.new("no-selection-copy", buffer.editor.document)
    replacement.set_cursor(current.cursor_line, current.cursor_col)
    replace_active_editor_view(buffer, replacement)
  end

  def popup_open_public : Bool
    @lsp_popup.open
  end

  def changes_public
    @lsp.as(CompletionAdversaryClient).changes
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
end

private def with_completion_adversary(&)
  root = Path.new(Dir.tempdir, "adamantine-completion-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = root / "sample.cr"
  File.write(path, "🙂 pr")
  app = CompletionAdversaryApp.new(project_root: root, lsp_command: "")
  app.client_public = CompletionAdversaryClient.new(root)
  app.open_public(path).should be_true
  app.editor_public.set_cursor(0, 4)
  yield app, root
ensure
  app.try &.close_public
  FileUtils.rm_rf(root) if root
end

describe "parent completion authority and routing checks" do
  it "captures completion authority without copying selected text" do
    with_completion_adversary do |app, _root|
      app.forbid_selection_copy_public
      app.complete_public
      app.popup_open_public.should be_true
    end
  end

  it "prefers a UTF-16 textEdit and inserts multiline text after an emoji" do
    with_completion_adversary do |app, _root|
      app.items_public = [Adamantine::Lsp::CompletionItem.new("candidate", insert_text: "WRONG",
        text_edit: Adamantine::Lsp::CompletionTextEdit.new(Adamantine::Lsp::Range.new(0, 3, 0, 5), "printf(\n)"))]
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 printf(\n)")
      app.changes_public.should eq([{Adamantine::Lsp::Range.new(0, 3, 0, 5), "printf(\n)"}])
      app.editor_public.undo.should be_true
      app.editor_public.text.should eq("🙂 pr")
      app.editor_public.redo.should be_true
      app.editor_public.text.should eq("🙂 printf(\n)")
    end
  end

  [
    Adamantine::Lsp::Range.new(0, 1, 0, 5), # surrogate interior
    Adamantine::Lsp::Range.new(0, 3, 0, 6), # oversized end, not clamped
    Adamantine::Lsp::Range.new(0, 5, 0, 3), # reversed
    Adamantine::Lsp::Range.new(0, 2, 0, 3), # does not contain request position
  ].each_with_index do |range, index|
    it "rejects invalid textEdit #{index} without changing text, selection or history" do
      with_completion_adversary do |app, _root|
        app.items_public = [Adamantine::Lsp::CompletionItem.new("candidate",
          text_edit: Adamantine::Lsp::CompletionTextEdit.new(range, "danger"))]
        app.complete_public
        app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
        app.editor_public.text.should eq("🙂 pr")
        app.editor_public.cursor_col.should eq(4)
        app.editor_public.copy.should be_nil
        app.editor_public.undo.should be_false
      end
    end
  end

  it "accepts a selected item through actual capture keys as one undoable edit" do
    with_completion_adversary do |app, _root|
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Down))
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 printf")
      app.editor_public.undo.should be_true
      app.editor_public.text.should eq("🙂 pr")
      app.editor_public.redo.should be_true
      app.editor_public.text.should eq("🙂 printf")
    end
  end

  it "uses Tab for explicit acceptance rather than indentation" do
    with_completion_adversary do |app, _root|
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab))
      app.editor_public.text.should eq("🙂 print")
    end
  end

  it "does not accept a result after document mutation" do
    with_completion_adversary do |app, _root|
      app.complete_public
      app.editor_public.insert_text("x")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 prx")
    end
  end

  it "does not accept after replacing the originating client" do
    with_completion_adversary do |app, root|
      app.complete_public
      app.client_public = CompletionAdversaryClient.new(root)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 pr")
    end
  end

  it "does not accept after replacing the editor within the same buffer object" do
    with_completion_adversary do |app, _root|
      app.complete_public
      app.replace_editor_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 pr")
      app.editor_public.undo.should be_false
    end
  end

  it "isolates editing keys and bracketed paste beneath the completion popup" do
    with_completion_adversary do |app, _root|
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Backspace))
      app.dispatch_public(Tui::PasteEvent.new("unexpected"))
      app.editor_public.text.should eq("🙂 pr")
      app.editor_public.cursor_col.should eq(4)
    end
  end

  it "rejects a changed selection even when its endpoint equals the captured cursor" do
    with_completion_adversary do |app, _root|
      app.complete_public
      app.editor_public.select_range(0, 2, 0, 4)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 pr")
      app.editor_public.copy.should eq("pr")
      app.editor_public.undo.should be_false
    end
  end

  it "preserves CRLF outside a multiline insertion and across Undo/Redo" do
    with_completion_adversary do |app, root|
      path = root / "crlf.cr"
      original = "header\r\n🙂 pr\r\ntail"
      File.write(path, original)
      app.open_public(path).should be_true
      app.editor_public.set_cursor(1, 4)
      app.items_public = [Adamantine::Lsp::CompletionItem.new("candidate",
        text_edit: Adamantine::Lsp::CompletionTextEdit.new(Adamantine::Lsp::Range.new(1, 3, 1, 5), "print(\r\n)"))]
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("header\r\n🙂 print(\r\n)\r\ntail")
      app.editor_public.undo.should be_true
      app.editor_public.text.should eq(original)
      app.editor_public.redo.should be_true
      app.editor_public.text.should eq("header\r\n🙂 print(\r\n)\r\ntail")
    end
  end

  it "restores the request cursor on Undo when a textEdit extends beyond it" do
    with_completion_adversary do |app, root|
      path = root / "suffix.cr"
      File.write(path, "🙂 print")
      app.open_public(path).should be_true
      app.editor_public.set_cursor(0, 4)
      app.items_public = [Adamantine::Lsp::CompletionItem.new("candidate",
        text_edit: Adamantine::Lsp::CompletionTextEdit.new(Adamantine::Lsp::Range.new(0, 3, 0, 8), "puts"))]
      app.complete_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("🙂 puts")
      app.editor_public.undo.should be_true
      app.editor_public.text.should eq("🙂 print")
      app.editor_public.cursor_col.should eq(4)
    end
  end
end
