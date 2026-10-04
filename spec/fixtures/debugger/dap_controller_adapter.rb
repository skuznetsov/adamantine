#!/usr/bin/env ruby
require "digest"
require "json"

# Deterministic stdio peer for the DebugController tests. It is not a target
# debugger and contains no shell/evaluation path beyond the explicit DAP
# evaluate branch used by watch-safety tests.
STDIN.binmode
STDOUT.binmode
STDOUT.sync = true
ARGV.shift if ARGV.first == "--no-lldbinit"
LOG_PATH = ARGV.fetch(0)
MODE = ARGV.fetch(1, "basic")
MODE_FLAGS = MODE.split(",")
$adapter_sequence = 0
$stack_trace_count = 0
$pending_launch = nil
$held_evaluate = nil

def mode?(name)
  MODE_FLAGS.include?(name)
end

def log_record(record)
  File.open(LOG_PATH, "a") { |file| file.puts(JSON.generate(record)) }
end

if mode?("smoke_process")
  log_record({"type" => "fixture", "name" => "smoke_process_started", "pid" => Process.pid})
  at_exit do
    log_record({"type" => "fixture", "name" => "smoke_process_exited", "pid" => Process.pid})
  end
end

def read_message
  headers = {}
  loop do
    line = STDIN.gets
    return nil unless line
    line = line.sub(/\r?\n\z/, "")
    break if line.empty?
    key, value = line.split(":", 2)
    return nil unless key && value
    headers[key.downcase] = value.strip
  end
  length = Integer(headers.fetch("content-length"), 10) rescue nil
  return nil unless length && length.positive? && length <= 16 * 1024 * 1024
  bytes = STDIN.read(length)
  return nil unless bytes && bytes.bytesize == length
  JSON.parse(bytes)
rescue JSON::ParserError
  nil
end

def write_message(message)
  $adapter_sequence += 1
  message["seq"] = $adapter_sequence
  body = JSON.generate(message)
  STDOUT.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  STDOUT.flush
end

def respond(request, body: {}, success: true, message: nil)
  response = {
    "type" => "response",
    "request_seq" => request.fetch("seq"),
    "command" => request.fetch("command"),
    "success" => success,
  }
  response["body"] = body if body
  response["message"] = message if message
  write_message(response)
end

def event(name, body = {})
  write_message({"type" => "event", "event" => name, "body" => body})
end

loop do
  request = read_message
  break unless request
  next unless request["type"] == "request"

  log_record(request)
  case request.fetch("command")
  when "initialize"
    capabilities = {
      "supportsConfigurationDoneRequest" => !mode?("config_done_unsupported"),
      "exceptionBreakpointFilters" => [
        {"filter" => "all", "label" => "All Exceptions", "default" => true},
      ],
    }
    capabilities["supportsValueFormattingOptions"] = true if mode?("value_format") || mode?("value_format_late") || mode?("value_format_sibling_refresh")
    capabilities["supportTerminateDebuggee"] = true if mode?("terminate_capability")
    respond(request, body: capabilities)
  when "launch"
    $pending_launch = request
    log_record({"type" => "fixture", "name" => "launch_pending"})
    event("initialized")
    if mode?("config_done_unsupported")
      log_record({"type" => "fixture", "name" => "launch_response"})
      respond($pending_launch)
      $pending_launch = nil
      event("process", {"name" => "fixture-target"})
      event("stopped", {"reason" => "pause", "threadId" => 42, "allThreadsStopped" => true})
    end
  when "setBreakpoints"
    source_breakpoints = request.dig("arguments", "breakpoints") || []
    if mode?("set_breakpoints_reject") && !source_breakpoints.empty?
      log_record({"type" => "fixture", "name" => "set_breakpoints_rejected"})
      respond(request, success: false, message: "fixture rejected breakpoint set")
      next
    end
    resolved = source_breakpoints.map.with_index do |breakpoint, index|
      {"id" => index + 1, "verified" => true, "line" => breakpoint.fetch("line")}
    end
    if mode?("hold_breakpoints")
      log_record({"type" => "fixture", "name" => "set_breakpoints_pending"})
      release_path = "#{LOG_PATH}.release"
      sleep 0.005 until File.exist?(release_path)
      log_record({"type" => "fixture", "name" => "set_breakpoints_released"})
    end
    log_record({"type" => "fixture", "name" => "set_breakpoints_response"})
    respond(request, body: {"breakpoints" => resolved})
  when "setExceptionBreakpoints"
    log_record({"type" => "fixture", "name" => "exception_breakpoints_response"})
    if mode?("exception_breakpoints_reject")
      respond(request, success: false, message: "fixture rejected exception filters")
    else
      respond(request)
    end
  when "configurationDone"
    log_record({"type" => "fixture", "name" => "configurationDone"})
    respond(request)
    if $pending_launch
      stop_body = {"reason" => "breakpoint", "allThreadsStopped" => true}
      stop_body["threadId"] = 42 unless mode?("no_thread")
      process_id = mode?("process_self_pid") ? Process.pid : 222
      if mode?("stop_before_launch_response")
        event("process", {"name" => "fixture-target", "systemProcessId" => process_id})
        log_record({"type" => "fixture", "name" => "stopped_before_launch_response"})
        event("stopped", stop_body)
        log_record({"type" => "fixture", "name" => "launch_response"})
        respond($pending_launch)
      else
        log_record({"type" => "fixture", "name" => "launch_response"})
        respond($pending_launch)
        event("process", {"name" => "fixture-target", "systemProcessId" => process_id})
        event("stopped", stop_body)
      end
      $pending_launch = nil
    end
  when "threads"
    respond(request, body: {"threads" => [{"id" => 42, "name" => "fixture-thread"}]})
  when "stackTrace"
    $stack_trace_count += 1
    source = if mode?("source_checksum")
               requested_path = ARGV.fetch(2) { raise ArgumentError, "source_checksum mode requires a source path" }
               source_path = File.realpath(requested_path)
               source = {
                 "name"      => File.basename(source_path),
                 "path"      => source_path,
               }
               unless mode?("checksum_absent")
                 checksum = Digest::SHA256.file(source_path).hexdigest
                 checksum_entry = if mode?("checksum_unknown")
                                    {"algorithm" => "future-hash", "checksum" => checksum}
                                  elsif mode?("checksum_malformed")
                                    {"algorithm" => "SHA256", "checksum" => "not-a-sha256"}
                                  else
                                    {"algorithm" => "SHA256", "checksum" => checksum}
                                  end
                 source["checksums"] = [checksum_entry]
               end
               source["sourceReference"] = 77 if mode?("source_reference")
               source
             else
               {"name" => "main.cr", "path" => "/fixture/main.cr"}
             end
    main_line = mode?("source_checksum") && $stack_trace_count > 1 ? 13 : 12
    respond(request, body: {"stackFrames" => [
      {"id" => 500, "name" => "fixture_main", "line" => main_line, "column" => 1,
       "source" => source},
      {"id" => 501, "name" => "fixture_caller", "line" => 4, "column" => 1,
       "source" => source},
    ]})
  when "scopes"
    if mode?("malformed_scope_entries")
      respond(request, body: {"scopes" => [
        nil,
        {},
        {"name" => 7, "variablesReference" => 700},
        {"name" => "String reference", "variablesReference" => "700"},
        {"name" => "Negative count", "variablesReference" => 700, "namedVariables" => -1},
        {"name" => "Typed count", "variablesReference" => 700, "indexedVariables" => "2"},
      ]})
      next
    end
    if mode?("malformed_scopes")
      respond(request, body: {"scopes" => "not-an-array"})
      next
    end
    if mode?("hold_scopes_reject")
      log_record({"type" => "fixture", "name" => "scopes_held"})
      release_path = "#{LOG_PATH}.scopes-release"
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
      until File.exist?(release_path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.005
      end
      respond(request, success: false, message: "fixture rejected stale scopes")
      log_record({"type" => "fixture", "name" => "scopes_released"})
      next
    end
    if mode?("reject_scopes")
      respond(request, success: false, message: "fixture rejected scopes")
      next
    end
    if mode?("empty_scopes")
      respond(request, body: {"scopes" => []})
      next
    end
      variable_count = mode?("value_format") || mode?("value_format_late") || mode?("value_format_no_capability") || mode?("value_format_sibling_refresh") ? 100 : 3
    scopes = [
      {"name" => "Locals", "variablesReference" => 700, "expensive" => false, "namedVariables" => variable_count},
    ]
    if mode?("value_format_sibling_refresh")
      scopes << {"name" => "Sibling", "variablesReference" => 710, "expensive" => false, "namedVariables" => 1}
    end
    respond(request, body: {"scopes" => scopes})
  when "variables"
    if mode?("value_json_provenance")
      variables = [
        {"name" => "multiline_json", "value" => "{\n  \"x\": 1\n}", "type" => "String", "variablesReference" => 0},
        {"name" => "control_json", "value" => "{\"x\":\"a\u0000b\"}", "type" => "String", "variablesReference" => 0},
        {"name" => "prefix_json", "value" => "[0]" + (" " * (64 * 1024)) + "not-json", "type" => "String", "variablesReference" => 0},
      ]
      respond(request, body: {"variables" => variables})
      next
    end
    if mode?("value_format") || mode?("value_format_late") || mode?("value_format_no_capability") || mode?("value_format_sibling_refresh")
      reference = request.dig("arguments", "variablesReference")
      start = request.dig("arguments", "start") || 0
      format = request.dig("arguments", "format")
      log_record({"type" => "fixture", "name" => "value_format_variables",
                  "reference" => reference, "start" => start,
                  "count" => request.dig("arguments", "count"), "format" => format})
      variables = if reference == 700
                    [
                      {"name" => "duplicate", "value" => "10", "type" => "Int32", "evaluateName" => "first", "variablesReference" => 0},
                      {"name" => "duplicate", "value" => "11", "type" => "Int32", "evaluateName" => "second", "variablesReference" => 0},
                    ]
                  elsif reference == 710 && mode?("value_format_sibling_refresh")
                    [{"name" => "sibling_value", "value" => "77", "type" => "Int32", "variablesReference" => 0}]
                  else
                    []
                  end
      if reference == 710 && mode?("value_format_sibling_refresh") && !format
        log_record({"type" => "fixture", "name" => "sibling_variables_held"})
        release_path = "#{LOG_PATH}.sibling-release"
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
        until File.exist?(release_path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.005
        end
        selected = variables.slice(start, request.dig("arguments", "count") || variables.size) || []
        respond(request, body: {"variables" => selected})
        log_record({"type" => "fixture", "name" => "sibling_variables_response_written"})
        next
      end
      count = request.dig("arguments", "count") || variables.size
      selected = variables.slice(start, count) || []
      if format && format["hex"] == true
        selected = selected.map do |variable|
          variable.merge("value" => (variable["evaluateName"] == "second" ? "0x0b" : "0x0a"))
        end
      end
      if mode?("value_format_wrong_child") && format && format["hex"] == true
        selected = selected.dup
        selected[1] = variables.first.merge("value" => "0xff") if selected.size > 1
      end
      if (mode?("value_format_late") || mode?("value_format_late_fail")) && format && format["hex"] == true
        log_record({"type" => "fixture", "name" => "value_format_held"})
        release_path = "#{LOG_PATH}.format-release"
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
        until File.exist?(release_path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.005
        end
      end
      if mode?("value_format_late_fail") && format && format["hex"] == true
        respond(request, success: false, message: "fixture formatted value failed after frame changed")
      else
        respond(request, body: {"variables" => selected})
      end
      if format && format["hex"] == true
        log_record({"type" => "fixture", "name" => "value_format_response_written",
                    "success" => !mode?("value_format_late_fail")})
      end
      next
    end
    start = request.dig("arguments", "start") || 0
    variables = [
      {"name" => "sentinel", "value" => "271828", "type" => "Int32", "variablesReference" => 0},
      {"name" => "record", "value" => "Record", "type" => "Record", "variablesReference" => 701, "namedVariables" => 1},
      {"name" => "items", "value" => "Array", "type" => "Array(Int32)", "variablesReference" => 702, "indexedVariables" => 2},
    ]
    children = {
      701 => [{"name" => "value", "value" => "31", "type" => "Int32", "variablesReference" => 0}],
      702 => [
        {"name" => "[0]", "value" => "22", "type" => "Int32", "variablesReference" => 0},
        {"name" => "[1]", "value" => "44", "type" => "Int32", "variablesReference" => 0},
      ],
    }
    data = children[request.dig("arguments", "variablesReference")] || variables
    count = request.dig("arguments", "count") || data.size
    respond(request, body: {"variables" => data.slice(start, count) || []})
  when "next", "stepIn", "stepOut"
    if mode?("next_never_replies")
      log_record({"type" => "fixture", "name" => "next_held_without_response"})
      next
    end
    step_event = {"reason" => "step", "threadId" => request.dig("arguments", "threadId"), "allThreadsStopped" => true}
    if $held_evaluate && (mode?("hold_evaluate") || mode?("hold_evaluate_fail") || mode?("hold_evaluate_fail_after_second") || mode?("hold_evaluate_success_after_second"))
      event("stopped", step_event)
      log_record({"type" => "fixture", "name" => "next_stopped"})
      respond(request)
      held = $held_evaluate
      $held_evaluate = nil
      if mode?("hold_evaluate_fail")
        respond(held, success: false, message: "fixture evaluation failed after frame changed")
      else
        expression = held.dig("arguments", "expression")
        respond(held, body: {"result" => "fixture-result:#{expression}", "type" => "String", "variablesReference" => 0})
      end
      log_record({"type" => "fixture", "name" => "evaluate_release_written"})
      log_record({"type" => "fixture", "name" => "evaluate_released_after_stop"})
    elsif mode?("stop_before_step_response")
      event("stopped", step_event)
      respond(request)
    else
      respond(request)
      event("stopped", step_event)
    end
  when "continue"
    respond(request, body: {"allThreadsContinued" => true})
    event("continued", {"threadId" => request.dig("arguments", "threadId"), "allThreadsContinued" => true})
    unless MODE_FLAGS.any? { |flag| flag.start_with?("pause_") }
      event("exited", {"exitCode" => 0})
      event("terminated", {})
    end
  when "pause"
    pause_event = {"reason" => "pause", "threadId" => request.dig("arguments", "threadId"), "allThreadsStopped" => false}
    if mode?("pause_stop_before_ack")
      event("stopped", pause_event)
      log_record({"type" => "fixture", "name" => "pause_response"})
      respond(request)
    else
      log_record({"type" => "fixture", "name" => "pause_response"})
      respond(request)
      event("stopped", pause_event) unless mode?("pause_ack_no_stop")
    end
  when "evaluate"
    expression = request.dig("arguments", "expression")
    if (mode?("hold_evaluate_fail_after_second") || mode?("hold_evaluate_success_after_second")) && $held_evaluate
      held = $held_evaluate
      $held_evaluate = request
      log_record({"type" => "fixture", "name" => "evaluate_second_held"})
      if mode?("hold_evaluate_fail_after_second")
        respond(held, success: false, message: "fixture evaluation failed after a newer request")
      else
        old_expression = held.dig("arguments", "expression")
        respond(held, body: {"result" => "fixture-result:#{old_expression}", "type" => "String", "variablesReference" => 0})
      end
      log_record({"type" => "fixture", "name" => "evaluate_release_written"})
      log_record({"type" => "fixture", "name" => "evaluate_released_after_second_request"})
    elsif (mode?("hold_evaluate") || mode?("hold_evaluate_fail") || mode?("hold_evaluate_fail_after_second") || mode?("hold_evaluate_success_after_second")) && !$held_evaluate
      $held_evaluate = request
      log_record({"type" => "fixture", "name" => "evaluate_held"})
    else
      log_record({"type" => "fixture", "name" => "evaluate_response"})
      respond(request, body: {"result" => "fixture-result:#{expression}", "type" => "String", "variablesReference" => 0})
    end
  when "disconnect"
    if mode?("disconnect_reject")
      log_record({"type" => "fixture", "name" => "disconnect_rejected"})
      respond(request, success: false, message: "fixture rejected disconnect")
      next
    end
    if mode?("hold_disconnect")
      release_argument = mode?("source_checksum") ? 3 : 2
      release_path = ARGV.fetch(release_argument) { raise ArgumentError, "hold_disconnect mode requires a release sentinel path" }
      log_record({"type" => "fixture", "name" => "disconnect_received"})
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
      until File.exist?(release_path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.005
      end
      marker = File.exist?(release_path) ? "disconnect_released" : "disconnect_hold_expired"
      log_record({"type" => "fixture", "name" => marker})
    end
    if $held_evaluate
      held = $held_evaluate
      $held_evaluate = nil
      log_record({"type" => "fixture", "name" => "evaluate_released_on_disconnect"})
      if mode?("hold_evaluate_fail") || mode?("hold_evaluate_fail_after_second")
        respond(held, success: false, message: "fixture evaluation failed during disconnect")
      else
        expression = held.dig("arguments", "expression")
        respond(held, body: {"result" => "fixture-result:#{expression}", "type" => "String", "variablesReference" => 0})
      end
      log_record({"type" => "fixture", "name" => "evaluate_release_written"})
    end
    respond(request)
    event("terminated", {})
    # Keep stdio open until the client closes it after observing the
    # disconnect response/event. This prevents an immediate EOF from racing
    # the client's bounded queue consumer and discarding those final frames.
  else
    respond(request)
  end
end
