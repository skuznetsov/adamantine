require "spec"
require "file_utils"
require "random/secure"
require "crystal_tui"

require "../src/adamantine/app"

private class LuaAppProbeHandle < Adamantine::Chat::Handle
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

private class LuaAppProbeTransport < Adamantine::Chat::Transport
  getter requests : Array(Adamantine::Chat::Request)
  getter callbacks : Array(Proc(Adamantine::Chat::Event, Nil))
  getter handles : Array(LuaAppProbeHandle)

  def initialize
    @requests = [] of Adamantine::Chat::Request
    @callbacks = [] of Proc(Adamantine::Chat::Event, Nil)
    @handles = [] of LuaAppProbeHandle
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
    handle = LuaAppProbeHandle.new
    @handles << handle
    handle
  end

  def emit(index : Int32, event : Adamantine::Chat::Event) : Nil
    @callbacks[index].call(event)
  end
end

private class LuaScriptAppSpecApp < Adamantine::App
  def render_surface_public(width : Int32 = 100, height : Int32 = 30) : Tui::Buffer
    mount_headless(width, height)
    buffer = Tui::Buffer.new(width, height)
    render(buffer, Tui::Rect.new(0, 0, width, height))
    buffer
  end

  def open_command_palette_public : Nil
    open_command_palette("")
  end

  def command_titles_public : Array(String)
    @command_palette.candidates.map(&.title)
  end

  def close_test_resources : Nil
    quit(force: true)
    Tui::App.clear_overlays
    Tui::Widget.focused_widget = nil
  end

  def open_lua_review_public(entry : Adamantine::LuaScripts::Entry) : Nil
    open_lua_script_review(entry)
  end

  def press_lua_review_enter_public : Bool
    handle_lua_review_input(Tui::KeyEvent.new(Tui::Key::Enter))
  end

  def press_lua_review_escape_public : Bool
    handle_lua_review_input(Tui::KeyEvent.new(Tui::Key::Escape))
  end

  def lua_review_approvable_public? : Bool
    lua_script_review_approvable?
  end

  def lua_run_active_public? : Bool
    lua_script_active?
  end

  def current_lua_run_public : Adamantine::LuaScripts::Run?
    @lua_active_run.try(&.run)
  end

  def lua_session_closed_public? : Bool
    @lua_active_run.try { |active| active.session.try(&.closed?) == true } == true
  end

  def lua_execution_busy_public? : Bool
    lua_execution_busy?
  end

  def lua_review_active_public? : Bool
    lua_script_review_active?
  end

  def lua_proposal_open_public? : Bool
    @lsp_popup.lua_proposal_open?
  end

  def chat_proposal_open_public? : Bool
    @lsp_popup.chat_proposal_open?
  end

  def status_text_public : String
    @status_log.entries.map(&.message).join("\n")
  end

  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def active_buffer_id_public : String?
    active_buffer_internal.try { |buffer| editor_tool_buffer_reference(buffer).id }
  end

  def active_revision_public : String?
    active_buffer_internal.try do |buffer|
      reference = editor_tool_buffer_reference(buffer)
      reference.refresh_revision!
      reference.revision
    end
  end

  def active_editor_text_public : String?
    active_editor_internal.as?(Adamantine::EditingTextEditor).try(&.text)
  end

  def active_editing_editor_public : Adamantine::EditingTextEditor?
    active_editor_internal.as?(Adamantine::EditingTextEditor)
  end

  def split_right_public : Bool
    split_editor_right
  end

  def active_editor_group_public : Int32
    @active_editor_group
  end

  def buffer_open_public?(path : Path) : Bool
    @document_session.open_buffers.has_key?(path.to_s)
  end

  def chat_input_mode_public : String
    active_input_mode.to_s
  end

  def chat_popup_title_public : String
    @lsp_popup.title
  end

  def chat_composer_public : Adamantine::Chat::Composer
    @chat_panel.not_nil!.composer
  end

  def retire_editor_tools_context_public : Nil
    retire_editor_tools_context
  end

  def project_root_public : Path
    @project_root
  end

  def lua_picker_public : Nil
    open_lua_script_picker
  end

  def select_lua_script_public(id : String) : Nil
    select_lua_script(id)
  end

  def on_lua_wakeup_public : Nil
    on_capture(Tui::WakeupEvent.new)
  end

  def clear_queued_events_public : Nil
    loop do
      break unless pop_queued_event_public
    end
  end

  def fill_event_queue_with_keys_public(count : Int32) : Nil
    events = @input.events
    count.times do
      select
      when events.send(Tui::KeyEvent.new('x'))
      else
        raise "could not fill the App input event queue"
      end
    end
  end

  def pop_queued_event_public : Tui::Event?
    events = @input.events
    select
    when event = events.receive
      event
    else
      nil
    end
  end

  def lua_cancel_public : Nil
    cancel_lua_script_action
  end

  def chat_focus_public : Bool
    chat_focus_action
  end

  def chat_submit_public : Bool
    chat_submit_action
  end

  def chat_review_active_public? : Bool
    chat_review_active?
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
end

describe "App Lua script discovery" do
  it "offers an explicit Run Lua script entry in F1 discovery" do
    Tui::App.clear_overlays
    Tui::Widget.focused_widget = nil
    root = Path.new(File.realpath(Dir.tempdir), "adamantine-lua-app-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    app = LuaScriptAppSpecApp.new(
      project_root: root,
      lsp_command: "",
      session_enabled: false,
      recovery_root: root / "recovery",
      clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new
    )

    app.open_command_palette_public
    app.command_titles_public.should contain("Run Lua script…")
  ensure
    app.try &.close_test_resources
    Tui::App.clear_overlays
    Tui::Widget.focused_widget = nil
    FileUtils.rm_rf(root) if root
  end
end

describe "Lua script review viewport" do
  it "wraps every permission and limit disclosure and refuses Enter when clipped" do
    Tui::App.clear_overlays
    Tui::Widget.focused_widget = nil
    root = Path.new(File.realpath(Dir.tempdir), "adamantine-lua-review-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)
    app = LuaScriptAppSpecApp.new(
      project_root: root,
      lsp_command: "",
      session_enabled: false,
      recovery_root: root / "recovery",
      clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new
    )
    source = root / "fixture.cr"
    File.write(source, "const value = 1;\n")
    app.open_file_public(source).should be_true
    entry = Adamantine::LuaScripts::Entry.new(
      "long-review-fixture",
      "Fixture " + "x" * 120,
      "print('never started')",
      [
        Adamantine::EditorTools::Capability::ReadEditor,
        Adamantine::EditorTools::Capability::ReadDebugger,
        Adamantine::EditorTools::Capability::Navigate,
        Adamantine::EditorTools::Capability::ProposeEdits,
      ],
      false
    )
    app.open_lua_review_public(entry)

    narrow = app.render_surface_public(42, 12)
    text = lua_script_app_surface_text(narrow)
    text.should contain("Resize to review all")
    text.should contain("Esc: cancel")
    app.press_lua_review_enter_public.should be_true
    app.lua_review_active_public?.should be_true
    app.lua_run_active_public?.should be_false

    # This has the minimum drawable modal geometry, but the four capability
    # disclosures and all limits must still fit before Enter becomes valid.
    boundary = app.render_surface_public(44, 12)
    boundary_text = lua_script_app_surface_text(boundary)
    boundary_text.should contain("Source SHA-256:")
    boundary_text.should contain("Resize to review all | Esc: cancel")
    boundary_text.should_not contain("ReadEditor: bounded shared buffer/list/search reads")
    app.press_lua_review_enter_public.should be_true
    app.lua_run_active_public?.should be_false

    wide = app.render_surface_public(60, 30)
    wide_text = lua_script_app_surface_text(wide)
    wide_text.should contain("Source SHA-256:")
    wide_text.should contain("ReadEditor: bounded shared buffer/list/search reads")
    wide_text.should contain("ReadDebugger: bounded debugger snapshot reads")
    # Disclosures are wrapped at the rendered content width, not clipped at
    # the right border. Verify both halves of the long Navigate disclosure.
    wide_text.should contain("Navigate: open/focus files and buffers inside the pr")
    wide_text.should contain("oject")
    wide_text.should contain("ProposeEdits: one proposal attempt; explicit inline")
    wide_text.should contain("review only")
    wide_text.should contain("Runtime limits: 5 s wall time")
    wide_text.should contain("Editor results: 64 KiB/call")
    wide_text.should contain("Enter: run once | Esc: cancel")
    app.lua_review_approvable_public?.should be_true
    # Keep this viewport-only test deterministic when a real worker is
    # configured for the suite; actual approval/run is covered by runtime specs.
    app.lua_run_active_public?.should be_false

    app.press_lua_review_escape_public.should be_true
    no_capabilities = Adamantine::LuaScripts::Entry.new(
      "no-capabilities",
      "No capabilities fixture",
      "print('fixture')",
      [] of Adamantine::EditorTools::Capability,
      false
    )
    app.open_lua_review_public(no_capabilities)
    no_capabilities_text = lua_script_app_surface_text(app.render_surface_public(120, 30))
    no_capabilities_text.should contain("Requested capabilities: none")
    no_capabilities_text.should contain("Enter: run once | Esc: cancel")
    app.lua_review_approvable_public?.should be_true
    app.press_lua_review_escape_public.should be_true
    app.lua_review_active_public?.should be_false
  ensure
    app.try &.close_test_resources
    Tui::App.clear_overlays
    Tui::Widget.focused_widget = nil
    FileUtils.rm_rf(root) if root
  end
end

private def lua_script_app_surface_text(buffer : Tui::Buffer) : String
  (0...buffer.height).map do |y|
    (0...buffer.width).map { |x| buffer.get(x, y).glyph }.join
  end.join("\n")
end

private def with_lua_runtime_app(
  transport : LuaAppProbeTransport? = nil,
  chat_enabled : Bool = false,
  wall_time : Time::Span = 5.seconds,
  &
)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-lua-runtime-app-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  config_path = root / "settings.json"
  chat_json = if chat_enabled
                %({"chat":{"enabled":true,"endpoint":"https://example.test/v1/chat/completions","model":"explicit-test-model","key_env":"CHAT_EDIT_TEST_KEY","max_completion_tokens":256}})
              else
                %({"chat":{"enabled":false}})
              end
  File.write(config_path, chat_json)
  worker = ENV["ADAMANTINE_LUA_WORKER"]? || raise "ADAMANTINE_LUA_WORKER is required for real Lua App tests"
  library = ENV["ADAMANTINE_LUA_LIBRARY"]? || raise "ADAMANTINE_LUA_LIBRARY is required for real Lua App tests"
  runner = Adamantine::LuaScripts::Runner.new(
    worker,
    library,
    Adamantine::LuaScripts::Limits.new(wall_time: wall_time)
  )
  app = LuaScriptAppSpecApp.new(
    project_root: root,
    lsp_command: "",
    keymap_path: config_path.to_s,
    session_enabled: false,
    recovery_root: root / "recovery",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    chat_transport: transport,
    lua_script_catalog: Adamantine::LuaScripts::Catalog.new(config_root: root / "user-lua"),
    lua_script_runner: runner
  )
  app.render_surface_public
  yield app, root
ensure
  app.try &.close_test_resources
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(root) if root
end

private def lua_proposal_source(replacement : String, tail : String = "") : String
  String.build do |source|
    source << "local selected=editor.context.selected_buffer\n"
    source << "local result=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=1,start_column=14,end_line=1,end_column=15,new_text="
    source << replacement.to_json
    source << "}}})\n"
    source << "print(\"LUA_PROPOSAL_RESULT \"..result.status..\"/\"..result.data.status)\n"
    source << tail
  end
end

private def start_lua_entry(app : LuaScriptAppSpecApp,
                            id : String, name : String, source : String,
                            capabilities : Array(Adamantine::EditorTools::Capability)) : Nil
  entry = Adamantine::LuaScripts::Entry.new(id, name, source, capabilities, false)
  app.open_lua_review_public(entry)
  app.lua_review_approvable_public?.should be_true
  app.press_lua_review_enter_public.should be_true
  app.lua_run_active_public?.should be_true
end

private def pump_lua_app_until(app : LuaScriptAppSpecApp,
                               timeout : Time::Span = 3.seconds,
                               &condition : -> Bool) : Nil
  deadline = Time.instant + timeout
  until condition.call
    raise "timed out waiting for Lua App state: #{app.status_text_public}" if Time.instant >= deadline
    app.on_lua_wakeup_public
    sleep 5.milliseconds
  end
end

private def lua_proposal_capabilities : Array(Adamantine::EditorTools::Capability)
  [Adamantine::EditorTools::Capability::ProposeEdits]
end

describe "real Lua App lifecycle and manual proposals" do
  it "retries the terminal owner wakeup after a full input queue drains" do
    with_lua_runtime_app do |app, _root|
      app.clear_queued_events_public
      app.fill_event_queue_with_keys_public(32)

      start_lua_entry(app, "full-wakeup-queue", "Fixture full wakeup queue", "print(\"FULL_QUEUE_SCRIPT_DONE\")",
        [] of Adamantine::EditorTools::Capability)
      run = app.current_lua_run_public || raise "Lua run was not captured"
      deadline = Time.instant + 3.seconds
      until run.reaped?
        raise "Lua worker did not reap: #{app.status_text_public}" if Time.instant >= deadline
        sleep 2.milliseconds
      end
      # Let the terminal branch attempt a Wakeup while all 32 slots remain
      # occupied. The owner has not consumed or dispatched any queued event.
      sleep 25.milliseconds
      app.lua_run_active_public?.should be_true

      wakeup = nil.as(Tui::Event?)
      wake_deadline = Time.instant + 500.milliseconds
      until wakeup
        raise "terminal Lua owner wakeup was not retried" if Time.instant >= wake_deadline
        event = app.pop_queued_event_public
        if event
          if event.is_a?(Tui::WakeupEvent)
            wakeup = event
          else
            event.should be_a(Tui::KeyEvent)
          end
        else
          # Drain key events without sleeping per slot. The timeout measures
          # delivery after queue space exists, not the cost of 32 timer wakes.
          Fiber.yield
        end
      end
      app.on_capture(wakeup.not_nil!).should be_true
      app.lua_run_active_public?.should be_false
      app.status_text_public.should contain("Lua script complete: Fixture full wakeup queue")
    end
  end

  it "publishes a proposal only after reaped success and keeps acceptance undoable and unsaved" do
    with_lua_runtime_app do |app, root|
      source_path = root / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true
      app.active_editor_text_public.should_not be_nil

      start_lua_entry(app, "successful-proposal", "Fixture successful proposal",
        lua_proposal_source("42", "print(\"LUA_SUCCESS_SENTINEL\")"), lua_proposal_capabilities)
      pump_lua_app_until(app, 4.seconds) do
        !app.lua_run_active_public? && app.status_text_public.includes?("Lua script complete: Fixture successful proposal")
      end
      app.status_text_public.should contain("LUA_SUCCESS_SENTINEL")
      app.lua_proposal_open_public?.should be_true
      app.chat_popup_title_public.should eq("Lua script proposed edits")
      app.active_editor_text_public.should eq(original)
      File.read(source_path).should eq(original)

      # The real App's render pass synchronizes the editor rect consumed by
      # the manual acceptance guard. As in the Chat preview integration,
      # render before sending the user's acceptance gesture.
      app.render_surface_public
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Enter)).should be_true
      app.status_text_public.should contain("Lua proposed edits accepted")
      app.active_editor_text_public.should eq("const value = 42;\n")
      File.read(source_path).should eq(original)
      app.lua_proposal_open_public?.should be_false
      app.on_capture(Tui::KeyEvent.new('z', Tui::Modifiers::Ctrl)).should be_true
      app.active_editor_text_public.should eq(original)
      File.read(source_path).should eq(original)
    end
  end

  it "discards a staged Lua proposal if the script errors before successful reaping" do
    with_lua_runtime_app do |app, root|
      source_path = root / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true

      start_lua_entry(app, "failed-proposal", "Fixture failed proposal",
        lua_proposal_source("99", "error(\"intentional Lua failure diagnostic\")"), lua_proposal_capabilities)
      pump_lua_app_until(app, 4.seconds) do
        !app.lua_run_active_public? &&
          app.status_text_public.includes?("LUA_PROPOSAL_RESULT ok/pending_review") &&
          app.status_text_public.includes?("(script_error)")
      end
      app.status_text_public.should contain("LUA_PROPOSAL_RESULT ok/pending_review")
      app.status_text_public.should contain("intentional Lua failure diagnostic")
      app.lua_proposal_open_public?.should be_false
      app.chat_proposal_open_public?.should be_false
      app.active_editor_text_public.should_not be_nil
      app.active_editor_text_public.not_nil!.should eq(original)
      File.read(source_path).should eq(original)
    end
  end

  it "revokes and reaps a staged proposal on explicit cancellation" do
    with_lua_runtime_app do |app, root|
      source_path = root / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true

      start_lua_entry(app, "cancelled-proposal", "Fixture cancelled proposal",
        lua_proposal_source("88", "while true do end"), lua_proposal_capabilities)
      run = app.current_lua_run_public || raise "Lua run was not captured"
      pump_lua_app_until(app, 2.seconds) do
        app.status_text_public.includes?("LUA_PROPOSAL_RESULT ok/pending_review")
      end
      run.active?.should be_true
      app.lua_cancel_public
      run.reaped?.should be_true
      app.lua_session_closed_public?.should be_true
      # Authority is revoked synchronously, but the App-owned run/lease stays
      # live until its terminal event has also been drained by the owner.
      app.lua_run_active_public?.should be_true
      app.lua_execution_busy_public?.should be_true
      pump_lua_app_until(app, 2.seconds) do
        !app.lua_run_active_public? && !app.lua_execution_busy_public?
      end
      app.status_text_public.should contain("Lua script cancelled: Fixture cancelled proposal")
      app.lua_proposal_open_public?.should be_false
      app.active_editor_text_public.not_nil!.should eq(original)
      File.read(source_path).should eq(original)
    end
  end

  it "consumes the one proposal attempt even when the second attempt is denied" do
    with_lua_runtime_app do |app, root|
      source_path = root / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true
      duplicate_attempt = String.build do |source|
        source << "local selected=editor.context.selected_buffer\n"
        source << "local args={buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=1,start_column=14,end_line=1,end_column=15,new_text=\"42\"}}}\n"
        source << "local first=editor.call(\"editor.propose_edits\",args)\n"
        source << "print(\"FIRST_PROPOSAL_STATUS \"..first.status..\"/\"..first.data.status)\n"
        source << "local second=editor.call(\"editor.propose_edits\",args)\n"
        source << "print(\"SECOND_PROPOSAL_STATUS \"..second.status)\n"
      end
      start_lua_entry(app, "one-attempt", "Fixture one attempt", duplicate_attempt, lua_proposal_capabilities)
      pump_lua_app_until(app, 4.seconds) do
        !app.lua_run_active_public? && app.status_text_public.includes?("Lua script complete: Fixture one attempt")
      end
      app.status_text_public.should contain("SECOND_PROPOSAL_STATUS denied")
      app.status_text_public.should contain("FIRST_PROPOSAL_STATUS ok/pending_review")
      app.lua_proposal_open_public?.should be_true
      app.active_editor_text_public.not_nil!.should eq(original)
      File.read(source_path).should eq(original)
    end
  end

  it "consumes the proposal attempt when the first typed proposal has an invalid range" do
    with_lua_runtime_app do |app, root|
      source_path = root / "invalid-first-attempt.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true
      invalid_then_valid_attempt = String.build do |source|
        source << "local selected=editor.context.selected_buffer\n"
        # Line 2 is schema-valid, but outside this one-line buffer. This
        # reaches host proposal validation instead of the parser's terminal
        # limit handling for out-of-contract integers such as line 0.
        source << "local invalid={buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=2,start_column=14,end_line=2,end_column=15,new_text=\"42\"}}}\n"
        source << "local first=editor.call(\"editor.propose_edits\",invalid)\n"
        source << "print(\"FIRST_INVALID_PROPOSAL_STATUS \"..first.status)\n"
        source << "local valid={buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=1,start_column=14,end_line=1,end_column=15,new_text=\"42\"}}}\n"
        source << "local second=editor.call(\"editor.propose_edits\",valid)\n"
        source << "print(\"SECOND_VALID_PROPOSAL_STATUS \"..second.status)\n"
      end
      start_lua_entry(app, "invalid-first-attempt", "Fixture invalid first attempt",
        invalid_then_valid_attempt, lua_proposal_capabilities)
      pump_lua_app_until(app, 4.seconds) do
        !app.lua_run_active_public? &&
          app.status_text_public.includes?("Lua script complete: Fixture invalid first attempt")
      end
      app.status_text_public.should contain("FIRST_INVALID_PROPOSAL_STATUS invalid_request")
      app.status_text_public.should contain("SECOND_VALID_PROPOSAL_STATUS denied")
      app.lua_proposal_open_public?.should be_false
      app.active_editor_text_public.not_nil!.should eq(original)
      File.read(source_path).should eq(original)
    end
  end

  it "discards a staged proposal when the EditorTools session quota is exhausted" do
    with_lua_runtime_app do |app, root|
      source_path = root / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true
      source = String.build do |script|
        script << "local selected=editor.context.selected_buffer\n"
        script << "local result=editor.call(\"editor.propose_edits\",{buffer_id=selected.buffer_id,revision=selected.revision,edits={{start_line=1,start_column=14,end_line=1,end_column=15,new_text=\"43\"}}})\n"
        script << "print(\"QUOTA_PROPOSAL_STAGED \"..result.status..\"/\"..result.data.status)\n"
        # The worker frame accepts this request, but the host's 8 KiB
        # EditorTools request bound returns LimitExceeded and must terminate
        # the run even though Lua would otherwise ignore the result.
        script << "editor.call(\"editor.list_buffers\",{padding=string.rep(\"x\",9000)})\n"
        script << "print(\"QUOTA_SCRIPT_SHOULD_NOT_COMPLETE\")\n"
      end
      start_lua_entry(app, "quota-after-proposal", "Fixture quota after proposal", source,
        [Adamantine::EditorTools::Capability::ReadEditor, Adamantine::EditorTools::Capability::ProposeEdits])
      run = app.current_lua_run_public || raise "Lua run was not captured"
      pump_lua_app_until(app, 5.seconds) { run.reaped? && !app.lua_run_active_public? }
      app.status_text_public.should contain("QUOTA_PROPOSAL_STAGED ok/pending_review")
      app.status_text_public.should contain("editor_tools_limit_exceeded")
      app.status_text_public.should_not contain("QUOTA_SCRIPT_SHOULD_NOT_COMPLETE")
      app.lua_proposal_open_public?.should be_false
      app.active_editor_text_public.not_nil!.should eq(original)
      File.read(source_path).should eq(original)
    end
  end

  it "does not revive a proposal after an edit then Undo restores the same text" do
    with_lua_runtime_app do |app, root|
      source_path = root / "aba.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true
      start_lua_entry(app, "proposal-aba", "Fixture proposal ABA",
        lua_proposal_source("44"), lua_proposal_capabilities)
      pump_lua_app_until(app, 4.seconds) do
        !app.lua_run_active_public? && app.lua_proposal_open_public?
      end
      editor = app.active_editing_editor_public || raise "selected editor unavailable"
      editor.text.should eq(original)
      editor.insert_text("temporary mutation")
      app.lua_proposal_open_public?.should be_false
      editor.undo.should be_true
      editor.text.should eq(original)
      app.lua_proposal_open_public?.should be_false
      app.status_text_public.should contain("source buffer changed")
      File.read(source_path).should eq(original)
    end
  end

  it "revokes a published proposal when the selected editor view changes" do
    with_lua_runtime_app do |app, root|
      source_path = root / "view-change.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true
      start_lua_entry(app, "proposal-view", "Fixture proposal view", lua_proposal_source("45"), lua_proposal_capabilities)
      pump_lua_app_until(app, 4.seconds) do
        !app.lua_run_active_public? && app.lua_proposal_open_public?
      end
      app.active_editor_group_public.should eq(0)
      app.split_right_public.should be_true
      app.active_editor_group_public.should eq(1)
      app.lua_proposal_open_public?.should be_false
      File.read(source_path).should eq(original)
    end
  end

  it "revokes a published proposal when its project context is retired" do
    with_lua_runtime_app do |app, root|
      source_path = root / "root-change.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true
      start_lua_entry(app, "proposal-root", "Fixture proposal root", lua_proposal_source("46"), lua_proposal_capabilities)
      pump_lua_app_until(app, 4.seconds) do
        !app.lua_run_active_public? && app.lua_proposal_open_public?
      end
      app.retire_editor_tools_context_public
      app.lua_proposal_open_public?.should be_false
      app.active_editor_text_public.not_nil!.should eq(original)
      File.read(source_path).should eq(original)
    end
  end

  it "does not let a failed Lua proposal steal a concurrent Chat completion or preview" do
    transport = LuaAppProbeTransport.new
    with_lua_runtime_app(transport, chat_enabled: true, wall_time: 1.5.seconds) do |app, root|
      source_path = root / "fixture.cr"
      original = "const value = 1;\n"
      File.write(source_path, original)
      app.open_file_public(source_path).should be_true
      app.chat_focus_public.should be_true
      app.choose_chat_context_public("Whole-file proposals")
      app.chat_focus_public.should be_true
      app.chat_composer_public.text = "replace the number"
      app.chat_submit_public.should be_true
      app.chat_review_active_public?.should be_true
      app.render_surface_public
      app.on_capture(Tui::KeyEvent.new('y')).should be_true
      transport.requests.size.should eq(1)

      start_lua_entry(app, "overlap-failure", "Fixture overlap failure",
        lua_proposal_source("77", "print(\"LUA_OVERLAP_STAGED\"); while true do end"), lua_proposal_capabilities)
      run = app.current_lua_run_public || raise "Lua run was not captured"
      pump_lua_app_until(app, 1.second) do
        app.status_text_public.includes?("LUA_PROPOSAL_RESULT ok/pending_review") &&
          app.status_text_public.includes?("LUA_OVERLAP_STAGED")
      end
      app.lua_run_active_public?.should be_true

      context = transport.requests.first.context
      raise "Chat context omitted selected buffer identity" unless context.buffer_id && context.revision
      chat_request = {
        "id"        => "concurrent-chat-proposal",
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
      transport.emit(0, Adamantine::Chat::Event.tool_request("concurrent-chat-proposal", chat_request))
      app.on_lua_wakeup_public
      transport.handles.first.tool_results.last[0].should eq("concurrent-chat-proposal")
      transport.emit(0, Adamantine::Chat::Event.complete)
      app.on_lua_wakeup_public
      app.chat_proposal_open_public?.should be_true
      app.chat_popup_title_public.should eq("Chat proposed edits · manual review")
      app.active_editor_text_public.not_nil!.should eq(original)

      pump_lua_app_until(app, 3.seconds) do
        run.reaped? && !app.lua_run_active_public?
      end
      app.status_text_public.should contain("Lua script failed: Fixture overlap failure")
      app.status_text_public.should contain("(wall_time_limit)")
      app.lua_proposal_open_public?.should be_false
      app.chat_proposal_open_public?.should be_true
      app.chat_popup_title_public.should eq("Chat proposed edits · manual review")
      app.active_editor_text_public.not_nil!.should eq(original)
    end
  end

  it "revokes a Lua open_file permit during a multi-chunk read before tab commit" do
    with_lua_runtime_app do |app, root|
      target = root / "multi-chunk.cr"
      File.write(target, "x" * (Adamantine::FileRevision::DEFAULT_CHUNK_SIZE * 4 + 1))
      start_lua_entry(app, "yielding-open", "Fixture yielding open",
        "local result=editor.call(\"editor.open_file\",{path=\"multi-chunk.cr\"}); print(\"OPEN_RESULT \"..result.status)",
        [Adamantine::EditorTools::Capability::Navigate])
      run = app.current_lua_run_public || raise "Lua run was not captured"
      deadline = Time.instant + 2.seconds
      until run.events_pending?
        raise "Lua open_file RPC was not queued" if Time.instant >= deadline
        sleep 2.milliseconds
      end

      # The first document read chunk yields. Cancel from another fiber at
      # that boundary so the live ExecutionPermit is false at tab commit.
      spawn do
        Fiber.yield
        run.cancel
      end
      app.on_lua_wakeup_public
      app.buffer_open_public?(target).should be_false
      pump_lua_app_until(app, 3.seconds) { run.reaped? && !app.lua_run_active_public? }
      app.buffer_open_public?(target).should be_false
      app.status_text_public.should contain("Lua script cancelled: Fixture yielding open")
    end
  end

  it "retires and observes child reaping on project-context retirement and App quit" do
    with_lua_runtime_app do |app, _root|
      start_lua_entry(app, "root-retired", "Fixture root retired", "print(\"ROOT_RETIRE_STARTED\"); while true do end",
        [] of Adamantine::EditorTools::Capability)
      root_run = app.current_lua_run_public || raise "Lua run was not captured"
      pump_lua_app_until(app, 2.seconds) { app.status_text_public.includes?("ROOT_RETIRE_STARTED") }
      app.retire_editor_tools_context_public
      root_run.reaped?.should be_true
      app.lua_session_closed_public?.should be_true
      app.lua_run_active_public?.should be_true
      app.lua_execution_busy_public?.should be_true
      pump_lua_app_until(app, 2.seconds) do
        !app.lua_run_active_public? && !app.lua_execution_busy_public?
      end

      start_lua_entry(app, "quit-retired", "Fixture quit retired", "print(\"QUIT_RETIRE_STARTED\"); while true do end",
        [] of Adamantine::EditorTools::Capability)
      quit_run = app.current_lua_run_public || raise "Lua run was not captured"
      pump_lua_app_until(app, 2.seconds) { app.status_text_public.includes?("QUIT_RETIRE_STARTED") }
      app.quit(force: true)
      quit_run.reaped?.should be_true
      app.lua_session_closed_public?.should be_true
      app.lua_run_active_public?.should be_true
      app.lua_execution_busy_public?.should be_true
      # App shutdown stops retrying owner wakeups. If a pending terminal wakeup
      # is delivered, the normal owner drain still releases only this run's
      # lease after observing both terminal state and reap.
      app.on_lua_wakeup_public
      app.lua_run_active_public?.should be_false
      app.lua_execution_busy_public?.should be_false
    end
  end
end
