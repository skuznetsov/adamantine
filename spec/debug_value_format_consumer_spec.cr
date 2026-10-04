require "spec"
require "random/secure"
require "json"
require "../src/adamantine/debug_controller"

private def format_consumer_root(label : String) : Path
  root = Path.new(Dir.tempdir, "adamantine-debug-format-#{label}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root.to_s)
  Path.new(File.realpath(root.to_s))
end

private def format_consumer_await(controller : Adamantine::DebugController,
                                  timeout : Time::Span = 4.seconds,
                                  &ready : Adamantine::DebugController::Snapshot -> Bool) : Adamantine::DebugController::Snapshot
  deadline = Time.monotonic + timeout
  snapshot = controller.poll
  until ready.call(snapshot)
    raise "format consumer fixture did not reach expected state: lifecycle=#{snapshot.state.lifecycle}, error=#{snapshot.last_error}" if Time.monotonic >= deadline
    sleep 5.milliseconds
    snapshot = controller.poll
  end
  snapshot
end

private def format_consumer_records(log : Path) : Array(JSON::Any)
  return [] of JSON::Any unless File.file?(log.to_s)
  File.read_lines(log.to_s).compact_map do |line|
    JSON.parse(line)
  rescue
    nil
  end
end

private def start_json_provenance_controller(label : String) : Tuple(Adamantine::DebugController, Path)
  root = format_consumer_root(label)
  adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
  ruby = Process.find_executable("ruby") || raise "Ruby is required for the local fixture"
  log = root / "adapter.jsonl"
  profile = Adamantine::Debugging::LaunchProfile.new(
    id: label,
    name: "Format fixture",
    adapter_argv: [ruby, adapter.to_s, log.to_s, "value_json_provenance"],
    program: Process.find_executable("true") || "/usr/bin/true",
    cwd: root.to_s
  )
  controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
    Adamantine::Dap::Client.new(argv, cwd)
  })
  review = controller.prepare_launch(profile, root)
  raise "local format fixture should be reviewable: #{review.errors.join("; ")}" unless review.valid?
  raise "local format fixture should start" unless controller.start(review).accepted?
  format_consumer_await(controller) do |snapshot|
    !snapshot.frames.empty? && snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active
  end
  raise "fixture scopes should be explicitly requestable" unless controller.open_scopes.accepted?
  format_consumer_await(controller) do |snapshot|
    names = snapshot.variables.nodes.map(&.name)
    names.includes?("multiline_json") && names.includes?("control_json") && names.includes?("prefix_json")
  end
  {controller, root}
end

private def start_value_format_controller(label : String, mode : String) : Tuple(Adamantine::DebugController, Path, Path)
  root = format_consumer_root(label)
  adapter = Path.new(Dir.current, "spec/fixtures/debugger/dap_controller_adapter.rb")
  ruby = Process.find_executable("ruby") || raise "Ruby is required for the local fixture"
  log = root / "adapter.jsonl"
  profile = Adamantine::Debugging::LaunchProfile.new(
    id: label,
    name: "Format fixture",
    adapter_argv: [ruby, adapter.to_s, log.to_s, mode],
    program: Process.find_executable("true") || "/usr/bin/true",
    cwd: root.to_s
  )
  controller = Adamantine::DebugController.new(->(argv : Array(String), cwd : Path) {
    Adamantine::Dap::Client.new(argv, cwd)
  })
  review = controller.prepare_launch(profile, root)
  raise "local format fixture should be reviewable: #{review.errors.join("; ")}" unless review.valid?
  raise "local format fixture should start" unless controller.start(review).accepted?
  format_consumer_await(controller) do |snapshot|
    !snapshot.frames.empty? && snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active
  end
  raise "fixture scopes should be explicitly requestable" unless controller.open_scopes.accepted?
  format_consumer_await(controller) do |snapshot|
    snapshot.variables.nodes.any? { |node| node.name == "duplicate" }
  end
  {controller, root, log}
end

describe "DebugController value-format consumer" do
  it "interprets complete multiline JSON but rejects control-sanitized and clipped valid-prefix text" do
    controller, _root = start_json_provenance_controller("json-provenance")
    nodes = controller.snapshot.variables.nodes
    multiline = nodes.find { |node| node.name == "multiline_json" } || raise "multiline JSON fixture node missing"
    control = nodes.find { |node| node.name == "control_json" } || raise "control JSON fixture node missing"
    prefix = nodes.find { |node| node.name == "prefix_json" } || raise "prefix JSON fixture node missing"

    parsed = controller.render_value(multiline.id, Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "complete multiline JSON should remain interpretable" unless parsed.available?
    raise "rendered JSON should remain structurally valid" unless JSON.parse(parsed.text)

    sanitized = controller.render_value(control.id, Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "JSON changed by terminal-safe sanitization must not be interpreted" if sanitized.available?

    clipped = controller.render_value(prefix.id, Adamantine::Debugging::DebugValueFormat::JsonInterpretation)
    raise "a clipped valid prefix must not be certified as complete JSON" if clipped.available?
    raise "the clipped-prefix rejection should explain completeness" unless clipped.reason.try(&.includes?("complete"))
  ensure
    controller.try(&.close)
  end

  it "refetches Hex from the exact originating page and matches duplicate names by full child identity" do
    controller, _root, log = start_value_format_controller("hex-origin", "value_format")
    duplicates = controller.snapshot.variables.nodes.select { |node| node.name == "duplicate" }
    raise "fixture must contain duplicate display names" unless duplicates.size == 2
    target = duplicates.find { |node| node.value == "11" } || raise "second duplicate is missing"
    first = duplicates.find { |node| node.value == "10" } || raise "first duplicate is missing"
    hex = Adamantine::Debugging::DebugValueFormat::Hex

    before = controller.render_value(target.id, hex)
    raise "rendering must not issue an implicit refetch" if before.available?
    raise "an unrequested value on a capable adapter should invite an explicit request" unless before.reason.try(&.includes?("request Hex explicitly"))
    raise "explicit Hex request should be accepted" unless controller.request_value_format(target.id, hex).accepted?
    format_consumer_await(controller) do |_snapshot|
      controller.render_value(target.id, hex).available?
    end

    rendered = controller.render_value(target.id, hex)
    raise "the selected duplicate must receive its own adapter Hex" unless rendered.text == "0x0b"
    raise "the unselected duplicate must not inherit another child's Hex" if controller.render_value(first.id, hex).available?
    records = format_consumer_records(log)
    request = records.find do |record|
      record["type"]?.try(&.as_s?) == "request" &&
        record["command"]?.try(&.as_s?) == "variables" &&
        record.dig?("arguments", "format", "hex") == JSON::Any.new(true)
    end || raise "explicit Hex must use DAP variables.format.hex"
    original_page = records.find do |record|
      record["type"]?.try(&.as_s?) == "request" &&
        record["command"]?.try(&.as_s?) == "variables" &&
        record.dig?("arguments", "format").nil?
    end || raise "fixture must record the original unformatted page request"
    arguments = request["arguments"]
    raise "format refetch must retain the originating container" unless arguments["variablesReference"].as_i == 700
    raise "format refetch must retain the originating page start" unless arguments["start"].as_i == 0
    raise "regular pages must request at most the configured 100 children" unless original_page["arguments"]["count"].as_i == 100
    raise "format refetch must preserve the exact originating wire count" unless arguments["count"] == original_page["arguments"]["count"]
    raise "format must use the top-level VariablesArguments.format object" unless arguments["format"].as_h == {"hex" => JSON::Any.new(true)}
    raise "formatting must not issue evaluate" if records.any? { |record| record["command"]?.try(&.as_s?) == "evaluate" }
  ensure
    controller.try(&.close)
  end

  it "refuses formatted values when the adapter did not advertise support and rejects a mismatched child" do
    unsupported, _unsupported_root, unsupported_log = start_value_format_controller("hex-unsupported", "value_format_no_capability")
    unsupported_node = unsupported.snapshot.variables.nodes.find { |node| node.name == "duplicate" } || raise "duplicate fixture value missing"
    raise "adapter capability should remain absent" if unsupported.snapshot.capabilities.value_formatting_options
    raise "unsupported explicit format should be rejected" if unsupported.request_value_format(unsupported_node.id, Adamantine::Debugging::DebugValueFormat::Hex).accepted?
    unsupported_detail = unsupported.render_value(unsupported_node.id, Adamantine::Debugging::DebugValueFormat::Hex)
    raise "missing capability should be reported honestly" unless unsupported_detail.reason.try(&.includes?("did not advertise"))
    unsupported_records = format_consumer_records(unsupported_log)
    raise "unsupported format must not send a DAP refetch" if unsupported_records.any? do |record|
                                                                record["type"]?.try(&.as_s?) == "request" && record.dig?("arguments", "format")
                                                              end
  ensure
    unsupported.try(&.close)
  end

  it "reports an explicit retry reason when a sibling variables page retires pending Hex" do
    controller, root, log = start_value_format_controller(
      "hex-sibling-refresh", "value_format,value_format_sibling_refresh")
    format = Adamantine::Debugging::DebugValueFormat::Hex
    target = controller.snapshot.variables.nodes.find do |node|
      node.name == "duplicate" && node.value == "11"
    end || raise "second duplicate is missing"
    raise "fixture must advertise standard value formatting" unless controller.snapshot.capabilities.value_formatting_options

    format_consumer_await(controller) do |_snapshot|
      format_consumer_records(log).any? do |record|
        record["name"]?.try(&.as_s?) == "sibling_variables_held"
      end
    end
    raise "explicit Hex request should be accepted" unless controller.request_value_format(target.id, format).accepted?
    format_consumer_await(controller) do |_snapshot|
      format_consumer_records(log).any? do |record|
        record["type"]?.try(&.as_s?) == "request" &&
          record["command"]?.try(&.as_s?) == "variables" &&
          record.dig?("arguments", "format", "hex").try(&.as_bool?) == true
      end
    end
    File.write((root / "adapter.jsonl.sibling-release").to_s, "release")
    format_consumer_await(controller) do |_snapshot|
      format_consumer_records(log).any? do |record|
        record["name"]?.try(&.as_s?) == "sibling_variables_response_written"
      end
    end
    format_consumer_await(controller) do |_snapshot|
      format_consumer_records(log).any? do |record|
        record["name"]?.try(&.as_s?) == "value_format_response_written"
      end
    end

    old_error = controller.snapshot.last_error
    format_consumer_await(controller) do |_snapshot|
      current = controller.render_value(target.id, format)
      current.reason != "formatted value request is pending"
    end
    rendered = controller.render_value(target.id, format)
    raise "expected a local refresh retry reason, got #{rendered.reason}" unless rendered.reason.try(&.includes?("variable data refreshed"))
    raise "a retired Hex response must not expose stale adapter text" if rendered.available?
    raise "the retry explanation must not claim formatting is unsupported" if rendered.reason.try(&.includes?("did not advertise"))
    raise "the sibling-page retirement must not fail the debugger session" if controller.snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Failed
    raise "retired Hex responses must not replace global diagnostics" unless controller.snapshot.last_error == old_error
    raise "rendering must not automatically retry Hex" if format_consumer_records(log).count do |record|
                                                            record["type"]?.try(&.as_s?) == "request" &&
                                                            record["command"]?.try(&.as_s?) == "variables" &&
                                                            record.dig?("arguments", "format", "hex").try(&.as_bool?) == true
                                                          end != 1

    # The old response must be consumed before a later explicit request can
    # use the single bounded formatted-request slot again.
    deadline = Time.monotonic + 1.second
    retry = nil.as(Adamantine::DebugController::ActionSubmission?)
    until retry
      raise "old Hex request was not retired from the client slot" if Time.monotonic >= deadline
      submission = controller.request_value_format(target.id, format)
      if submission.accepted?
        retry = submission
      else
        raise "unexpected retry rejection: #{submission.reason}" unless submission.reason.try(&.includes?("still pending"))
        controller.poll
        sleep 5.milliseconds
      end
    end
    controller.cancel_value_format(target.id)
  ensure
    controller.try(&.close)
  end

  it "fails closed when the adapter returns the wrong same-name child" do
    controller, _root, _log = start_value_format_controller("hex-wrong-child", "value_format,value_format_wrong_child")
    target = controller.snapshot.variables.nodes.find { |node| node.name == "duplicate" && node.value == "11" } || raise "second duplicate is missing"
    raise "explicit Hex request should be accepted" unless controller.request_value_format(target.id, Adamantine::Debugging::DebugValueFormat::Hex).accepted?
    snapshot = format_consumer_await(controller) do |_current|
      detail = controller.render_value(target.id, Adamantine::Debugging::DebugValueFormat::Hex)
      !detail.available? && detail.reason.try(&.includes?("different child")) == true
    end
    raise "a mismatched child must not publish a formatted value" if controller.render_value(target.id, Adamantine::Debugging::DebugValueFormat::Hex).available?
    raise "mismatch should remain bounded to inspection diagnostics" if snapshot.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Failed
  ensure
    controller.try(&.close)
  end

  it "retires late formatted success and failure after the selected frame changes" do
    {"value_format,value_format_late" => true, "value_format,value_format_late_fail" => false}.each do |mode, success|
      controller, root, log = start_value_format_controller("hex-late", mode)
      target = controller.snapshot.variables.nodes.find { |node| node.name == "duplicate" && node.value == "11" } || raise "second duplicate is missing"
      old_error = controller.snapshot.last_error
      raise "explicit Hex request should be accepted" unless controller.request_value_format(target.id, Adamantine::Debugging::DebugValueFormat::Hex).accepted?
      format_consumer_await(controller) do |_current|
        format_consumer_records(log).any? { |record| record["name"]?.try(&.as_s?) == "value_format_held" }
      end
      raise "an available caller frame should be selectable" unless controller.select_frame(501).accepted?
      File.write((root / "adapter.jsonl.format-release").to_s, "release")
      format_consumer_await(controller) do |_current|
        format_consumer_records(log).any? { |record| record["name"]?.try(&.as_s?) == "value_format_response_written" }
      end
      3.times do
        sleep 5.milliseconds
        controller.poll
      end
      rendered = controller.render_value(target.id, Adamantine::Debugging::DebugValueFormat::Hex)
      raise "late response must not survive frame retirement" if rendered.available?
      raise "stale formatted response must not replace global diagnostics" unless controller.snapshot.last_error == old_error
      outcome = format_consumer_records(log).find { |record| record["name"]?.try(&.as_s?) == "value_format_response_written" }
      raise "fixture mode should record its actual response outcome" unless outcome && outcome["success"]?.try(&.as_bool?) == success
    ensure
      controller.try(&.close)
    end
  end

  it "retires an explicit local cancellation, consumes the late ticket, and permits a later request" do
    {"value_format,value_format_late" => true, "value_format,value_format_late_fail" => false}.each do |mode, success|
      controller, root, log = start_value_format_controller("hex-cancel", mode)
      target = controller.snapshot.variables.nodes.find { |node| node.name == "duplicate" && node.value == "11" } || raise "second duplicate is missing"
      format = Adamantine::Debugging::DebugValueFormat::Hex
      raise "first explicit Hex request should be accepted" unless controller.request_value_format(target.id, format).accepted?
      format_consumer_await(controller) do |_current|
        format_consumer_records(log).any? { |record| record["name"]?.try(&.as_s?) == "value_format_held" }
      end
      controller.cancel_value_format(target.id)
      raise "explicit cancellation must retire the displayed detail immediately" if controller.render_value(target.id, format).available?
      File.write((root / "adapter.jsonl.format-release").to_s, "release")
      format_consumer_await(controller) do |_current|
        format_consumer_records(log).count { |record| record["name"]?.try(&.as_s?) == "value_format_response_written" } >= 1
      end
      raise "late response after cancellation must remain retired" if controller.render_value(target.id, format).available?

      raise "same-frame scopes should remain requestable after local cancellation" unless controller.open_scopes.accepted?
      format_consumer_await(controller) do |_current|
        requests = format_consumer_records(log).count do |record|
          record["type"]?.try(&.as_s?) == "request" && record["command"]?.try(&.as_s?) == "variables"
        end
        refreshed_nodes = controller.snapshot.variables.nodes.select { |node| node.name == "duplicate" }
        requests >= 3 && refreshed_nodes.size == 2 && refreshed_nodes.all? { |node| node.id != target.id }
      end
      fresh_target = controller.snapshot.variables.nodes.find { |node| node.name == "duplicate" && node.value == "11" } || raise "refreshed duplicate is missing"

      raise "a fresh request should be accepted after the old response is consumed" unless controller.request_value_format(fresh_target.id, format).accepted?
      format_consumer_await(controller) do |_current|
        format_consumer_records(log).count { |record| record["name"]?.try(&.as_s?) == "value_format_response_written" } >= 2
      end
      settled = format_consumer_await(controller) do |_current|
        detail = controller.render_value(fresh_target.id, format)
        detail.available? || detail.reason.try(&.includes?("fixture formatted value failed")) == true
      end
      detail = controller.render_value(fresh_target.id, format)
      raise "late failure must settle locally without poisoning session diagnostics" unless success ? detail.available? : detail.reason.try(&.includes?("fixture formatted value failed"))
      raise "the session must remain active after an adapter formatting failure" unless settled.state.lifecycle == Adamantine::DebugSessionState::Lifecycle::Active
    ensure
      controller.try(&.close)
    end
  end
end
