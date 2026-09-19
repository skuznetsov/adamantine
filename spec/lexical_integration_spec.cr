require "spec"
require "file_utils"
require "../src/adamantine/app"

private class LexicalIntegrationApp < Adamantine::App
  def open_lexical(path : Path) : Adamantine::OpenBuffer
    raise "fixture did not open" unless open_file(path)
    current_buffer.not_nil!
  end

  def close_lexical : Bool
    close_active_tab
  end
end

private def with_lexical_app(&)
  root = Path.new(Dir.tempdir, "adamantine-lexical-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  File.write(root / "config.json", "{}")
  app = LexicalIntegrationApp.new(
    project_root: root, lsp_command: "", keymap_path: (root / "config.json").to_s,
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    recovery_root: root / "recovery", session_enabled: false,
  )
  yield root, app
ensure
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

private def lexical_surface(buffer : Adamantine::OpenBuffer) : Tui::Buffer
  editor = buffer.editor
  editor.show_line_numbers = false
  editor.show_fold_gutter = false
  editor.show_scrollbar = false
  editor.rect = Tui::Rect.new(0, 0, 50, 5)
  surface = Tui::Buffer.new(50, 5)
  editor.render(surface, Tui::Rect.new(0, 0, 50, 5))
  surface
end

private def wait_lexical_color(buffer : Adamantine::OpenBuffer, x : Int32, y : Int32, token : String) : Nil
  deadline = Time.instant + 2.seconds
  loop do
    surface = lexical_surface(buffer)
    return if surface.get(x, y).style.fg == Adamantine::Theme::Syntax.color(token)
    raise "missing #{token} color at #{x},#{y}" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

describe "LSP-independent lexical rendering" do
  it "renders keywords, numbers and strings with no language server" do
    with_lexical_app do |root, app|
      path = root / "sample.cr"
      File.write(path, "def value\n  42\n  \"hello\"\nend\n")
      buffer = app.open_lexical(path)
      wait_lexical_color(buffer, 1, 0, "keyword")
      wait_lexical_color(buffer, 2, 1, "number")
      wait_lexical_color(buffer, 3, 2, "string")
      buffer.editor.modified?.should be_false
      File.read(path).should eq(buffer.editor.text)
    end
  end

  it "invalidates stale semantics on edit and preserves lexical fallback through Undo" do
    with_lexical_app do |root, app|
      path = root / "edit.cr"
      File.write(path, "def value\nend")
      buffer = app.open_lexical(path)
      buffer.semantic_overlay = Adamantine::SemanticOverlay.build(
        [0, 0, 3, 18, 0], ["def value", "end"], Adamantine::SemanticOverlay::STANDARD_LEGEND
      )
      lexical_surface(buffer).get(1, 0).style.fg.should eq(Adamantine::Theme::Syntax.color("string"))
      buffer.editor.set_cursor(0, 0)
      buffer.editor.insert_text("# ")
      buffer.semantic_overlay.any_tokens?.should be_false
      wait_lexical_color(buffer, 3, 0, "comment")
      buffer.editor.undo.should be_true
      wait_lexical_color(buffer, 1, 0, "keyword")
      buffer.editor.text.should eq("def value\nend")
    end
  end

  it "does not enable Crystal keywords for plain text" do
    with_lexical_app do |root, app|
      path = root / "sample.txt"
      File.write(path, "def value")
      buffer = app.open_lexical(path)
      lexical_surface(buffer).get(1, 0).style.fg.should_not eq(Adamantine::Theme::Syntax.color("keyword"))
    end
  end

  it "settles instead of repeatedly rescanning a viewport larger than its token cache" do
    with_lexical_app do |root, app|
      path = root / "pressure.cr"
      File.write(path, "def one\ndef two\ndef three\ndef four\nend")
      buffer = app.open_lexical(path)
      editor = buffer.editor.as(Adamantine::EditingTextEditor)
      buffer.lexical_highlighter = Adamantine::LexicalHighlighter.new(
        editor.search_source, max_cached_lines: 2, max_cached_spans: 4
      )
      lexical_surface(buffer)
      deadline = Time.instant + 2.seconds
      while buffer.lexical_worker_running
        raise "lexical worker did not settle" if Time.instant >= deadline
        sleep 1.millisecond
      end
      5.times do
        lexical_surface(buffer)
        buffer.lexical_worker_running.should be_false
        buffer.lexical_highlighter.not_nil!.cached_span_count.should be <= 4
      end
      editor.set_cursor(0, 0)
      editor.insert_text("# ")
      buffer.lexical_requested_lines.should be_empty
    end
  end

  it "keeps tab and Unicode display cells aligned with lexical codepoint spans" do
    with_lexical_app do |root, app|
      path = root / "unicode.cr"
      File.write(path, "\t界 = \"🙂\" # note")
      buffer = app.open_lexical(path)
      buffer.editor.tab_size = 4
      # Tab is four cells, CJK and emoji are two; token coordinates remain
      # codepoint columns in the lexer and cell conversion stays in renderer.
      wait_lexical_color(buffer, 9, 0, "string")
      wait_lexical_color(buffer, 10, 0, "string")
      wait_lexical_color(buffer, 14, 0, "comment")
    end
  end

  it "recomputes multiline string state after editing its opening quote" do
    with_lexical_app do |root, app|
      path = root / "multiline.cr"
      File.write(path, "\"start\ndef\nend\"")
      buffer = app.open_lexical(path)
      wait_lexical_color(buffer, 1, 1, "string")
      buffer.editor.set_cursor(0, 0)
      buffer.editor.delete
      wait_lexical_color(buffer, 1, 1, "keyword")
    end
  end

  it "does not let queued lexical work escape a closed and reopened buffer" do
    with_lexical_app do |root, app|
      path = root / "reopen.cr"
      File.write(path, "def old\nend")
      old = app.open_lexical(path)
      lexical_surface(old)
      app.close_lexical.should be_true
      File.write(path, "# replacement")
      current = app.open_lexical(path)
      current.same?(old).should be_false
      wait_lexical_color(current, 1, 0, "comment")
      sleep 5.milliseconds
      old.lexical_worker_running.should be_false
      current.editor.text.should eq("# replacement")
    end
  end

  it "rebinds an in-flight giant-line scan to edited text and stops on quit" do
    with_lexical_app do |root, app|
      path = root / "in-flight.cr"
      File.write(path, "x" * 100_000 + "\nend")
      buffer = app.open_lexical(path)
      lexer = buffer.lexical_highlighter.not_nil!
      lexical_surface(buffer)
      deadline = Time.instant + 2.seconds
      while lexer.last_progress.codepoints_scanned == 0
        raise "lexical work did not start" if Time.instant >= deadline
        sleep 1.millisecond
      end
      buffer.editor.replace_text("# replacement\ndef value\nend")
      wait_lexical_color(buffer, 1, 0, "comment")
      wait_lexical_color(buffer, 1, 1, "keyword")
      buffer.editor.replace_text("x" * 100_000)
      lexical_surface(buffer)
      app.quit(force: true)
      sleep 5.milliseconds
      buffer.lexical_worker_running.should be_false
      File.read(path).should eq("x" * 100_000 + "\nend")
    end
  end

  it "restarts from the correct source offset after an edit on a later CRLF line" do
    with_lexical_app do |root, app|
      path = root / "offset.cr"
      File.write(path, "# first\r\ndef value\r\n  42\r\nend")
      buffer = app.open_lexical(path)
      wait_lexical_color(buffer, 1, 1, "keyword")
      buffer.editor.set_cursor(1, 0)
      buffer.editor.insert_text("# ")
      wait_lexical_color(buffer, 4, 1, "comment")
      wait_lexical_color(buffer, 2, 2, "number")
      buffer.editor.undo.should be_true
      wait_lexical_color(buffer, 1, 1, "keyword")
    end
  end
end
