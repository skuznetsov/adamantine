require "spec"
require "json"

require "../src/adamantine/lua_script_runtime"

private def lua_runtime_environment : {String, String}
  worker = ENV["ADAMANTINE_LUA_WORKER"]?
  library = ENV["ADAMANTINE_LUA_LIBRARY"]?
  unless worker && File.file?(worker)
    raise "build the editor first and set ADAMANTINE_LUA_WORKER to its absolute path"
  end
  unless library && File.file?(library)
    raise "run scripts/build_test_lua.sh /tmp/adamantine-test-lua and set ADAMANTINE_LUA_LIBRARY to its output"
  end
  {File.realpath(worker), File.realpath(library)}
end

private def lua_fixture_worker : String
  File.realpath("scripts/fixtures/lua_protocol_worker.rb")
end

private def with_lua_test_environment(values : Hash(String, String), &)
  previous : Hash(String, String?) = {} of String => String?
  values.each_key { |name| previous[name] = ENV[name]? }
  values.each { |name, value| ENV[name] = value }
  begin
    yield
  ensure
    previous.each do |name, value|
      if value
        ENV[name] = value
      else
        ENV.delete(name)
      end
    end
  end
end

private def await_lua_queued_event(run : Adamantine::LuaScripts::Run,
                                   timeout : Time::Span = 4.seconds) : Nil
  deadline = Time.instant + timeout
  until run.events_pending? && run.active?
    raise "Lua event was not queued while its run was active" if Time.instant >= deadline || !run.active?
    Fiber.yield
  end
end

private def await_lua_reap(run : Adamantine::LuaScripts::Run,
                           timeout : Time::Span = 4.seconds) : Nil
  deadline = Time.instant + timeout
  until run.reaped?
    raise "Lua worker did not reap before the bounded test deadline" if Time.instant >= deadline
    Fiber.yield
  end
end

private def drain_lua_run(run : Adamantine::LuaScripts::Run,
                          timeout : Time::Span = 8.seconds) : Array(Adamantine::LuaScripts::Event)
  events = [] of Adamantine::LuaScripts::Event
  deadline = Time.instant + timeout
  while Time.instant < deadline
    events.concat(run.drain_events)
    break if events.any? { |event| event.kind.complete? || event.kind.failed? }
    Fiber.yield
  end
  events.concat(run.drain_events)
  events
end

private def lua_terminal(events : Array(Adamantine::LuaScripts::Event)) : Adamantine::LuaScripts::Event?
  events.reverse.find { |event| event.kind.complete? || event.kind.failed? }
end

private def require_lua_complete(run : Adamantine::LuaScripts::Run,
                                 events : Array(Adamantine::LuaScripts::Event),
                                 label : String) : Adamantine::LuaScripts::Event
  terminal = lua_terminal(events)
  return terminal.not_nil! if terminal.try(&.kind.complete?)

  raise "#{label} did not complete (terminal=#{terminal.try(&.kind)}, failure_code=#{terminal.try(&.failure_code).inspect}, run_failure_code=#{run.failure_code.inspect}, reaped=#{run.reaped?}, active=#{run.active?})"
end

private def expect_lua_failure(run : Adamantine::LuaScripts::Run,
                               events : Array(Adamantine::LuaScripts::Event),
                               code : String) : Nil
  terminal = lua_terminal(events)
  terminal.should_not be_nil
  terminal.not_nil!.kind.failed?.should be_true
  terminal.not_nil!.failure_code.should eq(code)
  run.active?.should be_false
  run.reaped?.should be_true
end

describe Adamantine::LuaScripts do
  it "runs real Lua in a child and publishes output only after reaping" do
    worker, library = lua_runtime_environment
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library)
    run = runner.start("runtime-positive", "print(\"answer\", 6 * 7)", JSON.parse("{}"))

    events = drain_lua_run(run)
    output = events.select { |event| event.kind.output? }.map(&.text.not_nil!).join

    output.should eq("answer\t42\n")
    lua_terminal(events).try(&.kind.complete?).should be_true
    run.active?.should be_false
    run.reaped?.should be_true
  ensure
    run.try(&.cancel_and_wait)
  end

  it "exposes only the bounded Lua allowlist and supports protected base computation" do
    worker, library = lua_runtime_environment
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library)
    source = <<-LUA
      local restricted = {"io", "os", "package", "debug", "require", "load", "loadfile", "dofile", "coroutine", "collectgarbage", "ffi"}
      for _, name in ipairs(restricted) do
        assert(_ENV[name] == nil, name .. " should be unavailable")
      end
      assert(type(editor) == "table" and type(editor.call) == "function")
      assert(type(math) == "table" and type(string) == "table")
      assert(type(table) == "table" and type(utf8) == "table")
      local ok, value = pcall(function()
        return math.floor(41.9) + string.len("x") + utf8.len("雪") + #table.concat({"A", "B"})
      end)
      assert(ok and value == 45)
      print("allowlist-ok", value)
    LUA
    run = runner.start("runtime-global-allowlist", source, JSON.parse("{}"))

    events = drain_lua_run(run)

    events.select(&.kind.output?).map(&.text.not_nil!).join.should eq("allowlist-ok\t45\n")
    lua_terminal(events).try(&.kind.complete?).should be_true
    run.reaped?.should be_true
  ensure
    run.try(&.cancel_and_wait)
  end

  it "clears inherited Lua/loader variables and starts outside the project cwd" do
    worker, library = lua_runtime_environment
    fixture = lua_fixture_worker
    runner = Adamantine::LuaScripts::Runner.new(worker_path: fixture, library_path: library)
    names = {
      "ADAMANTINE_LUA_TEST_SENTINEL", "LUA_INIT", "LUA_PATH", "LUA_CPATH",
      "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH",
    }
    values = names.to_h { |name| {name, "synthetic-test-value"} }

    with_lua_test_environment(values) do
      run = runner.start("fixture-startup-boundary", "", JSON.parse("{}"))
      events = drain_lua_run(run)
      terminal = require_lua_complete(run, events, "startup-boundary fixture")
      output = events.select(&.kind.output?).map(&.text.not_nil!).join
      observations = begin
        JSON.parse(output).as_h
      rescue ex
        raise "startup-boundary fixture output was not valid JSON (terminal=#{terminal.kind}, output=#{output.inspect}): #{ex.message}"
      end

      observations.size.should eq(9)
      observations.each_value { |value| value.as_bool.should be_true }
      lua_terminal(events).try(&.kind.complete?).should be_true
      run.reaped?.should be_true
    ensure
      run.try(&.cancel_and_wait)
    end
  end

  it "round-trips quotes, backslashes, and Unicode through an acknowledged tool call" do
    worker, library = lua_runtime_environment
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library)
    source = <<-LUA
      local result = editor.call("test.echo", {text = [=[quote " slash \\ snow 雪]=]})
      print(result.echo)
    LUA
    run = runner.start("runtime-json-roundtrip", source, JSON.parse("{}"))

    events = [] of Adamantine::LuaScripts::Event
    deadline = Time.instant + 8.seconds
    request_seen = false
    while Time.instant < deadline
      batch = run.drain_events
      events.concat(batch)
      if event = batch.find(&.kind.tool_request?)
        request = JSON.parse(event.request_json.not_nil!)
        request["name"].as_s.should eq("test.echo")
        request["arguments"]["text"].as_s.should eq("quote \" slash \\ snow 雪")
        response = JSON.build do |json|
          json.object do
            json.field "id", event.call_id.not_nil!
            json.field "status", "ok"
            json.field "echo", "response \" \\ ☃"
          end
        end
        run.reply(event.call_id.not_nil!, response).should be_true
        request_seen = true
      end
      break if events.any? { |event| event.kind.complete? || event.kind.failed? }
      Fiber.yield
    end
    events.concat(run.drain_events)

    request_seen.should be_true
    events.select { |event| event.kind.output? }.map(&.text.not_nil!).join.should eq("response \" \\ ☃\n")
    lua_terminal(events).try(&.kind.complete?).should be_true
    run.reaped?.should be_true
  ensure
    run.try(&.cancel_and_wait)
  end

  it "terminates an infinite loop even when pcall catches script errors" do
    worker, library = lua_runtime_environment
    limits = Adamantine::LuaScripts::Limits.new(wall_time: 1.second)
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library, limits: limits)
    source = "print(\"entered-pcall\"); local ok = pcall(function() while true do end end); print(ok)"
    run = runner.start("runtime-pcall-loop", source, JSON.parse("{}"))

    events = drain_lua_run(run, 4.seconds)

    events.select(&.kind.output?).map(&.text.not_nil!).join.should contain("entered-pcall\n")
    expect_lua_failure(run, events, "wall_time_limit")
  ensure
    run.try(&.cancel_and_wait)
  end

  it "terminates native Lua pattern work at the parent deadline" do
    worker, library = lua_runtime_environment
    limits = Adamantine::LuaScripts::Limits.new(wall_time: 1.second)
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library, limits: limits)
    source = "print(\"entered-pattern\"); string.find(string.rep(\"a\", 12000), \"a*a*a*a*a*a*a*a*a*a*b\")"
    run = runner.start("runtime-native-pattern", source, JSON.parse("{}"))

    events = drain_lua_run(run, 4.seconds)

    events.select(&.kind.output?).map(&.text.not_nil!).join.should contain("entered-pattern\n")
    expect_lua_failure(run, events, "wall_time_limit")
  ensure
    run.try(&.cancel_and_wait)
  end

  it "does not publish success while a Lua finalizer hangs during close" do
    worker, library = lua_runtime_environment
    limits = Adamantine::LuaScripts::Limits.new(wall_time: 1.second)
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library, limits: limits)
    source = "print(\"entered-finalizer\"); local value = setmetatable({}, {__gc = function() while true do end end})"
    run = runner.start("runtime-finalizer-loop", source, JSON.parse("{}"))

    events = drain_lua_run(run, 4.seconds)

    events.select(&.kind.output?).map(&.text.not_nil!).join.should contain("entered-finalizer\n")
    events.any?(&.kind.complete?).should be_false
    expect_lua_failure(run, events, "wall_time_limit")
  ensure
    run.try(&.cancel_and_wait)
  end

  it "keeps heap exhaustion sticky when pcall catches the allocation error" do
    worker, library = lua_runtime_environment
    limits = Adamantine::LuaScripts::Limits.new(lua_heap_bytes: 1024 * 1024)
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library, limits: limits)
    source = <<-LUA
      local caught = pcall(function()
        local retained = {}
        while true do retained[#retained + 1] = string.rep("x", 4096) end
      end)
      print("pcall-caught", caught)
    LUA
    run = runner.start("runtime-caught-oom", source, JSON.parse("{}"))

    events = drain_lua_run(run)

    expect_lua_failure(run, events, "memory_limit")
  ensure
    run.try(&.cancel_and_wait)
  end

  it "sanitizes C1 controls and enforces output byte and event limits" do
    worker, library = lua_runtime_environment
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library)
    sanitized_run = runner.start("runtime-c1-output", "print(\"safe\" .. utf8.char(0x85) .. \"end\")", JSON.parse("{}"))
    sanitized_events = drain_lua_run(sanitized_run)
    sanitized_events.select(&.kind.output?).map(&.text.not_nil!).join.should eq("safe�end\n")
    lua_terminal(sanitized_events).try(&.kind.complete?).should be_true
    sanitized_run.reaped?.should be_true

    byte_limits = Adamantine::LuaScripts::Limits.new(output_bytes: 4)
    byte_runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library, limits: byte_limits)
    byte_run = byte_runner.start("runtime-output-bytes", "print(\"12345\")", JSON.parse("{}"))
    expect_lua_failure(byte_run, drain_lua_run(byte_run), "output_limit")

    event_limits = Adamantine::LuaScripts::Limits.new(output_events: 2)
    event_runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library, limits: event_limits)
    event_run = event_runner.start("runtime-output-events", "print(1); print(2); print(3)", JSON.parse("{}"))
    expect_lua_failure(event_run, drain_lua_run(event_run), "output_limit")
  ensure
    sanitized_run.try(&.cancel_and_wait)
    byte_run.try(&.cancel_and_wait)
    event_run.try(&.cancel_and_wait)
  end

  it "accepts a worst-case escaped startup envelope within its derived ceiling" do
    worker, library = lua_runtime_environment
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library)
    source = "\0" * (64 * 1024)
    context = JSON::Any.new({"padding" => JSON::Any.new("\0" * 5_300)} of String => JSON::Any)
    context.to_json.bytesize.should be <= 32 * 1024
    run = runner.start("runtime-large-start-frame", source, context)

    events = drain_lua_run(run)

    expect_lua_failure(run, events, "script_error")
  ensure
    run.try(&.cancel_and_wait)
  end

  it "rejects binary Lua chunks instead of loading bytecode" do
    worker, library = lua_runtime_environment
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library)
    run = runner.start("runtime-binary-chunk", "\x1bLua\x54\x00", JSON.parse("{}"))

    expect_lua_failure(run, drain_lua_run(run), "script_error")
  ensure
    run.try(&.cancel_and_wait)
  end

  it "publishes a bounded sanitized syntax diagnostic with the script location" do
    worker, library = lua_runtime_environment
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library)
    run = runner.start("runtime-syntax-error", "local =", JSON.parse("{}"))

    events = drain_lua_run(run)
    terminal = lua_terminal(events).not_nil!

    terminal.kind.failed?.should be_true
    terminal.failure_code.should eq("script_error")
    terminal.failure_message.should_not be_nil
    message = terminal.failure_message.not_nil!
    message.should contain("@named-script:1")
    message.bytesize.should be <= 512
    message.each_char.none? { |char| Adamantine::EditorTools.control_char?(char) }.should be_true
    run.reaped?.should be_true
  ensure
    run.try(&.cancel_and_wait)
  end

  it "keeps diagnostics with many control characters inside the frame budget" do
    worker, library = lua_runtime_environment
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library)
    run = runner.start("runtime-control-diagnostic", "error(string.rep(string.char(1), 300))", JSON.parse("{}"))

    events = drain_lua_run(run)
    terminal = lua_terminal(events).not_nil!

    terminal.kind.failed?.should be_true
    terminal.failure_code.should eq("script_error")
    terminal.failure_message.should_not be_nil
    message = terminal.failure_message.not_nil!
    message.bytesize.should be <= 512
    message.each_char.none? { |char| Adamantine::EditorTools.control_char?(char) }.should be_true
    run.reaped?.should be_true
  ensure
    run.try(&.cancel_and_wait)
  end

  it "rejects pre-5.4 and 5.5 library ABIs before executing script code" do
    worker, library = lua_runtime_environment
    extension = {% if flag?(:darwin) %}"dylib"{% else %}"so"{% end %}
    library_dir = File.dirname(library)
    incompatible_paths = {
      File.join(library_dir, "liblua53fake.#{extension}"),
      File.join(library_dir, "liblua55fake.#{extension}"),
    }

    incompatible_paths.each_with_index do |path, index|
      File.file?(path).should be_true
      runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: path)
      run = runner.start("runtime-wrong-abi-#{index}", "print(\"must not run\")", JSON.parse("{}"))
      expect_lua_failure(run, drain_lua_run(run), "lua_incompatible")
    ensure
      run.try(&.cancel_and_wait)
    end
  end

  it "fails startup with an actionable error when the configured library is missing" do
    worker, _library = lua_runtime_environment
    error = expect_raises(Adamantine::LuaScripts::RuntimeError) do
      Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: "/tmp/adamantine-missing-lua-54.dylib")
    end
    error.message.not_nil!.should contain("ADAMANTINE_LUA_LIBRARY")
    error.message.not_nil!.should contain("Lua 5.4")
  end

  it "does not let pending RPC or output events delay cancellation and reap" do
    worker, library = lua_runtime_environment
    limits = Adamantine::LuaScripts::Limits.new(wall_time: 1.second)
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library, limits: limits)
    tool_run = runner.start("runtime-pending-tool", "editor.call(\"test.wait\", {})", JSON.parse("{}"))
    # Leave the queued request unconsumed and unacknowledged through the deadline.
    await_lua_queued_event(tool_run)
    await_lua_reap(tool_run)
    tool_events = tool_run.drain_events
    expect_lua_failure(tool_run, tool_events, "wall_time_limit")

    output_run = runner.start("runtime-pending-output", "print(\"queued\"); while true do end", JSON.parse("{}"))
    # Keep the finite output queue undrained until the worker is killed/reaped.
    await_lua_queued_event(output_run)
    await_lua_reap(output_run)
    output_events = output_run.drain_events
    expect_lua_failure(output_run, output_events, "wall_time_limit")
    output_events.any?(&.kind.output?).should be_true
  ensure
    tool_run.try(&.cancel_and_wait)
    output_run.try(&.cancel_and_wait)
  end

  it "rejects failed-plus-complete, partial-frame, stderr-flood, and closed-pipe live workers" do
    worker, library = lua_runtime_environment
    fixture = lua_fixture_worker

    runner = Adamantine::LuaScripts::Runner.new(worker_path: fixture, library_path: library)
    failed_complete = runner.start("fixture-failed-complete", "", JSON.parse("{}"))
    expect_lua_failure(failed_complete, drain_lua_run(failed_complete), "protocol_frame_invalid")

    duplicate_complete = runner.start("fixture-duplicate-complete", "", JSON.parse("{}"))
    duplicate_events = drain_lua_run(duplicate_complete)
    duplicate_events.any?(&.kind.complete?).should be_false
    expect_lua_failure(duplicate_complete, duplicate_events, "protocol_frame_invalid")

    complete_output = runner.start("fixture-complete-output", "", JSON.parse("{}"))
    output_events = drain_lua_run(complete_output)
    output_events.any?(&.kind.output?).should be_false
    expect_lua_failure(complete_output, output_events, "protocol_frame_invalid")

    complete_tool = runner.start("fixture-complete-tool", "", JSON.parse("{}"))
    tool_events = drain_lua_run(complete_tool)
    tool_events.any?(&.kind.tool_request?).should be_false
    expect_lua_failure(complete_tool, tool_events, "protocol_frame_invalid")

    complete_pending = runner.start("fixture-complete-pending", "", JSON.parse("{}"))
    pending_events = drain_lua_run(complete_pending)
    pending_events.any?(&.kind.tool_request?).should be_true
    expect_lua_failure(complete_pending, pending_events, "protocol_frame_invalid")

    partial = runner.start("fixture-partial", "", JSON.parse("{}"))
    partial_events = drain_lua_run(partial)
    partial_events.any?(&.kind.complete?).should be_false
    expect_lua_failure(partial, partial_events, "protocol_frame_limit")

    stderr_flood = runner.start("fixture-stderr-flood", "", JSON.parse("{}"))
    stderr_events = drain_lua_run(stderr_flood)
    error = expect_raises(Exception) { require_lua_complete(stderr_flood, stderr_events, "stderr-flood fixture") }
    error.message.should_not be_nil
    error.message.not_nil!.should contain("worker_stderr_limit")
    expect_lua_failure(stderr_flood, stderr_events, "worker_stderr_limit")

    invalid_diagnostic = runner.start("fixture-invalid-failure-message", "", JSON.parse("{}"))
    expect_lua_failure(invalid_diagnostic, drain_lua_run(invalid_diagnostic), "protocol_frame_invalid")

    short_limits = Adamantine::LuaScripts::Limits.new(wall_time: 1.second)
    live_runner = Adamantine::LuaScripts::Runner.new(worker_path: fixture, library_path: library, limits: short_limits)
    closed_live = live_runner.start("fixture-closed-live", "", JSON.parse("{}"))
    closed_events = drain_lua_run(closed_live, 4.seconds)
    closed_events.any?(&.kind.complete?).should be_false
    expect_lua_failure(closed_live, closed_events, "wall_time_limit")
  ensure
    failed_complete.try(&.cancel_and_wait)
    duplicate_complete.try(&.cancel_and_wait)
    complete_output.try(&.cancel_and_wait)
    complete_tool.try(&.cancel_and_wait)
    complete_pending.try(&.cancel_and_wait)
    partial.try(&.cancel_and_wait)
    stderr_flood.try(&.cancel_and_wait)
    invalid_diagnostic.try(&.cancel_and_wait)
    closed_live.try(&.cancel_and_wait)
  end

  it "supports bounded cancel-and-wait for owner shutdown paths" do
    worker, library = lua_runtime_environment
    runner = Adamantine::LuaScripts::Runner.new(worker_path: worker, library_path: library)
    run = runner.start("runtime-cancel", "while true do end", JSON.parse("{}"))

    run.cancel_and_wait(1.second).should be_true
    run.active?.should be_false
    run.reaped?.should be_true
    lua_terminal(run.drain_events).try(&.failure_code).should eq("cancelled")
  ensure
    run.try(&.cancel_and_wait)
  end
end
