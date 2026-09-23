require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private class EditorSplitSpecApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def run_command_public(command : String) : Bool
    @command_palette.open = true
    execute_command(":#{command}")
    !@command_palette.open
  end

  def set_binding_public(action : String, binding : String) : Nil
    @key_bindings[action] = [binding]
  end

  def active_path_public : Path?
    current_buffer.try(&.path)
  end

  def active_text_public : String?
    current_editor.try(&.text)
  end

  def buffer_count_public : Int32
    @document_session.open_buffers.size
  end

  def buffer_text_public(path : Path) : String
    @document_session.open_buffers[path.to_s]?.try(&.editor.text) || raise "missing buffer #{path}"
  end

  def buffer_editor_public(path : Path) : Tui::TextEditor
    @document_session.open_buffers[path.to_s]?.try(&.editor) || raise "missing buffer #{path}"
  end

  def buffer_watch_token_public(path : Path) : Adamantine::ExternalFileMonitor::WatchToken?
    @document_session.open_buffers[path.to_s]?.try(&.watch_token)
  end

  def buffer_paths_public : Array(String)
    @document_session.open_buffers.keys.sort
  end

  def tab_paths_public : Array(String)
    @editor_tabs.tabs.map(&.id)
  end

  def group_tab_paths_public : Array(Array(String))
    editor_tab_groups.map { |panel| panel.tabs.map(&.id) }
  end

  def split_active_public : Bool
    !@right_editor_tabs.nil?
  end

  def active_group_public : Int32
    @active_editor_group
  end

  def active_group_panel_public : Tui::TabbedPanel
    active_editor_tabs
  end

  def close_confirmation_active_public : Bool
    close_confirmation_active?
  end

  def warning_messages_public : Array(String)
    @status_log.entries.select do |entry|
      entry.level == Tui::Log::Level::Warning
    end.map(&.message)
  end

  def activate_session_public : Bool
    start_session_lifecycle
  end

  def save_session_public : Bool
    save_session_state
  end

  def render_text_public(width : Int32 = 120, height : Int32 = 32) : String
    mount_headless(width, height)
    surface = Tui::Buffer.new(width, height)
    render(surface, Tui::Rect.new(0, 0, width, height))
    String.build do |output|
      height.times do |y|
        width.times { |x| output << surface.get(x, y).glyph }
        output << '\n'
      end
    end
  end

  def dispatch_public(event : Tui::Event) : Bool
    handle_event(event)
  end
end

private def with_editor_split_workspace(&)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-editor-split-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

describe "two-group editor split" do
  it "routes a remapped split action, renders distinct files, and follows mouse focus" do
    with_editor_split_workspace do |root|
      left = root / "left.cr"
      right = root / "right.cr"
      File.write(left, "LEFT_PANE_MARKER\n")
      File.write(right, "RIGHT_PANE_MARKER\n")
      app = EditorSplitSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.run_command_public("closesplit").should be_true
      app.warning_messages_public.should contain("No editor split is open")

      app.open_file_public(left).should be_true
      app.render_text_public
      app.set_binding_public("app.split_right", "ctrl+alt+r")
      app.on_capture(Tui::KeyEvent.new('r', Tui::Modifiers::Ctrl | Tui::Modifiers::Alt)).should be_true
      app.split_active_public.should be_true
      app.active_group_public.should eq(1)
      Tui::Widget.focused_widget.should eq(app.active_group_panel_public)
      app.render_text_public.should contain("[Pane 2]")
      app.dispatch_public(Tui::KeyEvent.new('Z'))
      app.buffer_text_public(left).should eq("LEFT_PANE_MARKER\n")
      app.open_file_public(right).should be_true

      screen = app.render_text_public
      screen.should contain("LEFT_PANE_MARKER")
      screen.should contain("RIGHT_PANE_MARKER")
      app.active_path_public.should eq(right)

      left_editor = app.buffer_editor_public(left)
      app.dispatch_public(Tui::MouseEvent.new(left_editor.rect.x + 2, left_editor.rect.y + 1)).should be_true
      app.active_path_public.should eq(left)
      left_editor.insert_text("LEFT_EDIT")
      app.buffer_text_public(left).should contain("LEFT_EDIT")
      app.buffer_text_public(right).should eq("RIGHT_PANE_MARKER\n")

      right_editor = app.buffer_editor_public(right)
      # The tab strip belongs to the right group too, not only its text area.
      app.dispatch_public(Tui::MouseEvent.new(right_editor.rect.x + 2, right_editor.rect.y - 1)).should be_true
      app.active_path_public.should eq(right)
      app.dispatch_public(Tui::MouseEvent.new(left_editor.rect.x + 2, left_editor.rect.y - 1)).should be_true
      app.active_path_public.should eq(left)

      app.dispatch_public(Tui::MouseEvent.new(right_editor.rect.x + 2, right_editor.rect.y + 1)).should be_true
      app.active_path_public.should eq(right)
      right_editor.insert_text("RIGHT_EDIT")
      app.buffer_text_public(right).should contain("RIGHT_EDIT")

      # A split that becomes too narrow on resize collapses before layout can
      # feed invalid min/max bounds to SplitContainer.
      resized = app.render_text_public(48, 32)
      resized.should contain("RIGHT_PANE_MARKER")
      app.active_path_public.should eq(right)
      app.split_active_public.should be_false
      app.dispatch_public(Tui::KeyEvent.new('r', Tui::Modifiers::Ctrl | Tui::Modifiers::Alt)).should be_true
      app.split_active_public.should be_false
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "reopens an existing dirty path in its owner and collapses without closing buffers" do
    with_editor_split_workspace do |root|
      left = root / "left.cr"
      right = root / "right.cr"
      right2 = root / "right2.cr"
      File.write(left, "LEFT_STAYS_OPEN\n")
      File.write(right, "RIGHT_DIRTY_BASE\n")
      File.write(right2, "RIGHT_TWO_BASE\n")
      app = EditorSplitSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(left).should be_true
      app.run_command_public("splitright")
      app.open_file_public(right).should be_true
      app.group_tab_paths_public.should eq([[left.to_s], [right.to_s]])
      app.buffer_editor_public(right).insert_text("unsaved ")
      app.render_text_public.should contain("LEFT_STAYS_OPEN")
      app.render_text_public.should contain("unsaved RIGHT_DIRTY_BASE")
      app.run_command_public("focusnextgroup")
      app.open_file_public(right).should be_true
      app.active_path_public.should eq(right)
      app.buffer_count_public.should eq(2)
      app.run_command_public("q")
      app.close_confirmation_active_public.should be_true
      app.buffer_count_public.should eq(2)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.close_confirmation_active_public.should be_false
      right_editor = app.buffer_editor_public(right)
      app.run_command_public("focusnextgroup")
      app.active_path_public.should eq(left)

      watch_token = app.buffer_watch_token_public(right).not_nil!
      app.run_command_public("closesplit")
      app.buffer_count_public.should eq(2)
      app.active_path_public.should eq(left)
      app.split_active_public.should be_false
      app.buffer_editor_public(right).same?(right_editor).should be_true
      app.buffer_text_public(right).should eq("unsaved RIGHT_DIRTY_BASE\n")
      app.buffer_watch_token_public(right).should eq(watch_token)
      right_editor.can_undo?.should be_true
      right_editor.undo.should be_true
      app.buffer_text_public(right).should eq("RIGHT_DIRTY_BASE\n")
      right_editor.redo.should be_true
      app.buffer_text_public(right).should eq("unsaved RIGHT_DIRTY_BASE\n")
      app.tab_paths_public.sort.should eq([left.to_s, right.to_s].sort)

      # Repeat collapse with the right group active. Its selected buffer, live
      # editor/history object, and file watch must survive the transfer too.
      app.run_command_public("splitright")
      app.open_file_public(right2).should be_true
      app.buffer_editor_public(right2).insert_text("RIGHT_TWO_UNSAVED ")
      right2_editor = app.buffer_editor_public(right2)
      right2_watch_token = app.buffer_watch_token_public(right2).not_nil!
      app.render_text_public
      app.group_tab_paths_public.should eq([[left.to_s, right.to_s], [right2.to_s]])
      app.active_group_public.should eq(1)
      app.active_path_public.should eq(right2)

      app.run_command_public("closesplit")
      app.split_active_public.should be_false
      app.active_group_public.should eq(0)
      app.active_path_public.should eq(right2)
      app.buffer_count_public.should eq(3)
      app.buffer_editor_public(right2).same?(right2_editor).should be_true
      app.buffer_watch_token_public(right2).should eq(right2_watch_token)
      app.buffer_text_public(right2).should eq("RIGHT_TWO_UNSAVED RIGHT_TWO_BASE\n")
      right2_editor.can_undo?.should be_true
      right2_editor.undo.should be_true
      app.buffer_text_public(right2).should eq("RIGHT_TWO_BASE\n")
      right2_editor.redo.should be_true
      app.buffer_text_public(right2).should eq("RIGHT_TWO_UNSAVED RIGHT_TWO_BASE\n")
      app.tab_paths_public.sort.should eq([left.to_s, right.to_s, right2.to_s].sort)
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "restores flat v1 session tabs from both groups into one group" do
    with_editor_split_workspace do |root|
      state = root / "state"
      project = root / "project"
      Dir.mkdir_p(project)
      left = project / "left.cr"
      right = project / "right.cr"
      right2 = project / "right2.cr"
      File.write(left, "left\n")
      File.write(right, "right\n")
      File.write(right2, "RIGHT_RESTORED_MARKER\n")
      first = EditorSplitSpecApp.new(project, lsp_command: "", session_root: state, session_enabled: true)
      first.activate_session_public.should be_true
      first.open_file_public(left).should be_true
      first.render_text_public
      first.run_command_public("splitright")
      first.active_group_public.should eq(1)
      first.open_file_public(right).should be_true
      first.render_text_public
      first.render_text_public.should contain("[Pane 2]")
      first.open_file_public(right2).should be_true
      first.group_tab_paths_public.should eq([[left.to_s], [right.to_s, right2.to_s]])
      first.active_path_public.should eq(right2)

      # Tab navigation must stay within the active right-side group.
      first.run_command_public("tabprev")
      first.active_path_public.should eq(right)
      first.run_command_public("tabnext")
      first.active_path_public.should eq(right2)

      # Switch away and back, then save: the active right-side buffer remains
      # the target for navigation, file writes, and the session snapshot.
      first.buffer_editor_public(right2).insert_text("SAVED_RIGHT_2 ")
      first.run_command_public("focusnextgroup")
      first.active_group_public.should eq(0)
      first.run_command_public("focusnextgroup")
      first.active_group_public.should eq(1)
      first.active_path_public.should eq(right2)
      first.run_command_public("w")
      File.read(right2).should eq("SAVED_RIGHT_2 RIGHT_RESTORED_MARKER\n")
      first.render_text_public

      left_rect = first.buffer_editor_public(left).rect
      right_rect = first.buffer_editor_public(right2).rect
      left_rect.width.should be > 0
      right_rect.width.should be > 0
      left_rect.x.should be < right_rect.x
      split_editor_width = right_rect.width
      first.save_session_public.should be_true
      store = Adamantine::SessionStore.new(state, enabled: true)
      JSON.parse(File.read(store.state_path(project)))["version"].as_i.should eq(Adamantine::SessionStore::VERSION)
      persisted = store.load(project).state.not_nil!
      persisted.tabs.map(&.path.to_s).sort.should eq([left.to_s, right.to_s, right2.to_s].sort)
      persisted.active_tab.should eq(2)
      first.quit(force: true)

      second = EditorSplitSpecApp.new(project, lsp_command: "", session_root: state, session_enabled: true)
      second.activate_session_public.should be_true
      second.buffer_paths_public.should eq([left.to_s, right.to_s, right2.to_s].sort)
      second.active_path_public.should eq(right2)
      second.render_text_public.should contain("SAVED_RIGHT_2 RIGHT_RESTORED_MARKER")
      second.buffer_editor_public(right2).rect.width.should be > split_editor_width
      second.split_active_public.should be_false
      second.active_group_public.should eq(0)
    ensure
      first.try(&.quit(force: true))
      second.try(&.quit(force: true))
    end
  end
end
