require "spec"
require "file_utils"
require "json"
require "crystal_tui"
require "../src/adamantine/app"

private class EditorToolsAppSpecApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def buffer_public(path : Path) : Adamantine::OpenBuffer
    @document_session.open_buffers[path.to_s]? || raise "missing open buffer: #{path}"
  end

  def buffer_paths_public : Array(String)
    @document_session.open_buffers.keys.sort
  end

  def active_path_public : String?
    current_buffer.try(&.path.to_s)
  end

  def tab_paths_public : Array(Array(String))
    editor_tab_groups.map { |panel| panel.tabs.map(&.id) }
  end

  def open_buffer_count_public : Int32
    @document_session.open_buffers.size
  end

  def active_group_public : Int32
    @active_editor_group
  end

  def split_right_public : Bool
    split_editor_right
  end

  def activate_group_public(index : Int32) : Nil
    activate_editor_group_internal(editor_tab_groups[index])
  end

  def close_active_view_public : Bool
    active_editor_tabs.close_active_tab
  end

  def editor_tool_reference_count_public : Int32
    @editor_tools_buffer_refs.size
  end

  def open_settings_public : Nil
    open_settings_dialog
  end

  def close_settings_public : Nil
    close_settings_dialog
  end

  def input_mode_public : String
    active_input_mode.to_s
  end

  def set_buffer_version_public(path : Path, version : Int32) : Nil
    buffer_public(path).version = version
  end

  def insert_piece_tree_public(path : Path, offset : Int32, text : String) : Nil
    buffer_public(path).editor.document.buffer.insert(offset, text)
  end

  def set_line_ending_public(path : Path, line_ending : String) : Nil
    buffer_public(path).editor.line_ending = line_ending
  end

  def bind_debug_project_public(path : Path) : Bool
    @debug_controller.bind_project(path, @debug_project_generation)
  end
end

private def with_editor_tools_app(&)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-editor-tools-app-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  app = EditorToolsAppSpecApp.new(
    project_root: root,
    lsp_command: "",
    session_enabled: false,
    recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new
  )
  yield app, root
ensure
  app.try &.quit(force: true)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

private def editor_tools_args(values : Hash(String, T)) : Hash(String, JSON::Any) forall T
  values.transform_values { |value| JSON::Any.new(value) }
end

private def editor_tools_call(session : Adamantine::EditorTools::Session,
                              id : String, name : String,
                              arguments : Hash(String, JSON::Any) = {} of String => JSON::Any) : Adamantine::EditorTools::Result
  session.invoke_json({"id" => id, "name" => name, "arguments" => arguments}.to_json)
end

private def editor_tools_data(result : Adamantine::EditorTools::Result) : Hash(String, JSON::Any)
  result.data.try(&.as_h) || raise "tool result did not include data: #{result.to_json}"
end

private def editor_tools_list(session : Adamantine::EditorTools::Session,
                              id : String = "list") : Array(JSON::Any)
  result = editor_tools_call(session, id, "editor.list_buffers")
  result.ok?.should be_true
  editor_tools_data(result)["buffers"].as_a
end

describe "App editor tool sessions" do
  it "issues typed read tools and exposes no navigation grant by default" do
    with_editor_tools_app do |app, _root|
      session = app.open_tool_session
      names = session.definitions.map(&.name)
      names.should contain("editor.list_buffers")
      names.should contain("editor.read_buffer")
      names.should_not contain("editor.open_file")
      names.should_not contain("editor.focus_buffer")
    end
  end

  it "reads unsaved PieceTree content without focusing or altering the live buffer" do
    with_editor_tools_app do |app, root|
      first = root / "first.cr"
      second = root / "second.cr"
      File.write(first, "disk-first\n")
      File.write(second, "disk-second\n")
      app.open_file_public(first).should be_true
      app.open_file_public(second).should be_true
      first_buffer = app.buffer_public(first)
      first_buffer.editor.insert_text("unsaved-")
      first_buffer.version = Int32::MAX
      active_before = app.active_path_public
      file_before = File.read(first)
      modified_before = first_buffer.editor.modified?

      session = app.open_tool_session(capabilities: [Adamantine::EditorTools::Capability::ReadEditor])
      item = editor_tools_list(session).find { |row| row.as_h["path"].as_s == "first.cr" }.not_nil!.as_h
      result = editor_tools_call(session, "read-first", "editor.read_buffer",
        editor_tools_args({
          "buffer_id"    => item["buffer_id"].as_s,
          "revision"     => item["revision"].as_s,
          "start_line"   => 1,
          "line_count"   => 4,
          "start_column" => 0,
          "max_columns"  => 512,
        }))
      result.ok?.should be_true
      lines = editor_tools_data(result)["lines"].as_a
      lines.first.as_h["text"].as_s.should eq("unsaved-disk-first")
      app.active_path_public.should eq(active_before)
      File.read(first).should eq(file_before)
      first_buffer.editor.modified?.should eq(modified_before)
      first_buffer.version.should eq(Int32::MAX)
    end
  end

  it "invalidates an opaque buffer revision when PieceTree state changes at a fixed saturated version" do
    with_editor_tools_app do |app, root|
      path = root / "saturated.cr"
      File.write(path, "before\n")
      app.open_file_public(path).should be_true
      app.set_buffer_version_public(path, Int32::MAX)
      session = app.open_tool_session(capabilities: [Adamantine::EditorTools::Capability::ReadEditor])
      item = editor_tools_list(session).first.as_h
      app.insert_piece_tree_public(path, 0, "after-")
      app.set_buffer_version_public(path, Int32::MAX)

      result = editor_tools_call(session, "stale-read", "editor.read_buffer",
        editor_tools_args({"buffer_id" => item["buffer_id"].as_s, "revision" => item["revision"].as_s}))
      result.ok?.should be_false
      result.status.should eq(Adamantine::EditorTools::Status::Stale)
    end
  end

  it "invalidates an opaque buffer revision when only the document line ending changes" do
    with_editor_tools_app do |app, root|
      path = root / "line-ending.cr"
      File.write(path, "first\nsecond\n")
      app.open_file_public(path).should be_true
      session = app.open_tool_session(capabilities: [Adamantine::EditorTools::Capability::ReadEditor])
      item = editor_tools_list(session).first.as_h
      app.set_line_ending_public(path, "\r\n")

      result = editor_tools_call(session, "stale-eol", "editor.read_buffer",
        editor_tools_args({"buffer_id" => item["buffer_id"].as_s, "revision" => item["revision"].as_s}))
      result.ok?.should be_false
      result.status.should eq(Adamantine::EditorTools::Status::Stale)
    end
  end

  it "returns a bounded Unicode line fragment with an explicit continuation" do
    with_editor_tools_app do |app, root|
      path = root / "long-unicode.cr"
      File.write(path, "λ" * 500_000)
      app.open_file_public(path).should be_true
      session = app.open_tool_session(capabilities: [Adamantine::EditorTools::Capability::ReadEditor])
      item = editor_tools_list(session).first.as_h

      result = editor_tools_call(session, "read-unicode-fragment", "editor.read_buffer",
        editor_tools_args({
          "buffer_id"    => item["buffer_id"].as_s,
          "revision"     => item["revision"].as_s,
          "start_line"   => 1,
          "line_count"   => 1,
          "start_column" => 0,
          "max_columns"  => 1024,
        }))
      result.ok?.should be_true
      data = editor_tools_data(result)
      row = data["lines"].as_a.first.as_h
      row["text"].as_s.size.should eq(1024)
      row["text"].as_s.bytesize.should eq(2048)
      row["complete"].as_bool.should be_false
      data["partial"].as_bool.should be_true
      continuation = data["continuation"].as_h
      continuation["start_line"].as_i.should eq(1)
      continuation["start_column"].as_i.should eq(1024)
      result.to_json.bytesize.should be < 8 * 1024
    end
  end

  it "opens an exact in-project file and reuses its unsaved live document" do
    with_editor_tools_app do |app, root|
      path = root / "tool-open.cr"
      File.write(path, "disk contents\n")
      session = app.open_tool_session(capabilities: [
        Adamantine::EditorTools::Capability::ReadEditor,
        Adamantine::EditorTools::Capability::Navigate,
      ])

      opened = editor_tools_call(session, "open-once", "editor.open_file",
        editor_tools_args({"path" => "tool-open.cr"}))
      opened.ok?.should be_true
      editor_tools_data(opened)["opened"].as_bool.should be_true
      editor_tools_data(opened)["path"].as_s.should eq("tool-open.cr")
      app.open_buffer_count_public.should eq(1)

      app.buffer_public(path).editor.insert_text("unsaved-")
      reopened = editor_tools_call(session, "open-existing", "editor.open_file",
        editor_tools_args({"path" => "tool-open.cr"}))
      raise "reopen result: #{reopened.to_json}" unless reopened.ok?
      app.open_buffer_count_public.should eq(1)
      app.tab_paths_public.should eq([[path.to_s]])
      File.read(path).should eq("disk contents\n")

      item = editor_tools_list(session, "list-after-open").first.as_h
      read = editor_tools_call(session, "read-after-open", "editor.read_buffer",
        editor_tools_args({"buffer_id" => item["buffer_id"].as_s, "revision" => item["revision"].as_s}))
      read.ok?.should be_true
      editor_tools_data(read)["lines"].as_a.first.as_h["text"].as_s.should eq("unsaved-disk contents")
    end
  end

  it "does not commit binary, invalid UTF-8, or oversized file opens" do
    with_editor_tools_app do |app, root|
      binary = root / "binary.cr"
      invalid_utf8 = root / "invalid-utf8.cr"
      oversized = root / "oversized.cr"
      File.write(binary, "contains\0nul")
      File.write(invalid_utf8, String.new(Bytes[0xff_u8, 0xfe_u8]))
      File.write(oversized, "x" * (Adamantine::DocumentOrchestrator::MAX_FILE_BYTES + 1))
      session = app.open_tool_session(capabilities: [Adamantine::EditorTools::Capability::Navigate])

      {"binary.cr", "invalid-utf8.cr", "oversized.cr"}.each_with_index do |path, index|
        result = editor_tools_call(session, "reject-open-#{index}", "editor.open_file",
          editor_tools_args({"path" => path}))
        result.ok?.should be_false
        result.status.should eq(Adamantine::EditorTools::Status::Unavailable)
        app.buffer_paths_public.should be_empty
        app.tab_paths_public.should eq([[] of String])
      end
    end
  end

  it "does not revive a buffer token after closing and reopening the same path" do
    with_editor_tools_app do |app, root|
      path = root / "reopened.cr"
      File.write(path, "same file\n")
      app.open_file_public(path).should be_true
      session = app.open_tool_session(capabilities: [Adamantine::EditorTools::Capability::ReadEditor])
      old_item = editor_tools_list(session).first.as_h

      app.close_active_view_public.should be_true
      app.open_file_public(path).should be_true
      new_item = editor_tools_list(session, "list-reopened").first.as_h
      new_item["buffer_id"].as_s.should_not eq(old_item["buffer_id"].as_s)

      result = editor_tools_call(session, "read-old-token", "editor.read_buffer",
        editor_tools_args({"buffer_id" => old_item["buffer_id"].as_s, "revision" => old_item["revision"].as_s}))
      result.ok?.should be_false
      result.status.should eq(Adamantine::EditorTools::Status::NotFound)
    end
  end

  it "blocks navigation while a settings modal is active" do
    with_editor_tools_app do |app, root|
      path = root / "existing.cr"
      File.write(path, "existing\n")
      app.open_file_public(path).should be_true
      session = app.open_tool_session(capabilities: [
        Adamantine::EditorTools::Capability::ReadEditor,
        Adamantine::EditorTools::Capability::Navigate,
      ])
      item = editor_tools_list(session).first.as_h
      app.open_settings_public
      app.input_mode_public.should eq("Settings")

      result = editor_tools_call(session, "focus-modal", "editor.focus_buffer",
        editor_tools_args({"buffer_id" => item["buffer_id"].as_s, "revision" => item["revision"].as_s}))
      result.ok?.should be_false
      result.status.should eq(Adamantine::EditorTools::Status::Busy)
      app.close_settings_public
      app.input_mode_public.should eq("Normal")
    end
  end

  it "reports the actual active buffer in the current group and focuses existing views only" do
    with_editor_tools_app do |app, root|
      left_only = root / "left-only.cr"
      shared = root / "shared.cr"
      right_active = root / "right-active.cr"
      [left_only, shared, right_active].each { |path| File.write(path, "#{path.basename}\n") }
      app.open_file_public(left_only).should be_true
      app.split_right_public.should be_true
      app.open_file_public(shared).should be_true
      app.activate_group_public(0)
      app.open_file_public(shared).should be_true
      app.activate_group_public(1)
      app.open_file_public(right_active).should be_true

      session = app.open_tool_session(capabilities: [
        Adamantine::EditorTools::Capability::ReadEditor,
        Adamantine::EditorTools::Capability::Navigate,
      ])
      rows = editor_tools_list(session, "list-current")
      shared_row = rows.find { |row| row.as_h["path"].as_s == "shared.cr" }.not_nil!.as_h
      shared_row["group_indices"].as_a.map(&.as_i).should eq([1, 2])
      shared_row["active_group"].raw.should be_nil

      left_row = rows.find { |row| row.as_h["path"].as_s == "left-only.cr" }.not_nil!.as_h
      focus = editor_tools_call(session, "focus-left", "editor.focus_buffer",
        editor_tools_args({"buffer_id" => left_row["buffer_id"].as_s, "revision" => left_row["revision"].as_s}))
      focus.ok?.should be_true
      app.active_group_public.should eq(0)
      app.active_path_public.should eq(left_only.to_s)
      app.tab_paths_public.should eq([[left_only.to_s, shared.to_s], [shared.to_s, right_active.to_s]])
    end
  end

  it "prunes closed buffer snapshots at the actual close commit but retains a remaining shared view" do
    with_editor_tools_app do |app, root|
      first = root / "first-view.cr"
      other = root / "other-view.cr"
      File.write(first, "first\n")
      File.write(other, "other\n")
      app.open_file_public(first).should be_true
      app.split_right_public.should be_true
      app.open_file_public(first).should be_true
      app.activate_group_public(0)

      session = app.open_tool_session(capabilities: [
        Adamantine::EditorTools::Capability::ReadEditor,
        Adamantine::EditorTools::Capability::Navigate,
      ])
      first_row = editor_tools_list(session).first.as_h
      app.activate_group_public(1)
      app.close_active_view_public.should be_true
      app.open_buffer_count_public.should eq(1)
      app.editor_tool_reference_count_public.should eq(1)
      read = editor_tools_call(session, "read-after-one-view", "editor.read_buffer",
        editor_tools_args({"buffer_id" => first_row["buffer_id"].as_s, "revision" => first_row["revision"].as_s}))
      read.ok?.should be_true

      app.activate_group_public(0)
      app.close_active_view_public.should be_true
      app.open_buffer_count_public.should eq(0)
      app.editor_tool_reference_count_public.should eq(0)
    end
  end

  it "omits filenames with wire-forbidden control characters instead of publishing actionable paths" do
    with_editor_tools_app do |app, root|
      bad_path = root / "line\nbreak.cr"
      File.write(bad_path, "not a safe tool path\n")
      app.open_file_public(bad_path).should be_true
      session = app.open_tool_session(capabilities: [Adamantine::EditorTools::Capability::ReadEditor])

      listed = editor_tools_call(session, "list-control-path", "editor.list_buffers")
      listed.ok?.should be_true
      editor_tools_data(listed)["buffers"].as_a.should be_empty
      editor_tools_data(listed)["omitted"].as_i.should eq(1)

      found = editor_tools_call(session, "find-control-path", "editor.find_files",
        editor_tools_args({"query" => "line"}))
      found.ok?.should be_true
      paths = editor_tools_data(found)["paths"].as_a.map(&.as_h["path"].as_s)
      paths.should_not contain("line\nbreak.cr")
      editor_tools_data(found)["partial"].as_bool.should be_true
    end
  end

  it "revokes a yielding open before it can commit a tab or live buffer" do
    with_editor_tools_app do |app, root|
      large = root / "multi-chunk.cr"
      File.write(large, "a" * (Adamantine::FileRevision::DEFAULT_CHUNK_SIZE * 3 + 1))
      parent = app.open_tool_session(
        consumer: Adamantine::EditorTools::Consumer::Chat,
        capabilities: [Adamantine::EditorTools::Capability::Navigate],
      )
      session = parent.delegate(
        Adamantine::EditorTools::Consumer::Lua,
        [Adamantine::EditorTools::Capability::Navigate],
      )
      closed_during_read = false
      spawn do
        # The first FileRevision chunk yields once before this closer is
        # resumed by a later chunk, ensuring close precedes the open guard.
        Fiber.yield
        parent.close
        closed_during_read = true
      end

      result = editor_tools_call(session, "cancel-opening", "editor.open_file",
        editor_tools_args({"path" => "multi-chunk.cr"}))
      closed_during_read.should be_true
      result.ok?.should be_false
      result.status.should eq(Adamantine::EditorTools::Status::Denied)
      app.buffer_paths_public.should be_empty
      app.tab_paths_public.should eq([[] of String])
    end
  end

  it "denies traversal and symlink-leaf opens without changing buffers or tabs" do
    with_editor_tools_app do |app, root|
      link = root / "external.cr"
      File.symlink("/etc/passwd", link)
      session = app.open_tool_session(capabilities: [Adamantine::EditorTools::Capability::Navigate])

      traversal = editor_tools_call(session, "open-traversal", "editor.open_file",
        editor_tools_args({"path" => "../outside-editor-tool.cr"}))
      traversal.ok?.should be_false
      traversal.status.should eq(Adamantine::EditorTools::Status::Denied)
      app.buffer_paths_public.should be_empty
      app.tab_paths_public.should eq([[] of String])

      symlink = editor_tools_call(session, "open-symlink", "editor.open_file",
        editor_tools_args({"path" => "external.cr"}))
      symlink.ok?.should be_false
      symlink.status.should eq(Adamantine::EditorTools::Status::Denied)
      app.buffer_paths_public.should be_empty
      app.tab_paths_public.should eq([[] of String])
    end
  end

  it "does not relabel a debugger observation from another bound project" do
    with_editor_tools_app do |app, root|
      other_root = root / "other-project"
      Dir.mkdir_p(other_root)
      app.bind_debug_project_public(other_root).should be_true
      session = app.open_tool_session(capabilities: [Adamantine::EditorTools::Capability::ReadDebugger])

      result = editor_tools_call(session, "debug-other-project", "debug.snapshot")
      result.ok?.should be_false
      result.status.should eq(Adamantine::EditorTools::Status::Stale)
    end
  end
end
