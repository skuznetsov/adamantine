require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private class ContextMenuAvailabilityApp < Adamantine::App
  def open_menu_public(actions : Array(Adamantine::LspContextAction)) : Nil
    open_context_menu("Test actions", actions)
  end

  def execute_selected_public : Nil
    execute_selected_context_action
  end

  def handle_menu_public(event : Tui::KeyEvent) : Bool
    handle_context_menu_input(event)
  end

  def render_menu_public(buffer : Tui::Buffer, clip : Tui::Rect) : Nil
    render_lsp_context_menu(buffer, clip)
  end

  def menu_open? : Bool
    @context_menu.open
  end

  def menu_index : Int32
    @context_menu.index
  end

  def menu_index=(value : Int32) : Nil
    @context_menu.index = value
  end

  def menu_scroll : Int32
    @context_menu.scroll
  end
end

private def with_context_menu_availability_app(&)
  root = Path.new(Dir.tempdir, "adamantine-context-menu-availability-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config = root / "config.json"
  File.write(config, "{}")
  app = ContextMenuAvailabilityApp.new(
    project_root: root,
    lsp_command: "",
    keymap_path: config.to_s,
    session_enabled: false,
    recovery_root: root / "recovery",
  )
  yield app
ensure
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

describe "context menu availability" do
  it "rechecks a live availability callback before Enter and allows recovery" do
    with_context_menu_availability_app do |app|
      blocked : String? = nil
      calls = 0
      action = Adamantine::LspContextAction.new(
        "Run action",
        "r",
        -> { calls += 1 },
        -> : String? { blocked },
      )

      app.open_menu_public([action])
      app.execute_selected_public
      calls.should eq(1)

      app.open_menu_public([action])
      blocked = "LSP is reconnecting"
      app.execute_selected_public
      app.menu_open?.should be_true
      calls.should eq(1)

      blocked = nil
      app.execute_selected_public
      app.menu_open?.should be_false
      calls.should eq(2)
    end
  end

  it "keeps a disabled numbered selection open and never invokes it" do
    with_context_menu_availability_app do |app|
      calls = 0
      reason : String? = "No active editor"
      actions = [
        Adamantine::LspContextAction.new("First", "1", -> { calls += 1 }),
        Adamantine::LspContextAction.new("Second", "2", -> { calls += 1 }, -> : String? { reason }),
      ]

      app.open_menu_public(actions)
      app.handle_menu_public(Tui::KeyEvent.new('2')).should be_true
      app.menu_open?.should be_true
      app.menu_index.should eq(1)
      calls.should eq(0)

      reason = nil
      app.handle_menu_public(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.menu_open?.should be_false
      calls.should eq(1)
    end
  end

  it "keeps the selected row visible in a short viewport without splitting Unicode" do
    with_context_menu_availability_app do |app|
      actions = (1..30).map do |index|
        Adamantine::LspContextAction.new("Row #{index} 界e\u0301" + "界" * 50, "ctrl+x", -> { })
      end
      app.open_menu_public(actions)
      app.menu_index = 29

      [6, 8, 14].each do |height|
        buffer = Tui::Buffer.new(80, 20)
        buffer.clear(Tui::Cell.new('.'))
        clip = Tui::Rect.new(3, 2, 60, height)
        app.render_menu_public(buffer, clip)

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
        app.menu_scroll.should be > 0
      end
    end
  end
end
