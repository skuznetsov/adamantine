require "spec"
require "file_utils"
require "../src/adamantine/app"

private class ProblemsAdversaryApp < Adamantine::App
  def open_public(path : Path)
    open_file(path)
  end

  def install_client_public(client : Adamantine::Lsp::Client)
    @lsp = client
    configure_lsp_callbacks(client)
  end

  def buffer_public : Adamantine::OpenBuffer
    current_buffer.not_nil!
  end

  def dispatch_public(event : Tui::Event)
    buffer_public.editor.on_event(event) unless on_capture(event)
  end

  def mode_public : String
    active_input_mode.to_s
  end

  def close_public
    @document_orchestrator.close_active_tab
  end
end

private def with_problems_adversary(&)
  root = Path.new(Dir.tempdir, "adamantine-problems-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = root / "source.cr"
  File.write(path, "🙂x\nsecond\nthird\n")
  app = ProblemsAdversaryApp.new(project_root: root, lsp_command: "", recovery_root: root / "recovery")
  app.open_public(path).should be_true
  client = Adamantine::Lsp::Client.new("", root)
  app.install_client_public(client)
  yield app, client, root
ensure
  app.try &.quit(force: true)
  FileUtils.rm_rf(root) if root
end

private def problem_wire_item(line = 0, column = 2, ending = 3)
  Adamantine::Lsp::Diagnostic.new(line, column, "example", "test", 1, line, ending)
end

describe "parent Problems freshness and capture boundary" do
  it "does not cancel one document's conversion when another URI publishes" do
    with_problems_adversary do |app, client, root|
      first = app.buffer_public
      File.write(root / "other.cr", "other\n")
      app.open_public(root / "other.cr").should be_true
      second = app.buffer_public
      callback = client.on_versioned_diagnostics.not_nil!
      published = false
      spawn do
        callback.call(second.uri, second.version, [problem_wire_item(0, 0, 1)], false)
        published = true
      end
      callback.call(first.uri, first.version, Array.new(100) { problem_wire_item }, false)
      published.should be_true
      first.diagnostics.size.should eq(100)
      second.diagnostics.size.should eq(1)
    end
  end

  it "does not let a yielding older batch replace a newer same-version publication" do
    with_problems_adversary do |app, client, _root|
      buffer = app.buffer_public
      callback = client.on_versioned_diagnostics.not_nil!
      replacement = problem_wire_item(2, 1, 2)
      published = false
      spawn do
        callback.call(buffer.uri, buffer.version, [replacement], false)
        published = true
      end
      callback.call(buffer.uri, buffer.version, Array.new(100) { problem_wire_item }, false)
      published.should be_true
      buffer.diagnostics.size.should eq(1)
      buffer.diagnostics[0].line.should eq(2)
    end
  end

  it "marks a publication partial when a malformed UTF-16 range is discarded" do
    with_problems_adversary do |app, client, _root|
      buffer = app.buffer_public
      # UTF-16 column 1 splits the initial emoji; column 2 is the following x.
      items = [problem_wire_item(0, 1, 2), problem_wire_item]
      client.on_versioned_diagnostics.not_nil!.call(buffer.uri, buffer.version, items, false)
      buffer.diagnostics.size.should eq(1)
      buffer.diagnostics[0].character.should eq(1)
      buffer.diagnostics_partial.should be_true
    end
  end

  it "discards a conversion batch when editing occurs at a cooperative checkpoint" do
    with_problems_adversary do |app, client, _root|
      buffer = app.buffer_public
      edited = false
      spawn do
        buffer.editor.insert_text("changed")
        edited = true
      end
      items = Array.new(100) { problem_wire_item }
      client.on_versioned_diagnostics.not_nil!.call(buffer.uri, buffer.version, items, false)
      edited.should be_true
      buffer.diagnostics.should be_empty
    end
  end

  it "does not reuse a closed document version when the same URI is reopened" do
    with_problems_adversary do |app, client, root|
      original = app.buffer_public
      original_version = original.version
      app.close_public.should be_true
      File.write(root / "source.cr", "changed on disk\n")
      app.open_public(root / "source.cr").should be_true
      reopened = app.buffer_public
      reopened.version.should be > original_version
      client.on_versioned_diagnostics.not_nil!.call(reopened.uri, original_version, [problem_wire_item(0, 0, 1)], false)
      reopened.diagnostics.should be_empty
    end
  end

  it "accepts only the current supplied document version" do
    with_problems_adversary do |app, client, _root|
      buffer = app.buffer_public
      callback = client.on_versioned_diagnostics.not_nil!
      callback.call(buffer.uri, buffer.version - 1, [problem_wire_item], false)
      buffer.diagnostics.should be_empty
      callback.call(buffer.uri, buffer.version + 1, [problem_wire_item], false)
      buffer.diagnostics.should be_empty
      callback.call(buffer.uri, buffer.version, [problem_wire_item], false)
      buffer.diagnostics.size.should eq(1)
      buffer.diagnostics[0].character.should eq(1)
    end
  end

  it "navigates stored Unicode codepoints without interpreting them as UTF-16 again" do
    with_problems_adversary do |app, client, _root|
      buffer = app.buffer_public
      client.on_versioned_diagnostics.not_nil!.call(buffer.uri, buffer.version, [problem_wire_item], false)
      app.dispatch_public(Tui::KeyEvent.new('m', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift))
      app.mode_public.should eq("Problems")
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      {buffer.editor.cursor_line, buffer.editor.cursor_col}.should eq({0, 1})
      buffer.editor.text.should eq("🙂x\nsecond\nthird\n")
    end
  end

  it "wraps next and previous diagnostics in source order" do
    with_problems_adversary do |app, client, _root|
      buffer = app.buffer_public
      diagnostics = [problem_wire_item(2, 1, 2), problem_wire_item]
      client.on_versioned_diagnostics.not_nil!.call(buffer.uri, buffer.version, diagnostics, false)
      buffer.editor.set_cursor(0, 0)
      app.dispatch_public(Tui::KeyEvent.new('n', Tui::Modifiers::Alt))
      {buffer.editor.cursor_line, buffer.editor.cursor_col}.should eq({0, 1})
      app.dispatch_public(Tui::KeyEvent.new('n', Tui::Modifiers::Alt))
      {buffer.editor.cursor_line, buffer.editor.cursor_col}.should eq({2, 1})
      app.dispatch_public(Tui::KeyEvent.new('n', Tui::Modifiers::Alt))
      {buffer.editor.cursor_line, buffer.editor.cursor_col}.should eq({0, 1})
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Alt))
      {buffer.editor.cursor_line, buffer.editor.cursor_col}.should eq({2, 1})
    end
  end

  it "isolates paste and ordinary keys from the document under Problems" do
    with_problems_adversary do |app, client, _root|
      buffer = app.buffer_public
      client.on_versioned_diagnostics.not_nil!.call(buffer.uri, nil, [problem_wire_item], false)
      app.dispatch_public(Tui::KeyEvent.new('m', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift))
      app.mode_public.should eq("Problems")
      app.dispatch_public(Tui::PasteEvent.new("not document text"))
      app.dispatch_public(Tui::KeyEvent.new('z'))
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Backspace))
      app.dispatch_public(Tui::KeyEvent.new('p', Tui::Modifiers::Ctrl))
      app.mode_public.should eq("Problems")
      buffer.editor.text.should eq("🙂x\nsecond\nthird\n")
      buffer.editor.undo.should be_false
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.mode_public.should eq("Normal")
    end
  end

  it "does not navigate an old row after a fresh publication replaces the list" do
    with_problems_adversary do |app, client, _root|
      buffer = app.buffer_public
      callback = client.on_versioned_diagnostics.not_nil!
      callback.call(buffer.uri, buffer.version, [problem_wire_item(2, 1, 2)], false)
      app.dispatch_public(Tui::KeyEvent.new('m', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift))
      callback.call(buffer.uri, buffer.version, [] of Adamantine::Lsp::Diagnostic, false)
      # Call capture only: closing a stale overlay may legitimately return
      # control to the editor on a future keystroke, but cannot authorize a jump.
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      buffer.editor.cursor_line.should eq(0)
    end
  end

  it "clears already-published diagnostics immediately on an edit" do
    with_problems_adversary do |app, client, _root|
      client.on_diagnostics.not_nil!.call(app.buffer_public.uri, [problem_wire_item])
      app.buffer_public.diagnostics.size.should eq(1)
      app.buffer_public.editor.insert_text("new")
      app.buffer_public.diagnostics.should be_empty
    end
  end

  it "rejects a late legacy notification from a replaced client" do
    with_problems_adversary do |app, old_client, root|
      app.install_client_public(Adamantine::Lsp::Client.new("", root))
      old_client.on_diagnostics.not_nil!.call(app.buffer_public.uri, [problem_wire_item])
      app.buffer_public.diagnostics.should be_empty
    end
  end

  it "invalidates rows already published by a replaced client" do
    with_problems_adversary do |app, old_client, root|
      old_client.on_diagnostics.not_nil!.call(app.buffer_public.uri, [problem_wire_item(2, 1, 2)])
      app.buffer_public.diagnostics.size.should eq(1)
      app.install_client_public(Adamantine::Lsp::Client.new("", root))
      app.buffer_public.diagnostics.should be_empty
      app.dispatch_public(Tui::KeyEvent.new('n', Tui::Modifiers::Alt))
      app.buffer_public.editor.cursor_line.should eq(0)
    end
  end
end
