require "spec"
require "file_utils"
require "../src/adamantine/app"

private class IndentationTerminalApp < Adamantine::App
  def open_test_file(path : Path) : Nil
    raise "could not open fixture" unless open_file(path)
  end

  def editor : Tui::TextEditor
    current_editor || raise "missing editor"
  end

  def show_palette : Nil
    open_command_palette
  end

  def palette_active? : Bool
    command_palette_active?
  end

  def focus_tree : Nil
    @file_panel.focus
  end

  def feed_raw(bytes : String) : Nil
    parser = Tui::InputParser.new
    parser.feed(bytes).each { |event| handle_event(event) }
    if parser.has_pending_burst?
      sleep 25.milliseconds
      while event = parser.flush_paste_burst
        handle_event(event)
      end
    end
  end
end

private def with_indentation_terminal(content : String = "  alpha\nbeta", config : String = "{}", &)
  root = Path.new(Dir.tempdir, "adamantine-indent-terminal-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  file = root / "sample.txt"
  config_path = root / "config.json"
  File.write(file, content)
  File.write(config_path, config)
  app = IndentationTerminalApp.new(root, lsp_command: "", keymap_path: config_path.to_s,
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new)
  app.mount_headless(100, 30)
  app.open_test_file(file)
  yield app
ensure
  FileUtils.rm_rf(root) if root
end

describe "indentation through terminal input" do
  it "keeps Tab in the editor and inserts an indentation unit" do
    with_indentation_terminal do |app|
      app.editor.set_cursor(0, 2)
      app.feed_raw("\t")
      app.editor.text.should eq "    alpha\nbeta"
      Tui::Widget.focused_widget.should eq app.editor
      app.editor.undo.should be_true
      app.editor.text.should eq "  alpha\nbeta"
    end
  end

  it "carries indentation after Enter as one undoable change" do
    with_indentation_terminal do |app|
      app.editor.set_cursor(0, 7)
      app.feed_raw("\r")
      app.editor.text.should eq "  alpha\n  \nbeta"
      app.editor.undo.should be_true
      app.editor.text.should eq "  alpha\nbeta"
    end
  end

  it "still handles ordinary input and Undo as a positive control" do
    with_indentation_terminal do |app|
      app.feed_raw("x")
      app.editor.text.should eq "x  alpha\nbeta"
      app.feed_raw("\u001a")
      app.editor.text.should eq "  alpha\nbeta"
    end
  end

  it "uses configured width and allows auto-indent to be disabled" do
    with_indentation_terminal(config: %({"editor":{"indent_width":4,"auto_indent":false}})) do |app|
      app.editor.set_cursor(0, 7)
      app.feed_raw("\t")
      app.editor.text.should eq "  alpha    \nbeta"
      app.feed_raw("\r")
      app.editor.text.should eq "  alpha    \n\nbeta"
    end
  end

  it "dedents a selected CRLF block through terminal back-tab without touching its final zero-column line" do
    with_indentation_terminal("  alpha\r\n  beta\r\n  gamma") do |app|
      app.editor.select_range(0, 0, 2, 0)
      app.feed_raw("\e[Z")
      app.editor.text.should eq "alpha\r\nbeta\r\n  gamma"
      app.editor.undo.should be_true
      app.editor.text.should eq "  alpha\r\n  beta\r\n  gamma"
      app.editor.can_undo?.should be_false
    end
  end

  it "respects remapping instead of falling back to the widget's hardcoded Tab" do
    with_indentation_terminal(config: %({"keymap":{"app.indent":["ctrl+g"]}})) do |app|
      app.feed_raw("\t")
      app.editor.text.should eq "  alpha\nbeta"
      Tui::Widget.focused_widget.should eq app.editor
      app.feed_raw("\u0007")
      app.editor.text.should eq "    alpha\nbeta"
    end
  end

  it "does not indent a document behind the command palette" do
    with_indentation_terminal do |app|
      app.show_palette
      app.palette_active?.should be_true
      app.feed_raw("\t")
      app.palette_active?.should be_true
      app.feed_raw("\e[Z")
      app.editor.text.should eq "  alpha\nbeta"
      app.editor.can_undo?.should be_false
    end
  end

  it "does not let remapped indentation fall through a modal route" do
    with_indentation_terminal(config: %({"keymap":{"app.indent":["ctrl+g"]}})) do |app|
      app.show_palette
      app.feed_raw("\u0007")
      app.editor.text.should eq "  alpha\nbeta"
      app.editor.can_undo?.should be_false
    end
  end

  it "keeps Tab as focus navigation when the tree is focused" do
    with_indentation_terminal do |app|
      app.focus_tree
      previous_focus = Tui::Widget.focused_widget
      app.feed_raw("\t")
      (Tui::Widget.focused_widget == previous_focus).should be_false
      app.editor.text.should eq "  alpha\nbeta"
      app.editor.can_undo?.should be_false
    end
  end
end
