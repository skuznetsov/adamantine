#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "rbconfig"

SCENARIO = ARGV.fetch(0, "success")

def read_message
  lines = []
  loop do
    line = STDIN.gets("\r\n")
    return nil unless line
    break if line == "\r\n"
    lines << line
  end
  length_line = lines.find { |line| line.match?(/\AContent-Length:/i) }
  raise "missing client Content-Length" unless length_line
  length = length_line[/\AContent-Length:\s*(\d+)/i, 1].to_i
  body = STDIN.read(length)
  raise "truncated client message" unless body && body.bytesize == length
  JSON.parse(body)
end

def send_message(message)
  STDOUT.write(frame_message(message))
  STDOUT.flush
end

def frame_message(message)
  body = JSON.generate(message)
  "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
end

def response(request, body = {}, success: true, message: nil)
  envelope = {
    "seq" => 800 + request.fetch("seq"),
    "type" => "response",
    "request_seq" => request.fetch("seq"),
    "command" => request.fetch("command"),
    "success" => success,
    "body" => body
  }
  envelope["message"] = message if message
  send_message(envelope)
end

def event(name, body = {})
  send_message({"seq" => 700, "type" => "event", "event" => name, "body" => body})
end

def next_request(command)
  message = read_message
  raise "client closed before #{command}" unless message
  raise "expected request #{command}, got #{message.inspect}" unless message["type"] == "request" && message["command"] == command
  message
end

STDIN.binmode
STDOUT.binmode
initialize_request = read_message
raise "expected initialize" unless initialize_request && initialize_request["command"] == "initialize"

case SCENARIO
when "eof"
  STDOUT.close
  exit 0
when "malformed"
  STDOUT.write("Content-Length: nope\r\n\r\n")
  STDOUT.flush
  exit 0
when "oversize"
  STDOUT.write("Content-Length: 1048577\r\n\r\n")
  STDOUT.flush
  exit 0
when "truncated"
  STDOUT.write("Content-Length: 20\r\n\r\n{}")
  STDOUT.flush
  STDOUT.close
  exit 0
when "timeout-owned-child"
  child_marker = ARGV.fetch(1)
  child = Process.spawn(
    RbConfig.ruby,
    "-e",
    'trap("TERM") { File.write(ARGV.fetch(0), "term"); exit }; sleep 30',
    child_marker
  )
  File.write(ARGV.fetch(2), child.to_s)
  sleep 30
  exit 0
when "unknown-response"
  send_message({
    "seq" => 999,
    "type" => "response",
    "request_seq" => 9000,
    "command" => "initialize",
    "success" => true,
    "body" => {"supportsConfigurationDoneRequest" => true}
  })
  exit 0
when "event-saturation"
  65.times { event("output", {"output" => "bounded test output"}) }
when "metadata-burst"
  15.times do |index|
    event("module", {"module" => {"id" => index, "name" => "seeded-module-#{index}"}})
    event("breakpoint", {"reason" => "changed", "breakpoint" => {"id" => index}})
    event("capabilities", {"capabilities" => {"supportsStepBack" => false}})
    event("progressStart", {"progressId" => "seeded-#{index}", "title" => "bounded probe"})
    event("progressUpdate", {"progressId" => "seeded-#{index}", "message" => "bounded update"})
    event("progressEnd", {"progressId" => "seeded-#{index}"})
    event("output", {"category" => "console", "output" => "seeded metadata burst\n"})
  end
when "metadata-message-flood"
  257.times do |index|
    event("module", {"module" => {"id" => index, "name" => "seeded-module-#{index}"}})
  end
  exit 0
when "aggregate-byte-flood"
  5.times do |index|
    event("output", {"category" => "console", "output" => "x" * 900_000, "group" => "seeded-#{index}"})
  end
  exit 0
when "reverse-flood"
  257.times do |index|
    send_message({
      "seq" => 500 + index,
      "type" => "request",
      "command" => "runInTerminal",
      "arguments" => {}
    })
  end
  exit 0
when "reverse"
  send_message({"seq" => 501, "type" => "request", "command" => "runInTerminal", "arguments" => {}})
  reverse_response = read_message
  unless reverse_response && reverse_response["type"] == "response" && reverse_response["success"] == false
    raise "unsupported reverse request was not rejected"
  end
end

response(initialize_request, {"supportsConfigurationDoneRequest" => true})
launch_request = next_request("launch")
if SCENARIO == "launch-failed"
  STDERR.write("seeded launch diagnostic: target unavailable\n")
  response(launch_request, {}, success: false, message: "seeded launch failed before initialized")
  exit 0
end
if SCENARIO == "launch-failed-error-format"
  response(launch_request, {"error" => {"format" => "seeded body.error.format diagnostic"}}, success: false)
  exit 0
end
if SCENARIO == "output-byte-flood"
  3.times { event("output", {"category" => "console", "output" => "x" * 700}) }
end

if SCENARIO == "event-order"
  event("stopped", {"reason" => "breakpoint", "threadId" => 1})
  exit 0
end

if SCENARIO == "breakpoint-unverified"
  event("output", {"category" => "stderr", "output" => "seeded DAP target creation diagnostic\n"})
  event("output", {"category" => "console", "output" => "seeded second output record\n"})
end
event("initialized")
breakpoint_request = next_request("setBreakpoints")
source_path = breakpoint_request.dig("arguments", "source", "path")
marker_line = File.readlines(source_path, encoding: "UTF-8").find_index { |line| line.include?("DAP_BREAKPOINT: locals") }.to_i + 1
after_step_line = File.readlines(source_path, encoding: "UTF-8").find_index { |line| line.include?("DAP_AFTER_STEP") }.to_i + 1
resolved_line = SCENARIO == "wrong-breakpoint" ? marker_line + 1 : marker_line
if SCENARIO == "breakpoint-unverified"
  STDERR.write("seeded adapter diagnostic: source mapping unavailable\n")
  response(breakpoint_request, {
    "breakpoints" => [{"verified" => false, "line" => marker_line, "message" => "seeded breakpoint rejected by adapter"}]
  })
else
  response(breakpoint_request, {
    "breakpoints" => [{"verified" => true, "line" => resolved_line}]
  })
end
exit 0 if SCENARIO == "wrong-breakpoint"
exit 0 if SCENARIO == "breakpoint-unverified"

configuration_request = next_request("configurationDone")
response(configuration_request)
response(launch_request)
stop_reason = SCENARIO == "entry" ? "entry" : "breakpoint"
event("stopped", {"reason" => stop_reason, "threadId" => 1})
exit 0 if SCENARIO == "entry"

stack_request = next_request("stackTrace")
step_stack = false
response(stack_request, {
  "stackFrames" => [{
    "id" => 1,
    "name" => "debugger_locals_probe",
    "source" => {"path" => source_path},
    "line" => step_stack ? marker_line + 1 : marker_line
  }]
})

scopes_request = next_request("scopes")
response(scopes_request, {"scopes" => [{"name" => "Locals", "variablesReference" => 7, "namedVariables" => SCENARIO == "missing-locals" ? 1 : 12}]})
locals_request = next_request("variables")
locals = [
  {"name" => "debugger_sentinel", "type" => SCENARIO == "wrong-sentinel-type" ? "String" : "Int32", "value" => SCENARIO == "wrong-sentinel" ? "271829" : "271828", "variablesReference" => 0},
  {"name" => "debugger_string_empty", "type" => "String", "value" => "\"\"", "variablesReference" => 0},
  {"name" => "debugger_string_utf8", "type" => "String", "value" => "\"snowman ☃\"", "variablesReference" => 0},
  {"name" => "debugger_string_nul", "type" => "String", "value" => "\"left\\0right\"", "variablesReference" => 0},
  {"name" => "debugger_array_empty", "type" => "Array(Int32)", "value" => "[]", "variablesReference" => 9, "indexedVariables" => 0},
  {"name" => "debugger_array", "type" => "Array(Int32)", "value" => "[22, 44]", "variablesReference" => 8, "indexedVariables" => 2},
  {"name" => "debugger_union_int", "type" => "Int32 | String", "value" => "22", "variablesReference" => 10},
  {"name" => "debugger_union_string", "type" => "Int32 | String", "value" => "\"forty-four\"", "variablesReference" => 11},
  {"name" => "debugger_nullable_string_nil", "type" => "String?", "value" => "nil", "variablesReference" => 0},
  {"name" => "debugger_nullable_string_value", "type" => "String?", "value" => "\"present\"", "variablesReference" => 12},
  {"name" => "debugger_nullable_pointer_nil", "type" => "Pointer(UInt8)?", "value" => "nil", "variablesReference" => 0},
  {"name" => "debugger_nullable_pointer_value", "type" => "Pointer(UInt8)?", "value" => "0x1000", "variablesReference" => 13},
  {"name" => "debugger_nested_outer", "type" => "DebuggerNested", "value" => "DebuggerNested", "variablesReference" => 15, "namedVariables" => 2},
  {"name" => "debugger_nested", "type" => "Int32", "value" => "271918", "variablesReference" => 14},
  {"name" => "debugger_shadowed", "type" => "Int32", "value" => "20", "variablesReference" => 0},
  {"name" => "debugger_shadowed", "type" => "Int32", "value" => "10", "variablesReference" => 0}
]
locals << {"name" => "debugger_sentinel", "type" => "Int32", "value" => "271828", "variablesReference" => 0} if SCENARIO == "duplicate-sentinel"
locals.reject! { |variable| variable["name"] == "debugger_sentinel" } if SCENARIO == "missing-locals"
locals.reject! { |variable| variable["name"] == "debugger_nested_outer" } if SCENARIO == "missing-record"
response(locals_request, {"variables" => locals, "namedVariables" => locals.length})

next_request_request = nil
loop do
  request = read_message
  raise "client closed before stepping" unless request
  if request["command"] == "next"
    next_request_request = request
    break
  end
  raise "expected variables request" unless request["command"] == "variables"
  reference = request.dig("arguments", "variablesReference")
  children = case reference
             when 15
               value_name = SCENARIO == "wrong-record-names" ? "payload" : "value"
               value_type = SCENARIO == "wrong-record-type" ? "String" : "Int32"
               value = {"name" => value_name, "type" => value_type, "value" => SCENARIO == "wrong-record-value" ? "32" : "31", "variablesReference" => 0}
               fields = [value]
               fields << {"name" => "extra", "type" => "Int32", "value" => "0", "variablesReference" => 0} if SCENARIO == "wrong-record-count"
               fields
             when 8
               values = SCENARIO == "wrong-array-order" ? %w[44 22] : %w[22 44]
               names = SCENARIO == "wrong-array-names" ? %w[left right] : %w[0 1]
               records = values.each_with_index.map do |value, index|
                 {"name" => names[index], "type" => "Int32", "value" => value, "variablesReference" => 0}
               end
               records << {"name" => "2", "type" => "Int32", "value" => "66", "variablesReference" => 0} if SCENARIO == "wrong-array-count"
               records
             when 9 then []
             when 10 then [{"name" => "integer", "type" => "Int32", "value" => "22", "variablesReference" => 0}]
             when 11 then [{"name" => "text", "type" => "String", "value" => "\"forty-four\"", "variablesReference" => 0}]
             when 12 then [{"name" => "bytesize", "type" => "Int32", "value" => "7", "variablesReference" => 0}]
             when 13 then [{"name" => "address", "type" => "UInt64", "value" => "4096", "variablesReference" => 0}]
             when 14 then [{"name" => "value", "type" => "Int32", "value" => "271918", "variablesReference" => 0}]
             else []
  end
  if reference == 8 && SCENARIO == "wrong-array-response-command"
    send_message({"seq" => 901, "type" => "response", "request_seq" => request.fetch("seq"), "command" => "threads", "success" => true, "body" => {}})
  elsif reference == 8 && SCENARIO == "array-request-rejected"
    response(request, {}, success: false, message: "seeded Array expansion unsupported")
  elsif reference == 8 && SCENARIO == "array-shape-unavailable"
    response(request, {})
  else
    response(request, {"variables" => children, "namedVariables" => children.length, "indexedVariables" => 0})
  end
end

response(next_request_request)
event("stopped", {"reason" => "step", "threadId" => SCENARIO == "step-different-thread" ? 2 : 1})
stack_after_step = next_request("stackTrace")
step_source = SCENARIO == "step-wrong-source" ? __FILE__ : source_path
step_line = if SCENARIO == "step-same-frame"
              marker_line
            elsif SCENARIO == "step-wrong-line"
              after_step_line + 1
            else
              after_step_line
            end
step_stack_body = {
  "stackFrames" => [{"id" => 1, "name" => "debugger_locals_probe", "source" => {"path" => step_source}, "line" => step_line}]
}
if %w[early-exited terminated-before-exit partial-benign-before-continue].include?(SCENARIO)
  stack_response = {
    "seq" => 800 + stack_after_step.fetch("seq"),
    "type" => "response",
    "request_seq" => stack_after_step.fetch("seq"),
    "command" => stack_after_step.fetch("command"),
    "success" => true,
    "body" => step_stack_body
  }
  if SCENARIO == "early-exited"
    after_step = {"seq" => 700, "type" => "event", "event" => "exited", "body" => {"exitCode" => 0}}
    STDOUT.write(frame_message(stack_response) + frame_message(after_step))
    STDOUT.flush
  elsif SCENARIO == "terminated-before-exit"
    after_step = {"seq" => 700, "type" => "event", "event" => "terminated", "body" => {}}
    STDOUT.write(frame_message(stack_response) + frame_message(after_step))
    STDOUT.flush
  else
    after_step = {"seq" => 700, "type" => "event", "event" => "module", "body" => {"module" => {"id" => 1, "name" => "fragmented module"}}}
    full_frame = frame_message(after_step)
    split = 19
    STDOUT.write(frame_message(stack_response) + full_frame.byteslice(0, split))
    STDOUT.flush
    sleep 0.05
    STDOUT.write(full_frame.byteslice(split, full_frame.bytesize - split))
    STDOUT.flush
  end
else
  response(stack_after_step, step_stack_body)
end
exit 0 if SCENARIO.start_with?("step-")

if SCENARIO == "early-exited"
  sleep 0.08
end
continue_request = next_request("continue")
response(continue_request, {"allThreadsContinued" => true})
if SCENARIO == "lifecycle-event-flood"
  17.times { event("exited", {"exitCode" => 0}) }
elsif SCENARIO == "duplicate-terminated-after-exit"
  event("exited", {"exitCode" => 0})
  2.times { event("terminated", {}) }
else
  event("exited", {"exitCode" => 0})
end
event("terminated", {}) if SCENARIO == "post-exit-terminated"
disconnect_request = next_request("disconnect")
response(disconnect_request)
