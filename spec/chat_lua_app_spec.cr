require "spec"
require "digest/sha256"
require "json"
require "file_utils"
require "random/secure"
require "crystal_tui"

require "../src/adamantine/app"

private class ChatLuaAppProbeHandle < Adamantine::Chat::Handle
  getter tool_results : Array({String, String})
  getter cancelled : Bool

  def initialize
    @tool_results = [] of {String, String}
    @cancelled = false
  end

  def cancel : Nil
    @cancelled = true
  end

  def deliver_tool_result(call_id : String, result_json : String) : Nil
    @tool_results << {call_id, result_json}
  end
end

private class ChatLuaAppProbeTransport < Adamantine::Chat::Transport
  getter requests : Array(Adamantine::Chat::Request)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))
  getter handles : Array(ChatLuaAppProbeHandle)

  def initialize
    @requests = [] of Adamantine::Chat::Request
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
    @handles = [] of ChatLuaAppProbeHandle
  end

  def available? : Bool
    true
  end

  def external? : Bool
    true
  end

  def start(request : Adamantine::Chat::Request,
            on_event : Proc(Adamantine::Chat::Event, Nil)) : Adamantine::Chat::Handle
    @requests << request
    @callbacks << on_event
    handle = ChatLuaAppProbeHandle.new
    @handles << handle
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private class RecordingChatLuaRunner < Adamantine::LuaScripts::Runner
  getter runs : Array(Adamantine::LuaScripts::Run)

  def initialize(worker_path : String, library_path : String)
    super(worker_path, library_path)
    @runs = [] of Adamantine::LuaScripts::Run
  end

  def start(script_id : String, source : String, context : JSON::Any) : Adamantine::LuaScripts::Run
    run = super
    @runs << run
    run
  end
end

private class ChatLuaAppSpecApp < Adamantine::App
  def render_surface_public(width : Int32 = 100, height : Int32 = 30) : Tui::Buffer
    mount_headless(width, height)
    buffer = Tui::Buffer.new(width, height)
    render(buffer, Tui::Rect.new(0, 0, width, height))
    buffer
  end

  def open_palette_public : Nil
    open_command_palette("")
  end

  def command_titles_public : Array(String)
    @command_palette.candidates.map(&.title)
  end

  def choose_palette_entry_public(title : String) : Nil
    index = @command_palette.candidates.index { |entry| entry.title == title } ||
            raise "missing command palette entry #{title}"
    @command_palette.selected_index = index
    raise "command palette entry did not execute" unless on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def open_chat_context_public : Nil
    open_chat_context_menu
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def select_active_range_public(start_line : Int32, start_column : Int32,
                                 end_line : Int32, end_column : Int32) : Nil
    editor = active_editor_internal.as?(Adamantine::EditingTextEditor) || raise "no active editing view"
    editor.select_range(start_line, start_column, end_line, end_column)
  end

  def project_root_public : Path
    @project_root
  end

  def run_command_public(command : String) : Nil
    open_command_palette unless @command_palette.open
    command.each_char { |character| on_capture(Tui::KeyEvent.new(character)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def choose_chat_context_public(index : Int32) : Nil
    raise "Chat context menu did not open" unless chat_context_action
    index.times { on_capture(Tui::KeyEvent.new(Tui::Key::Down)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def choose_chat_context_public(label : String) : Nil
    raise "Chat context menu did not open" unless chat_context_action
    index = @context_menu.actions.index { |action| action.label == label } ||
            raise "missing Chat context action #{label.inspect}"
    index.times { on_capture(Tui::KeyEvent.new(Tui::Key::Down)) }
    on_capture(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def chat_review_active_public? : Bool
    chat_review_active?
  end

  def chat_review_lines_public : Array(String)
    @chat_review_lines.dup
  end

  def chat_lua_selected_public? : Bool
    !@chat_lua_selected_entry.nil?
  end

  def chat_context_reset_public? : Bool
    @chat_context_mode.none?
  end

  def chat_lua_worker_active_public? : Bool
    @chat_lua_worker_active
  end

  def chat_lua_run_reaped_public? : Bool
    @chat_lua_active_run.try(&.run.reaped?) == true
  end

  def chat_lua_ticket_active_public? : Bool
    @chat_lua_active_run.try(&.ticket.active?) == true
  end

  def chat_frontend_active_public? : Bool
    @chat_frontend.try(&.active?) == true
  end

  def lua_execution_busy_public? : Bool
    lua_execution_busy?
  end

  def chat_lua_child_flags_public : {Bool, Bool}
    {@chat_lua_child_succeeded, @chat_lua_child_failed}
  end

  def chat_edit_candidate_staged_public? : Bool
    !@chat_edit_staged_proposal.nil?
  end

  def chat_proposal_open_public? : Bool
    @lsp_popup.chat_proposal_open?
  end

  def active_editor_text_public : String?
    active_editor_internal.as?(Adamantine::EditingTextEditor).try(&.text)
  end

  def chat_submit_public : Bool
    chat_submit_action
  end

  def status_text_public : String
    @status_log.entries.map(&.message).join("\n")
  end

  def context_action_labels_public : Array(String)
    @context_menu.actions.map(&.label)
  end

  def close_test_resources : Nil
    quit(force: true)
    Tui::App.clear_overlays
    Tui::Widget.focused_widget = nil
  end
end

private def with_chat_lua_app(
  transport : ChatLuaAppProbeTransport = ChatLuaAppProbeTransport.new,
  catalog_setup : Proc(Path, Nil)? = nil,
  lua_script_runner : Adamantine::LuaScripts::Runner? = nil,
  &
)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(Dir.tempdir, "adamantine-chat-lua-app-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  catalog_setup.try(&.call(root))
  config_path = root / "settings.json"
  File.write(config_path, %({"chat":{"enabled":true,"endpoint":"https://example.test/v1/chat/completions","model":"explicit-test-model","key_env":"CHAT_LUA_TEST_KEY","max_completion_tokens":256}}))
  app = ChatLuaAppSpecApp.new(
    project_root: root,
    lsp_command: "",
    keymap_path: config_path.to_s,
    session_enabled: false,
    recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    chat_transport: transport,
    lua_script_catalog: Adamantine::LuaScripts::Catalog.new(config_root: root / "user-lua"),
    lua_script_runner: lua_script_runner
  )
  app.render_surface_public
  yield app, root
ensure
  app.try &.close_test_resources
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

describe "Chat-to-named-Lua host UI" do
  it "offers explicit next-turn selection and clearing in F1" do
    with_chat_lua_app do |app, _root|
      app.open_palette_public

      titles = app.command_titles_public
      titles.should contain("Choose Lua script for next Chat turn…")
      titles.should contain("Clear Chat Lua script")
    end
  end

  it "offers explicit combined buffer-context and named-script shortcuts" do
    with_chat_lua_app do |app, _root|
      app.open_chat_context_public

      labels = app.context_action_labels_public
      labels.should contain("Buffer read tools + Lua…")
      labels.should contain("Selection proposals (read + propose)")
      labels.should contain("Selection proposals + Lua…")
      labels.should contain("Whole-file proposals")
      labels.should contain("Whole-file proposals + Lua…")
    end
  end

  it "keeps a read-only turn alive through Session construction and reads only the reviewed buffer revision" do
    transport = ChatLuaAppProbeTransport.new
    with_chat_lua_app(transport) do |app, root|
      source = root / "selected.cr"
      File.write(source, "alpha=42\n")
      app.open_file_public(source).should be_true
      app.chat_focus_action.should be_true
      app.choose_chat_context_public("Buffer read tools")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "read the selected buffer"
      app.chat_submit_public.should be_true
      app.chat_review_active_public?.should be_true, app.status_text_public
      app.on_capture(Tui::KeyEvent.new('y')).should be_true

      transport.requests.size.should eq(1)
      request = transport.requests.first
      context = request.context
      context.mode.should eq(Adamantine::Chat::ContextMode::BufferTools)
      context.buffer_id.should_not be_nil
      context.revision.should_not be_nil
      context.lua_script_grant.should be_nil

      call = {
        "id"        => "selected-read",
        "name"      => "editor.read_buffer",
        "arguments" => {
          "buffer_id"  => context.buffer_id.not_nil!,
          "revision"   => context.revision.not_nil!,
          "start_line" => 1,
          "line_count" => 1,
        },
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("selected-read", call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      result = transport.handles.first.tool_results.last
      result[0].should eq("selected-read")
      parsed = JSON.parse(result[1])
      parsed["status"].as_s.should eq("ok")
      parsed["data"]["lines"][0]["text"].as_s.should eq("alpha=42")

      wrong_buffer = {
        "id"        => "wrong-buffer",
        "name"      => "editor.read_buffer",
        "arguments" => {
          "buffer_id" => "not-the-reviewed-buffer",
          "revision"  => context.revision.not_nil!,
        },
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("wrong-buffer", wrong_buffer))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      denied = JSON.parse(transport.handles.first.tool_results.last[1])
      denied["status"].as_s.should eq("denied")

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
    end
  end

  it "reviews one frozen named script, keeps it on review cancel, and resets it after accepted Send" do
    transport = ChatLuaAppProbeTransport.new
    lua_root = nil.as(Path?)
    script_path = nil.as(Path?)
    script_source = "print('FROZEN_CHAT_LUA_SOURCE')\nprint('FROZEN_SECOND_LINE')"
    setup = ->(root : Path) {
      lua_root = root / "user-lua"
      Dir.mkdir_p(lua_root.not_nil! / "scripts")
      script_path = lua_root.not_nil! / "scripts" / "frozen.lua"
      File.write(script_path.not_nil!, script_source)
      File.write(lua_root.not_nil! / "manifest.json", {
        "version" => 1,
        "scripts" => [{
          "id"           => "frozen-fixture",
          "name"         => "Frozen Fixture",
          "file"         => "frozen.lua",
          "capabilities" => ["read_editor", "propose_edits", "navigate"],
        }],
      }.to_json)
      nil
    }

    with_chat_lua_app(transport, setup) do |app, root|
      source = root / "selected.cr"
      File.write(source, "alpha=42\n")
      app.open_file_public(source).should be_true
      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Whole-file proposals + Lua…")
      app.command_titles_public.should contain("Frozen Fixture")
      app.choose_palette_entry_public("Frozen Fixture")
      app.chat_lua_selected_public?.should be_true
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "run the reviewed script"

      app.chat_submit_public.should be_true
      app.chat_review_active_public?.should be_true
      review = app.chat_review_lines_public.join("\n")
      review.should contain("Frozen script: Frozen Fixture (ID frozen-fixture)")
      review.should contain("SHA-256:")
      review.should contain("Requested capabilities: read_editor, propose_edits, navigate")
      review.should contain("Effective capabilities: read_editor, propose_edits")
      review.should contain("Excluded capabilities: navigate")
      review.should contain("Script source (frozen locally; not sent to provider):")
      review.should contain("FROZEN_CHAT_LUA_SOURCE")
      review.should contain("FROZEN_SECOND_LINE")

      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      app.chat_review_active_public?.should be_false
      app.chat_lua_selected_public?.should be_true
      transport.requests.should be_empty

      app.chat_submit_public.should be_true
      app.chat_review_active_public?.should be_true
      File.write(script_path.not_nil!, "print('MUTATED_AFTER_REVIEW')")
      app.on_capture(Tui::KeyEvent.new('y')).should be_true

      transport.requests.size.should eq(1)
      context = transport.requests.first.context
      context.mode.should eq(Adamantine::Chat::ContextMode::BufferProposals)
      grant = context.lua_script_grant || raise "approved metadata grant was missing"
      grant.id.should eq("frozen-fixture")
      grant.name.should eq("Frozen Fixture")
      grant.digest.should eq(Digest::SHA256.hexdigest(script_source))
      grant.effective_capabilities.should eq([
        Adamantine::EditorTools::Capability::ReadEditor,
        Adamantine::EditorTools::Capability::ProposeEdits,
      ])
      context.text.should be_empty
      transport.requests.first.text.should_not contain("FROZEN_CHAT_LUA_SOURCE")
      transport.requests.first.text.should_not contain("MUTATED_AFTER_REVIEW")
      app.chat_lua_selected_public?.should be_false
      app.chat_context_reset_public?.should be_true
    end
  end

  it "delivers a caught child refusal while keeping the parent read scope alive and proposals poisoned" do
    worker = ENV["ADAMANTINE_LUA_WORKER"]? || raise "ADAMANTINE_LUA_WORKER is required for real Chat Lua App tests"
    library = ENV["ADAMANTINE_LUA_LIBRARY"]? || raise "ADAMANTINE_LUA_LIBRARY is required for real Chat Lua App tests"
    runner = RecordingChatLuaRunner.new(worker, library)
    transport = ChatLuaAppProbeTransport.new
    script_source = String.build do |script|
      script << "local selected=editor.context.selected_buffer\n"
      script << "local proposal=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=1,start_column=14,end_line=1,end_column=15,new_text=\"77\"}}})\n"
      script << "assert(proposal.status == \"ok\")\n"
      script << "local ok,denied=pcall(function() return editor.call(\"editor.read_buffer\",{buffer_id=\"not-the-reviewed-buffer\",revision=selected.revision,start_line=1,line_count=1}) end)\n"
      script << "assert(ok and denied.status == \"denied\")\n"
      script << "local again=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=1,start_column=14,end_line=1,end_column=15,new_text=\"88\"}}})\n"
      script << "assert(again.status == \"denied\")\n"
      script << "print(\"CAUGHT_REFUSAL_NORMAL_RETURN\")\n"
    end
    setup = ->(root : Path) {
      lua_root = root / "user-lua"
      Dir.mkdir_p(lua_root / "scripts")
      File.write(lua_root / "scripts" / "sticky-refusal.lua", script_source)
      File.write(lua_root / "manifest.json", {
        "version" => 1,
        "scripts" => [{
          "id"           => "sticky-refusal",
          "name"         => "Sticky refusal",
          "file"         => "sticky-refusal.lua",
          "capabilities" => ["read_editor", "propose_edits"],
        }],
      }.to_json)
      nil
    }

    with_chat_lua_app(transport, setup, runner) do |app, root|
      source = root / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      app.open_file_public(source).should be_true
      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Whole-file proposals + Lua…")
      app.choose_palette_entry_public("Sticky refusal")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "run the selected script"
      app.chat_submit_public.should be_true
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      transport.requests.size.should eq(1)

      context = transport.requests.first.context
      run_call = {
        "id"        => "sticky-refusal-run",
        "name"      => "lua.run_script",
        "arguments" => {"script_id" => "sticky-refusal"},
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("sticky-refusal-run", run_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_lua_worker_active_public?.should be_true

      deadline = Time.instant + 5.seconds
      until transport.handles.first.tool_results.any? { |result| result[0] == "sticky-refusal-run" }
        raise "caught child refusal did not return a provider tool result: #{app.status_text_public}" if Time.instant >= deadline
        app.on_capture(Tui::WakeupEvent.new)
        sleep 5.milliseconds
      end
      run_result = JSON.parse(transport.handles.first.tool_results.find { |result| result[0] == "sticky-refusal-run" }.not_nil![1])
      run_result["status"].as_s.should_not eq("ok")
      run_result["message"].as_s.should contain(
        "named-script child tool call failed: read is outside the approved buffer revision"
      )
      runner.runs.size.should eq(1)
      runner.runs.first.reaped?.should be_true
      runner.runs.first.failure_code.should be_nil
      app.chat_frontend_active_public?.should be_true
      # The script asserts the first proposal RPC returned success before it
      # issues the denied read; that RPC only returns success after staging.
      # Avoid polling the transient candidate because proposal and refusal
      # events can both be drained in one App wakeup.
      app.chat_edit_candidate_staged_public?.should be_false
      app.chat_proposal_open_public?.should be_false
      app.active_editor_text_public.should eq(original)

      read_call = {
        "id"        => "parent-read-after-refusal",
        "name"      => "editor.read_buffer",
        "arguments" => {
          "buffer_id"  => context.buffer_id.not_nil!,
          "revision"   => context.revision.not_nil!,
          "start_line" => 1,
          "line_count" => 1,
        },
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("parent-read-after-refusal", read_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      read_result = JSON.parse(transport.handles.first.tool_results.last[1])
      read_result["status"].as_s.should eq("ok")
      read_result["data"]["lines"][0]["text"].as_s.should eq("const value = 1;")

      proposal_call = {
        "id"        => "parent-proposal-after-refusal",
        "name"      => "editor.propose_edits",
        "arguments" => {
          "buffer_id" => context.buffer_id.not_nil!,
          "revision"  => context.revision.not_nil!,
          "edits"     => [{
            "start_line"   => 1,
            "start_column" => 14,
            "end_line"     => 1,
            "end_column"   => 15,
            "new_text"     => "42",
          }],
        },
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("parent-proposal-after-refusal", proposal_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      proposal_result = JSON.parse(transport.handles.first.tool_results.last[1])
      proposal_result["status"].as_s.should eq("denied")
      app.chat_edit_candidate_staged_public?.should be_false

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_frontend_active_public?.should be_false
      app.chat_proposal_open_public?.should be_false
      app.active_editor_text_public.should eq(original)
    end
  end

  it "runs a selection-scoped Lua read and keeps its proposal private until successful Complete and manual acceptance" do
    worker = ENV["ADAMANTINE_LUA_WORKER"]? || raise "ADAMANTINE_LUA_WORKER is required for real Chat Lua App tests"
    library = ENV["ADAMANTINE_LUA_LIBRARY"]? || raise "ADAMANTINE_LUA_LIBRARY is required for real Chat Lua App tests"
    runner = RecordingChatLuaRunner.new(worker, library)
    transport = ChatLuaAppProbeTransport.new
    script_source = String.build do |script|
      script << "local context=editor.context\n"
      script << "assert(context.mode == \"selection_proposals\" and context.scope == \"selection\")\n"
      script << "assert(context.source_path == \"fixture.cr\")\n"
      script << "local range=context.source_range\n"
      script << "assert(range.start_line == 2 and range.start_column == 0 and range.end_line == 2 and range.end_column == 8)\n"
      script << "assert(context.selected_buffer ~= nil)\n"
      script << "local selected=context.selected_buffer\n"
      script << "local page=editor.call(\"editor.read_buffer\",{buffer_id=selected.buffer_id,revision=selected.revision,start_line=1,start_column=0,line_count=3,max_columns=64})\n"
      script << "assert(page.status == \"ok\" and page.data.complete and not page.data.partial)\n"
      script << "assert(#page.data.lines == 1 and page.data.continuation == nil)\n"
      script << "local row=page.data.lines[1]\n"
      script << "assert(row.line == 2 and row.start_column == 0 and row.end_column == 8)\n"
      script << "assert(row.text == \"TARGET=1\" and row.complete and not row.newline_after)\n"
      script << "local proposal=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=2,start_column=0,end_line=2,end_column=8,new_text=\"TARGET=2\"}}})\n"
      script << "assert(proposal.status == \"ok\" and proposal.data.status == \"pending_review\")\n"
      script << "print(\"ONLY_SELECTED_ROW=\" .. row.text)\n"
    end
    setup = ->(root : Path) {
      lua_root = root / "user-lua"
      Dir.mkdir_p(lua_root / "scripts")
      File.write(lua_root / "scripts" / "selection.lua", script_source)
      File.write(lua_root / "manifest.json", {
        "version" => 1,
        "scripts" => [{
          "id"           => "selection-scope",
          "name"         => "Selection scope",
          "file"         => "selection.lua",
          "capabilities" => ["read_editor", "propose_edits"],
        }],
      }.to_json)
      nil
    }

    with_chat_lua_app(transport, setup, runner) do |app, root|
      source = root / "fixture.cr"
      original = "BEFORE_SENTINEL\nTARGET=1\nAFTER_SENTINEL\n"
      File.write(source, original)
      app.open_file_public(source).should be_true
      app.select_active_range_public(1, 0, 1, 8)
      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Selection proposals + Lua…")
      app.choose_palette_entry_public("Selection scope")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "read only the selected row and propose its replacement"
      app.chat_submit_public.should be_true
      app.chat_review_active_public?.should be_true
      review = app.chat_review_lines_public.join("\n")
      review.should contain("Selection scope: selection: 2:0")
      review.gsub(/\s+/, "").should contain("0-basedUnicodecodepointcolumns,end-exclusive")
      review.should contain("fixture.cr")
      app.on_capture(Tui::KeyEvent.new('y')).should be_true

      transport.requests.size.should eq(1)
      context = transport.requests.first.context
      context.mode.should eq(Adamantine::Chat::ContextMode::SelectionProposals)
      context.source_path.should eq("fixture.cr")
      context.source_range.should eq(Adamantine::Chat::SourceRange.new(2, 0, 2, 8))
      context.text.should eq("TARGET=1")
      context.lua_script_grant.should_not be_nil

      run_call = {
        "id"        => "selection-scope-run",
        "name"      => "lua.run_script",
        "arguments" => {"script_id" => "selection-scope"},
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("selection-scope-run", run_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_lua_worker_active_public?.should be_true
      app.chat_proposal_open_public?.should be_false
      app.active_editor_text_public.should eq(original)

      deadline = Time.instant + 5.seconds
      until transport.handles.first.tool_results.any? { |result| result[0] == "selection-scope-run" }
        raise "selection-scoped Lua read/proposal did not finish: #{app.status_text_public}" if Time.instant >= deadline
        app.on_capture(Tui::WakeupEvent.new)
        sleep 5.milliseconds
      end
      run_result = JSON.parse(transport.handles.first.tool_results.find { |result| result[0] == "selection-scope-run" }.not_nil![1])
      run_result["status"].as_s.should eq("ok")
      run_result["data"]["output"].as_s.should eq("ONLY_SELECTED_ROW=TARGET=1\n")
      runner.runs.size.should eq(1)
      runner.runs.first.reaped?.should be_true
      app.chat_lua_worker_active_public?.should be_false
      app.chat_edit_candidate_staged_public?.should be_true
      app.chat_proposal_open_public?.should be_false
      app.active_editor_text_public.should eq(original)

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true
      app.chat_edit_candidate_staged_public?.should be_false
      app.render_surface_public(100, 40)
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.status_text_public.should contain("Chat proposed edits accepted")
      app.active_editor_text_public.should eq("BEFORE_SENTINEL\nTARGET=2\nAFTER_SENTINEL\n")
      File.read(source).should eq(original)
      app.on_capture(Tui::KeyEvent.new('z', Tui::Modifiers::Ctrl)).should be_true
      app.active_editor_text_public.should eq(original)
    end
  end

  it "rejects a Lua mixed in-scope/out-of-scope edit batch without staging any part" do
    worker = ENV["ADAMANTINE_LUA_WORKER"]? || raise "ADAMANTINE_LUA_WORKER is required for real Chat Lua App tests"
    library = ENV["ADAMANTINE_LUA_LIBRARY"]? || raise "ADAMANTINE_LUA_LIBRARY is required for real Chat Lua App tests"
    runner = RecordingChatLuaRunner.new(worker, library)
    transport = ChatLuaAppProbeTransport.new
    script_source = String.build do |script|
      script << "local selected=editor.context.selected_buffer\n"
      script << "local result=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits={"
      script << "{start_line=2,start_column=0,end_line=2,end_column=8,new_text=\"TARGET=2\"},"
      script << "{start_line=1,start_column=0,end_line=1,end_column=1,new_text=\"X\"}}})\n"
      script << "assert(result.status == \"denied\")\n"
      script << "print(\"OUTSIDE_BATCH_DENIED\")\n"
    end
    setup = ->(root : Path) {
      lua_root = root / "user-lua"
      Dir.mkdir_p(lua_root / "scripts")
      File.write(lua_root / "scripts" / "outside-batch.lua", script_source)
      File.write(lua_root / "manifest.json", {
        "version" => 1,
        "scripts" => [{
          "id"           => "outside-batch",
          "name"         => "Outside batch",
          "file"         => "outside-batch.lua",
          "capabilities" => ["read_editor", "propose_edits"],
        }],
      }.to_json)
      nil
    }

    with_chat_lua_app(transport, setup, runner) do |app, root|
      source = root / "fixture.cr"
      original = "BEFORE_SENTINEL\nTARGET=1\nAFTER_SENTINEL\n"
      File.write(source, original)
      app.open_file_public(source).should be_true
      app.select_active_range_public(1, 0, 1, 8)
      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Selection proposals + Lua…")
      app.choose_palette_entry_public("Outside batch")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "try a mixed edit batch"
      app.chat_submit_public.should be_true
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      context = transport.requests.first.context
      context.mode.should eq(Adamantine::Chat::ContextMode::SelectionProposals)

      run_call = {
        "id"        => "outside-batch-run",
        "name"      => "lua.run_script",
        "arguments" => {"script_id" => "outside-batch"},
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("outside-batch-run", run_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true

      deadline = Time.instant + 5.seconds
      until transport.handles.first.tool_results.any? { |result| result[0] == "outside-batch-run" }
        raise "out-of-selection Lua proposal did not return: #{app.status_text_public}" if Time.instant >= deadline
        app.on_capture(Tui::WakeupEvent.new)
        sleep 5.milliseconds
      end
      run_result = JSON.parse(transport.handles.first.tool_results.find { |result| result[0] == "outside-batch-run" }.not_nil![1])
      run_result["status"].as_s.should_not eq("ok")
      run_result["message"].as_s.should contain("proposal is outside the approved selection")
      runner.runs.size.should eq(1)
      runner.runs.first.reaped?.should be_true
      app.chat_lua_child_flags_public.should eq({false, true})
      app.chat_edit_candidate_staged_public?.should be_false
      app.chat_proposal_open_public?.should be_false
      app.active_editor_text_public.should eq(original)
      File.read(source).should eq(original)
    end
  end

  it "counts a rejected direct selection proposal against a later Lua proposal in the same turn" do
    worker = ENV["ADAMANTINE_LUA_WORKER"]? || raise "ADAMANTINE_LUA_WORKER is required for real Chat Lua App tests"
    library = ENV["ADAMANTINE_LUA_LIBRARY"]? || raise "ADAMANTINE_LUA_LIBRARY is required for real Chat Lua App tests"
    runner = RecordingChatLuaRunner.new(worker, library)
    transport = ChatLuaAppProbeTransport.new
    script_source = String.build do |script|
      script << "local selected=editor.context.selected_buffer\n"
      script << "local proposal=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=2,start_column=0,end_line=2,end_column=8,new_text=\"TARGET=2\"}}})\n"
      script << "print(\"CHILD_VALID_PROPOSAL=\" .. proposal.status)\n"
    end
    setup = ->(root : Path) {
      lua_root = root / "user-lua"
      Dir.mkdir_p(lua_root / "scripts")
      File.write(lua_root / "scripts" / "second-proposal.lua", script_source)
      File.write(lua_root / "manifest.json", {
        "version" => 1,
        "scripts" => [{
          "id"           => "second-proposal",
          "name"         => "Second proposal",
          "file"         => "second-proposal.lua",
          "capabilities" => ["read_editor", "propose_edits"],
        }],
      }.to_json)
      nil
    }

    with_chat_lua_app(transport, setup, runner) do |app, root|
      source = root / "fixture.cr"
      original = "BEFORE_SENTINEL\nTARGET=1\nAFTER_SENTINEL\n"
      File.write(source, original)
      app.open_file_public(source).should be_true
      app.select_active_range_public(1, 0, 1, 8)
      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Selection proposals + Lua…")
      app.choose_palette_entry_public("Second proposal")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "propose only the selected row"
      app.chat_submit_public.should be_true
      app.on_capture(Tui::KeyEvent.new('y')).should be_true

      context = transport.requests.first.context
      context.mode.should eq(Adamantine::Chat::ContextMode::SelectionProposals)
      buffer_id = context.buffer_id || raise "approved buffer id was missing"
      revision = context.revision || raise "approved revision was missing"

      # This is a syntactically valid edit against the approved buffer and
      # revision, but it is outside the frozen selection. The frontend rejects
      # it before the App proposal backend can consume the host attempt ledger.
      rejected_direct_call = {
        "id"        => "rejected-direct-selection-proposal",
        "name"      => "editor.propose_edits",
        "arguments" => {
          "buffer_id" => buffer_id,
          "revision"  => revision,
          "edits"     => [{
            "start_line"   => 1,
            "start_column" => 0,
            "end_line"     => 1,
            "end_column"   => 1,
            "new_text"     => "X",
          }],
        },
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request(
        "rejected-direct-selection-proposal", rejected_direct_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      direct_result = JSON.parse(transport.handles.first.tool_results.last[1])
      direct_result["status"].as_s.should eq("denied")
      direct_result["message"].as_s.should contain("proposal is outside the approved selection")
      app.chat_edit_candidate_staged_public?.should be_false

      run_call = {
        "id"        => "second-proposal-run",
        "name"      => "lua.run_script",
        "arguments" => {"script_id" => "second-proposal"},
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("second-proposal-run", run_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true

      deadline = Time.instant + 5.seconds
      until transport.handles.first.tool_results.any? { |result| result[0] == "second-proposal-run" }
        raise "second selection proposal did not finish: #{app.status_text_public}" if Time.instant >= deadline
        app.on_capture(Tui::WakeupEvent.new)
        sleep 5.milliseconds
      end
      run_result = JSON.parse(transport.handles.first.tool_results.find { |result| result[0] == "second-proposal-run" }.not_nil![1])
      runner.runs.size.should eq(1)
      runner.runs.first.reaped?.should be_true
      child_flags = app.chat_lua_child_flags_public

      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true

      # Assert after parent Complete as well: a rejected first attempt must
      # poison the child proposal, not stage a candidate or produce a preview.
      {
        run_result["status"].as_s,
        child_flags,
        app.chat_edit_candidate_staged_public?,
        app.chat_proposal_open_public?,
        app.active_editor_text_public == original,
        File.read(source) == original,
      }.should eq({
        "denied",
        {false, true},
        false,
        false,
        true,
        true,
      })
    end
  end

  it "rejects a Lua run after selection changes away and back after Send approval" do
    worker = ENV["ADAMANTINE_LUA_WORKER"]? || raise "ADAMANTINE_LUA_WORKER is required for real Chat Lua App tests"
    library = ENV["ADAMANTINE_LUA_LIBRARY"]? || raise "ADAMANTINE_LUA_LIBRARY is required for real Chat Lua App tests"
    runner = RecordingChatLuaRunner.new(worker, library)
    transport = ChatLuaAppProbeTransport.new
    script_source = "print(\"MUST_NOT_RUN_AFTER_SELECTION_REVOCATION\")"
    setup = ->(root : Path) {
      lua_root = root / "user-lua"
      Dir.mkdir_p(lua_root / "scripts")
      File.write(lua_root / "scripts" / "stale-selection.lua", script_source)
      File.write(lua_root / "manifest.json", {
        "version" => 1,
        "scripts" => [{
          "id"           => "stale-selection",
          "name"         => "Stale selection",
          "file"         => "stale-selection.lua",
          "capabilities" => ["read_editor", "propose_edits"],
        }],
      }.to_json)
      nil
    }

    with_chat_lua_app(transport, setup, runner) do |app, root|
      source = root / "fixture.cr"
      original = "BEFORE_SENTINEL\nTARGET=1\nAFTER_SENTINEL\n"
      File.write(source, original)
      app.open_file_public(source).should be_true
      app.select_active_range_public(1, 0, 1, 8)
      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Selection proposals + Lua…")
      app.choose_palette_entry_public("Stale selection")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "run only while the approved selection remains current"
      app.chat_submit_public.should be_true
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      context = transport.requests.first.context
      context.source_range.should eq(Adamantine::Chat::SourceRange.new(2, 0, 2, 8))

      # Returning to the identical coordinates must not revive the approved
      # selection capability after the intervening observed range change.
      app.select_active_range_public(0, 0, 0, 6)
      app.select_active_range_public(1, 0, 1, 8)
      run_call = {
        "id"        => "stale-selection-run",
        "name"      => "lua.run_script",
        "arguments" => {"script_id" => "stale-selection"},
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("stale-selection-run", run_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true

      run_result = JSON.parse(transport.handles.first.tool_results.find { |result| result[0] == "stale-selection-run" }.not_nil![1])
      run_result["status"].as_s.should eq("stale")
      run_result["message"].as_s.should contain("tool session context changed")
      runner.runs.should be_empty
      app.chat_lua_worker_active_public?.should be_false
      app.chat_edit_candidate_staged_public?.should be_false
      app.chat_proposal_open_public?.should be_false
      app.active_editor_text_public.should eq(original)
      File.read(source).should eq(original)
    end
  end

  it "keeps a newer direct proposal when a retired child run drains its late terminal event" do
    worker = ENV["ADAMANTINE_LUA_WORKER"]? || raise "ADAMANTINE_LUA_WORKER is required for real Chat Lua App tests"
    library = ENV["ADAMANTINE_LUA_LIBRARY"]? || raise "ADAMANTINE_LUA_LIBRARY is required for real Chat Lua App tests"
    runner = Adamantine::LuaScripts::Runner.new(worker, library)
    transport = ChatLuaAppProbeTransport.new
    script_source = String.build do |script|
      script << "local selected=editor.context.selected_buffer\n"
      script << "local result=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=1,start_column=14,end_line=1,end_column=15,new_text=\"77\"}}})\n"
      script << "print(\"OLD_CHILD_PROPOSAL \"..result.status)\n"
      script << "while true do end\n"
    end
    setup = ->(root : Path) {
      lua_root = root / "user-lua"
      Dir.mkdir_p(lua_root / "scripts")
      File.write(lua_root / "scripts" / "old-child.lua", script_source)
      File.write(lua_root / "manifest.json", {
        "version" => 1,
        "scripts" => [{
          "id"           => "old-child",
          "name"         => "Old child",
          "file"         => "old-child.lua",
          "capabilities" => ["read_editor", "propose_edits"],
        }],
      }.to_json)
      nil
    }

    with_chat_lua_app(transport, setup, runner) do |app, root|
      source = root / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source, original)
      app.open_file_public(source).should be_true
      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Whole-file proposals + Lua…")
      app.choose_palette_entry_public("Old child")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "run the selected script"
      app.chat_submit_public.should be_true
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      transport.requests.size.should eq(1)

      run_call = {
        "id"        => "approved-run",
        "name"      => "lua.run_script",
        "arguments" => {"script_id" => "old-child"},
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("approved-run", run_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_lua_worker_active_public?.should be_true
      app.lua_execution_busy_public?.should be_true

      deadline = Time.instant + 3.seconds
      until app.chat_edit_candidate_staged_public?
        raise "child proposal did not stage: #{app.status_text_public}" if Time.instant >= deadline
        app.on_capture(Tui::WakeupEvent.new)
        sleep 5.milliseconds
      end
      app.chat_proposal_open_public?.should be_false
      app.active_editor_text_public.should eq(original)

      app.chat_cancel_action.should be_true
      app.chat_edit_candidate_staged_public?.should be_false
      app.chat_lua_worker_active_public?.should be_true
      app.lua_execution_busy_public?.should be_true
      # Cancellation is asynchronous: the old exact Run remains owned while a
      # fresh, non-Lua Chat proposal turn is allowed to make progress.
      app.chat_lua_run_reaped_public?.should be_false

      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Whole-file proposals")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "replace the value in a new turn"
      app.chat_submit_public.should be_true
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      transport.requests.size.should eq(2)
      new_request = transport.requests.last
      context = new_request.context
      context.mode.should eq(Adamantine::Chat::ContextMode::BufferProposals)
      context.lua_script_grant.should be_nil

      new_call = {
        "id"        => "new-direct-proposal",
        "name"      => "editor.propose_edits",
        "arguments" => {
          "buffer_id" => context.buffer_id.not_nil!,
          "revision"  => context.revision.not_nil!,
          "edits"     => [{
            "start_line"   => 1,
            "start_column" => 14,
            "end_line"     => 1,
            "end_column"   => 15,
            "new_text"     => "42",
          }],
        },
      }.to_json
      transport.emit(1, Adamantine::Chat::Event.tool_request("new-direct-proposal", new_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      result = JSON.parse(transport.handles.last.tool_results.last[1])
      result["status"].as_s.should eq("ok")
      result["data"]["status"].as_s.should eq("pending_review")
      app.chat_edit_candidate_staged_public?.should be_true
      app.active_editor_text_public.should eq(original)

      deadline = Time.instant + 3.seconds
      while app.lua_execution_busy_public?
        raise "retired child terminal was not drained: #{app.status_text_public}" if Time.instant >= deadline
        app.on_capture(Tui::WakeupEvent.new)
        sleep 5.milliseconds
      end
      app.chat_lua_worker_active_public?.should be_false
      app.chat_lua_child_flags_public.should eq({false, false})
      app.chat_edit_candidate_staged_public?.should be_true

      transport.emit(1, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true
    end
  end

  it "retires Chat Lua across a project-root change without touching a new-root proposal" do
    worker = ENV["ADAMANTINE_LUA_WORKER"]? || raise "ADAMANTINE_LUA_WORKER is required for real Chat Lua App tests"
    library = ENV["ADAMANTINE_LUA_LIBRARY"]? || raise "ADAMANTINE_LUA_LIBRARY is required for real Chat Lua App tests"
    runner = Adamantine::LuaScripts::Runner.new(worker, library)
    transport = ChatLuaAppProbeTransport.new
    script_source = String.build do |script|
      script << "local selected=editor.context.selected_buffer\n"
      script << "local result=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=1,start_column=14,end_line=1,end_column=15,new_text=\"77\"}}})\n"
      script << "print(\"ROOT_CHANGE_CHILD_PROPOSAL \"..result.status)\n"
      script << "while true do end\n"
    end
    setup = ->(root : Path) {
      lua_root = root / "user-lua"
      Dir.mkdir_p(lua_root / "scripts")
      File.write(lua_root / "scripts" / "root-change.lua", script_source)
      File.write(lua_root / "manifest.json", {
        "version" => 1,
        "scripts" => [{
          "id"           => "root-change",
          "name"         => "Root change",
          "file"         => "root-change.lua",
          "capabilities" => ["read_editor", "propose_edits"],
        }],
      }.to_json)
      nil
    }

    with_chat_lua_app(transport, setup, runner) do |app, root|
      original = "const value = 1;\n"
      old_source = root / "old-fixture.cr"
      File.write(old_source, original)
      app.open_file_public(old_source).should be_true
      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Whole-file proposals + Lua…")
      app.choose_palette_entry_public("Root change")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "run the selected script"
      app.chat_submit_public.should be_true
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      transport.requests.size.should eq(1)

      run_call = {
        "id"        => "root-change-run",
        "name"      => "lua.run_script",
        "arguments" => {"script_id" => "root-change"},
      }.to_json
      transport.emit(0, Adamantine::Chat::Event.tool_request("root-change-run", run_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_lua_worker_active_public?.should be_true

      deadline = Time.instant + 3.seconds
      until app.chat_edit_candidate_staged_public?
        raise "child proposal did not stage before root switch: #{app.status_text_public}" if Time.instant >= deadline
        app.on_capture(Tui::WakeupEvent.new)
        sleep 5.milliseconds
      end
      app.active_editor_text_public.should eq(original)
      app.chat_lua_ticket_active_public?.should be_true
      app.chat_frontend_active_public?.should be_true

      new_root = root / "new-project"
      Dir.mkdir_p(new_root)
      app.run_command_public("cd #{new_root}")
      app.project_root_public.should eq(Path.new(File.realpath(new_root.to_s)))
      app.chat_frontend_active_public?.should be_false
      app.chat_lua_ticket_active_public?.should be_false
      transport.handles.first.cancelled.should be_true
      app.chat_edit_candidate_staged_public?.should be_false
      app.lua_execution_busy_public?.should be_true

      # Root retirement revokes the parent and proposal synchronously. The old
      # process/lease is still App-owned until its terminal event is drained.
      new_source = new_root / "new-fixture.cr"
      File.write(new_source, original)
      app.open_file_public(new_source).should be_true
      app.chat_focus_action.should be_true
      app.open_chat_context_public
      app.choose_chat_context_public("Whole-file proposals")
      app.chat_focus_action.should be_true
      app.chat_panel.composer.text = "replace the value in the new root"
      app.chat_submit_public.should be_true
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      transport.requests.size.should eq(2)
      new_request = transport.requests.last
      context = new_request.context
      context.mode.should eq(Adamantine::Chat::ContextMode::BufferProposals)
      context.lua_script_grant.should be_nil
      context.buffer_id.should_not eq(transport.requests.first.context.buffer_id)

      new_call = {
        "id"        => "new-root-direct-proposal",
        "name"      => "editor.propose_edits",
        "arguments" => {
          "buffer_id" => context.buffer_id.not_nil!,
          "revision"  => context.revision.not_nil!,
          "edits"     => [{
            "start_line"   => 1,
            "start_column" => 14,
            "end_line"     => 1,
            "end_column"   => 15,
            "new_text"     => "42",
          }],
        },
      }.to_json
      transport.emit(1, Adamantine::Chat::Event.tool_request("new-root-direct-proposal", new_call))
      app.on_capture(Tui::WakeupEvent.new).should be_true
      result = JSON.parse(transport.handles.last.tool_results.last[1])
      result["status"].as_s.should eq("ok")
      result["data"]["status"].as_s.should eq("pending_review")
      app.chat_edit_candidate_staged_public?.should be_true
      app.active_editor_text_public.should eq(original)

      deadline = Time.instant + 3.seconds
      while app.lua_execution_busy_public?
        raise "retired root-bound child terminal was not drained: #{app.status_text_public}" if Time.instant >= deadline
        app.on_capture(Tui::WakeupEvent.new)
        sleep 5.milliseconds
      end
      app.chat_lua_worker_active_public?.should be_false
      app.chat_lua_child_flags_public.should eq({false, false})
      app.chat_edit_candidate_staged_public?.should be_true
      app.project_root_public.should eq(Path.new(File.realpath(new_root.to_s)))

      transport.emit(1, Adamantine::Chat::Event.complete)
      app.on_capture(Tui::WakeupEvent.new).should be_true
      app.chat_proposal_open_public?.should be_true
    end
  end
end
