require "spec"
require "file_utils"
require "../src/adamantine/app"

class ContextActionsAuthorityApp < Adamantine::App
  def open_test_file(path : Path) : Nil
    open_file(path)
  end

  def menu_open? : Bool
    @context_menu.open
  end

  def palette_open? : Bool
    @command_palette.open
  end

  def text : String
    current_editor.not_nil!.text
  end

  def paste_generation : UInt64
    @clipboard_paste_generation
  end

  def open_test_menu : Nil
    open_context_menu("Test actions", [Adamantine::LspContextAction.new("No-op", "", -> { })])
  end

  def draw_menu(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
    render_lsp_context_menu(buffer, clip)
  end

  def open_live_menu(reason : Proc(String?)) : Nil
    open_context_menu("Live action", [Adamantine::LspContextAction.new("Run", "", -> { }, reason)])
  end

  def set_long_menu : Nil
    open_context_menu("Wide 界 actions", (1..30).map do |index|
      Adamantine::LspContextAction.new("Row #{index} " + "界" * 50, "ctrl+x", -> { })
    end)
    @context_menu.index = 29
  end
end

private def with_context_authority_app(&)
  root = Path.new(Dir.tempdir, "adamantine-context-authority-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config = root / "config.json"
  File.write(config, "{}")
  file = root / "source.cr"
  File.write(file, "unchanged\n")
  app = ContextActionsAuthorityApp.new(project_root: root, lsp_command: "",
    keymap_path: config.to_s, session_enabled: false, recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new)
  app.open_test_file(file)
  yield app, file
ensure
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

describe "context action authority" do
  it "invalidates earlier paste and owns editing keys, paste and mouse until cancel" do
    with_context_authority_app do |app, file|
      previous = app.paste_generation
      app.open_test_menu
      app.paste_generation.should_not eq(previous)
      app.on_capture(Tui::KeyEvent.new('Z')).should be_true
      app.on_capture(Tui::PasteEvent.new("UNWANTED")).should be_true
      app.on_capture(Tui::MouseEvent.new(10, 5)).should be_true
      app.on_capture(Tui::ResizeEvent.new(80, 24)).should be_false
      app.menu_open?.should be_true
      app.text.should eq("unchanged\n")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      app.menu_open?.should be_false
      app.handle_event(Tui::KeyEvent.new('Z'))
      app.text.should_not eq("unchanged\n")
      File.read(file).should eq("unchanged\n")
    end
  end

  it "preserves the explicit F1 transition without leaking text to the editor" do
    with_context_authority_app do |app, _file|
      app.open_test_menu
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1)).should be_true
      app.menu_open?.should be_false
      app.palette_open?.should be_true
      app.text.should eq("unchanged\n")
    end
  end

  it "does not replace a menu with the unrelated Problems shortcut" do
    with_context_authority_app do |app, _file|
      app.open_test_menu
      app.on_capture(Tui::KeyEvent.new('m', Tui::Modifiers::Ctrl | Tui::Modifiers::Shift)).should be_true
      app.menu_open?.should be_true
      app.text.should eq("unchanged\n")
    end
  end

  it "keeps a selected long Unicode row visible and bounded after resize" do
    with_context_authority_app do |app, _file|
      app.set_long_menu
      [6, 8, 14].each do |height|
        buffer = Tui::Buffer.new(80, 20)
        buffer.clear(Tui::Cell.new('.'))
        clip = Tui::Rect.new(3, 2, 60, height)
        app.draw_menu(buffer, clip)
        rendered = String.build do |io|
          buffer.height.times do |y|
            buffer.width.times do |x|
              cell = buffer.get(x, y)
              cell.char.should eq('.') unless clip.contains?(x, y)
              io << cell.char
            end
            io << '\n'
          end
        end
        rendered.should contain("Row 30")
      end
    end
  end

  it "refreshes the selected reason on render and clips even degenerate viewports" do
    with_context_authority_app do |app, _file|
      reason : String? = "LSP is not connected"
      app.open_live_menu(-> : String? { reason })
      buffer = Tui::Buffer.new(80, 20)
      clip = Tui::Rect.new(3, 2, 60, 8)
      app.draw_menu(buffer, clip)
      String.build { |io| 20.times { |y| 80.times { |x| io << buffer.get(x, y).char } } }.should contain("LSP is not connected")
      reason = nil
      buffer.clear
      app.draw_menu(buffer, clip)
      String.build { |io| 20.times { |y| 80.times { |x| io << buffer.get(x, y).char } } }.should_not contain("Unavailable")

      [0, 1, 2, 3, 8].each do |width|
        [0, 1, 2, 3, 4].each do |height|
          buffer.clear(Tui::Cell.new('.'))
          tiny_clip = Tui::Rect.new(3, 2, width, height)
          app.draw_menu(buffer, tiny_clip)
          20.times do |y|
            80.times do |x|
              buffer.get(x, y).char.should eq('.') unless tiny_clip.contains?(x, y)
            end
          end
        end
      end
    end
  end
end
