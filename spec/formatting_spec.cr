require "spec"
require "file_utils"
require "json"

require "../src/adamantine/app"

private class FormattingParseClient < Adamantine::Lsp::Client
  def initialize
    super("", Path.new(Dir.current))
  end

  def parse_formatting_public(raw : JSON::Any?) : Array(JSON::Any)
    parse_formatting_edits(raw)
  end
end

private class FormattingTestClient < Adamantine::Lsp::Client
  property edits : Array(JSON::Any) = [] of JSON::Any
  getter calls = [] of Tuple(String, Int32, Bool)
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)
  property block : Bool = false

  def initialize(root : Path, supported : JSON::Any = JSON.parse("true"))
    super("", root)
    self.connected = true
    self.server_capabilities = JSON.parse({"documentFormattingProvider" => supported}.to_json)
  end

  def formatting(uri : String, tab_size : Int32 = 2, insert_spaces : Bool = true) : Array(JSON::Any)
    @calls << {uri, tab_size, insert_spaces}
    if @block
      @entered.send(nil)
      @release.receive
    end
    @edits
  end
end

private class FormattingTestApp < Adamantine::App
  def open_public(path : Path) : Bool
    open_file(path)
  end

  def client_public=(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def key_bindings_public=(bindings : Adamantine::KeyConfig::ActionMap) : Nil
    @key_bindings = bindings
  end

  def editor_public : Adamantine::EditingTextEditor
    current_editor.as(Adamantine::EditingTextEditor)
  end

  def format_public : Nil
    format_document
  end

  def wait_public(timeout_span : Time::Span = 2.seconds) : Nil
    deadline = Time.instant + timeout_span
    while @lsp_action_running
      raise "formatting timeout" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  def dispatch_public(event : Tui::Event) : Nil
    editor_public.on_event(event) unless on_capture(event)
  end

  def popup_open_public? : Bool
    @lsp_popup.open
  end

  def popup_lines_public : Array(String)
    @lsp_popup.lines
  end

  def popup_top_public : Int32
    @lsp_popup.formatting_top
  end

  def preview_row_count_public : Int32
    @lsp_popup.edit_preview.not_nil!.row_count
  end

  def formatting_open_public? : Bool
    @lsp_popup.formatting_open?
  end

  def options_public : Tuple(Int32, Bool)
    formatting_options_for(editor_public)
  end

  def open_generic_public : Nil
    open_lsp_popup("Other", ["row"])
  end

  def render_popup_public(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
    @lsp_popup.overlay.not_nil!.call(buffer, clip)
  end

  def project_root_public=(root : Path) : Nil
    @project_root = root
  end

  def close_public : Nil
    shutdown_lsp
  end
end

private def with_formatting_app(content : String = "x = 1\n", &)
  root = Path.new(Dir.tempdir, "adamantine-formatting-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = root / "sample.cr"
  File.write(path, content)
  app = FormattingTestApp.new(project_root: root, lsp_command: "")
  app.open_public(path).should be_true
  yield app, root
ensure
  app.try &.close_public
  FileUtils.rm_rf(root) if root
end

private def formatting_edit(start_line : Int32, start_character : Int32, end_line : Int32, end_character : Int32, new_text : String) : JSON::Any
  JSON.parse({
    "range" => {
      "start" => {"line" => start_line, "character" => start_character},
      "end"   => {"line" => end_line, "character" => end_character},
    },
    "newText" => new_text,
  }.to_json)
end

describe "LSP document formatting" do
  it "accepts null and rejects non-array formatting results" do
    client = FormattingParseClient.new
    client.parse_formatting_public(JSON.parse("null")).should be_empty
    client.parse_formatting_public(JSON.parse("[]")).should be_empty
    expect_raises(ArgumentError) { client.parse_formatting_public(JSON.parse("{}")) }
    expect_raises(ArgumentError) { client.parse_formatting_public(JSON.parse("\"bad\"")) }
  end

  it "recognizes boolean and object formatting capabilities only" do
    client = FormattingTestClient.new(Path.new(Dir.current), JSON.parse("true"))
    client.document_formatting_supported?.should be_true
    client.server_capabilities = JSON.parse(%({"documentFormattingProvider": {}}))
    client.document_formatting_supported?.should be_true
    client.server_capabilities = JSON.parse(%({"documentFormattingProvider": false}))
    client.document_formatting_supported?.should be_false
    client.server_capabilities = JSON.parse(%({"documentFormattingProvider": "yes"}))
    client.document_formatting_supported?.should be_false
  end

  it "captures per-file tab size and insert-spaces policy" do
    with_formatting_app do |app, _root|
      app.editor_public.apply_editor_config(2, indent_style: :space, tab_width: 8)
      app.options_public.should eq({2, true})
      app.editor_public.apply_editor_config(2, indent_style: :tab, tab_width: 8)
      app.options_public.should eq({8, false})
    end
  end

  it "returns while formatting is waiting for the server" do
    with_formatting_app do |app, root|
      client = FormattingTestClient.new(root)
      client.block = true
      app.client_public = client

      finished = Channel(Nil).new(1)
      spawn do
        app.format_public
        finished.send(nil)
      end
      select
      when finished.receive
      when timeout(250.milliseconds)
        raise "format command blocked on the LSP response"
      end

      client.entered.receive
      client.release.send(nil)
      app.wait_public
      app.popup_open_public?.should be_false
    end
  end

  it "shows a bounded preview, cancels without editing, and clears modal state" do
    with_formatting_app do |app, root|
      client = FormattingTestClient.new(root)
      client.edits = [
        formatting_edit(0, 0, 0, 1, "x = 2"),
        formatting_edit(0, 5, 0, 5, "\n# formatted"),
      ]
      app.client_public = client
      before = app.editor_public.text
      app.format_public
      app.wait_public
      app.popup_open_public?.should be_true
      app.formatting_open_public?.should be_true
      app.popup_lines_public.any? { |line| line.includes?("edit 1") }.should be_true

      app.dispatch_public(Tui::PasteEvent.new("must not edit"))
      app.dispatch_public(Tui::MouseEvent.new(2, 0))
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Tab))
      app.editor_public.text.should eq(before)
      app.popup_open_public?.should be_true

      100.times { app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Down)) }
      app.popup_top_public.should be <= app.popup_lines_public.size - 1
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.popup_open_public?.should be_false
      app.formatting_open_public?.should be_false
      app.editor_public.text.should eq(before)
      app.editor_public.undo.should be_false

      app.open_generic_public
      app.formatting_open_public?.should be_false
    end
  end

  it "applies the complete batch as one undoable edit" do
    with_formatting_app do |app, root|
      client = FormattingTestClient.new(root)
      client.edits = [formatting_edit(0, 0, 0, 5, "x = 2")]
      app.client_public = client
      app.format_public
      app.wait_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("x = 2\n")
      app.editor_public.undo.should be_true
      app.editor_public.text.should eq("x = 1\n")
      app.editor_public.undo.should be_false
    end
  end

  it "does not publish a response after the document becomes stale" do
    with_formatting_app do |app, root|
      client = FormattingTestClient.new(root)
      client.block = true
      client.edits = [formatting_edit(0, 0, 0, 5, "x = 2")]
      app.client_public = client
      app.format_public
      client.entered.receive
      app.editor_public.insert_text("# changed\n")
      client.release.send(nil)
      app.wait_public
      app.popup_open_public?.should be_false
      app.editor_public.text.should contain("# changed")
    end
  end

  it "clamps scrolling to the visible end in a short terminal" do
    content = (0...10).map { |index| "line#{index}\n" }.join
    with_formatting_app(content) do |app, root|
      client = FormattingTestClient.new(root)
      client.edits = Array(JSON::Any).new(10) do |index|
        formatting_edit(index, 0, index, 0, "# #{index}\n")
      end
      app.client_public = client
      app.format_public
      app.wait_public

      buffer = Tui::Buffer.new(32, 10)
      app.editor_public.rect = Tui::Rect.new(0, 0, 32, 10)
      100.times { app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Down)) }
      app.render_popup_public(buffer, Tui::Rect.new(0, 0, 32, 10))
      visible = 8 # inline title/footer leave the active editor body rows
      app.popup_top_public.should eq([app.preview_row_count_public - visible, 0].max)
    end
  end

  it "marks a formatting row that is clipped by the popup width" do
    with_formatting_app("x = 1\n") do |app, root|
      client = FormattingTestClient.new(root)
      client.edits = [formatting_edit(0, 0, 0, 5, "x = " + ("a" * 120))]
      app.client_public = client
      app.format_public
      app.wait_public

      buffer = Tui::Buffer.new(24, 10)
      app.editor_public.rect = Tui::Rect.new(0, 0, 24, 10)
      app.render_popup_public(buffer, Tui::Rect.new(0, 0, 24, 10))
      rendered = (0...buffer.height).map do |y|
        (0...buffer.width).map { |x| buffer.get(x, y).glyph }.join
      end.join("\n")
      rendered.includes?("…").should be_true
    end
  end

  it "renders the proposed edit inside the active editor rect without mutating the view" do
    with_formatting_app("before = \"😀\"\nafter = true\n") do |app, root|
      client = FormattingTestClient.new(root)
      client.edits = [formatting_edit(0, 0, 0, 8, "before = \"🦊\"")]
      app.client_public = client
      app.format_public
      app.wait_public

      app.editor_public.rect = Tui::Rect.new(4, 2, 32, 7)
      app.editor_public.set_cursor(1, 3)
      cursor_before = {app.editor_public.cursor_line, app.editor_public.cursor_col}
      scroll_before = {app.editor_public.session_scroll_y, app.editor_public.session_scroll_x}
      buffer = Tui::Buffer.new(40, 12)
      buffer.set(0, 0, 'Q')

      app.render_popup_public(buffer, Tui::Rect.new(0, 0, 40, 12))
      rendered = (0...buffer.height).map do |y|
        (0...buffer.width).map { |x| buffer.get(x, y).glyph }.join
      end.join("\n")

      rendered.should contain("Enter Accept all")
      rendered.should contain("Esc Reject")
      rendered.should contain("-")
      rendered.should contain("+")
      rendered.should contain("before")
      buffer.get(0, 0).glyph.should eq("Q")
      buffer.get(4, 3).glyph.should eq("-")
      buffer.get(4, 4).glyph.should eq("+")
      buffer.get(4, 3).style.fg.should eq(Adamantine::Theme::Status.error)
      buffer.get(4, 4).style.fg.should eq(Adamantine::Theme::Status.success)
      app.editor_public.text.should eq("before = \"😀\"\nafter = true\n")
      {app.editor_public.cursor_line, app.editor_public.cursor_col}.should eq(cursor_before)
      {app.editor_public.session_scroll_y, app.editor_public.session_scroll_x}.should eq(scroll_before)
    end
  end

  it "keeps partial repaint coordinates and narrow accept/reject hints" do
    with_formatting_app("old\ncontext\n") do |app, root|
      client = FormattingTestClient.new(root)
      client.edits = [formatting_edit(0, 0, 0, 3, "界new")]
      app.client_public = client
      app.format_public
      app.wait_public
      editor_rect = Tui::Rect.new(4, 2, 32, 7)
      app.editor_public.rect = editor_rect
      full = Tui::Buffer.new(40, 12)
      app.render_popup_public(full, Tui::Rect.new(0, 0, 40, 12))

      # Starts at the continuation cell of the candidate's leading CJK glyph;
      # excludes title, footer and the glyph's leading cell.
      clip = Tui::Rect.new(11, 4, 13, 3)
      partial = Tui::Buffer.new(40, 12)
      12.times do |y|
        40.times { |x| partial.set(x, y, 'Q') }
      end
      partial.set(10, 4, "語")
      before = Array.new(12) { |y| Array.new(40) { |x| partial.get(x, y) } }
      app.render_popup_public(partial, clip)
      12.times do |y|
        40.times do |x|
          expected = clip.contains?(x, y) ? full.get(x, y) : before[y][x]
          partial.get(x, y).should eq(expected)
        end
      end

      [22, 14].each do |width|
        app.editor_public.rect = Tui::Rect.new(0, 0, width, 1)
        narrow = Tui::Buffer.new(width, 1)
        app.render_popup_public(narrow, Tui::Rect.new(0, 0, width, 1))
        text = (0...width).map { |x| narrow.get(x, 0).glyph }.join
        text.should contain("Enter")
        text.should contain("Esc")
      end
      app.editor_public.rect = editor_rect
      right_edge = Tui::Buffer.new(40, 12)
      right_edge.set(11, 4, 'Q')
      app.render_popup_public(right_edge, Tui::Rect.new(4, 4, 7, 1))
      right_edge.get(10, 4).wide?.should be_false
      right_edge.get(11, 4).glyph.should eq("Q")
      app.editor_public.text.should eq("old\ncontext\n")
      app.editor_public.can_undo?.should be_false
    end
  end

  it "keeps raw arrows, Enter, and Escape when completion keys are remapped" do
    content = (0...10).map { |index| "line#{index}\n" }.join
    with_formatting_app(content) do |app, root|
      bindings = Adamantine::KeyConfig.defaults
      bindings["lsp.completion_up"] = ["ctrl+u"]
      bindings["lsp.completion_down"] = ["ctrl+d"]
      bindings["lsp.completion_accept"] = ["ctrl+a"]
      bindings["lsp.completion_cancel"] = ["ctrl+c"]
      app.key_bindings_public = bindings

      client = FormattingTestClient.new(root)
      client.edits = Array(JSON::Any).new(10) do |index|
        formatting_edit(index, 0, index, 0, "# #{index}\n")
      end
      app.client_public = client
      app.format_public
      app.wait_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Down))
      app.popup_top_public.should be > 0
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Escape))
      app.popup_open_public?.should be_false
      app.editor_public.text.should eq(content)

      app.format_public
      app.wait_public
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should contain("# 0")
      app.popup_open_public?.should be_false
    end
  end

  it "rejects an explicit apply after the client identity changes" do
    with_formatting_app do |app, root|
      client = FormattingTestClient.new(root)
      client.edits = [formatting_edit(0, 0, 0, 5, "x = 2")]
      app.client_public = client
      app.format_public
      app.wait_public
      before = app.editor_public.text
      app.client_public = FormattingTestClient.new(root)
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq(before)
      app.popup_open_public?.should be_false
    end
  end

  it "rejects an explicit apply after the active editor changes" do
    with_formatting_app do |app, root|
      client = FormattingTestClient.new(root)
      client.edits = [formatting_edit(0, 0, 0, 5, "x = 2")]
      app.client_public = client
      app.format_public
      app.wait_public
      other = root / "other.cr"
      File.write(other, "other = 1\n")
      app.open_public(other).should be_true
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq("other = 1\n")
      app.popup_open_public?.should be_false
    end
  end

  it "rejects an explicit apply after the project root changes" do
    with_formatting_app do |app, root|
      client = FormattingTestClient.new(root)
      client.edits = [formatting_edit(0, 0, 0, 5, "x = 2")]
      app.client_public = client
      app.format_public
      app.wait_public
      before = app.editor_public.text
      app.project_root_public = root / "moved"
      app.dispatch_public(Tui::KeyEvent.new(Tui::Key::Enter))
      app.editor_public.text.should eq(before)
      app.popup_open_public?.should be_false
    end
  end

  it "does not send a request when the server lacks formatting capability" do
    with_formatting_app do |app, root|
      client = FormattingTestClient.new(root, JSON.parse("false"))
      app.client_public = client
      app.format_public
      sleep 10.milliseconds
      client.calls.should be_empty
      app.popup_open_public?.should be_false
    end
  end
end
