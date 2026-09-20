require "spec"
require "file_utils"
require "json"
require "crystal_tui"

require "../src/adamantine/app"

class ContextActionsCatalogSpecApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def open_quick_actions_public : Nil
    open_quick_actions_menu
  end

  def open_lsp_context_menu_public : Nil
    open_lsp_context_menu
  end

  def open_discovery_palette_public : Nil
    open_command_palette("")
  end

  def context_menu_open? : Bool
    @context_menu.open
  end

  def context_menu_labels : Array(String)
    @context_menu.actions.map(&.label)
  end

  def context_menu_shortcuts : Array(String)
    @context_menu.actions.map(&.shortcut)
  end

  def context_menu_reasons : Array(String?)
    @context_menu.actions.map(&.disabled_reason)
  end

  def palette_open? : Bool
    @command_palette.open
  end

  def selected_palette_reason : String?
    entry = @command_palette.candidates[@command_palette.selected_index]?
    entry.try { |candidate| command_disabled_reason(candidate) }
  end

  def selected_palette_title : String?
    @command_palette.candidates[@command_palette.selected_index]?.try(&.title)
  end

  def remap(action : String, bindings : Array(String)) : Nil
    @key_bindings[action] = bindings
  end

  def set_lsp_client(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def mark_lsp_reconnecting : Nil
    state = lsp_recovery_state
    state.mutex.synchronize do
      state.command = "catalog-test"
      state.active = @lsp
      state.ready = false
      state.resyncing = false
      state.phase = "retrying"
    end
  end

  def render_palette_text(width : Int32 = 80, height : Int32 = 16) : String
    buffer = Tui::Buffer.new(width, height)
    buffer.clear(Tui::Cell.new('.'))
    render_command_palette(buffer, Tui::Rect.new(0, 0, width, height))
    String.build do |io|
      height.times do |y|
        width.times { |x| io << buffer.get(x, y).char }
        io << '\n'
      end
    end
  end
end

private def with_context_actions_catalog_app(&)
  root = Path.new(Dir.tempdir, "adamantine-context-actions-catalog-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config = root / "config.json"
  File.write(config, "{}")
  app = ContextActionsCatalogSpecApp.new(
    project_root: root,
    lsp_command: "",
    keymap_path: config.to_s,
    session_enabled: false,
    recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new
  )
  yield app, root
ensure
  app.try { |instance| instance.quit(force: true) }
  FileUtils.rm_rf(root) if root
end

describe "context action catalog" do
  it "keeps the four search rows and appends the specialized LSP plus shared rows" do
    with_context_actions_catalog_app do |app, root|
      source = root / "main.cr"
      File.write(source, "def main\nend\n")
      app.open_file_public(source)
      app.open_quick_actions_public

      labels = app.context_menu_labels
      labels[0, 4].should eq(["Find in file", "Find backward", "Find in project", "Replace text"])
      labels[4, 10].should eq([
        "Go to definition",
        "Go to declaration",
        "Go to type definition",
        "Go to implementation",
        "Show hover",
        "Show references",
        "Show signature",
        "Show completion",
        "Show diagnostics",
        "Code actions",
      ])
      labels[-4, 4].should eq(["Format document", "Rename symbol", "Quick fix", "Review external changes"])
      app.context_menu_shortcuts[0].should eq("global: ctrl+f")
      app.context_menu_shortcuts[1].should eq("command: ?")
      app.context_menu_shortcuts[2].should eq("global: alt+f / option+f / ctrl+shift+f")
      app.context_menu_shortcuts[3].should eq("command: :r/")
      app.context_menu_shortcuts[4].should eq("global: f12")
      app.context_menu_shortcuts[5].should eq("unbound")
      app.context_menu_shortcuts[8].should eq("global: f6")
      app.context_menu_shortcuts[9].should eq("global: f7")
      app.context_menu_shortcuts[-1].should eq("global: ctrl+shift+e")
      app.context_menu_reasons[-1].should eq("No external changes to review")
    end
  end

  it "uses the active keymap for global hints and does not resurrect unbound defaults" do
    with_context_actions_catalog_app do |app, root|
      source = root / "main.cr"
      File.write(source, "def main\nend\n")
      app.open_file_public(source)
      app.remap("lsp.goto_definition", ["alt+d"])
      app.remap("lsp.hover", [] of String)
      app.open_quick_actions_public

      app.context_menu_shortcuts[4].should eq("global: alt+d")
      app.context_menu_shortcuts[8].should eq("unbound")
    end
  end

  it "keeps an unavailable shared action visible in discovery without executing it" do
    with_context_actions_catalog_app do |app, _root|
      app.open_discovery_palette_public
      "format document".each_char { |char| app.on_capture(Tui::KeyEvent.new(char)) }

      app.selected_palette_title.should eq("Format document")
      app.selected_palette_reason.should eq("No active editor")
      app.render_palette_text.should contain("Unavailable: No active editor | Esc close")
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Tab)).should be_true
      app.palette_open?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.palette_open?.should be_true
    end
  end

  it "shows capability and reconnecting reasons without hiding LSP rows" do
    with_context_actions_catalog_app do |app, root|
      source = root / "main.cr"
      File.write(source, "def main\nend\n")
      app.open_file_public(source)
      client = Adamantine::Lsp::Client.new("", root, [] of String)
      client.connected = true
      client.server_capabilities = JSON.parse(%({
        "documentFormattingProvider": false,
        "renameProvider": false,
        "codeActionProvider": false
      }))
      app.set_lsp_client(client)
      app.open_quick_actions_public

      app.context_menu_reasons[14].should eq("Document formatting is unavailable")
      app.context_menu_reasons[15].should eq("Rename is unavailable")
      app.context_menu_reasons[16].should eq("Quick Fix is unavailable")

      app.mark_lsp_reconnecting
      app.open_lsp_context_menu_public
      app.context_menu_reasons.size.should eq(10)
      app.context_menu_reasons.each do |reason|
        reason.should eq("LSP is reconnecting; actions are temporarily unavailable")
      end
    end
  end

  it "keeps all specialized LSP rows visible with a current editor reason" do
    with_context_actions_catalog_app do |app, _root|
      app.open_lsp_context_menu_public

      app.context_menu_open?.should be_true
      app.context_menu_labels.size.should eq(10)
      app.context_menu_reasons.each do |reason|
        reason.should eq("No active editor")
      end
    end
  end
end
