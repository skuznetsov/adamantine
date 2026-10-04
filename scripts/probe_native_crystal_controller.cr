require "option_parser"
require "../src/adamantine/debug_controller"

private def wait_for(controller : Adamantine::DebugController,
                     label : String,
                     timeout : Time::Span = 20.seconds,
                     &ready : Adamantine::DebugController::Snapshot -> Bool) : Adamantine::DebugController::Snapshot
  deadline = Time.monotonic + timeout
  snapshot = controller.poll
  until ready.call(snapshot)
    raise "timed out waiting for #{label}: lifecycle=#{snapshot.state.lifecycle}, execution=#{snapshot.state.execution}, error=#{snapshot.last_error}" if Time.monotonic >= deadline
    sleep 10.milliseconds
    snapshot = controller.poll
  end
  snapshot
end

private def fixture_line(path : Path, marker : String) : Int32
  matches = [] of Int32
  line_number = 0
  File.each_line(path) do |line|
    line_number += 1
    matches << line_number if line.includes?(marker)
  end
  raise "fixture must have one #{marker} marker" unless matches.size == 1
  matches.first
end

private def run_probe(options : Hash(String, String)) : Nil
  controller = nil.as(Adamantine::DebugController?)
  root = Path.new(File.realpath(options.fetch("project-root") { raise "missing --project-root" }))
  source = Path.new(File.realpath(options.fetch("source") { raise "missing --source" }))
  program = Path.new(File.realpath(options.fetch("program") { raise "missing --program" }))
  cwd = Path.new(File.realpath(options.fetch("cwd") { raise "missing --cwd" }))
  adapter = Path.new(File.realpath(options.fetch("adapter") { raise "missing --adapter" }))
  marker_dap_line = fixture_line(source, "DAP_BREAKPOINT: native values")
  marker_editor_line = marker_dap_line - 1
  source_key = Adamantine::Debugging::DebugSourceKey.local(source.to_s)
  baseline = Adamantine::DebugController::SourceBaseline.new(source, File.read(source))
  profile = Adamantine::Debugging::LaunchProfile.new(
    id: "owned-native-crystal-controller-probe",
    name: "Reviewed stock Crystal native values probe",
    adapter_argv: [adapter.to_s, "--no-lldbinit"],
    program: program.to_s,
    cwd: cwd.to_s,
    native_values: Adamantine::Debugging::NativeValueProvider::StockCrystal,
  )

  active_controller = Adamantine::DebugController.default
  controller = active_controller
  raise "project binding failed" unless active_controller.bind_project(root, 0_u64)
  raise "native-values breakpoint rejected" unless active_controller.toggle_breakpoint(source_key, marker_editor_line).accepted?
  review = active_controller.prepare_launch(profile, root, [baseline])
  raise "explicit StockCrystal profile review failed: #{review.errors.join("; ")}" unless review.valid?
  raise "reviewed profile launch rejected" unless active_controller.start(review).accepted?

  stopped = wait_for(active_controller, "native fixture stop") do |snapshot|
    snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active &&
      snapshot.state.execution == Adamantine::DebugSessionState::Execution::Stopped &&
      !snapshot.frames.empty?
  end
  verified_breakpoint = stopped.breakpoints.any? do |row|
    row.source_key == source_key && row.breakpoint.requested_line == marker_editor_line &&
      row.breakpoint.status == Adamantine::Debugging::BreakpointStatus::Verified
  end
  unless verified_breakpoint
    rows = stopped.breakpoints.map { |row| {row.source_key.to_s, row.breakpoint.requested_line, row.breakpoint.status.to_s} }
    raise "native fixture breakpoint was not verified; rows=#{rows.inspect}; frames=#{stopped.frames.map { |frame| {frame.source_key.to_s, frame.dap_line} }.inspect}; last_error=#{stopped.last_error}"
  end
  unless stopped.frames.any? { |frame| frame.source_key == source_key && frame.dap_line == marker_dap_line }
    rows = stopped.frames.map { |frame| {frame.name, frame.source_key.to_s, frame.source_path, frame.dap_line} }
    raise "fixture source frame was not retained at expected DAP line #{marker_dap_line}; frames=#{rows.inspect}"
  end
  raise "scope request rejected" unless active_controller.open_scopes.accepted?

  locals = wait_for(active_controller, "native locals") do |snapshot|
    names = snapshot.variables.nodes.map(&.name)
    %w[native_string_empty native_string_utf8 native_string_nul native_string_long native_array_empty native_array native_array_large native_array_shifted].all? do |name|
      names.includes?(name)
    end && snapshot.variables.nodes.none? { |node| node.load_state == Adamantine::Debugging::DebugVariableLoadState::Loading }
  end
  find_local = ->(name : String) {
    locals.variables.nodes.find { |node| node.name == name } ||
    raise "local not found: #{name}"
  }
  empty_string = find_local.call("native_string_empty")
  utf8_string = find_local.call("native_string_utf8")
  nul_string = find_local.call("native_string_nul")
  long_string = find_local.call("native_string_long")
  empty_array = find_local.call("native_array_empty")
  simple_array = find_local.call("native_array")
  large_array = find_local.call("native_array_large")
  shifted_array = find_local.call("native_array_shifted")

  {
    "native_string_empty" => {empty_string.value, "\"\" (0 bytes)"},
    "native_string_utf8"  => {utf8_string.value, "\"snowman ☃\" (11 bytes)"},
    "native_string_nul"   => {nul_string.value, "\"left\\u0000right\" (10 bytes)"},
  }.each do |name, (value, suffix)|
    raise "#{name} summary was not exact: #{value.inspect}" unless value.ends_with?(suffix)
  end
  raise "large String summary omitted preview bound" unless long_string.value.ends_with?("(2048 bytes; preview limited to 1024 bytes)") && long_string.value.includes?("…")
  raise "empty Array summary was incorrect" unless empty_array.value.ends_with?("[] (size=0)")
  raise "simple Array summary was incorrect" unless simple_array.value.ends_with?("[22, 44] (size=2)")
  raise "large Array summary did not reveal its cap" unless large_array.value.ends_with?("[0, 1, 2, 3, 4, 5, 6, 7, …] (size=300); preview shows 8 of 300; indexed children capped at 256")
  raise "large Array indexed count is not the explicit 256 cap" unless large_array.indexed_variables == 256
  raise "shifted Array summary applied offset twice or missed logical buffer" unless shifted_array.value.ends_with?("[5, 7] (size=2)")
  raise "empty Array must not be expandable" if empty_array.expandable?

  {"native_array" => simple_array, "native_array_shifted" => shifted_array}.each do |name, parent|
    raise "#{name} expansion rejected" unless active_controller.expand_variable(parent.id).accepted?
    expected = name == "native_array" ? ["22", "44"] : ["5", "7"]
    expanded = wait_for(active_controller, "#{name} indexed children") do |snapshot|
      children = snapshot.variables.nodes.select { |node| node.parent_id == parent.id }
      children.map(&.value) == expected && children.all? { |node| node.load_state != Adamantine::Debugging::DebugVariableLoadState::Loading }
    end
    children = expanded.variables.nodes.select { |node| node.parent_id == parent.id }
    raise "#{name} indexed child names/types were not exact" unless children.map(&.name) == ["[0]", "[1]"] && children.all? { |node| node.type == "int" }
  end

  puts "PASS: production DebugController StockCrystal profile; embedded provider yielded exact String summaries, [22, 44] and [5, 7] indexed values, size-aware large preview and 256-child cap"
ensure
  if current_controller = controller
    begin
      current = current_controller.snapshot
      unless current.state.lifecycle.in?(Adamantine::DebugSessionState::Lifecycle::Ended, Adamantine::DebugSessionState::Lifecycle::Failed)
        current_controller.stop
      end
      current_controller.close
      deadline = Time.monotonic + 10.seconds
      while current_controller.cleanup_pending? && Time.monotonic < deadline
        current_controller.poll
        sleep 10.milliseconds
      end
      raise "owned adapter cleanup did not finish" if current_controller.cleanup_pending?
    rescue ex
      STDERR.puts "CLEANUP ERROR: #{ex.message}"
      raise ex
    end
  end
end

options = {} of String => String
parser = OptionParser.new do |cli|
  cli.banner = "Usage: probe_native_crystal_controller --adapter PATH --program PATH --cwd DIR --source PATH --project-root DIR"
  cli.on("--adapter PATH", "Explicit LLDB-DAP executable") { |value| options["adapter"] = value }
  cli.on("--program PATH", "Owned fixture executable") { |value| options["program"] = value }
  cli.on("--cwd DIR", "Private fixture working directory") { |value| options["cwd"] = value }
  cli.on("--source PATH", "Owned fixture source") { |value| options["source"] = value }
  cli.on("--project-root DIR", "Canonical editor project root") { |value| options["project-root"] = value }
  cli.on("-h", "--help") do
    puts cli
    exit 0
  end
end

begin
  parser.parse
  run_probe(options)
rescue ex
  STDERR.puts "FAIL: #{ex.message}"
  exit 1
end
