require "spec"
require "file_utils"
require "../src/adamantine/app"

class PaletteAuthoritySpecApp < Adamantine::App
  def type_query(text : String) : Nil
    text.each_char { |char| on_capture(Tui::KeyEvent.new(char)) }
  end

  def open_test_file(path : Path) : Nil
    open_file(path)
  end

  def command_input : String
    @command_palette.input
  end

  def palette_open? : Bool
    @command_palette.open
  end

  def closed? : Bool
    @input.events.closed?
  end

  def confirmation_open? : Bool
    close_confirmation_active?
  end

  def text : String
    current_editor.not_nil!.text
  end

  def remap(action : String, bindings : Array(String)) : Nil
    @key_bindings[action] = bindings
  end

  def draw_palette(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
    render_command_palette(buffer, clip)
  end

  def selected_title : String
    @command_palette.candidates[@command_palette.selected_index].title
  end

  def palette_text : String
    buffer = Tui::Buffer.new(100, 16)
    draw_palette(buffer, Tui::Rect.new(0, 0, 100, 16))
    String.build do |io|
      16.times do |y|
        100.times { |x| io << buffer.get(x, y).char }
        io << '\n'
      end
    end
  end
end

private def with_palette_authority_app(&)
  root = Path.new(Dir.tempdir, "adamantine-palette-authority-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config = root / "config.json"
  File.write(config, "{}")
  app = PaletteAuthoritySpecApp.new(project_root: root, lsp_command: "",
    session_enabled: false, recovery_root: root / "recovery", keymap_path: config.to_s,
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new)
  file = root / "test.cr"
  File.write(file, "unchanged\n")
  app.open_test_file(file)
  yield app, file
ensure
  app.try { |instance| instance.quit(force: true) unless instance.closed? }
  FileUtils.rm_rf(root) if root
end

describe "palette command authority" do
  it "does not discover force quit but permits explicitly typed colon force quit" do
    with_palette_authority_app do |app, file|
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query("q!")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.closed?.should be_false
      app.palette_open?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query(":q!")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.closed?.should be_true
      File.read(file).should eq("unchanged\n")
    end
  end

  it "does not let discovery bypass the dirty quit confirmation" do
    with_palette_authority_app do |app, file|
      app.handle_event(Tui::KeyEvent.new('!'))
      dirty = app.text
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query("quit editor")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.confirmation_open?.should be_true
      app.closed?.should be_false
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query(":q!")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.closed?.should be_false
      app.palette_open?.should be_false
      app.text.should eq(dirty)
      File.read(file).should eq("unchanged\n")
    end
  end

  it "keeps remapped printable menu controls as query text" do
    with_palette_authority_app do |app, file|
      app.remap("app.menu_select", ["x"])
      app.remap("app.menu_close", ["c"])
      app.remap("app.menu_up", ["k"])
      app.remap("app.menu_down", ["j"])
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query("xckj")
      app.palette_open?.should be_true
      app.command_input.should eq("xckj")
      app.text.should eq("unchanged\n")
      File.read(file).should eq("unchanged\n")
    end
  end

  it "never substitutes a discovered action for an unknown explicit command" do
    with_palette_authority_app do |app, file|
      app.handle_event(Tui::KeyEvent.new('!'))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query(":save active file")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.palette_open?.should be_true
      app.command_input.should eq(":save active file")
      File.read(file).should eq("unchanged\n")
    end
  end

  it "owns mouse and paste input without swallowing resize events" do
    with_palette_authority_app do |app, _file|
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.on_capture(Tui::MouseEvent.new(10, 5)).should be_true
      app.on_capture(Tui::PasteEvent.new("injected")).should be_true
      app.on_capture(Tui::ResizeEvent.new(80, 24)).should be_false
      app.text.should eq("unchanged\n")
      app.palette_open?.should be_true
    end
  end

  it "ranks exact aliases first and resets selection when the query changes" do
    with_palette_authority_app do |app, file|
      app.handle_event(Tui::KeyEvent.new('!'))
      edited = app.text
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      3.times { app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)) }
      app.type_query("w")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      File.read(file).should eq(edited)
      app.closed?.should be_false
    end
  end

  it "renders remapped and unbound shortcuts without advertising defaults" do
    with_palette_authority_app do |app, _file|
      app.remap("app.save", ["alt+s"])
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query("save")
      app.palette_text.should contain("[alt+s]")
      app.palette_text.should_not contain("[ctrl+s]")
      app.remap("app.save", [] of String)
      app.palette_text.should contain("Save (w) [unbound]")
      app.palette_text.should_not contain("[ctrl+s]")
    end
  end

  it "recalls command history explicitly from discovery with Alt Up" do
    with_palette_authority_app do |app, _file|
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query(":pwd")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query("unmatched query")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Up, Tui::Modifiers::Alt))
      app.command_input.should eq(":pwd")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.palette_open?.should be_false
      app.text.should eq("unchanged\n")
    end
  end

  it "does not transfer prepared argument authority to a different raw command" do
    with_palette_authority_app do |app, file|
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query("open file path")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab))
      app.command_input.should eq(":open ")
      5.times { app.on_capture(Tui::KeyEvent.new(Tui::Key::Backspace)) }
      app.type_query("cd")
      app.command_input.should eq(":cd")
      app.palette_text.should_not contain("<path>")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      app.palette_open?.should be_false
      app.text.should eq("unchanged\n")
      File.read(file).should eq("unchanged\n")
    end
  end

  it "confines long wide-character input to tiny and offset clips" do
    with_palette_authority_app do |app, _file|
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      app.type_query(":" + "界" * 80)
      [1, 2, 5, 12, 28, 60].each do |width|
        [1, 2, 4, 8, 14].each do |height|
          buffer = Tui::Buffer.new(70, 20)
          buffer.clear(Tui::Cell.new('.'))
          clip = Tui::Rect.new(3, 2, width, height)
          app.draw_palette(buffer, clip)
          buffer.height.times do |y|
            buffer.width.times do |x|
              next if clip.contains?(x, y)
              buffer.get(x, y).char.should eq('.')
            end
          end
        end
      end
    end
  end

  it "keeps the selected result visible after resizing to a short terminal" do
    with_palette_authority_app do |app, _file|
      app.on_capture(Tui::KeyEvent.new(Tui::Key::F1))
      20.times { app.on_capture(Tui::KeyEvent.new(Tui::Key::Down)) }
      [14, 8, 6].each do |height|
        buffer = Tui::Buffer.new(90, height)
        app.draw_palette(buffer, Tui::Rect.new(0, 0, 90, height))
        rendered = String.build do |io|
          height.times do |y|
            90.times { |x| io << buffer.get(x, y).char }
            io << '\n'
          end
        end
        rendered.should contain("> #{app.selected_title}")
      end
    end
  end
end
