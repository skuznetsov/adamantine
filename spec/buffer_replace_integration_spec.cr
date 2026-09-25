require "spec"
require "file_utils"
require "../src/adamantine/app"

private class ReplaceGetterGuard < Adamantine::EditingTextEditor
  def text : String
    raise "replace must not materialize the document through text"
  end

  def lines : Array(String)
    raise "replace must not materialize a line array"
  end

  def bytes_for_test : String
    @buffer.text
  end

  def validate_for_test : Nil
    @buffer.validate!
  end
end

private class NoSlicePieceTreeBuffer < Tui::PieceTreeBuffer
  def slice(offset : Int32, length : Int32) : String
    raise "single-line replacement candidate was scanned"
  end
end

private class ReplaceLineEndingProbe < Adamantine::EditingTextEditor
  def replacement_line_ending_for_test(candidate : Tui::PieceTreeBuffer) : String
    replacement_line_ending(candidate)
  end
end

private class BufferReplaceApp < Adamantine::App
  def open_plain(path : Path) : Adamantine::EditingTextEditor
    raise "file did not open" unless open_file(path)
    current_editor.as(Adamantine::EditingTextEditor)
  end

  def set_client(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def open_guarded(path : Path) : ReplaceGetterGuard
    raise "file did not open" unless open_file(path)
    buffer = current_buffer.not_nil!
    current = current_editor.not_nil!
    editor = ReplaceGetterGuard.new(path.to_s, buffer.editor.document)
    editor.set_cursor(current.cursor_line, current.cursor_col)
    buffer.editor = editor
    replace_active_editor_view(path, editor)
    editor
  end

  private def replace_active_editor_view(path : Path, replacement : Tui::TextEditor) : Nil
    index = @editor_tabs.tabs.index { |tab| tab.id == path.to_s }.not_nil!
    tab = @editor_tabs.tabs[index]
    old_view = tab.content.as(Tui::TextEditor)
    @editor_tabs.remove_child(old_view)
    @editor_tabs.tabs[index] = Tui::TabbedPanel::Tab.new(tab.id, tab.label, tab.tooltip, replacement, tab.closable)
    @editor_tabs.add_child(replacement)
    old_view.detach
    @editor_tabs.mark_dirty!
  end

  def replace_public(arguments : String) : Nil
    execute_replace_command(arguments)
  end

  def warning_messages : Array(String)
    @status_log.entries.select(&.level.==(Tui::Log::Level::Warning)).map(&.message)
  end

  def cleanup_public : Nil
    cancel_search_workers
    @document_orchestrator.stop_external_file_monitor
    @recovery_controller.stop(force: true)
    @clipboard.close
    @header.stop_clock
  end
end

private class ReplaceSyncClient < Adamantine::Lsp::Client
  getter changes = [] of Tuple(Int32, String)

  def initialize
    super("", Path.new(Dir.current), [] of String)
  end

  def connected? : Bool
    true
  end

  def incremental_text_sync? : Bool
    true
  end

  def text_change(uri : String, version : Int32, text : String) : Nil
    @changes << {version, text}
  end
end

private def with_replace_app(&)
  root = Path.new(Dir.tempdir, "buffer-replace-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config = root / "config.json"
  File.write(config, "{}")
  app = BufferReplaceApp.new(project_root: root, lsp_command: "", keymap_path: config.to_s,
    recovery_root: root / ".recovery", clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new)
  begin
    yield root, app
  ensure
    app.cleanup_public
    FileUtils.rm_rf(root)
  end
end

describe "bounded buffer replacement commands" do
  it "counts standalone CR and a CRLF seam as line breaks" do
    Tui::PieceTreeBuffer.new("plain").line_count.should eq(1)
    Tui::PieceTreeBuffer.new("before\rafter").line_count.should eq(2)
    Tui::PieceTreeBuffer.new("before\nafter").line_count.should eq(2)
    Tui::PieceTreeBuffer.new("before\r\nafter").line_count.should eq(2)

    seam = Tui::PieceTreeBuffer.new(("x" * 4095) + "\r" + ("x" * 5000))
    seam.insert(4096, "\n")
    seam.line_count.should eq(2)
    seam.validate!
  end

  it "uses the prior line-ending style without scanning a one-line candidate" do
    editor = ReplaceLineEndingProbe.new("line-ending-fast-path")
    editor.load_content_as_saved("before\r\nafter")
    candidate = NoSlicePieceTreeBuffer.new("one long line")

    candidate.line_count.should eq(1)
    editor.replacement_line_ending_for_test(candidate).should eq("\r\n")
  end

  it "still adopts CR and CRLF found in the replacement candidate" do
    [
      {"old\nend", "\n", "\r", "\r"},
      {"old\nend", "\n", "\r\n", "\r\n"},
    ].each do |original, old_text, new_text, expected_ending|
      editor = ReplaceGetterGuard.new("replacement-newline-regression")
      editor.load_content_as_saved(original)
      flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)
      editor.replace_literal(old_text, new_text, flags).should be_true
      candidate_text = original.sub(old_text, new_text)

      editor.insert_newline
      editor.bytes_for_test.should eq(expected_ending + candidate_text)
      editor.validate_for_test
    end
  end

  it "retains legacy cursor clamping and resulting newline style" do
    [
      {"a\r\nold", "a", "\n"},
      {"a\r\nb", "\r\n", ""},
      {"a\rb\nc", "\r", ""},
      {"abc\ndef", "\n", "\r\n"},
    ].each do |original, old_text, new_text|
      editor = ReplaceGetterGuard.new("cursor-replace")
      editor.auto_indent = false
      baseline = Tui::TextEditor.new("cursor-oracle")
      editor.load_content_as_saved(original)
      baseline.load_content_as_saved(original)
      editor.select_range(0, 0, 2, 8)
      baseline.select_range(0, 0, 2, 8)
      flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)
      expected = Adamantine::ReplaceUtils.replace_text_content(original, old_text, new_text, flags)
      baseline.replace_text(expected)
      editor.replace_literal(old_text, new_text, flags).should be_true
      {editor.cursor_line, editor.cursor_col}.should eq({baseline.cursor_line, baseline.cursor_col})
      editor.copy.should eq(baseline.copy)
      editor.insert_newline
      baseline.insert_newline
      editor.bytes_for_test.should eq(baseline.text)
      editor.validate_for_test
    end
  end

  it "reports unsafe arguments without changing text, history or LSP state" do
    with_replace_app do |root, app|
      path = root / "refused.txt"
      File.write(path, "old old")
      editor = app.open_plain(path)
      client = ReplaceSyncClient.new
      app.set_client(client)
      ["/old/\\\\k<missing>/gi", "/#{"x" * 16_385}/new/g"].each do |command|
        before = app.warning_messages.size
        app.replace_public(command)
        app.warning_messages.size.should eq(before + 1)
        editor.text.should eq("old old")
        editor.can_undo?.should be_false
        editor.modified?.should be_false
        client.changes.should be_empty
      end
    end
  end

  it "abandons a partially prepared candidate without losing redo or selection" do
    with_replace_app do |root, app|
      path = root / "candidate-refused.txt"
      File.write(path, "old old")
      editor = app.open_plain(path)
      flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)
      editor.replace_literal("old", "new", flags).should be_true
      editor.undo.should be_true
      editor.select_range(0, 1, 0, 5)
      selection = editor.copy
      client = ReplaceSyncClient.new
      app.set_client(client)
      expect_raises(ArgumentError, /match limit/) do
        editor.replace_literal("old", "new", flags, max_changes: 1)
      end
      expect_raises(ArgumentError, /output limit/) do
        editor.replace_literal("old", "new!", flags, max_output_bytes: 8_i64)
      end
      editor.text.should eq("old old")
      editor.copy.should eq(selection)
      editor.modified?.should be_false
      editor.can_undo?.should be_false
      client.changes.should be_empty
      editor.redo.should be_true
      editor.text.should eq("new new")
    end
  end

  it "discards earlier flushed batches if a later match exceeds the work limit" do
    original = "old" + ("x" * 9000) + "old" + ("x" * 9000) + "old"
    editor = ReplaceGetterGuard.new("late-refusal")
    editor.load_content_as_saved(original)
    changes = [] of Tui::TextEditor::TextChange
    editor.on_text_change { |change| changes << change; nil }
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)

    expect_raises(ArgumentError, /match limit/) do
      editor.replace_literal("old", "NEW!", flags, max_changes: 2)
    end

    editor.bytes_for_test.should eq(original)
    editor.can_undo?.should be_false
    editor.modified?.should be_false
    editor.validate_for_test
    changes.should be_empty
  end

  it "preserves byte-exact legacy replacement across Unicode and newline boundaries" do
    cases = [
      {"\rX\n", "/X/Y/g"},
      {"\rX\n", "/X//g"},
      {"\n\n", "/\n/\r/g"},
      {"\r\n\r\n", "/\n/Q/g"},
      {"\r\n\r\n", "/\r/Q/g"},
      {"a\r\nb\rc\na", "/a/\r/g"},
      {"a\r\nb\rc\na", "/\r\n/🙂/g"},
      {"aaaaa", "/aa/b/g"},
      {"aaaaa", "/aa/b/"},
      {"ſSskKKßẞΣσςİi", "/s/Q/gi"},
      {"ſSskKKßẞΣσςİi", "/k/Q/gi"},
      {"ſSskKKßẞΣσςİi", "/ß/Q/gi"},
      {"ſSskKKßẞΣσςİi", "/σ/Q/gi"},
      {"ſSskKKßẞΣσςİi", "/i/Q/gi"},
      {("a" * 2047) + "🙂\r\nold" + ("a" * 2047) + "old", "/old/X/g"},
      {"old OLD old", "/old/\\\\0!/gi"},
    ]
    with_replace_app do |root, app|
      path = root / "oracle.txt"
      File.write(path, "")
      editor = app.open_guarded(path)
      cases.each do |original, command|
        editor.load_content_as_saved(original, path).should be_true
        old_text, new_text, flags = Adamantine::ReplaceUtils.parse_replace_arguments(command).not_nil!
        expected = Adamantine::ReplaceUtils.replace_text_content(original, old_text, new_text, flags)
        app.replace_public(command)
        editor.bytes_for_test.should eq(expected), "command #{command.inspect} on #{original.inspect}"
        if expected == original
          editor.can_undo?.should be_false
        else
          editor.undo.should be_true
          editor.bytes_for_test.should eq(original)
          editor.can_undo?.should be_false
          editor.redo.should be_true
          editor.bytes_for_test.should eq(expected)
        end
      end
    end
  end

  it "does not consume history or redo for a no-op or preview" do
    with_replace_app do |root, app|
      path = root / "history.txt"
      File.write(path, "old old")
      editor = app.open_guarded(path)
      app.replace_public("/old/new/g")
      editor.undo.should be_true
      app.replace_public("/old/old/g")
      app.replace_public("/absent/new/g")
      app.replace_public("/old/new/gc")
      editor.bytes_for_test.should eq("old old")
      editor.modified?.should be_false
      editor.can_undo?.should be_false
      editor.redo.should be_true
      editor.bytes_for_test.should eq("new new")
    end
  end

  it "preserves mixed UTF-8 and newly formed CRLF seams across edit batches" do
    flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: true)
    [
      {"\n" * 20_000, "\n", "\r"},
      {"\n\r" * 5000, "\n\r", "X"},
      {("🙂old\r\n界" * 3000), "old", "\r"},
      {("a" * 8191) + "old" + ("a" * 8191) + "old", "old", ""},
    ].each do |original, old_text, new_text|
      editor = ReplaceGetterGuard.new("batch-replace")
      editor.load_content_as_saved(original)
      editor.replace_literal(old_text, new_text, flags).should be_true
      editor.bytes_for_test.should eq(original.gsub(old_text, new_text))
      editor.validate_for_test
      editor.undo.should be_true
      editor.bytes_for_test.should eq(original)
      editor.can_undo?.should be_false
      editor.redo.should be_true
      editor.bytes_for_test.should eq(original.gsub(old_text, new_text))
      editor.validate_for_test
    end
  end

  it "matches the legacy string oracle for deterministic mixed-byte edit sequences" do
    random = Random.new(971_843)
    alphabet = ["a", "A", "k", "K", "🙂", "界", "\r", "\n"]
    with_replace_app do |root, app|
      path = root / "random.txt"
      File.write(path, "")
      editor = app.open_guarded(path)
      120.times do
        original = String.build { |io| random.rand(1..80).times { io << alphabet[random.rand(alphabet.size)] } }
        old_text = String.build { |io| random.rand(1..3).times { io << alphabet[random.rand(alphabet.size)] } }
        new_text = String.build { |io| random.rand(0..3).times { io << alphabet[random.rand(alphabet.size)] } }
        flags = Adamantine::ReplaceUtils::ReplaceFlags.new(global: random.rand(2) == 0, ignore_case: random.rand(2) == 0)
        expected = Adamantine::ReplaceUtils.replace_text_content(original, old_text, new_text, flags)
        editor.load_content_as_saved(original, path).should be_true
        # Use the editor API here: the command parser intentionally strips
        # outer whitespace, which is a separate behavior from byte replacement.
        changed = editor.replace_literal(old_text, new_text, flags)
        changed.should eq(expected != original)
        editor.bytes_for_test.should eq(expected)
        editor.validate_for_test
        if changed
          editor.undo.should be_true
          editor.bytes_for_test.should eq(original)
          editor.can_undo?.should be_false
          editor.redo.should be_true
          editor.bytes_for_test.should eq(expected)
          editor.validate_for_test
        else
          editor.can_undo?.should be_false
        end
      end
    end
  end

  it "notifies LSP only once per committed replacement, Undo and Redo" do
    with_replace_app do |root, app|
      path = root / "sync.txt"
      original = "old🙂old\r\nold\r"
      File.write(path, original)
      editor = app.open_plain(path)
      client = ReplaceSyncClient.new
      app.set_client(client)

      app.replace_public("/old/new/gc")
      client.changes.should be_empty
      app.replace_public("/absent/new/g")
      client.changes.should be_empty
      app.replace_public("/old/new/g")
      client.changes.size.should eq 1
      client.changes.last[1].should eq(original.gsub("old", "new"))
      editor.undo.should be_true
      client.changes.size.should eq 2
      client.changes.last[1].should eq(original)
      editor.redo.should be_true
      client.changes.size.should eq 3
      client.changes.last[1].should eq(original.gsub("old", "new"))
      versions = client.changes.map(&.[0])
      versions.should eq([versions.first, versions.first + 1, versions.first + 2])
    end
  end

  it "replaces without full getters and uses exactly one undo entry" do
    with_replace_app do |root, app|
      path = root / "large.txt"
      original = ("界" * 30_000) + "\r\nold🙂old\rfinal\n"
      File.write(path, original)
      editor = app.open_guarded(path)

      app.replace_public("/old/new/g")

      editor.bytes_for_test.should eq(original.gsub("old", "new"))
      editor.undo.should be_true
      editor.bytes_for_test.should eq(original)
      editor.can_undo?.should be_false
      editor.redo.should be_true
      editor.bytes_for_test.should eq(original.gsub("old", "new"))
    end
  end

  it "previews without full getters or mutation" do
    with_replace_app do |root, app|
      path = root / "preview.txt"
      original = "old" + ("x" * 80_000) + "old\r\n"
      File.write(path, original)
      editor = app.open_guarded(path)

      app.replace_public("/old/new/gc")

      editor.bytes_for_test.should eq(original)
      editor.modified?.should be_false
      editor.can_undo?.should be_false
    end
  end
end
