require "spec"
require "file_utils"
require "random/secure"
require "crystal_tui"

require "../src/adamantine/app"

private class ChatEditAppProbeHandle < Adamantine::Chat::Handle
  getter tool_results : Array({String, String})

  def initialize
    @tool_results = [] of {String, String}
  end

  def cancel : Nil
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    @tool_results << {call_id, result_json}
  end
end

private class ChatEditAppProbeTransport < Adamantine::Chat::Transport
  def available? : Bool
    true
  end

  def external? : Bool
    true
  end

  getter requests : Array(Adamantine::Chat::Request)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))
  getter handles : Array(ChatEditAppProbeHandle)

  def initialize
    @requests = [] of Adamantine::Chat::Request
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
    @handles = [] of ChatEditAppProbeHandle
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    @requests << request
    @callbacks << on_event
    handle = ChatEditAppProbeHandle.new
    @handles << handle
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private class ChatEditAppProbe < Adamantine::App
  def render_surface_public(width : Int32 = 100, height : Int32 = 30) : Tui::Buffer
    mount_headless(width, height)
    buffer = Tui::Buffer.new(width, height)
    render(buffer, Tui::Rect.new(0, 0, width, height))
    buffer
  end

  def open_chat_context_public : Bool
    chat_context_action
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def split_editor_right_public : Bool
    split_editor_right
  end

  def activate_group_public(group : Int32) : Nil
    panel = group == 1 ? @right_editor_tabs : @editor_tabs
    raise "requested editor group is unavailable" unless panel
    activate_editor_group_internal(panel.not_nil!)
  end

  def activate_path_public(path : Path) : Nil
    active_editor_tabs.switch_to(path.to_s)
  end

  def choose_chat_context_public(index : Int32) : Nil
    raise "Chat context action was not handled" unless chat_context_action
    index.times do
      raise "Chat context navigation was not handled" unless on_capture(Tui::KeyEvent.new(Tui::Key::Down))
    end
    raise "Chat context selection was not handled" unless on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def choose_chat_context_public(label : String) : Nil
    raise "Chat context action was not handled" unless chat_context_action
    index = @context_menu.actions.index { |action| action.label == label } ||
            raise "missing Chat context action #{label.inspect}"
    index.times do
      raise "Chat context navigation was not handled" unless on_capture(Tui::KeyEvent.new(Tui::Key::Down))
    end
    raise "Chat context selection was not handled" unless on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def context_action_labels_public : Array(String)
    @context_menu.actions.map(&.label)
  end

  def chat_review_active_public? : Bool
    chat_review_active?
  end

  def chat_submit_public : Bool
    chat_submit_action
  end

  def project_root_public : Path
    @project_root
  end

  def chat_proposal_open_public? : Bool
    @lsp_popup.chat_proposal_open?
  end

  def chat_popup_title_public : String
    @lsp_popup.title
  end

  def input_mode_public : String
    active_input_mode.to_s
  end

  def editor_public(path : Path) : Adamantine::EditingTextEditor
    editor = @document_session.open_buffers[path.to_s]?.try(&.editor.as?(Adamantine::EditingTextEditor))
    editor || raise "missing editor for #{path}"
  end

  def active_editor_public : Adamantine::EditingTextEditor?
    active_editor_internal.as?(Adamantine::EditingTextEditor)
  end

  def select_active_range_public(start_line : Int32, start_column : Int32,
                                 end_line : Int32, end_column : Int32) : Nil
    editor = active_editor_public || raise "no active editing view"
    editor.select_range(start_line, start_column, end_line, end_column)
  end

  def chat_review_lines_public : Array(String)
    @chat_review_lines.dup
  end

  def chat_edit_receipt_source_range_public : Adamantine::Chat::SourceRange?
    @chat_edit_turn_receipt.try(&.source_range)
  end

  def chat_edit_receipt_selection_epoch_public : UInt64?
    @chat_edit_turn_receipt.try(&.selection_epoch)
  end

  def status_text_public : String
    @status_log.entries.map(&.message).join("\n")
  end

  def close_test_resources : Nil
    quit(force: true)
    Tui::App.clear_overlays
    Tui::Widget.focused_widget = nil
  end
end

private def with_chat_edit_app(
  transport : ChatEditAppProbeTransport = ChatEditAppProbeTransport.new,
  chat_enabled : Bool = false,
  &
)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(Dir.tempdir, "adamantine-chat-edit-ui-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config_path = root / "settings.json"
  chat_json = if chat_enabled
                %({"chat":{"enabled":true,"endpoint":"https://example.test/v1/chat/completions","model":"explicit-test-model","key_env":"CHAT_EDIT_TEST_KEY","max_completion_tokens":256}})
              else
                %({"chat":{"enabled":false}})
              end
  File.write(config_path, chat_json)
  app = ChatEditAppProbe.new(
    project_root: root,
    lsp_command: "",
    keymap_path: config_path.to_s,
    session_enabled: false,
    recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    chat_transport: transport
  )
  app.render_surface_public
  yield app
ensure
  app.try &.close_test_resources
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

private def chat_edit_ui_surface_text(buffer : Tui::Buffer) : String
  (0...buffer.height).map do |y|
    (0...buffer.width).map { |x| buffer.get(x, y).glyph }.join
  end.join("\n")
end

private def start_chat_edit_turn(
  app : ChatEditAppProbe,
  transport : ChatEditAppProbeTransport,
  source : Path,
  prompt : String = "replace the selected number",
  split_right : Bool = false,
) : Adamantine::EditingTextEditor
  app.open_file_public(source).should be_true
  if split_right
    app.split_editor_right_public.should be_true
    app.open_file_public(source).should be_true
    app.render_surface_public
    selected_view = app.active_editor_public || raise "right-group editor is not active"
    selected_view.same?(app.editor_public(source)).should be_false
  end
  app.chat_focus_action.should be_true
  app.choose_chat_context_public("Whole-file proposals")
  app.chat_focus_action.should be_true
  app.chat_panel.composer.text = prompt
  app.chat_submit_public.should be_true
  app.chat_review_active_public?.should be_true
  app.render_surface_public
  app.on_capture(Tui::KeyEvent.new('y')).should be_true
  app.chat_review_active_public?.should be_false
  transport.requests.size.should eq(1)
  transport.requests.first.context.mode.should eq(Adamantine::Chat::ContextMode::BufferProposals)
  app.editor_public(source)
end

private def start_chat_selection_proposal_turn(
  app : ChatEditAppProbe,
  transport : ChatEditAppProbeTransport,
  source : Path,
  selection : Tuple(Int32, Int32, Int32, Int32),
  prompt : String = "edit only the selected text",
  split_right : Bool = false,
) : Adamantine::EditingTextEditor
  app.open_file_public(source).should be_true
  if split_right
    app.split_editor_right_public.should be_true
    app.open_file_public(source).should be_true
    app.render_surface_public
    selected_view = app.active_editor_public || raise "right-group editor is not active"
    selected_view.same?(app.editor_public(source)).should be_false
  end
  app.select_active_range_public(selection[0], selection[1], selection[2], selection[3])
  app.chat_focus_action.should be_true
  app.choose_chat_context_public("Selection proposals (read + propose)")
  app.chat_focus_action.should be_true
  app.chat_panel.composer.text = prompt
  app.chat_submit_public.should be_true
  app.chat_review_active_public?.should be_true
  app.render_surface_public
  review = app.chat_review_lines_public.join("\n")
  review.should contain("Approved source: #{source.basename}")
  review.should contain("Selection scope:")
  app.on_capture(Tui::KeyEvent.new('y')).should be_true
  app.chat_review_active_public?.should be_false
  transport.requests.size.should eq(1)
  context = transport.requests.first.context
  context.mode.should eq(Adamantine::Chat::ContextMode::SelectionProposals)
  context.source_path.should eq(source.basename.to_s)
  context.text.should eq(app.active_editor_public.not_nil!.chat_selection_snapshot.not_nil!)
  app.active_editor_public || raise "selected editor is unavailable"
end

private def chat_edit_proposal_request(
  call_id : String,
  request : Adamantine::Chat::Request,
  start_column : Int32 = 14,
  end_column : Int32 = 15,
  replacement : String = "42",
  start_line : Int32 = 1,
  end_line : Int32 = 1,
) : String
  context = request.context
  raise "approved proposal context omitted buffer identity" unless context.buffer_id && context.revision
  {
    "id"        => call_id,
    "name"      => "editor.propose_edits",
    "arguments" => {
      "buffer_id" => context.buffer_id.not_nil!,
      "revision"  => context.revision.not_nil!,
      "edits"     => [{
        "start_line"   => start_line,
        "start_column" => start_column,
        "end_line"     => end_line,
        "end_column"   => end_column,
        "new_text"     => replacement,
      }],
    },
  }.to_json
end

private def chat_edit_proposal_batch_request(
  call_id : String,
  request : Adamantine::Chat::Request,
  edits : Array(NamedTuple(start_line: Int32, start_column: Int32,
    end_line: Int32, end_column: Int32, new_text: String)),
) : String
  context = request.context
  raise "approved proposal context omitted buffer identity" unless context.buffer_id && context.revision
  {
    "id"        => call_id,
    "name"      => "editor.propose_edits",
    "arguments" => {
      "buffer_id" => context.buffer_id.not_nil!,
      "revision"  => context.revision.not_nil!,
      "edits"     => edits.map do |edit|
        {
          "start_line"   => edit[:start_line],
          "start_column" => edit[:start_column],
          "end_line"     => edit[:end_line],
          "end_column"   => edit[:end_column],
          "new_text"     => edit[:new_text],
        }
      end,
    },
  }.to_json
end

private def chat_edit_read_request(
  call_id : String,
  request : Adamantine::Chat::Request,
  start_line : Int32 = 1,
  start_column : Int32 = 0,
  line_count : Int32 = 64,
  max_columns : Int32 = 64,
) : String
  context = request.context
  raise "approved tool context omitted buffer identity" unless context.buffer_id && context.revision
  {
    "id"        => call_id,
    "name"      => "editor.read_buffer",
    "arguments" => {
      "buffer_id"    => context.buffer_id.not_nil!,
      "revision"     => context.revision.not_nil!,
      "start_line"   => start_line,
      "line_count"   => line_count,
      "start_column" => start_column,
      "max_columns"  => max_columns,
    },
  }.to_json
end

private def chat_edit_tool_result(
  app : ChatEditAppProbe,
  transport : ChatEditAppProbeTransport,
  call_id : String,
  request_json : String,
) : JSON::Any
  transport.emit(0, Adamantine::Chat::Event.tool_request(call_id, request_json))
  app.on_capture(Tui::WakeupEvent.new).should be_true
  result = transport.handles.first.tool_results.last
  result[0].should eq(call_id)
  JSON.parse(result[1])
end

private def submit_chat_edit_proposal(
  app : ChatEditAppProbe,
  transport : ChatEditAppProbeTransport,
  call_id : String,
  request_json : String,
) : JSON::Any
  transport.emit(0, Adamantine::Chat::Event.tool_request(call_id, request_json))
  app.on_capture(Tui::WakeupEvent.new).should be_true
  result = transport.handles.first.tool_results.last
  result[0].should eq(call_id)
  JSON.parse(result[1])
end

describe "Chat edit proposal UI" do
  it "offers selection-scoped proposals separately from explicit whole-file proposals" do
    with_chat_edit_app do |app|
      app.open_chat_context_public.should be_true
      labels = app.context_action_labels_public

      labels.should contain("Selection proposals (read + propose)")
      labels.should contain("Whole-file proposals")
      labels.should contain("Selection proposals + Lua…")
      labels.should contain("Whole-file proposals + Lua…")
    end
  end

  it "freezes and displays the active selection as the selection-proposal capability" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      File.write(source, "LEFT_SENTINEL|TARGET|RIGHT_SENTINEL\nOUTSIDE_SENTINEL\n")

      app.open_file_public(source).should be_true
      app.select_active_range_public(0, 14, 0, 20)
      app.chat_focus_action.should be_true
      app.choose_chat_context_public("Selection proposals (read + propose)")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "edit only the selected text"
      app.chat_submit_public.should be_true
      app.chat_review_active_public?.should be_true
      app.render_surface_public

      review = app.chat_review_lines_public.join(" ").gsub(/\s+/, " ")
      review.should contain("Approved source: #{source.basename}")
      review.should contain("Initial editor context: 6 bytes (selected text shown below)")
      review.should contain("Selection scope: selection: 1:14–1:20")
      review.gsub(/\s+/, "").should contain("0-basedUnicodecodepointcolumns,end-exclusive")

      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      editor = app.editor_public(source)
      context = transport.requests.first.context
      context.text.should eq("TARGET")
      context.source_path.should eq("fixture.cr")
      context.source_range.should eq(Adamantine::Chat::SourceRange.new(1, 14, 1, 20))
      app.chat_edit_receipt_source_range_public.should eq(context.source_range)
      context.mode.proposal_context?.should be_true
      editor.text.should contain("LEFT_SENTINEL|TARGET|RIGHT_SENTINEL")
    end
  end

  it "rejects a send review after selection changes away and back before approval" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      File.write(source, "aaaTARGETzzz\n")
      app.open_file_public(source).should be_true
      app.select_active_range_public(0, 3, 0, 9)
      app.chat_focus_action.should be_true
      app.choose_chat_context_public("Selection proposals (read + propose)")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "edit selected text"
      app.chat_submit_public.should be_true
      app.chat_review_active_public?.should be_true

      app.select_active_range_public(0, 0, 0, 1)
      app.select_active_range_public(0, 3, 0, 9)
      app.on_capture(Tui::KeyEvent.new('y')).should be_true

      app.chat_review_active_public?.should be_false
      transport.requests.should be_empty
      app.status_text_public.should contain("review is stale")
      File.read(source).should eq("aaaTARGETzzz\n")
    end
  end

  it "returns only the requested intersection with the frozen selection and denies disjoint reads" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      File.write(source, "LEFT_SENTINEL|TARGET|RIGHT_SENTINEL\nOUTSIDE_SENTINEL\n")
      start_chat_selection_proposal_turn(app, transport, source, {0, 14, 0, 20})
      request = transport.requests.first

      page = chat_edit_tool_result(app, transport, "selection-read-clipped",
        chat_edit_read_request("selection-read-clipped", request, start_line: 1, start_column: 0,
          line_count: 1, max_columns: 17))
      page["status"].as_s.should eq("ok")
      page["data"]["lines"][0]["line"].as_i.should eq(1)
      page["data"]["lines"][0]["start_column"].as_i.should eq(14)
      page["data"]["lines"][0]["end_column"].as_i.should eq(17)
      page["data"]["lines"][0]["text"].as_s.should eq("TAR")
      page["data"]["lines"][0]["complete"].as_bool.should be_false
      page["data"]["continuation"]["start_line"].as_i.should eq(1)
      page["data"]["continuation"]["start_column"].as_i.should eq(17)
      page.to_json.should_not contain("LEFT_SENTINEL")
      page.to_json.should_not contain("RIGHT_SENTINEL")
      page.to_json.should_not contain("OUTSIDE_SENTINEL")

      final_page = chat_edit_tool_result(app, transport, "selection-read-final",
        chat_edit_read_request("selection-read-final", request, start_line: 1, start_column: 17,
          line_count: 1, max_columns: 64))
      final_page["data"]["lines"][0]["text"].as_s.should eq("GET")
      final_page["data"]["lines"][0]["start_column"].as_i.should eq(17)
      final_page["data"]["lines"][0]["end_column"].as_i.should eq(20)
      final_page["data"]["lines"][0]["complete"].as_bool.should be_true
      final_page["data"]["continuation"].raw.should be_nil

      denied = chat_edit_tool_result(app, transport, "selection-read-disjoint",
        chat_edit_read_request("selection-read-disjoint", request, start_line: 2, start_column: 0,
          line_count: 1, max_columns: 64))
      denied["status"].as_s.should eq("denied")
      denied.to_json.should_not contain("OUTSIDE_SENTINEL")
    end
  end

  it "skips preceding rows and does not claim an unread selected newline on a partial page" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      File.write(source, "BEFORE_SENTINEL\nfirstTARGETsuffix\nNEXT_SENTINELtail\nOUTSIDE_SENTINEL\n")
      start_chat_selection_proposal_turn(app, transport, source, {1, 5, 2, 4})
      request = transport.requests.first

      partial = chat_edit_tool_result(app, transport, "selection-read-partial-line",
        chat_edit_read_request("selection-read-partial-line", request, start_line: 2, start_column: 0,
          line_count: 2, max_columns: 8))
      partial["status"].as_s.should eq("ok")
      partial["data"]["lines"].size.should eq(1)
      partial["data"]["lines"][0]["line"].as_i.should eq(2)
      partial["data"]["lines"][0]["text"].as_s.should eq("TAR")
      partial["data"]["lines"][0]["newline_after"].as_bool.should be_false
      partial["data"]["complete"].as_bool.should be_false
      partial["data"]["continuation"]["start_line"].as_i.should eq(2)
      partial["data"]["continuation"]["start_column"].as_i.should eq(8)
      partial.to_json.should_not contain("BEFORE_SENTINEL")
      partial.to_json.should_not contain("first")
      partial.to_json.should_not contain("suffix")
      partial.to_json.should_not contain("NEXT_SENTINEL")
      partial.to_json.should_not contain("OUTSIDE_SENTINEL")

      complete = chat_edit_tool_result(app, transport, "selection-read-multiline",
        chat_edit_read_request("selection-read-multiline", request, start_line: 1, start_column: 0,
          line_count: 3, max_columns: 64))
      complete["status"].as_s.should eq("ok")
      complete["data"]["lines"].size.should eq(2)
      complete["data"]["lines"][0]["line"].as_i.should eq(2)
      complete["data"]["lines"][0]["text"].as_s.should eq("TARGETsuffix")
      complete["data"]["lines"][0]["newline_after"].as_bool.should be_true
      complete["data"]["lines"][1]["line"].as_i.should eq(3)
      complete["data"]["lines"][1]["text"].as_s.should eq("NEXT")
      complete["data"]["lines"][1]["newline_after"].as_bool.should be_false
      complete["data"]["complete"].as_bool.should be_true
      complete["data"]["continuation"].raw.should be_nil
      complete.to_json.should_not contain("BEFORE_SENTINEL")
      complete.to_json.should_not contain("tail")
      complete.to_json.should_not contain("OUTSIDE_SENTINEL")
    end
  end

  it "does not reveal excluded prefix, suffix, or file bounds through selected-read validation" do
    prefix_rows = [] of Array(String)
    prefix_only_outcomes = [] of {String, String}
    suffix_outcomes = [] of {String, String}
    after_eof_outcomes = [] of {String, String}
    overflow_outcomes = [] of {String, String}

    [{"P", "", 0}, {"P" * 40, "AFTER_SENTINEL" * 4, 12}].each_with_index do |fixture, index|
      prefix, suffix, trailing_rows = fixture
      transport = ChatEditAppProbeTransport.new
      with_chat_edit_app(transport, chat_enabled: true) do |app|
        source = app.project_root_public / "fixture.cr"
        File.write(source, "#{prefix}\nLEFTTARGET#{suffix}\n" + ("OUTSIDE_ROW\n" * trailing_rows))
        start_chat_selection_proposal_turn(app, transport, source, {1, 4, 1, 10})
        request = transport.requests.first

        spanning_prefix = chat_edit_tool_result(app, transport, "selection-prefix-spanning-#{index}",
          chat_edit_read_request("selection-prefix-spanning-#{index}", request, start_line: 1,
            start_column: 20, line_count: 2, max_columns: 64))
        spanning_prefix["status"].as_s.should eq("ok")
        prefix_rows << spanning_prefix["data"]["lines"].as_a.map do |row|
          "#{row["line"].as_i}:#{row["text"].as_s}"
        end
        spanning_prefix.to_json.should_not contain("AFTER_SENTINEL")
        spanning_prefix.to_json.should_not contain("OUTSIDE_ROW")

        prefix_only = chat_edit_tool_result(app, transport, "selection-prefix-only-#{index}",
          chat_edit_read_request("selection-prefix-only-#{index}", request, start_line: 1,
            start_column: 20, line_count: 1, max_columns: 64))
        prefix_only_outcomes << {prefix_only["status"].as_s, prefix_only["message"].as_s}

        suffix_only = chat_edit_tool_result(app, transport, "selection-suffix-only-#{index}",
          chat_edit_read_request("selection-suffix-only-#{index}", request, start_line: 2,
            start_column: 11, line_count: 1, max_columns: 64))
        suffix_outcomes << {suffix_only["status"].as_s, suffix_only["message"].as_s}

        after_eof = chat_edit_tool_result(app, transport, "selection-after-eof-#{index}",
          chat_edit_read_request("selection-after-eof-#{index}", request, start_line: 10,
            line_count: 1, max_columns: 64))
        after_eof_outcomes << {after_eof["status"].as_s, after_eof["message"].as_s}

        overflow = chat_edit_tool_result(app, transport, "selection-overflow-#{index}",
          chat_edit_read_request("selection-overflow-#{index}", request, start_line: Int32::MAX,
            line_count: 64, max_columns: 64))
        overflow_outcomes << {overflow["status"].as_s, overflow["message"].as_s}
      end
    end

    prefix_rows.should eq([["2:TARGET"], ["2:TARGET"]])
    denied = {"denied", "read does not intersect the approved selection"}
    prefix_only_outcomes.should eq([denied, denied])
    suffix_outcomes.should eq([denied, denied])
    after_eof_outcomes.should eq([denied, denied])
    overflow_outcomes.should eq([denied, denied])
  end

  it "represents a newline-only selection without exposing the next line or a false continuation" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      File.write(source, "left\nOUTSIDE_LINE_SENTINEL\n")
      start_chat_selection_proposal_turn(app, transport, source, {0, 4, 1, 0})
      request = transport.requests.first
      request.context.text.should eq("\n")
      request.context.source_range.should eq(Adamantine::Chat::SourceRange.new(1, 4, 2, 0))

      page = chat_edit_tool_result(app, transport, "selection-read-newline",
        chat_edit_read_request("selection-read-newline", request, start_line: 1, start_column: 0,
          line_count: 2, max_columns: 64))
      page["status"].as_s.should eq("ok")
      page["data"]["lines"].size.should eq(1)
      row = page["data"]["lines"][0]
      row["start_column"].as_i.should eq(4)
      row["end_column"].as_i.should eq(4)
      row["text"].as_s.should eq("")
      row["newline_after"].as_bool.should be_true
      page["data"]["complete"].as_bool.should be_true
      page["data"]["continuation"].raw.should be_nil
      page.to_json.should_not contain("OUTSIDE_LINE_SENTINEL")

      denied = chat_edit_tool_result(app, transport, "selection-read-after-newline",
        chat_edit_read_request("selection-read-after-newline", request, start_line: 2, start_column: 0,
          line_count: 1, max_columns: 64))
      denied["status"].as_s.should eq("denied")
    end
  end

  it "rejects a mixed selected and outside edit batch before staging anything" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "aaaTARGETzzz\nOUTSIDE_SENTINEL\n"
      File.write(source, original)
      editor = start_chat_selection_proposal_turn(app, transport, source, {0, 3, 0, 9})
      result = submit_chat_edit_proposal(app, transport, "selection-mixed-edits",
        chat_edit_proposal_batch_request("selection-mixed-edits", transport.requests.first, [
          {start_line: 1, start_column: 4, end_line: 1, end_column: 5, new_text: "X"},
          {start_line: 2, start_column: 0, end_line: 2, end_column: 1, new_text: "Y"},
        ]))

      result["status"].as_s.should eq("denied")
      result.to_json.should_not contain("pending_review")
      app.chat_proposal_open_public?.should be_false
      editor.text.should eq(original)
      File.read(source).should eq(original)
    end
  end

  it "accepts insertions at both selection boundaries as one unsaved undoable edit" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "aaaTARGETzzz\n"
      File.write(source, original)
      editor = start_chat_selection_proposal_turn(app, transport, source, {0, 3, 0, 9})
      result = submit_chat_edit_proposal(app, transport, "selection-boundary-inserts",
        chat_edit_proposal_batch_request("selection-boundary-inserts", transport.requests.first, [
          {start_line: 1, start_column: 3, end_line: 1, end_column: 3, new_text: "["},
          {start_line: 1, start_column: 9, end_line: 1, end_column: 9, new_text: "]"},
        ]))
      result["status"].as_s.should eq("ok")

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      editor.text.should eq("aaa[TARGET]zzz\n")
      File.read(source).should eq(original)
      app.on_capture(Tui::KeyEvent.new('z', Tui::Modifiers::Ctrl)).should be_true
      editor.text.should eq(original)
      editor.undo.should be_false
    end
  end

  it "uses Unicode codepoint columns for selected reads and replacements" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "A🙂B\n"
      File.write(source, original)
      editor = start_chat_selection_proposal_turn(app, transport, source, {0, 1, 0, 2})
      context = transport.requests.first.context
      context.text.should eq("🙂")
      context.source_range.should eq(Adamantine::Chat::SourceRange.new(1, 1, 1, 2))
      page = chat_edit_tool_result(app, transport, "selection-read-astral",
        chat_edit_read_request("selection-read-astral", transport.requests.first,
          start_line: 1, start_column: 0, line_count: 1, max_columns: 8))
      page["data"]["lines"][0]["text"].as_s.should eq("🙂")
      page["data"]["lines"][0]["start_column"].as_i.should eq(1)
      page["data"]["lines"][0]["end_column"].as_i.should eq(2)

      result = submit_chat_edit_proposal(app, transport, "selection-replace-astral",
        chat_edit_proposal_request("selection-replace-astral", transport.requests.first,
          start_column: 1, end_column: 2, replacement: "X"))
      result["status"].as_s.should eq("ok")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      editor.text.should eq("AXB\n")
      File.read(source).should eq(original)
    end
  end

  it "normalizes a reversed multiline CRLF selection with astral and combining codepoints through accept and Undo" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original_bytes = "before🙂\r\nTARGETe\u0301\r\nAFTER_SENTINEL\r\n"
      File.write(source, original_bytes)
      editor = start_chat_selection_proposal_turn(app, transport, source, {1, 6, 0, 6})
      context = transport.requests.first.context
      context.text.should eq("🙂\nTARGET")
      context.source_range.should eq(Adamantine::Chat::SourceRange.new(1, 6, 2, 6))
      app.chat_edit_receipt_source_range_public.should eq(context.source_range)

      page = chat_edit_tool_result(app, transport, "selection-crlf-read",
        chat_edit_read_request("selection-crlf-read", transport.requests.first,
          start_line: 1, start_column: 0, line_count: 3, max_columns: 64))
      page["status"].as_s.should eq("ok")
      page["data"]["lines"].size.should eq(2)
      page["data"]["lines"][0]["line"].as_i.should eq(1)
      page["data"]["lines"][0]["start_column"].as_i.should eq(6)
      page["data"]["lines"][0]["text"].as_s.should eq("🙂")
      page["data"]["lines"][0]["newline_after"].as_bool.should be_true
      page["data"]["lines"][1]["end_column"].as_i.should eq(6)
      page["data"]["lines"][1]["text"].as_s.should eq("TARGET")
      page.to_json.should_not contain("e\u0301")
      page.to_json.should_not contain("AFTER_SENTINEL")

      before_accept = editor.text
      result = submit_chat_edit_proposal(app, transport, "selection-crlf-accept",
        chat_edit_proposal_request("selection-crlf-accept", transport.requests.first,
          start_line: 2, end_line: 2, start_column: 0, end_column: 6, replacement: "VALUE"))
      result["status"].as_s.should eq("ok")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      editor.text.should contain("VALUEe\u0301")
      editor.text.should_not contain("TARGET")
      File.read(source).should eq(original_bytes)
      app.on_capture(Tui::KeyEvent.new('z', Tui::Modifiers::Ctrl)).should be_true
      editor.text.should eq(before_accept)
      editor.undo.should be_false
      File.read(source).should eq(original_bytes)
    end
  end

  it "revokes a selected preview when the active selection drifts before manual acceptance" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "aaaTARGETzzz\n"
      File.write(source, original)
      editor = start_chat_selection_proposal_turn(app, transport, source, {0, 3, 0, 9})
      result = submit_chat_edit_proposal(app, transport, "selection-stale-preview",
        chat_edit_proposal_request("selection-stale-preview", transport.requests.first,
          start_column: 4, end_column: 5, replacement: "X"))
      result["status"].as_s.should eq("ok")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true

      # Returning to the approved coordinates must not revive the receipt.
      app.select_active_range_public(0, 0, 0, 1)
      app.select_active_range_public(0, 3, 0, 9)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      editor.text.should eq(original)
      File.read(source).should eq(original)
      app.chat_proposal_open_public?.should be_false
      app.status_text_public.should contain("stale")
    end
  end

  it "does not revive selected tool authority after an A-to-B-to-A change during generation" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "aaaTARGETzzz\n"
      File.write(source, original)
      editor = start_chat_selection_proposal_turn(app, transport, source, {0, 3, 0, 9})
      receipt_epoch = app.chat_edit_receipt_selection_epoch_public || raise "selection receipt omitted its epoch"

      app.select_active_range_public(0, 0, 0, 1)
      app.select_active_range_public(0, 3, 0, 9)
      editor.chat_selection_epoch.should be > receipt_epoch
      result = chat_edit_tool_result(app, transport, "selection-aba-tool",
        chat_edit_proposal_request("selection-aba-tool", transport.requests.first,
          start_column: 4, end_column: 5, replacement: "X"))

      result["status"].as_s.should eq("stale")
      result["message"].as_s.should contain("context changed")
      editor.text.should eq(original)
      app.chat_proposal_open_public?.should be_false
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_false
      File.read(source).should eq(original)
    end
  end

  it "does not publish a privately staged selected candidate after selection A-to-B-to-A" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "aaaTARGETzzz\n"
      File.write(source, original)
      editor = start_chat_selection_proposal_turn(app, transport, source, {0, 3, 0, 9})
      result = submit_chat_edit_proposal(app, transport, "selection-aba-staged",
        chat_edit_proposal_request("selection-aba-staged", transport.requests.first,
          start_column: 4, end_column: 5, replacement: "X"))
      result["status"].as_s.should eq("ok")
      result["data"]["status"].as_s.should eq("pending_review")
      editor.text.should eq(original)
      app.chat_proposal_open_public?.should be_false

      app.select_active_range_public(0, 0, 0, 1)
      app.select_active_range_public(0, 3, 0, 9)
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_false
      editor.text.should eq(original)
      File.read(source).should eq(original)
      app.status_text_public.should contain("approved source changed")
    end
  end

  it "revokes a selected proposal when another same-file split view becomes active" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "aaaTARGETzzz\n"
      File.write(source, original)
      editor = start_chat_selection_proposal_turn(app, transport, source, {0, 3, 0, 9}, split_right: true)
      result = submit_chat_edit_proposal(app, transport, "selection-sibling-view",
        chat_edit_proposal_request("selection-sibling-view", transport.requests.first,
          start_column: 4, end_column: 5, replacement: "X"))
      result["status"].as_s.should eq("ok")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true

      app.activate_group_public(0)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
      editor.text.should eq(original)
      File.read(source).should eq(original)
      app.chat_proposal_open_public?.should be_false
    end
  end

  it "discloses the one-attempt and 8 KiB boundary before provider approval" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      app.open_file_public(source).should be_true
      app.select_active_range_public(0, 6, 0, 11)
      app.chat_focus_action.should be_true
      app.choose_chat_context_public("Whole-file proposals")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "replace the number only"
      app.chat_submit_public.should be_true

      surface = chat_edit_ui_surface_text(app.render_surface_public)
      review = app.chat_review_lines_public.join(" ").gsub(/\s+/, " ")
      review.should contain("Initial editor context: 0 bytes")
      review.should contain("Informational editor selection; access scope: whole_file: 1:6–1:11")
      review.gsub(/\s+/, "").should contain("0-basedUnicodecodepointcolumns,end-exclusive")
      surface.should contain("One proposal attempt")
      surface.should contain("32 edits / 8 KiB tool request")
      surface.should contain("manual review only")
      surface.should contain("never auto-")
      surface.should contain("applied/saved")
      transport.requests.should be_empty
    end
  end

  it "stages privately, then accepts the proposal as one undoable unsaved edit from a split view" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      editor = start_chat_edit_turn(app, transport, source, split_right: true)

      result = submit_chat_edit_proposal(app, transport, "proposal-1",
        chat_edit_proposal_request("proposal-1", transport.requests.first))
      result["status"].as_s.should eq("ok")
      result["data"]["status"].as_s.should eq("pending_review")
      result["data"]["applied"].as_bool.should be_false
      result["data"]["buffer_id"].as_s.should eq(transport.requests.first.context.buffer_id.not_nil!)
      result["data"]["revision"].as_s.should eq(transport.requests.first.context.revision.not_nil!)
      editor.text.should eq(original)
      app.chat_proposal_open_public?.should be_false

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true
      app.chat_popup_title_public.should eq("Chat proposed edits · manual review")
      app.input_mode_public.should eq("LspPopup")
      chat_edit_ui_surface_text(app.render_surface_public).should contain("fixture.cr")
      editor.text.should eq(original)
      File.read(source).should eq(original)

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      editor.text.should eq("const value = 42;\n")
      File.read(source).should eq(original)
      app.chat_proposal_open_public?.should be_false
      app.input_mode_public.should eq("Normal")

      app.on_capture(Tui::KeyEvent.new('z', Tui::Modifiers::Ctrl)).should be_true
      editor.text.should eq(original)
      editor.undo.should be_false
      File.read(source).should eq(original)
    end
  end

  it "keeps the source identity and unsaved state on the 112x30 preview header" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      File.write(source, "const value = 1;\n")
      start_chat_edit_turn(app, transport, source)
      submit_chat_edit_proposal(app, transport, "proposal-header",
        chat_edit_proposal_request("proposal-header", transport.requests.first))
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true

      surface = chat_edit_ui_surface_text(app.render_surface_public(112, 30))
      review_header = surface.lines.find { |line| line.includes?("Chat proposed edits") }
      review_header.should_not be_nil
      review_header.not_nil!.should contain("fixture.cr")
      review_header.not_nil!.should contain("not saved")
      surface.should contain("Apply selected")
      surface.should contain("Esc Reject")
    end
  end

  it "spends the single typed proposal attempt even when its first range is invalid" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      editor = start_chat_edit_turn(app, transport, source)
      request = transport.requests.first

      invalid = submit_chat_edit_proposal(app, transport, "invalid-range",
        chat_edit_proposal_request("invalid-range", request, start_column: 999, end_column: 1000))
      invalid["status"].as_s.should eq("invalid_request")
      editor.text.should eq(original)

      second = submit_chat_edit_proposal(app, transport, "second-attempt",
        chat_edit_proposal_request("second-attempt", request))
      second["status"].as_s.should eq("denied")
      second["message"].as_s.should contain("only one proposal")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_false
      editor.text.should eq(original)
    end
  end

  it "closes the shared popup input mode on explicit rejection" do
    transport = ChatEditAppProbeTransport.new
    with_chat_edit_app(transport, chat_enabled: true) do |app|
      source = app.project_root_public / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      editor = start_chat_edit_turn(app, transport, source)
      submit_chat_edit_proposal(app, transport, "proposal-escape",
        chat_edit_proposal_request("proposal-escape", transport.requests.first))
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.chat_proposal_open_public?.should be_false
      app.input_mode_public.should eq("Normal")
      editor.text.should eq(original)

      # A subsequent shared modal can open only if LspPopup mode was fully
      # unwound along with the proposal overlay.
      app.open_chat_context_public.should be_true
    end
  end
end
