require "option_parser"
require "../src/adamantine/debug_controller"

private def await_snapshot(controller : Adamantine::DebugController,
                           label : String,
                           timeout : Time::Span = 15.seconds,
                           &ready : Adamantine::DebugController::Snapshot -> Bool) : Adamantine::DebugController::Snapshot
  deadline = Time.monotonic + timeout
  latest = controller.poll
  until ready.call(latest)
    if Time.monotonic >= deadline
      raise "timed out waiting for #{label}: lifecycle=#{latest.state.lifecycle}, execution=#{latest.state.execution}, last_error=#{latest.last_error}"
    end
    sleep 10.milliseconds
    latest = controller.poll
  end
  latest
end

private def local_source_frame?(frame : Adamantine::DebugController::FrameView,
                                source_key : Adamantine::Debugging::DebugSourceKey,
                                dap_line : Int32) : Bool
  frame.source_key == source_key && frame.dap_line == dap_line
end

# A fixture-only numeric oracle. A DAP adapter may retain presentation settings
# after Hex formatting; editor display still uses the returned text unchanged.
private def fixture_number?(text : String, expected : Int64) : Bool
  return true if text == expected.to_s
  lower = text.downcase
  lower.starts_with?("0x") && lower[2..].to_i64?(16) == expected
end

private def run_probe(options : Hash(String, String)) : Nil
  adapter = Path.new(File.realpath(options.fetch("adapter") { raise "missing adapter" }))
  program = Path.new(File.realpath(options.fetch("program") { raise "missing program" }))
  cwd = Path.new(File.realpath(options.fetch("cwd") { raise "missing cwd" }))
  source = Path.new(File.realpath(options.fetch("source") { raise "missing source" }))
  project_root = Path.new(File.realpath(options.fetch("project-root") { raise "missing project root" }))
  raise "source must be inside the reviewed project root" unless source.to_s.starts_with?("#{project_root}/")

  source_text = File.read(source.to_s)
  source_key = Adamantine::Debugging::DebugSourceKey.local(source.to_s)
  baseline = Adamantine::DebugController::SourceBaseline.new(source, source_text)
  profile = Adamantine::Debugging::LaunchProfile.new(
    id: "dbg-controller-real-probe",
    name: "Owned Crystal controller probe",
    adapter_argv: [adapter.to_s, "--no-lldbinit"],
    program: program.to_s,
    cwd: cwd.to_s
  )

  controller = Adamantine::DebugController.default
  raise "project binding failed" unless controller.bind_project(project_root, 0_u64)
  raise "source breakpoint was rejected" unless controller.toggle_breakpoint(source_key, 23).accepted?
  review = controller.prepare_launch(profile, project_root, [baseline])
  raise "launch review failed: #{review.errors.join("; ")}" unless review.valid?
  raise "explicit launch was rejected" unless controller.start(review).accepted?

  initial = await_snapshot(controller, "verified line-24 breakpoint stop") do |snapshot|
    snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
      snapshot.state.execution == Adamantine::DebugSessionState::Execution::Stopped &&
      snapshot.breakpoints.any? do |row|
        row.source_key == source_key && row.breakpoint.requested_line == 23 &&
          row.breakpoint.status == Adamantine::Debugging::BreakpointStatus::Verified
      end && snapshot.frames.any? { |frame| local_source_frame?(frame, source_key, 24) }
  end
  raise "frame line 24 from the requested source was not retained" unless initial.frames.any? { |frame| local_source_frame?(frame, source_key, 24) }

  raise "captured source could not be opened from the session store" unless controller.open_source(source_key).accepted?
  source_view = controller.snapshot.sources.find { |view| view.key == source_key }
  raise "source provenance must remain explicitly Unverified" unless source_view && source_view.not_nil!.checksum_status == Adamantine::Debugging::ChecksumStatus::Unverified

  raise "scope request was rejected" unless controller.open_scopes.accepted?
  locals = await_snapshot(controller, "primitive and composite locals") do |snapshot|
    nodes = snapshot.variables.nodes
    sentinel = nodes.find { |node| node.name == "debugger_sentinel" }
    nested = nodes.find { |node| node.name == "debugger_nested_outer" }
    sentinel.try(&.value) == "271828" && nested.try(&.expandable?) == true &&
      nodes.none? { |node| node.load_state == Adamantine::Debugging::DebugVariableLoadState::Loading }
  end
  sentinel = locals.variables.nodes.find { |node| node.name == "debugger_sentinel" }
  raise "primitive sentinel must be exact" unless sentinel && sentinel.not_nil!.value == "271828"
  hex_result = "not advertised by adapter"
  if locals.capabilities.value_formatting_options
    node_id = sentinel.not_nil!.id
    raise "explicit hexadecimal request was rejected" unless controller.request_value_format(node_id).accepted?
    await_snapshot(controller, "adapter-provided hexadecimal sentinel") do |_snapshot|
      detail = controller.render_value(node_id, Adamantine::Debugging::DebugValueFormat::Hex)
      unless detail.available? || detail.reason == "formatted value request is pending"
        raise "adapter-provided hexadecimal sentinel is unavailable: #{detail.reason}"
      end
      detail.available?
    end
    formatted = controller.render_value(node_id, Adamantine::Debugging::DebugValueFormat::Hex)
    # This conversion is a test oracle for our known fixture, not editor-side
    # formatting. The displayed text must have come from the adapter request.
    text = formatted.text.downcase
    raise "adapter hexadecimal sentinel was not exact: #{text}" unless text.starts_with?("0x") && text[2..].to_i64?(16) == 271828_i64
    hex_result = "adapter-provided #{text}"
    controller.cancel_value_format(node_id)
    raise "retired hexadecimal detail remained available" if controller.render_value(node_id, Adamantine::Debugging::DebugValueFormat::Hex).available?
  elsif options["require-hex"]? == "true"
    raise "adapter did not advertise the required hexadecimal representation"
  end
  nested = locals.variables.nodes.find { |node| node.name == "debugger_nested_outer" }
  raise "nested record local is unavailable" unless nested && nested.not_nil!.expandable?
  raise "nested record expansion was rejected" unless controller.expand_variable(nested.not_nil!.id).accepted?
  expanded = await_snapshot(controller, "nested value 31") do |snapshot|
    snapshot.variables.nodes.any? do |node|
      node.parent_id == nested.not_nil!.id && node.name == "value" && fixture_number?(node.value, 31_i64)
    end
  end
  raise "nested composite child 31 was not observed" unless expanded.variables.nodes.any? do |node|
                                                              node.parent_id == nested.not_nil!.id && node.name == "value" && fixture_number?(node.value, 31_i64)
                                                            end
  nested_text = expanded.variables.nodes.find { |node| node.parent_id == nested.not_nil!.id && node.name == "value" }.not_nil!.value

  prior_stop_epoch = expanded.state.stop_epoch
  raise "step-over request was rejected" unless controller.step_over.accepted?
  stepped = await_snapshot(controller, "next stop on DAP line 25") do |snapshot|
    snapshot.state.stop_epoch > prior_stop_epoch &&
      snapshot.state.execution == Adamantine::DebugSessionState::Execution::Stopped &&
      snapshot.frames.any? { |frame| local_source_frame?(frame, source_key, 25) }
  end
  raise "step did not advance to the exact fixture line" unless stepped.frames.any? { |frame| local_source_frame?(frame, source_key, 25) }

  raise "continue request was rejected" unless controller.continue.accepted?
  ended = await_snapshot(controller, "exit code zero and owned cleanup", 15.seconds) do |snapshot|
    snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Ended &&
      snapshot.state.target_liveness == Adamantine::DebugSessionState::TargetLiveness::Exited &&
      snapshot.target_exit_code == 0 && !snapshot.cleanup_pending
  end
  raise "target exit code was not zero" unless ended.target_exit_code == 0

  STDOUT.puts "PASS: verified breakpoint stop at DAP 24; sentinel 271828; Hex #{hex_result}; nested value 31 (adapter text #{nested_text}); step to DAP 25; exited 0; owned adapter cleanup complete; source checksum remains Unverified"
ensure
  if controller
    begin
      current = controller.not_nil!.snapshot
      unless current.state.lifecycle.in?(Adamantine::DebugSessionState::Lifecycle::Ended, Adamantine::DebugSessionState::Lifecycle::Failed)
        controller.not_nil!.stop
      end
      controller.not_nil!.close
      deadline = Time.monotonic + 7.seconds
      while controller.not_nil!.cleanup_pending? && Time.monotonic < deadline
        controller.not_nil!.poll
        sleep 10.milliseconds
      end
      raise "owned adapter cleanup did not finish before the probe deadline" if controller.not_nil!.cleanup_pending?
    rescue ex
      STDERR.puts "CLEANUP ERROR: #{ex.message}"
      raise ex
    end
  end
end

options = {} of String => String
parser = OptionParser.new do |cli|
  cli.banner = "Usage: crystal run scripts/probe_debug_controller.cr -- --adapter PATH --program PATH --cwd DIR --source PATH --project-root DIR"
  cli.on("--adapter PATH", "Explicit lldb-dap wrapper path") { |value| options["adapter"] = value }
  cli.on("--program PATH", "Already-built Crystal fixture executable") { |value| options["program"] = value }
  cli.on("--cwd DIR", "Private working directory for the fixture") { |value| options["cwd"] = value }
  cli.on("--source PATH", "Canonical source fixture path") { |value| options["source"] = value }
  cli.on("--project-root DIR", "Canonical editor project root") { |value| options["project-root"] = value }
  cli.on("--require-hex", "Fail unless the adapter supplies the known sentinel in hexadecimal") { options["require-hex"] = "true" }
  cli.on("-h", "--help", "Show this help") do
    puts cli
    exit 0
  end
end

status = 0
begin
  parser.parse
  required = %w[adapter program cwd source project-root]
  missing = required.reject { |key| options.has_key?(key) }
  raise "missing required options: #{missing.join(", ")}" unless missing.empty?
  run_probe(options)
rescue ex
  STDERR.puts "FAIL: #{ex.message}"
  status = 1
end
exit status
