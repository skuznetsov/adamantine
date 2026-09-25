require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private class SameFileViewsLspProbe < Adamantine::Lsp::Client
  getter opened = [] of Tuple(String, String, Int32)
  getter changes = [] of Tuple(String, Int32)
  getter saved = [] of String
  getter closed = [] of String

  def initialize(root : Path)
    super("same-file-views-probe", root)
  end

  def start : Bool
    self.connected = true
    true
  end

  def stop : Nil
    self.connected = false
  end

  def semantic_tokens_supported? : Bool
    false
  end

  def folding_ranges_supported? : Bool
    false
  end

  def open_text_document(uri : String, language_id : String, version : Int32, text : String) : Nil
    @opened << {uri, text, version}
  end

  def text_change(uri : String, version : Int32, text : String) : Nil
    @changes << {uri, version}
  end

  def text_change(uri : String, version : Int32, range : Adamantine::Lsp::Range, text : String) : Nil
    @changes << {uri, version}
  end

  def close_text_document(uri : String) : Nil
    @closed << uri
  end

  def save_text_document(uri : String) : Nil
    @saved << uri
  end
end

private class SameFileViewsIntegrationSpecApp < Adamantine::App
  @pending_lsp_clients = [] of SameFileViewsLspProbe
  getter lexical_closed_views = [] of Tui::TextEditor
  getter lexical_close_counts = [] of Int32
  getter search_closed_paths = [] of String
  getter problem_closed_paths = [] of String

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def run_command_public(command : String) : Bool
    @command_palette.open = true
    execute_command(":#{command}")
    !@command_palette.open
  end

  def change_setting_public(action : String) : Nil
    open_settings_dialog
    index = @settings.actions.index(action) || raise "missing settings row: #{action}"
    set_settings_selection(index)
    raise "setting not handled: #{action}" unless execute_selected_settings_action
    close_settings_dialog
  end

  def reapply_theme_public : Nil
    apply_theme
  end

  def open_buffer_count_public : Int32
    @document_session.open_buffers.size
  end

  def group_tab_paths_public : Array(Array(String))
    editor_tab_groups.map { |panel| panel.tabs.map(&.id) }
  end

  def active_group_public : Int32
    @active_editor_group
  end

  def group_view_widgets_public : Array(Tui::TextEditor)
    editor_tab_groups.flat_map do |panel|
      panel.tabs.compact_map { |tab| tab.content.as?(Tui::TextEditor) }
    end
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

  def buffer_editor_public(path : Path) : Tui::TextEditor
    @document_session.open_buffers[path.to_s]?.try(&.editor) || raise "missing buffer #{path}"
  end

  def current_editor_public : Tui::TextEditor
    current_editor.not_nil!
  end

  def active_path_public : String?
    @editor_tabs.active_tab_id
  end

  def close_buffer_direct_public(path : Path) : Nil
    @document_orchestrator.close_tab(path.to_s)
  end

  def buffer_document_public(path : Path) : Tui::TextEditor::Document
    @document_session.open_buffers[path.to_s].not_nil!.editor.document
  end

  def buffer_version_public(path : Path) : Int32
    @document_session.open_buffers[path.to_s]?.try(&.version) || raise "missing buffer #{path}"
  end

  def set_diagnostics_public(path : Path, diagnostics : Array(Adamantine::Lsp::Diagnostic)) : Nil
    buffer = @document_session.open_buffers[path.to_s].not_nil!
    buffer.diagnostics = diagnostics
    buffer.diagnostics_generation &+= 1_u64
  end

  def open_problems_public : Nil
    open_problems
  end

  def select_problem_public(index : Int32) : Nil
    @problems.selected = index
  end

  def problems_open_public? : Bool
    @problems.open
  end

  def request_lexical_token_public(path : Path, editor : Tui::TextEditor) : String?
    buffer = @document_session.open_buffers[path.to_s].not_nil!
    lexical_token_at(buffer, editor.as(Adamantine::EditingTextEditor), 0, 0)
  end

  def lexical_secondary_view_count_public : Int32
    @lexical_secondary_views.size
  end

  def lexical_secondary_has_view_public?(editor : Tui::TextEditor) : Bool
    @lexical_secondary_views.any? { |view| view.editor.same?(editor) }
  end

  def buffer_watch_token_public(path : Path) : Adamantine::ExternalFileMonitor::WatchToken?
    @document_session.open_buffers[path.to_s]?.try(&.watch_token)
  end

  def close_group_tab_public(group : Int32, path : Path) : Bool
    editor_group_panel(group).close_tab(path.to_s)
  end

  def close_confirmation_active_public : Bool
    close_confirmation_active?
  end

  def template_session_active_public? : Bool
    @template_session.try(&.active?) || false
  end

  def template_session_editor_public : Tui::TextEditor?
    @template_session.try(&.editor)
  end

  def activate_session_public : Bool
    start_session_lifecycle
  end

  def save_session_public : Bool
    save_session_state
  end

  def connect_lsp_public(client : SameFileViewsLspProbe) : Nil
    @pending_lsp_clients << client
    connect_lsp_if_requested("same-file-views-probe", [] of String)
  end

  protected def new_lsp_client(command : String, root : Path, args : Array(String)) : Adamantine::Lsp::Client
    @pending_lsp_clients.shift
  end

  private def lexical_view_closed(buffer : Adamantine::OpenBuffer, editor : Tui::TextEditor) : Nil
    @lexical_closed_views << editor
    super
    @lexical_close_counts << @lexical_secondary_views.size
  end

  private def search_tab_closed(path : String) : Nil
    @search_closed_paths << path
    super
  end

  private def close_problems_for_buffer(buffer : Adamantine::OpenBuffer) : Nil
    @problem_closed_paths << buffer.path.to_s
    super
  end
end

private def with_same_file_views_workspace(&)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-same-file-views-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

describe "same-file split views" do
  it "opens the existing document in the right group as a distinct view" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "SHARED_DOCUMENT\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      app.run_command_public("splitright").should be_true
      app.active_group_public.should eq(1)

      app.open_file_public(path).should be_true
      {
        open_buffers: app.open_buffer_count_public,
        group_tabs:   app.group_tab_paths_public,
        active_group: app.active_group_public,
      }.should eq({
        open_buffers: 1,
        group_tabs:   [[path.to_s], [path.to_s]],
        active_group: 1,
      })

      views = app.group_view_widgets_public
      views.size.should eq(2)
      views[0].same?(views[1]).should be_false
      views[0].document.same?(views[1].document).should be_true

      original_text = "SHARED_DOCUMENT\n"
      version = app.buffer_version_public(path)
      watch_token = app.buffer_watch_token_public(path).not_nil!
      views[0].set_cursor(0, 2)
      views[1].set_cursor(0, 6)
      views[1].insert_text("!")
      views[0].text.should eq("SHARED!_DOCUMENT\n")
      views[1].text.should eq("SHARED!_DOCUMENT\n")
      app.buffer_version_public(path).should eq(version + 1)
      {views[0].cursor_line, views[0].cursor_col}.should eq({0, 2})
      {views[1].cursor_line, views[1].cursor_col}.should eq({0, 7})

      views[0].undo.should be_true
      views[1].text.should eq(original_text)
      views[1].redo.should be_true
      views[0].text.should eq("SHARED!_DOCUMENT\n")

      # Closing the original view must retain the single dirty document and
      # its watch, and promote the surviving widget as the live buffer anchor.
      app.close_group_tab_public(0, path).should be_true
      app.group_tab_paths_public.should eq([[] of String, [path.to_s]])
      app.open_buffer_count_public.should eq(1)
      app.buffer_editor_public(path).same?(views[1]).should be_true
      app.buffer_watch_token_public(path).should eq(watch_token)
      app.buffer_version_public(path).should eq(version + 3)
      app.close_confirmation_active_public.should be_false

      # The final view remains subject to the existing dirty-close safeguard.
      app.close_group_tab_public(1, path).should be_false
      app.close_confirmation_active_public.should be_true
      app.open_buffer_count_public.should eq(1)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "invalidates git gutter markers in both views after a shared edit" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "module Shared\nend\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      views = app.group_view_widgets_public.map(&.as(Adamantine::EditingTextEditor))
      views[0].line_change_markers = {0 => '+'}
      views[1].line_change_markers = {0 => '+'}

      views[1].insert_text("!")
      views[0].line_change_markers.should be_empty
      views[1].line_change_markers.should be_empty
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "collapses duplicate paths to the active pane's view without retiring the document" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "SHARED_DOCUMENT\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      left_view = app.group_view_widgets_public.first
      watch_token = app.buffer_watch_token_public(path).not_nil!
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      right_view = app.group_view_widgets_public.last
      right_view.same?(left_view).should be_false
      app.active_group_public.should eq(1)
      app.request_lexical_token_public(path, right_view)
      app.lexical_secondary_view_count_public.should eq(1)

      app.run_command_public("closesplit").should be_true
      app.group_tab_paths_public.should eq([[path.to_s]])
      app.group_view_widgets_public.size.should eq(1)
      app.buffer_editor_public(path).same?(right_view).should be_true
      app.lexical_secondary_view_count_public.should eq(0)
      app.buffer_watch_token_public(path).should eq(watch_token)
      app.open_buffer_count_public.should eq(1)

      # A left-active collapse instead keeps its own widget and unregisters
      # the right duplicate, while retaining the same shared document.
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      app.run_command_public("focusnextgroup").should be_true
      app.active_group_public.should eq(0)
      left_survivor = app.group_view_widgets_public.first
      app.run_command_public("closesplit").should be_true
      app.group_tab_paths_public.should eq([[path.to_s]])
      app.group_view_widgets_public.size.should eq(1)
      app.buffer_editor_public(path).same?(left_survivor).should be_true
      app.buffer_watch_token_public(path).should eq(watch_token)
      app.open_buffer_count_public.should eq(1)
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "clears the promoted view's secondary lexical cache when its peer closes" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "module Shared\nend\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      original_view = app.group_view_widgets_public.first
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      promoted_view = app.group_view_widgets_public.last
      app.buffer_editor_public(path).same?(original_view).should be_true

      app.request_lexical_token_public(path, promoted_view)
      app.lexical_secondary_view_count_public.should eq(1)
      app.lexical_secondary_has_view_public?(promoted_view).should be_true

      app.close_group_tab_public(0, path).should be_true
      app.buffer_editor_public(path).same?(promoted_view).should be_true
      app.lexical_secondary_view_count_public.should eq(0)
      app.lexical_closed_views.size.should eq(2)
      app.lexical_closed_views[0].same?(original_view).should be_true
      app.lexical_closed_views[1].same?(promoted_view).should be_true
      app.lexical_close_counts.should eq([1, 0])
      original_view.same?(promoted_view).should be_false
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "preserves the active tab when a lower-level close removes an earlier tab" do
    with_same_file_views_workspace do |root|
      paths = %w[a.cr b.cr c.cr d.cr].map do |name|
        path = root / name
        File.write(path, "module #{name.split('.').first}\nend\n")
        path
      end
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      paths.each { |path| app.open_file_public(path).should be_true }
      app.open_file_public(paths[2]).should be_true
      app.active_path_public.should eq(paths[2].to_s)

      app.close_buffer_direct_public(paths[0])

      app.group_tab_paths_public.first.should eq(paths[1..].map(&.to_s))
      app.active_path_public.should eq(paths[2].to_s)
      app.buffer_editor_public(paths[2]).same?(app.current_editor_public).should be_true
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "retains document-scoped search and Problems state until the final view closes" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "SHARED_DOCUMENT\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true

      app.close_group_tab_public(0, path).should be_true
      app.search_closed_paths.should be_empty
      app.problem_closed_paths.should be_empty
      app.open_buffer_count_public.should eq(1)

      app.close_group_tab_public(1, path).should be_true
      app.search_closed_paths.should eq([path.to_s])
      app.problem_closed_paths.should eq([path.to_s])
      app.open_buffer_count_public.should eq(0)
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "cancels a template session when its owning view closes" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      app.run_command_public("template def").should be_true
      app.template_session_active_public?.should be_true
      template_view = app.template_session_editor_public.not_nil!

      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      app.close_group_tab_public(0, path).should be_true

      app.template_session_active_public?.should be_false
      app.template_session_editor_public.should be_nil
      app.buffer_editor_public(path).same?(template_view).should be_false
      app.open_buffer_count_public.should eq(1)
      app.buffer_editor_public(path).text.should start_with("def name(args)")
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "cancels a template session when split collapse discards its owning view" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      app.run_command_public("template def").should be_true
      app.template_session_active_public?.should be_true
      template_view = app.template_session_editor_public.not_nil!

      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      app.run_command_public("closesplit").should be_true

      app.template_session_active_public?.should be_false
      app.template_session_editor_public.should be_nil
      app.buffer_editor_public(path).same?(template_view).should be_false
      app.open_buffer_count_public.should eq(1)
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "inserts a template into the active secondary view" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      left_view = app.group_view_widgets_public.first
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      right_view = app.group_view_widgets_public.last
      right_view.set_cursor(0, 0)
      app.active_group_public.should eq(1)

      app.run_command_public("template def").should be_true

      app.buffer_editor_public(path).text.should start_with("def name(args)")
      app.template_session_active_public?.should be_true
      app.template_session_editor_public.same?(right_view).should be_true
      app.current_editor_public.same?(right_view).should be_true
      left_view.same?(right_view).should be_false
      {left_view.cursor_line, left_view.cursor_col}.should_not eq({right_view.cursor_line, right_view.cursor_col})
      {right_view.cursor_line, right_view.cursor_col}.should eq({0, 8})
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "fans out editing settings and theme changes to every view" do
    with_same_file_views_workspace do |root|
      Adamantine::Theme.load("vscode-dark")
      path = root / "shared.cr"
      File.write(path, "SHARED_DOCUMENT\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      views = app.group_view_widgets_public.map(&.as(Adamantine::EditingTextEditor))
      views.map(&.tab_size).should eq([2, 2])
      views.map(&.auto_indent).should eq([true, true])
      original_text_color = views.map(&.text_fg).first

      app.change_setting_public("setting:editor.indent_width")
      app.change_setting_public("setting:editor.auto_indent")
      views.map(&.tab_size).should eq([3, 3])
      views.map(&.auto_indent).should eq([false, false])

      Adamantine::Theme.load("vscode-light").should be_true
      app.reapply_theme_public
      expected_text_color = Adamantine::Theme::Editor.text_fg
      expected_text_color.should_not eq(original_text_color)
      views.each { |view| view.text_fg.should eq(expected_text_color) }
    ensure
      app.try(&.quit(force: true))
      Adamantine::Theme.load("vscode-dark")
    end
  end

  it "runs :r against the active secondary view without moving the peer cursor" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "old old\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      left_view = app.group_view_widgets_public.first
      left_view.set_cursor(0, 1)
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      right_view = app.group_view_widgets_public.last
      right_view.set_cursor(0, 5)
      app.active_group_public.should eq(1)

      app.run_command_public("r /old/new/g").should be_true

      {left_view.text, right_view.text}.should eq({"new new\n", "new new\n"})
      app.current_editor_public.same?(right_view).should be_true
      app.active_group_public.should eq(1)
      {left_view.cursor_line, left_view.cursor_col}.should eq({0, 1})
      {right_view.cursor_line, right_view.cursor_col}.should eq({0, 5})
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "sends one LSP lifecycle for shared views and only closes after the final view" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "SHARED_DOCUMENT\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)
      client = SameFileViewsLspProbe.new(root)
      app.connect_lsp_public(client)

      app.open_file_public(path).should be_true
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      client.opened.size.should eq(1)

      view = app.group_view_widgets_public.last
      view.set_cursor(0, 4)
      view.insert_text("!")
      view.undo.should be_true
      view.redo.should be_true
      client.changes.map(&.[1]).should eq([2, 3, 4])

      app.close_group_tab_public(0, path).should be_true
      client.closed.should be_empty
      app.open_buffer_count_public.should eq(1)

      app.run_command_public("w").should be_true
      client.saved.should eq([client.opened.first[0]])
      app.close_group_tab_public(1, path).should be_true
      client.closed.should eq([client.opened.first[0]])
      app.open_buffer_count_public.should eq(0)
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "ignores old document publishers after final close and reopen at the same path" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "SHARED_DOCUMENT\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)
      client = SameFileViewsLspProbe.new(root)
      app.connect_lsp_public(client)

      app.open_file_public(path).should be_true
      old_document = app.buffer_document_public(path)
      old_version = app.buffer_version_public(path)

      # Positive controls: the old document's publishers are live while its
      # buffer is registered, so later silence is meaningful.
      old_document.publish_text_change(Tui::TextEditor::TextChange.full, 0_u64)
      app.buffer_version_public(path).should eq(old_version + 1)
      client.changes.map(&.[1]).should eq([old_version + 1])
      old_document.publish_save(path)
      client.saved.should eq([client.opened.first[0]])

      app.close_group_tab_public(0, path).should be_true
      app.open_buffer_count_public.should eq(0)
      client.closed.should eq([client.opened.first[0]])

      app.open_file_public(path).should be_true
      app.open_buffer_count_public.should eq(1)
      client.opened.size.should eq(2)
      new_version = app.buffer_version_public(path)
      change_count = client.changes.size
      save_count = client.saved.size

      old_document.publish_text_change(Tui::TextEditor::TextChange.full, 0_u64)
      old_document.publish_save(path)

      app.buffer_version_public(path).should eq(new_version)
      client.changes.size.should eq(change_count)
      client.saved.size.should eq(save_count)
      client.closed.should eq([client.opened.first[0]])
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "navigates an open-file Problems row in the active secondary view" do
    with_same_file_views_workspace do |root|
      path = root / "shared.cr"
      File.write(path, "line0\nline1\n")
      app = SameFileViewsIntegrationSpecApp.new(root, lsp_command: "", session_enabled: false)

      app.open_file_public(path).should be_true
      left_view = app.group_view_widgets_public.first
      left_view.set_cursor(0, 2)
      app.run_command_public("splitright").should be_true
      app.open_file_public(path).should be_true
      right_view = app.group_view_widgets_public.last
      right_view.set_cursor(0, 0)
      app.active_group_public.should eq(1)

      diagnostic = Adamantine::Lsp::Diagnostic.new(1, 2, "secondary target", "test", 1, 1, 3)
      app.set_diagnostics_public(path, [diagnostic])
      app.open_problems_public
      app.problems_open_public?.should be_true
      app.select_problem_public(0)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))

      app.problems_open_public?.should be_false
      app.current_editor_public.same?(right_view).should be_true
      {right_view.cursor_line, right_view.cursor_col}.should eq({1, 2})
      {left_view.cursor_line, left_view.cursor_col}.should eq({0, 2})
      app.active_group_public.should eq(1)
    ensure
      app.try(&.quit(force: true))
    end
  end

  it "round-trips independent cursor and viewport state for duplicate paths" do
    with_same_file_views_workspace do |root|
      state_root = root / "state"
      project = root / "project"
      Dir.mkdir_p(project)
      path = project / "shared.cr"
      File.write(path, "line0\nline1\nline2\nline3\nline4\nline5\n")
      first = SameFileViewsIntegrationSpecApp.new(project, lsp_command: "", session_root: state_root, session_enabled: true)
      first.activate_session_public.should be_true
      first.open_file_public(path).should be_true
      first.run_command_public("splitright").should be_true
      first.open_file_public(path).should be_true

      views = first.group_view_widgets_public
      views.size.should eq(2)
      views[0].set_cursor(0, 2)
      views[1].set_cursor(4, 3)
      left_editor = views[0].as(Adamantine::EditingTextEditor)
      right_editor = views[1].as(Adamantine::EditingTextEditor)
      left_editor.restore_session_view(1, 0)
      right_editor.restore_session_view(3, 1)
      first.save_session_public.should be_true

      store = Adamantine::SessionStore.new(state_root, enabled: true)
      persisted = store.load(project).state.not_nil!
      persisted.tabs.map(&.path.to_s).should eq([path.to_s, path.to_s])
      persisted.tab_groups.should eq([0, 1])
      persisted.tabs.map { |tab| {tab.cursor.line, tab.cursor.column} }.should eq([{0, 2}, {4, 3}])
      persisted.tabs.map { |tab| {tab.scroll.line, tab.scroll.column} }.should eq([{1, 0}, {3, 1}])
      first.quit(force: true)

      second = SameFileViewsIntegrationSpecApp.new(project, lsp_command: "", session_root: state_root, session_enabled: true)
      second.render_text_public(100, 32)
      second.activate_session_public.should be_true
      second.group_tab_paths_public.should eq([[path.to_s], [path.to_s]])
      restored = second.group_view_widgets_public
      restored.size.should eq(2)
      restored[0].same?(restored[1]).should be_false
      restored[0].document.same?(restored[1].document).should be_true
      {restored[0].cursor_line, restored[0].cursor_col}.should eq({0, 2})
      {restored[1].cursor_line, restored[1].cursor_col}.should eq({4, 3})
      restored_left = restored[0].as(Adamantine::EditingTextEditor)
      restored_right = restored[1].as(Adamantine::EditingTextEditor)
      {restored_left.session_scroll_y, restored_left.session_scroll_x}.should eq({1, 0})
      {restored_right.session_scroll_y, restored_right.session_scroll_x}.should eq({3, 1})
    ensure
      first.try(&.quit(force: true))
      second.try(&.quit(force: true))
    end
  end
end
