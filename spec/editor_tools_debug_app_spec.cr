require "spec"
require "file_utils"
require "json"
require "random/secure"
require "crystal_tui"
require "./support/debugger_fixture_support"

require "../src/adamantine/app"

private class EditorToolsDebugAppSpecApp < Adamantine::App
  def stop_debug_polling_public : Nil
    stop_debug_polling
  end
end

private def with_editor_tools_debug_app_workspace(&)
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  workspace = Path.new(File.realpath(Dir.tempdir), "adamantine-editor-tools-debug-app-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(workspace)
  File.write((workspace / "keymap.json").to_s, "{}")
  apps = [] of EditorToolsDebugAppSpecApp
  controllers = [] of Adamantine::DebugController
  yield workspace, apps, controllers
ensure
  controllers.try do |owned_controllers|
    owned_controllers.each do |controller|
      controller.close
      deadline = Time.instant + 3.seconds
      while controller.cleanup_pending? && Time.instant < deadline
        controller.poll
        sleep 5.milliseconds
      end
    end
  end
  apps.try do |owned_apps|
    owned_apps.each do |app|
      app.stop_debug_polling_public
      app.quit(force: true)
    end
  end
  Tui::App.clear_overlays
  Tui::Widget.focused_widget = nil
  FileUtils.rm_rf(workspace.to_s) if workspace
end

private def new_editor_tools_debug_app(
  workspace : Path,
  root : Path,
  controller : Adamantine::DebugController,
  apps : Array(EditorToolsDebugAppSpecApp),
) : EditorToolsDebugAppSpecApp
  app = EditorToolsDebugAppSpecApp.new(
    project_root: root,
    lsp_command: "",
    keymap_path: (workspace / "keymap.json").to_s,
    session_enabled: false,
    recovery_root: workspace / "recovery-#{apps.size}",
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    debug_controller: controller
  )
  apps << app
  app
end

private def new_editor_tools_debug_app_controller(
  root : Path,
  log_path : Path,
  controllers : Array(Adamantine::DebugController),
  mode : String = "basic",
) : Adamantine::DebugController
  ruby = DebuggerFixtureSupport.ruby_executable
  adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
  controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
    Adamantine::Dap::Client.new(argv, cwd)
  })
  controllers << controller
  profile = Adamantine::Debugging::LaunchProfile.new(
    id: "editor-tools-debug-app-fixture",
    name: "Editor tools debug fixture",
    adapter_argv: [ruby, adapter.to_s, log_path.to_s, mode],
    program: Process.find_executable("true") || "/usr/bin/true",
    cwd: root.to_s
  )
  review = controller.prepare_launch(profile, root)
  raise "debug fixture launch review should be valid: #{review.errors.join("; ")}" unless review.valid?
  raise "debug fixture launch should be accepted" unless controller.start(review).accepted?
  controller
end

private def await_editor_tools_debug_app_inspection(
  controller : Adamantine::DebugController,
  timeout : Time::Span = 3.seconds,
  &ready : Adamantine::DebugController::InspectionSnapshot -> Bool
) : Adamantine::DebugController::InspectionSnapshot
  deadline = Time.instant + timeout
  loop do
    snapshot = controller.inspection_snapshot
    return snapshot if ready.call(snapshot)
    if Time.instant >= deadline
      raise "debug fixture timed out: lifecycle=#{snapshot.state.lifecycle}, execution=#{snapshot.state.execution}, " \
            "stack_fresh=#{snapshot.stack_fresh}, scopes_loaded=#{snapshot.scopes_loaded}, " \
            "pending=#{snapshot.scopes_request_pending}, variables=#{snapshot.variables.nodes.map(&.name)}"
    end
    controller.poll
    sleep 5.milliseconds
  end
end

private def prepare_editor_tools_debug_app_variables(controller : Adamantine::DebugController) : Nil
  stopped = await_editor_tools_debug_app_inspection(controller) { |snapshot| snapshot.stack_fresh }
  stopped.frames.map(&.id).should eq([500_i64, 501_i64])

  controller.open_scopes.accepted?.should be_true
  loaded = await_editor_tools_debug_app_inspection(controller) do |snapshot|
    snapshot.scopes_loaded && snapshot.variables.nodes.any? { |node| node.name == "record" }
  end
  record = loaded.variables.nodes.find { |node| node.name == "record" } || raise "fixture record variable was not retained"
  controller.expand_variable(record.id).accepted?.should be_true
  expanded = await_editor_tools_debug_app_inspection(controller) do |snapshot|
    snapshot.variables.nodes.any? { |node| node.name == "value" && node.parent_id == record.id }
  end
  expanded.scopes_loaded.should be_true
end

private def editor_tools_debug_app_commands(root : Path) : Array(String)
  log_path = root / "dap.jsonl"
  return [] of String unless File.file?(log_path.to_s)
  File.read_lines(log_path.to_s).compact_map do |line|
    record = JSON.parse(line).as_h
    record["command"]?.try(&.as_s?) if record["type"]?.try(&.as_s?) == "request"
  end
end

private def editor_tools_debug_app_invoke(
  session : Adamantine::EditorTools::Session,
  id : String,
) : Adamantine::EditorTools::Result
  session.invoke_json({
    "id"        => id,
    "name"      => "debug.snapshot",
    "arguments" => {} of String => JSON::Any,
  }.to_json)
end

private def editor_tools_debug_app_data(result : Adamantine::EditorTools::Result) : Hash(String, JSON::Any)
  result.data.try(&.as_h) || raise "debug tool result did not include data: #{result.to_json}"
end

describe "App typed debugger tool boundary" do
  it "returns inert truthful frame and variable identities through a Lua child session" do
    with_editor_tools_debug_app_workspace do |workspace, apps, controllers|
      root = workspace / "project-a"
      Dir.mkdir_p(root)
      controller = new_editor_tools_debug_app_controller(root, workspace / "dap.jsonl", controllers)
      prepare_editor_tools_debug_app_variables(controller)
      app = new_editor_tools_debug_app(workspace, root, controller, apps)

      chat = app.open_tool_session(
        consumer: Adamantine::EditorTools::Consumer::Chat,
        capabilities: [Adamantine::EditorTools::Capability::ReadDebugger]
      )
      lua = chat.delegate(
        Adamantine::EditorTools::Consumer::Lua,
        [Adamantine::EditorTools::Capability::ReadDebugger]
      )
      before = editor_tools_debug_app_commands(workspace)
      result = editor_tools_debug_app_invoke(lua, "same-root-debug-snapshot")
      after = editor_tools_debug_app_commands(workspace)

      result.ok?.should be_true
      result.encoded_bytes.should be <= Adamantine::EditorTools::MAX_RESPONSE_BYTES
      after.should eq(before)

      data = editor_tools_debug_app_data(result)
      data["observation"].as_h["stack_fresh"].as_bool.should be_true
      data["frames"].as_h["fresh"].as_bool.should be_true
      frames = data["frames"].as_h["items"].as_a
      frames.map { |frame| frame.as_h["dap_frame_id"].as_s }.should eq(["500", "501"])

      variables = data["variables"].as_h["items"].as_a.map(&.as_h)
      locals = variables.find { |node| node["name"].as_s == "Locals" } || raise "root scope was not exported"
      record = variables.find { |node| node["name"].as_s == "record" } || raise "record variable was not exported"
      value = variables.find { |node| node["name"].as_s == "value" } || raise "expanded child was not exported"
      locals["root"].as_bool.should be_true
      locals["parent_observation_node_id"].raw.should be_nil
      record["root"].as_bool.should be_false
      record["parent_observation_node_id"].as_s.should eq(locals["observation_node_id"].as_s)
      value["root"].as_bool.should be_false
      value["parent_observation_node_id"].as_s.should eq(record["observation_node_id"].as_s)
      value["type"].as_s.should eq("Int32")
      value["value"].as_s.should eq("31")
    end
  end

  it "denies retained target values at another root and after same-path replacement" do
    with_editor_tools_debug_app_workspace do |workspace, apps, controllers|
      root_a = workspace / "project-a"
      root_b = workspace / "project-b"
      moved_root = workspace / "project-a-before-replacement"
      Dir.mkdir_p(root_a)
      Dir.mkdir_p(root_b)
      controller = new_editor_tools_debug_app_controller(root_a, workspace / "dap.jsonl", controllers)
      prepare_editor_tools_debug_app_variables(controller)
      origin = controller.inspection_snapshot.origin_project_stamp || raise "fixture must retain its launch-time root identity"

      app_b = new_editor_tools_debug_app(workspace, root_b, controller, apps)
      b_session = app_b.open_tool_session(
        capabilities: [Adamantine::EditorTools::Capability::ReadDebugger]
      )
      b_result = editor_tools_debug_app_invoke(b_session, "retained-a-at-b")
      b_result.status.should eq(Adamantine::EditorTools::Status::Stale)
      b_result.data.should be_nil

      app_a = new_editor_tools_debug_app(workspace, root_a, controller, apps)
      same_root = app_a.open_tool_session(
        capabilities: [Adamantine::EditorTools::Capability::ReadDebugger]
      )
      same_root_result = editor_tools_debug_app_invoke(same_root, "before-root-replacement")
      same_root_result.ok?.should be_true

      File.rename(root_a.to_s, moved_root.to_s)
      Dir.mkdir_p(root_a.to_s)
      Adamantine::FileRevision.probe(root_a).same_target?(origin).should be_false

      replacement_session = app_a.open_tool_session(
        capabilities: [Adamantine::EditorTools::Capability::ReadDebugger]
      )
      replacement_result = editor_tools_debug_app_invoke(replacement_session, "after-root-replacement")
      replacement_result.status.should eq(Adamantine::EditorTools::Status::Stale)
      replacement_result.data.should be_nil
      controller.inspection_snapshot.origin_project_stamp.not_nil!.same_target?(origin).should be_true
    end
  end
end
