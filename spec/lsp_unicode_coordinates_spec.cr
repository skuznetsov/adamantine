require "spec"
require "file_utils"

require "../src/adamantine/app"

private class UnicodeCoordinateApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def set_lsp_client_public(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def configure_lsp_callbacks_public(client : Adamantine::Lsp::Client) : Nil
    configure_lsp_callbacks(client)
  end

  def show_hover_public : Nil
    show_hover_hint
  end

  def show_definition_public : Nil
    goto_definition
  end

  def set_cursor_public(line : Int32, column : Int32) : Nil
    current_editor.not_nil!.set_cursor(line, column)
  end

  def wait_for_action_public(timeout_span : Time::Span = 1.second) : Nil
    deadline = Time.instant + timeout_span
    while @lsp_action_running
      raise "timed out waiting for asynchronous LSP action" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  def current_path_public : String?
    current_buffer.try(&.path.to_s)
  end

  def current_column_public : Int32
    current_editor.not_nil!.cursor_col
  end

  def current_line_public : Int32
    current_editor.not_nil!.cursor_line
  end

  def insert_public(text : String) : Nil
    current_editor.not_nil!.insert_text(text)
  end

  def diagnostics_public(path : Path) : Array(Adamantine::Lsp::Diagnostic)
    @document_session.open_buffers[path.to_s].not_nil!.diagnostics
  end
end

private class UnicodeCoordinateClient < Adamantine::Lsp::Client
  getter hover_position : Tuple(Int32, Int32)?

  def initialize(
    root : Path,
    @target : Path? = nil,
    @target_line : Int32 = 0,
    @target_character : Int32 = 2,
    @diagnostics_uri : String? = nil,
  )
    super("", root)
    self.connected = true
  end

  def hover(uri : String, line : Int32, character : Int32) : Adamantine::Lsp::Hover?
    @hover_position = {line, character}
    Adamantine::Lsp::Hover.new("hover")
  end

  def goto_definition(uri : String, line : Int32, character : Int32) : Array(Adamantine::Lsp::Location)
    target = @target
    return [] of Adamantine::Lsp::Location unless target
    [Adamantine::Lsp::Location.new(
      Adamantine::UriCodec.path_to_uri(target.not_nil!),
      @target_line,
      @target_character
    )]
  end
end

private def with_unicode_coordinate_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-lsp-unicode-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe "LSP Unicode coordinate boundary" do
  it "sends interactive codepoint columns as UTF-16" do
    with_unicode_coordinate_workspace do |tmp|
      source = tmp / "source.cr"
      File.write(source.to_s, "a🙂b\n")
      app = UnicodeCoordinateApp.new(project_root: tmp, lsp_command: "")
      client = UnicodeCoordinateClient.new(tmp)
      app.set_lsp_client_public(client)
      raise "source should open" unless app.open_file_public(source)

      app.set_cursor_public(0, 2)
      app.show_hover_public
      app.wait_for_action_public

      client.hover_position.should eq({0, 3})
    end
  end

  it "converts navigation locations against the opened target editor" do
    with_unicode_coordinate_workspace do |tmp|
      source = tmp / "source.cr"
      target = tmp / "target.cr"
      File.write(source.to_s, "puts :source\n")
      File.write(target.to_s, "🙂x\n")
      app = UnicodeCoordinateApp.new(project_root: tmp, lsp_command: "")
      client = UnicodeCoordinateClient.new(tmp, target)
      app.set_lsp_client_public(client)
      raise "source should open" unless app.open_file_public(source)

      app.show_definition_public
      app.wait_for_action_public

      app.current_path_public.should eq(target.to_s)
      app.current_column_public.should eq(1)
    end
  end

  it "converts against unsaved content when the target is already open" do
    with_unicode_coordinate_workspace do |tmp|
      source = tmp / "source.cr"
      target = tmp / "target.cr"
      File.write(source.to_s, "puts :source\n")
      File.write(target.to_s, "🙂x\n")
      app = UnicodeCoordinateApp.new(project_root: tmp, lsp_command: "")
      # UTF-16 column 1 is an invalid interior position in the on-disk line,
      # but is the codepoint boundary after the inserted ASCII prefix in the
      # unsaved editor.  The already-open resolver must use that editor.
      client = UnicodeCoordinateClient.new(tmp, target, 0, 1)
      app.set_lsp_client_public(client)
      raise "source should open" unless app.open_file_public(source)
      raise "target should open" unless app.open_file_public(target)
      app.insert_public("a")
      raise "source should be active" unless app.open_file_public(source)

      app.show_definition_public
      app.wait_for_action_public

      app.current_path_public.should eq(target.to_s)
      app.current_line_public.should eq(0)
      app.current_column_public.should eq(1)
    end
  end

  it "uses the editor line model for bare CR navigation" do
    with_unicode_coordinate_workspace do |tmp|
      source = tmp / "source.cr"
      target = tmp / "target.cr"
      File.write(source.to_s, "puts :source\n")
      File.write(target.to_s, "first\r🙂x\r")
      app = UnicodeCoordinateApp.new(project_root: tmp, lsp_command: "")
      client = UnicodeCoordinateClient.new(tmp, target, 1, 2)
      app.set_lsp_client_public(client)
      raise "source should open" unless app.open_file_public(source)

      app.show_definition_public
      app.wait_for_action_public

      app.current_path_public.should eq(target.to_s)
      app.current_line_public.should eq(1)
      app.current_column_public.should eq(1)
    end
  end

  it "consumes diagnostics against their originating editor, not the active tab" do
    with_unicode_coordinate_workspace do |tmp|
      first = tmp / "first.cr"
      second = tmp / "second.cr"
      File.write(first.to_s, "🙂x\n")
      File.write(second.to_s, "plain\n")
      app = UnicodeCoordinateApp.new(project_root: tmp, lsp_command: "")
      client = UnicodeCoordinateClient.new(tmp)
      app.set_lsp_client_public(client)
      raise "first should open" unless app.open_file_public(first)
      raise "second should open" unless app.open_file_public(second)
      app.configure_lsp_callbacks_public(client)

      callback = client.on_diagnostics.not_nil!
      callback.call(
        Adamantine::UriCodec.path_to_uri(first),
        [Adamantine::Lsp::Diagnostic.new(0, 2, "emoji", nil, nil, 0, 3)]
      )

      diagnostics = app.diagnostics_public(first)
      diagnostics.size.should eq(1)
      diagnostics[0].character.should eq(1)
      diagnostics[0].end_character.should eq(2)
    end
  end
end
