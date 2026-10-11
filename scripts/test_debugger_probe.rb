#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "lib/debugger_probe"

class DebuggerProbeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.join(ROOT, "spec", "fixtures", "debugger", "control.c")
  ADAPTER = File.join(ROOT, "spec", "fixtures", "debugger", "fake_dap_adapter.rb")

  def test_source_breakpoint_is_not_entry_stop
    assert DebuggerProbe::DAPProbe.breakpoint_stop?({
      "type" => "event",
      "event" => "stopped",
      "body" => {"reason" => "breakpoint", "threadId" => 1}
    })
    refute DebuggerProbe::DAPProbe.breakpoint_stop?({
      "type" => "event",
      "event" => "stopped",
      "body" => {"reason" => "entry", "threadId" => 1}
    })
  end

  def test_sentinel_requires_known_integer_type_name_and_exact_value
    variables = [{"name" => "debugger_sentinel", "type" => "volatile Int32", "value" => "271828"}]
    assert DebuggerProbe::DAPProbe.sentinel_match?(variables, "271828")
    refute DebuggerProbe::DAPProbe.sentinel_match?(variables + variables, "271828")
    refute DebuggerProbe::DAPProbe.sentinel_match?(variables.map { |item| item.merge("value" => "271829") }, "271828")
    refute DebuggerProbe::DAPProbe.sentinel_match?(variables.map { |item| item.merge("type" => "String") }, "271828")
    refute DebuggerProbe::DAPProbe.sentinel_match?(variables.map { |item| item.merge("type" => "<unknown>") }, "271828")
  end

  def test_report_text_clipping_keeps_valid_utf8_and_sanitizes_invalid_bytes
    split_character = DebuggerProbe.text_excerpt("a☃b", 2)
    assert_equal "a", split_character
    assert split_character.valid_encoding?

    invalid_bytes = DebuggerProbe.text_excerpt("\xFFA\x00".b, 16)
    assert_equal "?A?", invalid_bytes
    assert invalid_bytes.valid_encoding?
  end

  def test_debugserver_identity_is_specific_validated_and_hashed
    assert_equal "unset", DebuggerProbe.debugserver_identity({})["status"]

    valid = DebuggerProbe.debugserver_identity("LLDB_DEBUGSERVER_PATH" => RbConfig.ruby)
    assert_equal "valid", valid["status"]
    assert_equal File.realpath(RbConfig.ruby), valid["resolved_path"]
    assert_equal Digest::SHA256.file(File.realpath(RbConfig.ruby)).hexdigest, valid["sha256"]

    invalid = DebuggerProbe.debugserver_identity("LLDB_DEBUGSERVER_PATH" => "/missing/debugserver")
    assert_equal "invalid", invalid["status"]
    assert_equal "path is not an executable file", invalid["validation_error"]
  end

  def test_framing_rejects_malformed_oversize_and_truncated_messages
    [
      "Content-Length: nope\r\n\r\n",
      "Content-Length: 9\r\n\r\n{}",
      "Content-Length: 4\r\n\r\n{}"
    ].each do |frame|
      assert_raises(DebuggerProbe::ProtocolError) do
        DebuggerProbe::DAPProbe.decode_message(frame, max_bytes: 8)
      end
    end
  end

  def test_success_requires_ordered_breakpoint_locals_array_step_and_exit
    result = run_probe("reverse")

    assert_equal "PASS", result["status"], result["failure"]
    assert_equal ["runInTerminal"], result["reverse_requests_rejected"]
    assert_equal ["initialized", "stopped", "stopped", "exited"], result["events"]
    assert_equal "PASS", result.dig("steps", "locals_sentinel")
    assert_equal "PASS", result.dig("steps", "record_child")
    assert_equal "PASS", result.dig("steps", "step_frame")
    assert_equal result["requested_breakpoint_line"] + 1, result.dig("step_frame", "line")
    assert_equal "none; values are opaque adapter output", result["formatter_certification"]
    record_children = result.fetch("raw_structural_children").find { |record| record["parent"] == "debugger_nested_outer" }
    assert_equal 1, record_children["returned_count"]
    assert_equal %w[value], record_children["children"].map { |child| child["name"] }
    assert_equal "31", record_children["children"].find { |child| child["name"] == "value" }["value"]
    assert_match(/PASS/, result["array_indexed_observation"])
    assert result["container_observations"].any? { |value| value["name"] == "debugger_array" }
  end

  def test_metadata_burst_is_sampled_boundedly_without_blocking_lifecycle
    result = run_probe("metadata-burst")
    assert_equal "PASS", result["status"], result["failure"]
    assert_equal 109, result["event_count"]
    assert_equal true, result["event_history_truncated"]
    assert_equal 64, result["events"].length
    assert_equal %w[initialized stopped stopped exited], result["events"].last(4)
    assert_equal "PASS", result.dig("steps", "exited")
  end

  def test_locally_buffered_early_exit_and_lifecycle_flood_cannot_certify_success
    early = run_probe("early-exited")
    refute_equal "PASS", early["status"]
    assert_match(/\Acontinue:/, early.fetch("failure"))
    assert_match(/exited event arrived before continue/, early.fetch("failure"))
    refute early.fetch("steps").key?("continue")

    flood = run_probe("lifecycle-event-flood")
    refute_equal "PASS", flood["status"]
    assert_match(/duplicate exited event|too many queued DAP lifecycle events/, flood.fetch("failure"))
  end

  def test_terminated_event_is_allowed_only_after_a_valid_exit_and_fragmented_observation_is_drained
    post_exit = run_probe("post-exit-terminated")
    assert_equal "PASS", post_exit["status"], post_exit["failure"]
    assert_equal %w[initialized stopped stopped exited terminated], post_exit["events"].last(5)

    premature = run_probe("terminated-before-exit")
    refute_equal "PASS", premature["status"]
    assert_match(/terminated event arrived before required exited event/, premature.fetch("failure"))

    duplicate = run_probe("duplicate-terminated-after-exit")
    refute_equal "PASS", duplicate["status"]
    assert_match(/\Adisconnect:/, duplicate.fetch("failure"))
    assert_match(/duplicate terminated event/, duplicate.fetch("failure"))

    fragmented = run_probe("partial-benign-before-continue")
    assert_equal "PASS", fragmented["status"], fragmented["failure"]
    assert_includes fragmented["events"], "module"
    assert_equal "PASS", fragmented.dig("steps", "exited")
  end

  def test_observation_floods_hit_message_and_aggregate_byte_budgets
    message_flood = run_probe("metadata-message-flood", step_timeout: 2.0, process_timeout: 5.0)
    refute_equal "PASS", message_flood["status"]
    assert_match(/\Ainitialize:/, message_flood.fetch("failure"))
    assert_match(/DAP message count exceeds limit/, message_flood.fetch("failure"))
    assert_equal 256, message_flood.fetch("event_count")
    assert_equal 64, message_flood.fetch("events").length
    assert_equal true, message_flood.fetch("event_history_truncated")

    byte_flood = run_probe("aggregate-byte-flood", step_timeout: 3.0, process_timeout: 8.0)
    refute_equal "PASS", byte_flood["status"]
    assert_match(/\Ainitialize:/, byte_flood.fetch("failure"))
    assert_match(/DAP total traffic exceeds limit/, byte_flood.fetch("failure"))
    assert_equal 4, byte_flood.fetch("dap_output_event_count")
    assert_operator byte_flood.fetch("dap_output_bytes_captured"), :<=, 1200
  end

  def test_seeded_protocol_and_false_positive_cases_fail_closed
    cases = {
      "wrong-breakpoint" => "source_breakpoint",
      "entry" => "stop_breakpoint",
      "missing-locals" => "locals",
      "wrong-sentinel" => "locals",
      "wrong-sentinel-type" => "locals",
      "duplicate-sentinel" => "locals",
      "missing-record" => "children",
      "wrong-record-value" => "children",
      "wrong-record-type" => "children",
      "wrong-record-names" => "children",
      "wrong-record-count" => "children",
      "step-same-frame" => "step_stackTrace",
      "step-wrong-line" => "step_stackTrace",
      "step-wrong-source" => "step_stackTrace",
      "step-different-thread" => "stop_step",
      "event-order" => "initialized",
      "reverse-flood" => "initialize",
      "unknown-response" => "initialize",
      "wrong-array-response-command" => "children",
      "malformed" => "initialize",
      "oversize" => "initialize",
      "truncated" => "initialize",
      "eof" => "initialize"
    }

    cases.each do |scenario, phase|
      result = run_probe(scenario)
      refute_equal "PASS", result["status"], "#{scenario} falsely passed"
      assert_match(/\A#{Regexp.escape(phase)}:/, result.fetch("failure"), "#{scenario} failed in an unexpected phase")
    end
  end

  def test_array_formatter_observations_do_not_gate_generic_children_or_stepping
    %w[wrong-array-order wrong-array-names wrong-array-count array-request-rejected array-shape-unavailable].each do |scenario|
      result = run_probe(scenario)
      assert_equal "PASS", result["status"], result["failure"]
      assert_equal "PASS", result.dig("steps", "record_child")
      assert_equal "PASS", result.dig("steps", "step_frame")
      assert_equal "PASS", result.dig("steps", "exited")
      assert_match(/NOT_ADMITTED/, result["array_indexed_observation"])
    end
  end

  def test_failed_launch_and_unverified_breakpoint_preserve_bounded_diagnostics
    launch = run_probe("launch-failed")
    refute_equal "PASS", launch["status"]
    assert_match(/seeded launch failed before initialized/, launch.fetch("failure"))
    assert_equal "launch", launch.dig("failed_dap_responses", 0, "command")
    assert_match(/seeded launch diagnostic/, launch.fetch("adapter_stderr_excerpt"))
    assert_operator launch.fetch("adapter_stderr_excerpt").bytesize, :<=, 1200

    formatted = run_probe("launch-failed-error-format")
    refute_equal "PASS", formatted["status"]
    assert_match(/seeded body\.error\.format diagnostic/, formatted.fetch("failure"))
    assert_match(/seeded body\.error\.format diagnostic/, formatted.dig("failed_dap_responses", 0, "message"))

    breakpoint = run_probe("breakpoint-unverified")
    refute_equal "PASS", breakpoint["status"]
    assert_match(/seeded breakpoint rejected by adapter/, breakpoint.fetch("failure"))
    assert_match(/seeded breakpoint rejected by adapter/, breakpoint.dig("resolved_breakpoint", "message"))
    assert_match(/seeded adapter diagnostic/, breakpoint.fetch("adapter_stderr_excerpt"))
    assert_operator breakpoint.fetch("adapter_stderr_excerpt").bytesize, :<=, 1200
    assert_equal 2, breakpoint.fetch("dap_output_event_count")
    assert_equal %w[stderr console], breakpoint.fetch("dap_output_events").map { |event| event["category"] }
    assert_match(/seeded DAP target creation diagnostic/, breakpoint.dig("dap_output_events", 0, "output"))
  end

  def test_dap_output_capture_is_bounded_with_count_and_truncation_signals
    result = run_probe("output-byte-flood")
    assert_equal "PASS", result["status"], result["failure"]
    assert_equal 3, result["dap_output_event_count"]
    assert_equal 2100, result["dap_output_bytes_observed"]
    assert_equal 1200, result["dap_output_bytes_captured"]
    assert_equal true, result["dap_output_capture_truncated"]
    assert_operator result.fetch("dap_output_events").length, :<=, 8
    assert_operator result.fetch("dap_output_events").sum { |event| event.fetch("output").bytesize }, :<=, 1200

    saturated = run_probe("event-saturation")
    assert_equal "PASS", saturated["status"], saturated["failure"]
    assert_equal 65, saturated["dap_output_event_count"]
    assert_equal 8, saturated.fetch("dap_output_events").length
    assert_equal true, saturated["dap_output_capture_truncated"]
    assert_equal 69, saturated["event_count"]
    assert_equal true, saturated["event_history_truncated"]
    assert_equal %w[initialized stopped stopped exited], saturated["events"].last(4)
  end

  def test_timeout_cleans_only_the_owned_process_group
    Dir.mktmpdir("debugger-probe-test-") do |directory|
      marker = File.join(directory, "child-term")
      pidfile = File.join(directory, "child.pid")
      result = run_probe("timeout-owned-child", step_timeout: 0.15, process_timeout: 1.0, adapter_args: [marker, pidfile])

      refute_equal "PASS", result["status"]
      assert_equal "owned_process_group_terminated", result.dig("adapter_cleanup", "status")
      assert_equal "term", File.read(marker)
      assert_match(/\A\d+\z/, File.read(pidfile))
    end
  end

  def test_adapter_write_deadline_bounds_a_peer_that_never_reads
    process = DebuggerProbe::OwnedProcess.new([RbConfig.ruby, "-e", "sleep 30"])
    started = DebuggerProbe.monotonic_time
    assert_raises(DebuggerProbe::StepTimeout) do
      process.write("x" * (4 * 1024 * 1024), deadline: started + 0.12)
    end
    assert_operator DebuggerProbe.monotonic_time - started, :<, 1.0
  ensure
    process.terminate if process
    process.close if process
  end

  def test_timeout_options_reject_nonfinite_values
    assert_raises(OptionParser::InvalidArgument) do
      DebuggerProbe.parse_options([
        "--adapter", ADAPTER, "--cc", ADAPTER, "--crystal-bin", ADAPTER, "--adamas-bin", ADAPTER,
        "--step-timeout", "Infinity"
      ])
    end
  end

  private

  def run_probe(scenario, step_timeout: 0.4, process_timeout: 2.0, adapter_args: [])
    probe = DebuggerProbe::DAPProbe.new(
      adapter_path: ADAPTER,
      adapter_args: [scenario] + adapter_args,
      step_timeout: step_timeout,
      process_timeout: process_timeout
    )
    probe.run(binary_path: __FILE__, source_path: FIXTURE)
  end
end
