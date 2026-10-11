#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "rbconfig"
require "tmpdir"

module DebuggerProbe
  class ProbeError < StandardError; end
  class ProtocolError < ProbeError; end
  class StepTimeout < ProbeError; end
  class ChildObservationUnavailable < ProbeError; end

  class DAPRequestFailure < ProbeError
    attr_reader :command

    def initialize(command, message)
      @command = command
      super(message)
    end
  end

  ROOT = File.expand_path("../..", __dir__)
  FIXTURES = File.join(ROOT, "spec", "fixtures", "debugger")
  MAX_HEADER_BYTES = 8 * 1024
  MAX_MESSAGE_BYTES = 1024 * 1024
  MAX_CAPTURE_BYTES = 8 * 1024
  MAX_LOCALS = 256
  MAX_SCOPES = 16
  MAX_CHILD_EXPANSIONS = 12
  MAX_CHILDREN = 128
  MAX_CHILD_SAMPLE = 24
  MAX_VALUE_BYTES = 192
  MAX_PROTOCOL_MESSAGES = 256
  MAX_PROTOCOL_BYTES = 4 * 1024 * 1024
  MAX_PENDING_REQUESTS = 16
  MAX_QUEUED_RESPONSES = 16
  MAX_REVERSE_REQUESTS = 16
  MAX_DAP_OUTPUT_RECORDS = 8
  MAX_DAP_OUTPUT_BYTES = 1200
  MAX_DAP_OUTPUT_CATEGORY_BYTES = 80
  MAX_EVENT_HISTORY = 64
  MAX_LIFECYCLE_EVENTS = 16
  LIFECYCLE_EVENTS = %w[initialized stopped exited terminated].freeze
  OBSERVATION_EVENTS = %w[output module breakpoint capabilities progressStart progressUpdate progressEnd].freeze
  SENTINEL = "271828"
  PRIMITIVE_INTEGER_TYPE = /\A(?:u?int(?:8|16|32|64|128)?(?:_t)?|i(?:8|16|32|64|128)|u(?:8|16|32|64|128)|long(?: long)?|short|intptr_t|uintptr_t|integer)\z/i
  COMPOSITE_NAMES = %w[
    debugger_nested_outer
    debugger_array
    debugger_array_empty
    debugger_union_int
    debugger_union_string
    debugger_nullable_string_value
    debugger_nullable_pointer_value
  ].freeze
  VALUE_NAMES = %w[
    debugger_string_empty
    debugger_string_utf8
    debugger_string_nul
    debugger_array_empty
    debugger_array
    debugger_union_int
    debugger_union_string
    debugger_nullable_string_nil
    debugger_nullable_string_value
    debugger_nullable_pointer_nil
    debugger_nullable_pointer_value
    debugger_nested_outer
    debugger_shadowed
    debugger_out_of_scope
  ].freeze

  def self.monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.text_excerpt(value, limit = 240)
    text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    text = text.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "?")
    clipped = text.byteslice(0, [limit.to_i, 0].max).to_s.force_encoding("UTF-8")
    clipped = clipped.byteslice(0, clipped.bytesize - 1).to_s.force_encoding("UTF-8") until clipped.valid_encoding?
    clipped
  end

  def self.decode_message(raw, max_bytes: MAX_MESSAGE_BYTES)
    data = raw.to_s.b
    separator = data.index("\r\n\r\n".b)
    raise ProtocolError, "truncated DAP header" unless separator
    raise ProtocolError, "DAP header exceeds limit" if separator > MAX_HEADER_BYTES

    headers = data.byteslice(0, separator).split("\r\n".b)
    lengths = headers.select { |line| line.match?(/\AContent-Length:/i) }
    raise ProtocolError, "DAP frame needs one Content-Length" unless lengths.length == 1

    match = lengths.first.match(/\AContent-Length:\s*(\d+)\s*\z/i)
    raise ProtocolError, "malformed DAP Content-Length" unless match
    body_length = match[1].to_i
    raise ProtocolError, "DAP message exceeds limit" if body_length > max_bytes

    body_start = separator + 4
    body = data.byteslice(body_start, body_length)
    raise ProtocolError, "truncated DAP body" unless body && body.bytesize == body_length
    raise ProtocolError, "unexpected bytes after DAP message" unless body_start + body_length == data.bytesize

    parse_json_message(body)
  end

  def self.parse_json_message(body)
    message = JSON.parse(body)
    unless message.is_a?(Hash) && %w[request response event].include?(message["type"])
      raise ProtocolError, "invalid DAP envelope"
    end
    message
  rescue JSON::ParserError => error
    raise ProtocolError, "invalid DAP JSON: #{text_excerpt(error.message, 120)}"
  end

  def self.breakpoint_stop?(message)
    message.is_a?(Hash) && message["type"] == "event" && message["event"] == "stopped" &&
      message.dig("body", "reason") == "breakpoint"
  end

  def self.sentinel_match?(variables, expected)
    matches = Array(variables).select do |variable|
      variable.is_a?(Hash) && variable["name"] == "debugger_sentinel"
    end
    return false unless matches.length == 1

    variable = matches.first
    type = variable["type"].to_s.gsub(/\b(?:const|volatile|signed|unsigned)\b/i, " ").strip
    PRIMITIVE_INTEGER_TYPE.match?(type) && variable["value"].to_s.strip == expected.to_s
  end

  def self.debugserver_identity(environment = ENV)
    provided = environment["LLDB_DEBUGSERVER_PATH"]
    return {"status" => "unset"} if provided.nil? || provided.empty?

    identity = {"status" => "invalid", "provided_path" => text_excerpt(provided, 600)}
    absolute = File.expand_path(provided)
    return identity.merge("validation_error" => "path is not an executable file") unless File.file?(absolute) && File.executable?(absolute)

    resolved = File.realpath(absolute)
    identity.merge(
      "status" => "valid",
      "resolved_path" => text_excerpt(resolved, 600),
      "sha256" => Digest::SHA256.file(resolved).hexdigest
    )
  rescue SystemCallError => error
    identity.merge("validation_error" => text_excerpt(error.message, 180))
  end

  class OwnedProcess
    attr_reader :pid, :stderr_bytes, :stderr_truncated

    def initialize(argv, env: {}, cwd: nil)
      raise ProbeError, "empty child command" if argv.nil? || argv.empty?

      @stdin_reader, @stdin_writer = IO.pipe
      @stdout_reader, @stdout_writer = IO.pipe
      @stderr_reader, @stderr_writer = IO.pipe
      @stdin_writer.sync = true
      @stdout_reader.binmode
      @stderr_reader.binmode
      options = {
        in: @stdin_reader,
        out: @stdout_writer,
        err: @stderr_writer,
        pgroup: true,
        close_others: true
      }
      options[:chdir] = cwd if cwd
      @pid = Process.spawn(env, *argv, options)
      @stdin_reader.close
      @stdout_writer.close
      @stderr_writer.close
      @stderr_bytes = 0
      @stderr_kept = "".b
      @stderr_truncated = false
      @stdout_eof = false
      @stderr_eof = false
      @status = nil
      @closed = false
    rescue Exception
      close_pipes
      raise
    end

    def write(bytes, deadline:)
      raise ProbeError, "child stdin is closed" if @stdin_writer.closed?
      data = bytes.to_s.b
      offset = 0
      while offset < data.bytesize
        remaining = deadline - DebuggerProbe.monotonic_time
        raise StepTimeout, "DAP write deadline exceeded" if remaining <= 0
        chunk = data.byteslice(offset, 16 * 1024)
        written = @stdin_writer.write_nonblock(chunk, exception: false)
        if written == :wait_writable
          ready = IO.select(nil, [@stdin_writer], nil, [remaining, 0.05].min)
          raise StepTimeout, "DAP write deadline exceeded" unless ready
        else
          raise ProbeError, "child stdin write made no progress" unless written.is_a?(Integer) && written > 0
          offset += written
        end
      end
    rescue Errno::EPIPE, IOError => error
      raise ProbeError, "child stdin closed: #{DebuggerProbe.text_excerpt(error.message, 100)}"
    end

    def close_stdin
      @stdin_writer.close unless @stdin_writer.closed?
    rescue IOError
      nil
    end

    def stdout_reader
      @stdout_reader
    end

    def stderr_reader
      @stderr_reader
    end

    def stdout_eof?
      @stdout_eof
    end

    def stderr_eof?
      @stderr_eof
    end

    def mark_stdout_eof
      @stdout_eof = true
    end

    def mark_stderr_eof
      @stderr_eof = true
    end

    def capture_stderr(chunk)
      return if chunk.nil? || chunk.empty?
      @stderr_bytes += chunk.bytesize
      available = MAX_CAPTURE_BYTES - @stderr_kept.bytesize
      if available > 0
        @stderr_kept << chunk.byteslice(0, available)
      end
      @stderr_truncated = true if chunk.bytesize > available
    end

    def stderr_excerpt
      DebuggerProbe.text_excerpt(@stderr_kept, 1200)
    end

    def poll_status
      return @status if @status
      waited = Process.waitpid2(@pid, Process::WNOHANG)
      @status = waited[1] if waited
      @status
    rescue Errno::ECHILD
      @status
    end

    def status
      @status
    end

    def terminate(grace: 0.4)
      return if @closed
      if process_group_alive?
        signal_group("TERM")
        deadline = DebuggerProbe.monotonic_time + grace
        while DebuggerProbe.monotonic_time < deadline && process_group_alive?
          sleep 0.02
        end
        signal_group("KILL") if process_group_alive?
      end
      reap
    ensure
      close_pipes
    end

    def wait_for_exit(timeout)
      deadline = DebuggerProbe.monotonic_time + timeout
      until poll_status
        remaining = deadline - DebuggerProbe.monotonic_time
        return false if remaining <= 0
        IO.select([@stdout_reader, @stderr_reader].reject(&:closed?), nil, nil, [remaining, 0.05].min)
        drain_stdout
        drain_stderr
      end
      drain_stdout
      drain_stderr
      true
    end

    def drain_stdout
      return if @stdout_reader.closed? || @stdout_eof
      16.times do
        @stdout_reader.read_nonblock(16 * 1024)
      rescue IO::WaitReadable
        break
      rescue EOFError
        @stdout_eof = true
        break
      end
    end

    def drain_stderr
      return if @stderr_reader.closed? || @stderr_eof
      16.times do
        chunk = @stderr_reader.read_nonblock(16 * 1024)
        capture_stderr(chunk)
      rescue IO::WaitReadable
        break
      rescue EOFError
        @stderr_eof = true
        break
      end
    end

    def exit_code
      return nil unless @status
      return @status.exitstatus if @status.exited?
      128 + @status.termsig.to_i
    end

    def close
      return if @closed
      close_pipes
      @closed = true
    end

    private

    def signal_group(signal)
      # The negative id is the process group created by this exact spawn call.
      Process.kill(signal, -@pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def reap
      return if @status
      _pid, @status = Process.waitpid2(@pid)
    rescue Errno::ECHILD
      nil
    end

    def process_group_alive?
      Process.kill(0, -@pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def close_pipes
      [@stdin_reader, @stdin_writer, @stdout_reader, @stdout_writer, @stderr_reader, @stderr_writer].each do |io|
        io.close unless io.closed?
      rescue IOError
        nil
      end
    end
  end

  class CommandRunner
    def run(argv, env: {}, cwd:, timeout:, capture_limit: MAX_CAPTURE_BYTES)
      process = OwnedProcess.new(argv, env: env, cwd: cwd)
      stdout = "".b
      stdout_bytes = 0
      stdout_eof = false
      timed_out = false
      deadline = DebuggerProbe.monotonic_time + timeout

      loop do
        status = process.poll_status
        break if status && stdout_eof && process.stderr_eof?

        remaining = deadline - DebuggerProbe.monotonic_time
        if remaining <= 0
          timed_out = true
          process.terminate
          break
        end

        readers = []
        readers << process.stdout_reader unless stdout_eof
        readers << process.stderr_reader unless process.stderr_eof?
        ready = IO.select(readers, nil, nil, [remaining, 0.05].min)
        Array(ready && ready[0]).each do |io|
          if io == process.stdout_reader
            16.times do
              chunk = io.read_nonblock(16 * 1024)
              stdout_bytes += chunk.bytesize
              available = capture_limit - stdout.bytesize
              stdout << chunk.byteslice(0, available) if available > 0
            rescue IO::WaitReadable
              break
            rescue EOFError
              stdout_eof = true
              break
            end
          else
            process.drain_stderr
          end
        end
        if process.poll_status && !stdout_eof && !readers.include?(process.stdout_reader)
          stdout_eof = true
        end
      end

      process.drain_stderr
      {
        "exit_code" => process.exit_code,
        "timed_out" => timed_out,
        "stdout_bytes" => stdout_bytes,
        "stderr_bytes" => process.stderr_bytes,
        "stdout_truncated" => stdout_bytes > stdout.bytesize,
        "stderr_truncated" => process.stderr_truncated,
        "stdout" => stdout,
        "stderr_excerpt" => DebuggerProbe.text_excerpt(process.instance_variable_get(:@stderr_kept), 800)
      }
    rescue SystemCallError, ProbeError => error
      {
        "exit_code" => nil,
        "timed_out" => false,
        "stdout_bytes" => 0,
        "stderr_bytes" => 0,
        "stdout_truncated" => false,
        "stderr_truncated" => false,
        "error" => DebuggerProbe.text_excerpt(error.message, 300)
      }
    ensure
      process.terminate if process
      process.close if process
    end
  end

  class DAPProbe
    attr_reader :phase

    def initialize(adapter_path:, adapter_args: [], step_timeout: 5.0, process_timeout: 30.0)
      @adapter_path = adapter_path
      @adapter_args = adapter_args
      @step_timeout = step_timeout
      @process_timeout = process_timeout
      @seq = 1
      @buffer = "".b
      @responses = {}
      @outstanding_requests = {}
      @events = []
      @event_names = []
      @event_count = 0
      @event_history_truncated = false
      @steps = {}
      @phase = "preflight"
      @configuration_done_sent = false
      @launch_sent = false
      @initialized_event_seen = false
      @continue_sent = false
      @target_exited = false
      @exited_event_seen = false
      @terminated_event_seen = false
      @expected_stops = []
      @reverse_requests = []
      @process_started_at = nil
      @process = nil
      @result = nil
      @terminate_requested = false
      @cleanup = {"status" => "not_started"}
      @protocol_message_count = 0
      @protocol_bytes = 0
    end

    def self.breakpoint_stop?(message)
      DebuggerProbe.breakpoint_stop?(message)
    end

    def self.sentinel_match?(variables, expected)
      DebuggerProbe.sentinel_match?(variables, expected)
    end

    def self.decode_message(raw, max_bytes: MAX_MESSAGE_BYTES)
      DebuggerProbe.decode_message(raw, max_bytes: max_bytes)
    end

    def run(binary_path:, source_path:, sentinel: SENTINEL)
      @result = {
        "status" => "FAIL",
        "source" => source_path.to_s,
        "requested_breakpoint_line" => nil,
        "steps" => @steps,
        "events" => @event_names,
        "event_count" => 0,
        "event_history_truncated" => false,
        "reverse_requests_rejected" => @reverse_requests,
        "container_observations" => [],
        "raw_structural_children" => [],
        "failed_dap_responses" => [],
        "dap_output_events" => [],
        "dap_output_event_count" => 0,
        "dap_output_bytes_observed" => 0,
        "dap_output_bytes_captured" => 0,
        "dap_output_capture_truncated" => false
      }
      @binary_path = File.realpath(binary_path)
      @source_path = File.realpath(source_path)
      @marker_line = source_marker_line(@source_path, "DAP_BREAKPOINT: locals")
      @step_line = source_marker_line(@source_path, "DAP_AFTER_STEP")
      @result["source"] = @source_path
      @result["requested_breakpoint_line"] = @marker_line

      start_adapter
      initialize_adapter
      launch
      wait_initialized
      breakpoints = set_source_breakpoint
      configuration_done
      launch_response
      stop = wait_for_stop("breakpoint")
      inspect_stopped_frame(stop, breakpoints, sentinel)
      step_over
      continue_to_exit
      disconnect
      @result["status"] = "PASS"
    rescue ProbeError, SystemCallError => error
      @result["failure"] = "#{@phase}: #{DebuggerProbe.text_excerpt(error.message, 300)}"
      @result["status"] = "FAIL"
    rescue StandardError => error
      @result["failure"] = "#{@phase}: unexpected #{error.class}: #{DebuggerProbe.text_excerpt(error.message, 200)}"
      @result["status"] = "FAIL"
    ensure
      cleanup_adapter
      if @result
        @result["steps"] = @steps
        @result["events"] = @event_names
        @result["event_count"] = @event_count
        @result["event_history_truncated"] = @event_history_truncated
        @result["reverse_requests_rejected"] = @reverse_requests.first(16)
        @result["adapter_cleanup"] = @cleanup
        @result["adapter_stderr_bytes"] = @process ? @process.stderr_bytes : 0
        @result["adapter_stderr_truncated"] = @process ? @process.stderr_truncated : false
        @result["adapter_stderr_excerpt"] = @process ? @process.stderr_excerpt : ""
      end
      return @result if @result
    end

    private

    def source_marker_line(path, marker)
      lines = File.readlines(path, encoding: "UTF-8")
      matches = []
      lines.each_with_index { |line, index| matches << index + 1 if line.include?(marker) }
      raise ProbeError, "fixture must have exactly one #{marker} marker" unless matches.length == 1
      matches.first
    end

    def start_adapter
      @phase = "start_adapter"
      argv = [@adapter_path] + @adapter_args + ["--no-lldbinit"]
      @process = OwnedProcess.new(argv, cwd: File.dirname(@binary_path))
      @process_started_at = DebuggerProbe.monotonic_time
      @steps["adapter_started"] = true
    end

    def initialize_adapter
      @phase = "initialize"
      seq = send_request("initialize", {
        "clientID" => "adamantine-dbg0-probe",
        "clientName" => "Adamantine DBG-0 Probe",
        "adapterID" => "lldb",
        "locale" => "en-US",
        "linesStartAt1" => true,
        "columnsStartAt1" => true,
        "pathFormat" => "path",
        "supportsVariableType" => true,
        "supportsVariablePaging" => false,
        "supportsRunInTerminalRequest" => false
      })
      response = await_response(seq, "initialize")
      capabilities = response.fetch("body", {})
      @configuration_done_supported = capabilities["supportsConfigurationDoneRequest"] == true
      raise ProbeError, "adapter lacks supportsConfigurationDoneRequest" unless @configuration_done_supported
      @steps["initialize"] = "PASS"
    end

    def launch
      @phase = "launch"
      @launch_request_seq = send_request("launch", {
        "program" => @binary_path,
        "cwd" => File.dirname(@binary_path),
        "args" => [],
        "stopOnEntry" => false,
        "console" => "internalConsole"
      })
      @launch_sent = true
      @steps["launch_pending"] = "PASS"
    end

    def wait_initialized
      @phase = "initialized"
      event = await_event("initialized")
      raise ProbeError, "initialized event arrived before launch" unless @launch_sent
      @steps["initialized"] = "PASS"
      event
    end

    def set_source_breakpoint
      @phase = "source_breakpoint"
      seq = send_request("setBreakpoints", {
        "source" => {"name" => File.basename(@source_path), "path" => @source_path},
        "breakpoints" => [{"line" => @marker_line}],
        "sourceModified" => false
      })
      response = await_response(seq, "setBreakpoints")
      breakpoints = response.dig("body", "breakpoints")
      breakpoint = Array(breakpoints).first
      unless breakpoint.is_a?(Hash) && breakpoint["verified"] == true
        message = breakpoint.is_a?(Hash) ? bounded_string(breakpoint["message"], 180) : nil
        @result["resolved_breakpoint"] = {
          "verified" => breakpoint.is_a?(Hash) ? breakpoint["verified"] : nil,
          "line" => breakpoint.is_a?(Hash) ? breakpoint["line"] : nil,
          "message" => message
        }
        suffix = message ? "; adapter says: #{message}" : ""
        raise ProbeError, "source breakpoint was not verified#{suffix}"
      end
      resolved_line = breakpoint["line"]
      unless resolved_line.is_a?(Integer) && resolved_line == @marker_line
        raise ProbeError, "source breakpoint resolved to unexpected line #{resolved_line.inspect}"
      end
      @result["resolved_breakpoint"] = {
        "verified" => true,
        "line" => resolved_line,
        "message" => bounded_string(breakpoint["message"], 180)
      }
      @steps["source_breakpoint"] = "PASS"
      {"line" => resolved_line}
    end

    def configuration_done
      @phase = "configurationDone"
      @expected_stops << "breakpoint"
      @configuration_done_sent = true
      seq = send_request("configurationDone", {})
      await_response(seq, "configurationDone")
      @steps["configurationDone"] = "PASS"
    end

    def launch_response
      @phase = "launch_response"
      await_response(@launch_request_seq, "launch")
      @steps["launch_response"] = "PASS"
    end

    def wait_for_stop(expected_reason, expected_thread_id: nil)
      @phase = "stop_#{expected_reason}"
      event = await_event("stopped")
      actual_reason = event.dig("body", "reason")
      raise ProbeError, "expected #{expected_reason} stop, got #{actual_reason.inspect}" unless actual_reason == expected_reason
      thread_id = event.dig("body", "threadId")
      raise ProbeError, "stopped event has no positive threadId" unless thread_id.is_a?(Integer) && thread_id > 0
      if expected_thread_id && thread_id != expected_thread_id
        raise ProbeError, "step stopped on unexpected thread #{thread_id}"
      end
      @steps["stop_#{expected_reason}"] = "PASS"
      @result["stopped_thread_id"] = thread_id
      {"event" => event, "thread_id" => thread_id}
    end

    def inspect_stopped_frame(stop, breakpoints, sentinel)
      @phase = "stackTrace"
      seq = send_request("stackTrace", {
        "threadId" => stop.fetch("thread_id"),
        "startFrame" => 0,
        "levels" => MAX_SCOPES
      })
      response = await_response(seq, "stackTrace")
      frames = response.dig("body", "stackFrames")
      frame = Array(frames).first
      raise ProbeError, "stackTrace returned no frame" unless frame.is_a?(Hash)
      frame_source = frame.dig("source", "path")
      raise ProbeError, "top frame source does not match fixture" unless same_path?(frame_source, @source_path)
      frame_line = frame["line"]
      expected_line = breakpoints.fetch("line")
      raise ProbeError, "top frame line does not match resolved breakpoint" unless frame_line == expected_line
      raise ProbeError, "top frame has no integer id" unless frame["id"].is_a?(Integer)
      @result["top_frame"] = {
        "name" => bounded_string(frame["name"], 120),
        "source" => frame_source,
        "line" => frame_line
      }
      @steps["stackTrace"] = "PASS"

      @phase = "scopes"
      seq = send_request("scopes", {"frameId" => frame["id"]})
      response = await_response(seq, "scopes")
      scopes = response.dig("body", "scopes")
      raise ProbeError, "scopes returned no scopes" unless scopes.is_a?(Array) && !scopes.empty?
      raise ProbeError, "too many scopes returned" if scopes.length > MAX_SCOPES
      scope_records = scopes.map do |scope|
        unless scope.is_a?(Hash) && scope["name"].is_a?(String) && scope["variablesReference"].is_a?(Integer)
          raise ProbeError, "malformed scope record"
        end
        {
          "name" => bounded_string(scope["name"], 100),
          "variablesReference" => scope["variablesReference"],
          "namedVariables" => optional_nonnegative(scope["namedVariables"]),
          "indexedVariables" => optional_nonnegative(scope["indexedVariables"])
        }
      end
      @result["scopes"] = scope_records
      locals_scope = scopes.find { |scope| scope["name"].casecmp("Locals").zero? }
      raise ProbeError, "Locals scope missing" unless locals_scope
      raise ProbeError, "Locals scope has no variablesReference" unless locals_scope["variablesReference"].to_i > 0
      @steps["scopes"] = "PASS"

      @phase = "locals"
      seq = send_request("variables", {"variablesReference" => locals_scope["variablesReference"]})
      response = await_response(seq, "variables")
      locals = response.dig("body", "variables")
      raise ProbeError, "Locals returned no variable array" unless locals.is_a?(Array)
      raise ProbeError, "Locals exceeds #{MAX_LOCALS} variables" if locals.length > MAX_LOCALS
      @result["locals_returned"] = locals.length
      @result["locals_reported_named_count"] = optional_nonnegative(locals_scope["namedVariables"])
      safe_locals = locals.map { |variable| normalize_variable(variable) }
      @result["locals"] = safe_locals.first(MAX_LOCALS)
      unless self.class.sentinel_match?(locals, sentinel)
        raise ProbeError, "known primitive sentinel did not match name, type and value"
      end
      @steps["locals_sentinel"] = "PASS"
      @result["locals_names_and_types"] = safe_locals.map do |variable|
        {"name" => variable["name"], "type" => variable["type"]}
      end
      @result["value_presence"] = value_presence(safe_locals)
      @result["container_observations"] = container_observations(safe_locals)
      @result["formatter_certification"] = "none; values are opaque adapter output"
      expand_children(safe_locals)
    end

    def expand_children(locals)
      @phase = "children"
      record = locals.find { |variable| variable["name"] == "debugger_nested_outer" }
      raise ProbeError, "debugger_nested_outer local missing" unless record
      reference = record["variablesReference"].to_i
      raise ProbeError, "debugger_nested_outer has no expandable child reference" unless reference > 0
      children = request_children(reference, "debugger_nested_outer", required: true)
      fields = children["children"].each_with_object({}) { |child, result| result[child["name"]] ||= child }
      unless children["returned_count"] == 1 && fields.keys == %w[value]
        raise ProbeError, "debugger_nested_outer children did not match the single known value field"
      end
      value = fields.fetch("value")
      value_type = value["type"].to_s.gsub(/\b(?:const|volatile|signed|unsigned)\b/i, " ").strip
      unless DebuggerProbe::PRIMITIVE_INTEGER_TYPE.match?(value_type) && value["value"].to_s.strip == "31"
        raise ProbeError, "debugger_nested_outer.value did not match known integer field 31"
      end
      @steps["record_child"] = "PASS"

      array = locals.find { |variable| variable["name"] == "debugger_array" }
      array_observation = "UNAVAILABLE"
      if array && array["variablesReference"].to_i > 0
        array_children = request_children(array["variablesReference"], "debugger_array", required: false)
        array_items = array_children["children"] || []
        indexed_values = array_items.map { |child| child["value"] }
        indexed_names = array_items.each_with_index.all? do |child, index|
          [index.to_s, "[#{index}]"].include?(child["name"]) && !child["type"].to_s.empty?
        end
        array_observation = if array_children["unavailable"]
                              "NOT_ADMITTED; adapter did not provide an expandable Array response"
                            elsif array_children["returned_count"] == 2 && indexed_values == %w[22 44] && indexed_names
                              "PASS; adapter exposed indexed children [22,44]"
                            else
                              "NOT_ADMITTED; adapter did not expose the expected indexed Array shape"
                            end
      end
      @result["array_indexed_observation"] = array_observation

      expanded = 2
      locals.each do |variable|
        break if expanded >= MAX_CHILD_EXPANSIONS
        next unless COMPOSITE_NAMES.include?(variable["name"])
        next if %w[debugger_array debugger_nested_outer].include?(variable["name"])
        next unless variable["variablesReference"].to_i > 0
        request_children(variable["variablesReference"], variable["name"], required: false)
        expanded += 1
      end
      @result["raw_structural_children"] = @result["raw_structural_children"].first(MAX_CHILD_EXPANSIONS)
    end

    def request_children(reference, name, required:)
      seq = send_request("variables", {"variablesReference" => reference})
      response = await_response(seq, "variables")
      body = response.fetch("body", {})
      children = body["variables"]
      raise ChildObservationUnavailable, "#{name} children missing variable array" unless children.is_a?(Array)
      raise ProbeError, "#{name} exceeds #{MAX_CHILDREN} children" if children.length > MAX_CHILDREN
      normalized = children.first(MAX_CHILD_SAMPLE).map { |variable| normalize_variable(variable) }
      record = {
        "parent" => name,
        "returned_count" => children.length,
        "named_count" => optional_nonnegative(body["namedVariables"]),
        "indexed_count" => optional_nonnegative(body["indexedVariables"]),
        "truncated_sample" => children.length > MAX_CHILD_SAMPLE,
        "children" => normalized
      }
      @result["raw_structural_children"] << record
      record
    rescue DAPRequestFailure, ChildObservationUnavailable => error
      raise if required || (error.is_a?(DAPRequestFailure) && error.command != "variables")
      @result["raw_structural_children"] << {"parent" => name, "failure" => bounded_string(error.message, 180)}
      {"children" => [], "unavailable" => true}
    end

    def step_over
      @phase = "next"
      @expected_stops << "step"
      seq = send_request("next", {"threadId" => @result.fetch("stopped_thread_id"), "singleThread" => false})
      await_response(seq, "next")
      @steps["next"] = "PASS"
      stop = wait_for_stop("step", expected_thread_id: @result.fetch("stopped_thread_id"))
      @phase = "step_stackTrace"
      stack_seq = send_request("stackTrace", {
        "threadId" => stop.fetch("thread_id"),
        "startFrame" => 0,
        "levels" => 1
      })
      response = await_response(stack_seq, "stackTrace")
      frame = Array(response.dig("body", "stackFrames")).first
      raise ProbeError, "step stackTrace returned no frame" unless frame.is_a?(Hash)
      raise ProbeError, "step top frame source does not match fixture" unless same_path?(frame.dig("source", "path"), @source_path)
      raise ProbeError, "step did not advance to the DAP_AFTER_STEP source line" unless frame["line"] == @step_line
      @result["step_frame"] = {"source" => frame.dig("source", "path"), "line" => frame["line"]}
      @steps["step_frame"] = "PASS"
    end

    def continue_to_exit
      @phase = "continue"
      drain_locally_buffered_messages_before_continue
      seq = send_request("continue", {"threadId" => @result.fetch("stopped_thread_id"), "singleThread" => false})
      # This is the local write boundary, not a claim about the peer's emission time.
      @continue_sent = true
      await_response(seq, "continue")
      @steps["continue"] = "PASS"
      @phase = "exited"
      event = await_event("exited")
      exit_code = event.dig("body", "exitCode")
      raise ProbeError, "target exited with #{exit_code.inspect}" unless exit_code == 0
      @target_exited = true
      @steps["exited"] = "PASS"
      @result["target_exit_code"] = exit_code
    end

    def disconnect
      @phase = "disconnect"
      seq = send_request("disconnect", {"restart" => false, "terminateDebuggee" => false})
      await_response(seq, "disconnect")
      @steps["disconnect"] = "PASS"
      @process.close_stdin
      @cleanup["status"] = "disconnect_acknowledged"
    end

    def send_request(command, arguments)
      ensure_process_budget!
      raise ProtocolError, "too many outstanding client requests" if @outstanding_requests.length >= MAX_PENDING_REQUESTS
      seq = @seq
      @seq += 1
      @outstanding_requests[seq] = command
      begin
        write_message({"seq" => seq, "type" => "request", "command" => command, "arguments" => arguments})
      rescue StandardError
        @outstanding_requests.delete(seq)
        raise
      end
      seq
    end

    def write_message(message, deadline: nil)
      payload = JSON.generate(message).b
      raise ProtocolError, "outgoing DAP message exceeds limit" if payload.bytesize > MAX_MESSAGE_BYTES
      frame = "Content-Length: #{payload.bytesize}\r\n\r\n".b + payload
      record_protocol_traffic(frame.bytesize)
      @process.write(frame, deadline: deadline || step_deadline)
    end

    def await_response(seq, command)
      deadline = step_deadline
      loop do
        response = @responses.delete(seq)
        if response
          raise ProtocolError, "DAP response command mismatch for #{command}" unless response["command"] == command
          unless response["success"] == true
            message = response["message"] || "request failed"
            raise ProbeError, "#{command} failed: #{bounded_string(message, 180)}"
          end
          return response
        end
        dispatch(read_message(deadline), deadline: deadline)
      end
    end

    def await_event(event_name)
      deadline = step_deadline
      loop do
        index = @events.index { |event| event["event"] == event_name }
        return @events.delete_at(index) if index
        dispatch(read_message(deadline), deadline: deadline)
      end
    end

    def dispatch(message, deadline: nil)
      record_protocol_message
      case message["type"]
      when "response"
        request_seq = message["request_seq"]
        raise ProtocolError, "DAP response has no request_seq" unless request_seq.is_a?(Integer)
        expected_command = @outstanding_requests.delete(request_seq)
        raise ProtocolError, "unknown or duplicate DAP response" unless expected_command
        raise ProtocolError, "DAP response command mismatch" unless message["command"] == expected_command
        raise ProtocolError, "DAP response has malformed success flag" unless [true, false].include?(message["success"])
        if message["success"] == false
          failure_message = dap_failure_message(message)
          failure = {"command" => expected_command, "message" => failure_message}
          @result["failed_dap_responses"] << failure if @result["failed_dap_responses"].length < MAX_QUEUED_RESPONSES
          raise DAPRequestFailure.new(expected_command, "#{expected_command} failed: #{failure_message}")
        end
        raise ProtocolError, "too many queued DAP responses" if @responses.length >= MAX_QUEUED_RESPONSES
        @responses[request_seq] = message
      when "event"
        event_name = message["event"]
        raise ProtocolError, "DAP event has no name" unless event_name.is_a?(String)
        raise ProtocolError, "DAP event name exceeds limit" if event_name.bytesize > 120
        record_event_history(event_name)
        capture_dap_output(message) if event_name == "output"
        validate_event_order(message)
        if LIFECYCLE_EVENTS.include?(event_name)
          raise ProtocolError, "too many queued DAP lifecycle events" if @events.length >= MAX_LIFECYCLE_EVENTS
          @events << message
        elsif OBSERVATION_EVENTS.include?(event_name)
          # Observation-only notifications are recorded in bounded history, then discarded.
        end
      when "request"
        reject_reverse_request(message, deadline: deadline)
      else
        raise ProtocolError, "unknown DAP message type"
      end
    end

    def dap_failure_message(message)
      body = message["body"].is_a?(Hash) ? message["body"] : {}
      error = body["error"].is_a?(Hash) ? body["error"] : {}
      candidate = [message["message"], error["format"], error["message"]].find do |value|
        value.is_a?(String) && !value.empty?
      end
      bounded_string(candidate, 180) || "request failed"
    end

    def capture_dap_output(message)
      body = message["body"].is_a?(Hash) ? message["body"] : {}
      output = body["output"].to_s
      event_count = @result["dap_output_event_count"].to_i + 1
      observed_bytes = @result["dap_output_bytes_observed"].to_i + output.bytesize
      captured_bytes = @result["dap_output_bytes_captured"].to_i
      remaining = [MAX_DAP_OUTPUT_BYTES - captured_bytes, 0].max
      excerpt = DebuggerProbe.text_excerpt(output, remaining)

      @result["dap_output_event_count"] = event_count
      @result["dap_output_bytes_observed"] = observed_bytes
      @result["dap_output_bytes_captured"] = captured_bytes + excerpt.bytesize
      @result["dap_output_capture_truncated"] = true if event_count > MAX_DAP_OUTPUT_RECORDS || output.bytesize > remaining
      if @result["dap_output_events"].length < MAX_DAP_OUTPUT_RECORDS
        @result["dap_output_events"] << {
          "category" => bounded_string(body["category"], MAX_DAP_OUTPUT_CATEGORY_BYTES),
          "output" => excerpt
        }
      else
        @result["dap_output_capture_truncated"] = true
      end
    end

    def validate_event_order(message)
      name = message["event"]
      if name == "initialized"
        raise ProtocolError, "initialized event arrived before launch" unless @launch_sent
        raise ProtocolError, "duplicate initialized event" if @initialized_event_seen
        @initialized_event_seen = true
      end
      if name == "stopped"
        raise ProtocolError, "stopped event arrived before configurationDone" unless @configuration_done_sent
        expected = @expected_stops.shift
        actual = message.dig("body", "reason")
        raise ProtocolError, "unexpected stop reason #{actual.inspect}; expected #{expected.inspect}" unless actual == expected
      end
      if name == "exited"
        raise ProtocolError, "exited event arrived before continue" unless @continue_sent
        raise ProtocolError, "duplicate exited event" if @exited_event_seen
        @exited_event_seen = true
      end
      if name == "terminated"
        raise ProtocolError, "terminated event arrived before required exited event" unless @exited_event_seen
        raise ProtocolError, "duplicate terminated event" if @terminated_event_seen
        @terminated_event_seen = true
      end
    end

    def record_event_history(name)
      @event_count += 1
      @event_names << bounded_string(name, 80)
      return if @event_names.length <= MAX_EVENT_HISTORY

      @event_names.shift
      @event_history_truncated = true
    end

    def drain_locally_buffered_messages_before_continue
      deadline = step_deadline
      loop do
        ensure_deadline!(deadline)
        if (message = extract_buffered_message)
          dispatch(message, deadline: deadline)
          next
        end

        readers = [@process.stdout_reader]
        readers << @process.stderr_reader unless @process.stderr_eof?
        ready = IO.select(readers, nil, nil, 0)
        if !ready
          break if @buffer.empty?
          # A partial frame has already arrived locally. Allow its remaining bytes
          # to complete, but only within this step's existing deadline.
          remaining = [deadline - DebuggerProbe.monotonic_time,
                       @process_started_at + @process_timeout - DebuggerProbe.monotonic_time].min
          raise StepTimeout, "step deadline exceeded" if remaining <= 0
          ready = IO.select(readers, nil, nil, [remaining, 0.05].min)
          next unless ready
        end

        ready[0].each do |io|
          if io == @process.stdout_reader
            begin
              @buffer << io.read_nonblock(4096)
              if @buffer.bytesize > MAX_MESSAGE_BYTES + MAX_HEADER_BYTES + 4096
                raise ProtocolError, "DAP receive buffer exceeds limit"
              end
            rescue IO::WaitReadable
              next
            rescue EOFError
              @process.mark_stdout_eof
              raise ProtocolError, "adapter closed DAP stdout before continue"
            end
          else
            @process.drain_stderr
          end
        end
      end

      raise ProtocolError, "incomplete DAP frame buffered before continue" unless @buffer.empty?
    end

    def ensure_deadline!(deadline)
      now = DebuggerProbe.monotonic_time
      raise StepTimeout, "step deadline exceeded" if now >= deadline
      raise StepTimeout, "adapter process deadline exceeded" if now >= @process_started_at + @process_timeout
    end

    def reject_reverse_request(message, deadline: nil)
      seq = message["seq"]
      command = message["command"]
      raise ProtocolError, "malformed adapter reverse request" unless seq.is_a?(Integer) && command.is_a?(String)
      raise ProtocolError, "too many adapter reverse requests" if @reverse_requests.length >= MAX_REVERSE_REQUESTS
      response = {
        "seq" => @seq,
        "type" => "response",
        "request_seq" => seq,
        "command" => command,
        "success" => false,
        "message" => "Unsupported adapter request"
      }
      @seq += 1
      write_message(response, deadline: deadline)
      @reverse_requests << command
    end

    def read_message(deadline)
      loop do
        remaining = deadline - DebuggerProbe.monotonic_time
        raise StepTimeout, "step deadline exceeded" if remaining <= 0
        process_deadline = @process_started_at + @process_timeout
        remaining_process = process_deadline - DebuggerProbe.monotonic_time
        raise StepTimeout, "adapter process deadline exceeded" if remaining_process <= 0
        message = extract_buffered_message
        return message if message

        timeout = [remaining, remaining_process, 0.05].min
        readers = [@process.stdout_reader]
        readers << @process.stderr_reader unless @process.stderr_eof?
        ready = IO.select(readers, nil, nil, timeout)
        next unless ready
        ready[0].each do |io|
          if io == @process.stdout_reader
            begin
              chunk = io.read_nonblock(4096)
              @buffer << chunk
              if @buffer.bytesize > MAX_MESSAGE_BYTES + MAX_HEADER_BYTES + 4096
                raise ProtocolError, "DAP receive buffer exceeds limit"
              end
            rescue IO::WaitReadable
              next
            rescue EOFError
              @process.mark_stdout_eof
              raise ProtocolError, "adapter closed DAP stdout before required response/event"
            end
          else
            @process.drain_stderr
          end
        end
      end
    end

    def extract_buffered_message
      separator = @buffer.index("\r\n\r\n".b)
      unless separator
        raise ProtocolError, "DAP header exceeds limit" if @buffer.bytesize > MAX_HEADER_BYTES
        return nil
      end
      raise ProtocolError, "DAP header exceeds limit" if separator > MAX_HEADER_BYTES
      header = @buffer.byteslice(0, separator).split("\r\n".b)
      lengths = header.select { |line| line.match?(/\AContent-Length:/i) }
      raise ProtocolError, "DAP frame needs one Content-Length" unless lengths.length == 1
      match = lengths.first.match(/\AContent-Length:\s*(\d+)\s*\z/i)
      raise ProtocolError, "malformed DAP Content-Length" unless match
      body_length = match[1].to_i
      raise ProtocolError, "DAP message exceeds limit" if body_length > MAX_MESSAGE_BYTES
      body_start = separator + 4
      return nil if @buffer.bytesize < body_start + body_length
      body = @buffer.byteslice(body_start, body_length)
      @buffer = @buffer.byteslice(body_start + body_length, @buffer.bytesize) || "".b
      record_protocol_traffic(body_start + body_length)
      DebuggerProbe.parse_json_message(body)
    end

    def record_protocol_message
      @protocol_message_count += 1
      raise ProtocolError, "DAP message count exceeds limit" if @protocol_message_count > MAX_PROTOCOL_MESSAGES
    end

    def record_protocol_traffic(bytes)
      @protocol_bytes += bytes
      raise ProtocolError, "DAP total traffic exceeds limit" if @protocol_bytes > MAX_PROTOCOL_BYTES
    end

    def step_deadline
      [DebuggerProbe.monotonic_time + @step_timeout, @process_started_at + @process_timeout].min
    end

    def ensure_process_budget!
      deadline = @process_started_at + @process_timeout
      raise StepTimeout, "adapter process deadline exceeded" if DebuggerProbe.monotonic_time >= deadline
    end

    def same_path?(candidate, expected)
      return false unless candidate.is_a?(String)
      File.expand_path(candidate) == expected
    end

    def optional_nonnegative(value)
      value.is_a?(Integer) && value >= 0 ? value : nil
    end

    def bounded_string(value, limit)
      return nil unless value.is_a?(String)
      DebuggerProbe.text_excerpt(value, limit)
    end

    def normalize_variable(variable)
      raise ProbeError, "malformed variable record" unless variable.is_a?(Hash) && variable["name"].is_a?(String)
      {
        "name" => bounded_string(variable["name"], 120),
        "type" => bounded_string(variable["type"], 120),
        "value" => bounded_string(variable["value"], MAX_VALUE_BYTES),
        "variablesReference" => optional_nonnegative(variable["variablesReference"]) || 0,
        "namedVariables" => optional_nonnegative(variable["namedVariables"]),
        "indexedVariables" => optional_nonnegative(variable["indexedVariables"])
      }
    end

    def value_presence(locals)
      by_name = locals.each_with_object({}) { |variable, result| result[variable["name"]] ||= variable }
      VALUE_NAMES.each_with_object({}) do |name, result|
        result[name] = {
          "present" => by_name.key?(name),
          "expected_absent" => name == "debugger_out_of_scope",
          "type" => by_name[name] && by_name[name]["type"],
          "adapter_value" => by_name[name] && by_name[name]["value"],
          "named_child_count" => by_name[name] && by_name[name]["namedVariables"],
          "indexed_child_count" => by_name[name] && by_name[name]["indexedVariables"]
        }
      end
    end

    def container_observations(locals)
      wanted = VALUE_NAMES.reject { |name| name == "debugger_out_of_scope" }
      locals.select { |variable| wanted.include?(variable["name"]) }.map do |variable|
        {
          "name" => variable["name"],
          "type" => variable["type"],
          "adapter_value" => variable["value"],
          "variablesReference" => variable["variablesReference"],
          "namedVariables" => variable["namedVariables"],
          "indexedVariables" => variable["indexedVariables"]
        }
      end
    end

    def cleanup_adapter
      return unless @process
      was_complete = @result && @result["status"] == "PASS"
      if @launch_sent && !@target_exited && !@process.poll_status
        begin
          @terminate_requested = true
          seq = @seq
          @seq += 1
          cleanup_deadline = [DebuggerProbe.monotonic_time + 0.05, @process_started_at + @process_timeout].min
          write_message({
            "seq" => seq,
            "type" => "request",
            "command" => "disconnect",
            "arguments" => {"restart" => false, "terminateDebuggee" => true}
          }, deadline: cleanup_deadline)
          @cleanup["terminate_debuggee_requested"] = true
        rescue StandardError
          @cleanup["terminate_debuggee_requested"] = false
        end
      end
      @process.close_stdin
      exited = @process.wait_for_exit(was_complete ? [@step_timeout, 0.8].min : 0.2)
      if exited
        @process.terminate
        @cleanup["status"] = @cleanup["status"] == "disconnect_acknowledged" ? "clean" : "adapter_exited"
      else
        @process.terminate
        @cleanup["status"] = "owned_process_group_terminated"
        @cleanup["forced"] = true
        if was_complete
          @result["status"] = "FAIL"
          @result["failure"] = "disconnect: adapter did not exit within cleanup deadline"
        end
      end
      @cleanup["adapter_exit_code"] = @process.exit_code
    rescue StandardError => error
      @cleanup["status"] = "cleanup_error"
      @cleanup["error"] = DebuggerProbe.text_excerpt(error.message, 160)
      @process.terminate if @process && @process.status.nil?
    ensure
      @process.close if @process
    end
  end

  class Harness
    def initialize(options)
      @options = options
      @runner = CommandRunner.new
      @report = {
        "probe" => "DBG-0 real-binary compatibility probe",
        "claim_boundary" => "C is a reference control; Crystal and Adamas outcomes remain separate; adapter values do not certify native formatters",
        "targets" => {}
      }
    end

    def run
      unless File.directory?("/private/tmp") && File.writable?("/private/tmp")
        raise ProbeError, "/private/tmp is not writable"
      end
      @report["inherited_lldb_debugserver"] = DebuggerProbe.debugserver_identity
      if @report.dig("inherited_lldb_debugserver", "status") == "invalid"
        raise ProbeError, "LLDB_DEBUGSERVER_PATH is set but not a valid executable"
      end
      Dir.mktmpdir("adamantine-dbg0-", "/private/tmp") do |root|
        @temporary_root = root
        %w[adapter cc c crystal adamas xdg].each { |name| FileUtils.mkdir_p(File.join(root, name)) }
        @tools = {
          "adapter" => inspect_tool("adapter", @options[:adapter], ["--version"], root),
          "cc" => inspect_tool("cc", @options[:cc], ["--version"], root),
          "crystal" => inspect_tool("crystal", @options[:crystal_bin], ["version"], root),
          "adamas" => inspect_tool("adamas", @options[:adamas_bin], ["--version"], root)
        }
        adamas_help = run_tool_command(@tools["adamas"], ["--help"], root, File.join(root, "xdg", "adamas"))
        @tools["adamas"]["help"] = {
          "exit_code" => adamas_help["exit_code"],
          "timed_out" => adamas_help["timed_out"],
          "output_bytes" => adamas_help["stdout_bytes"].to_i + adamas_help["stderr_bytes"].to_i,
          "empty" => adamas_help["stdout_bytes"].to_i + adamas_help["stderr_bytes"].to_i == 0,
          "recognized_flags" => recognized_adamas_flags(adamas_help)
        }
        @tools["adamas"]["source_provenance"] = "unknown prebuilt binary; does not certify current or dirty source HEAD"
        @report["tools"] = @tools

        run_target("c", @tools["cc"], File.join(FIXTURES, "control.c"), root)
        run_target("crystal", @tools["crystal"], File.join(FIXTURES, "control.cr"), root)
        run_target("adamas", @tools["adamas"], File.join(FIXTURES, "adamas_locals.cr"), root)
        summarize
      end
      @report
    end

    private

    def inspect_tool(name, path, version_args, root)
      provided = path.to_s
      absolute = File.expand_path(provided)
      tool = {
        "name" => name,
        "provided_path" => provided,
        "resolved_path" => nil,
        "sha256" => nil,
        "file_kind" => "unknown",
        "version" => nil,
        "version_status" => "unavailable"
      }
      unless File.file?(absolute) && File.executable?(absolute)
        tool["preflight_error"] = "explicit path is not an executable file"
        return tool
      end
      resolved = File.realpath(absolute)
      tool["resolved_path"] = resolved
      tool["sha256"] = Digest::SHA256.file(resolved).hexdigest
      first_line = File.open(resolved, "rb") { |file| file.read(2 * 1024) }.to_s.lines.first.to_s
      tool["file_kind"] = first_line.start_with?("#!") ? "script-or-wrapper" : "native-or-unknown"
      version = @runner.run([resolved] + version_args, env: cache_env(File.join(root, "xdg", name)),
                            cwd: File.join(root, name), timeout: @options[:process_timeout])
      version_text = version["stdout"].to_s.empty? ? version["stderr_excerpt"].to_s : version["stdout"].to_s
      tool["version"] = DebuggerProbe.text_excerpt(version_text.lines.first.to_s.strip, 240)
      tool["version_status"] = if version["timed_out"]
                                 "timeout"
                               elsif version["exit_code"] == 0 && !tool["version"].to_s.empty?
                                 "reported"
                               elsif version["exit_code"] == 0
                                 "empty"
                               else
                                 "failed"
                               end
      tool["version_exit_code"] = version["exit_code"]
      tool["version_stdout_bytes"] = version["stdout_bytes"]
      tool
    rescue SystemCallError => error
      tool["preflight_error"] = DebuggerProbe.text_excerpt(error.message, 200)
      tool
    end

    def run_tool_command(tool, extra_args, root, cache_home)
      return {"exit_code" => nil, "timed_out" => false, "stdout_bytes" => 0, "stderr_bytes" => 0} unless tool["resolved_path"]
      env = cache_env(cache_home)
      if tool["name"] == "adamas"
        env["ADAMAS_LLVM_CACHE"] = "0"
      end
      @runner.run([tool["resolved_path"]] + extra_args, env: env,
                  cwd: File.join(root, tool["name"]), timeout: @options[:process_timeout])
    end

    def cache_env(cache_home)
      FileUtils.mkdir_p(cache_home)
      {"XDG_CACHE_HOME" => cache_home}
    end

    def recognized_adamas_flags(help_result)
      output = help_result["stdout"].to_s + help_result["stderr_excerpt"].to_s
      %w[--debug --no-llvm-cache --no-ast-cache --output -o].select { |flag| output.include?(flag) }
    end

    def run_target(name, tool, source, root)
      result = {"status" => "FAIL", "source" => source, "compiler" => name}
      target_dir = File.join(root, name)
      output = File.join(target_dir, "#{name}-probe")
      cache_home = File.join(root, "xdg", name)
      FileUtils.mkdir_p(cache_home)
      unless tool["resolved_path"]
        result["failure"] = "explicit compiler path unavailable"
        @report["targets"][name] = result
        return
      end

      argv = compile_argv(name, tool["resolved_path"], source, output, tool["version"])
      env = cache_env(cache_home)
      env["CC"] = @tools["cc"]["resolved_path"] if @tools["cc"]["resolved_path"]
      if name == "adamas"
        env["ADAMAS_LLVM_CACHE"] = "0"
        env["XDG_CACHE_HOME"] = File.join(root, "xdg", "adamas")
      end
      original_path = ENV["PATH"].to_s
      cc_dir = @tools["cc"]["resolved_path"] && File.dirname(@tools["cc"]["resolved_path"])
      env["PATH"] = [cc_dir, original_path].compact.reject(&:empty?).join(File::PATH_SEPARATOR) if cc_dir
      result["compile_argv"] = argv
      result["cache_controls"] = if name == "adamas"
                                   {
                                     "cwd" => target_dir,
                                     "XDG_CACHE_HOME" => env["XDG_CACHE_HOME"],
                                     "ADAMAS_LLVM_CACHE" => "0",
                                     "flags" => %w[--no-llvm-cache --no-ast-cache],
                                     "pipeline_cache_files_confined_to" => File.join(target_dir, "tmp"),
                                     "home_unchanged" => true
                                   }
                                 else
                                   {"cwd" => target_dir, "XDG_CACHE_HOME" => cache_home, "home_unchanged" => true}
                                 end
      compile = @runner.run(argv, env: env, cwd: target_dir, timeout: @options[:process_timeout])
      result["compile"] = command_summary(compile)
      unless compile["exit_code"] == 0 && !compile["timed_out"] && File.file?(output) && File.executable?(output)
        result["failure"] = compile["timed_out"] ? "compile process timed out" : "compile did not produce an executable"
        result["compile"]["stderr_excerpt"] = compile["stderr_excerpt"] if compile["stderr_excerpt"]
        @report["targets"][name] = result
        return
      end

      result["binary"] = {
        "path" => output,
        "sha256" => Digest::SHA256.file(output).hexdigest
      }
      probe = DAPProbe.new(
        adapter_path: @tools["adapter"]["resolved_path"] || @options[:adapter],
        step_timeout: @options[:step_timeout],
        process_timeout: @options[:process_timeout]
      )
      debugger = probe.run(binary_path: output, source_path: source)
      result["debugger"] = debugger
      result["status"] = debugger["status"]
      result["failure"] = debugger["failure"] if debugger["failure"]
      @report["targets"][name] = result
    rescue StandardError => error
      result["failure"] ||= "#{error.class}: #{DebuggerProbe.text_excerpt(error.message, 240)}"
      @report["targets"][name] = result
    end

    def compile_argv(name, compiler, source, output, version)
      case name
      when "c"
        [compiler, "-g", "-O0", "-std=gnu11", source, "-o", output]
      when "crystal"
        flags = [compiler, "build", "--debug", "-O", "0", "-o", output]
        if RUBY_PLATFORM.match?(/darwin/i) && version.to_s.match?(/\b1\.21(?:\.0)?\b/)
          flags << "--link-flags=-fuse-ld=/usr/bin/ld"
        end
        flags << source
        flags
      when "adamas"
        [compiler, "--debug", "-O", "0", "--no-llvm-cache", "--no-ast-cache", source, "--output", output]
      else
        raise ProbeError, "unknown compiler target #{name}"
      end
    end

    def command_summary(result)
      {
        "exit_code" => result["exit_code"],
        "timed_out" => result["timed_out"],
        "stdout_bytes" => result["stdout_bytes"],
        "stderr_bytes" => result["stderr_bytes"],
        "stdout_truncated" => result["stdout_truncated"],
        "stderr_truncated" => result["stderr_truncated"]
      }
    end

    def summarize
      c_passed = @report.dig("targets", "c", "status") == "PASS"
      language_passes = %w[crystal adamas].count { |name| @report.dig("targets", name, "status") == "PASS" }
      @report["reference_control"] = c_passed ? "PASS" : "FAIL"
      @report["language_probes_passed"] = language_passes
      @report["language_admission"] = language_passes > 0 ? "at least one target-language core probe passed" : "no target-language core probe passed"
      @report["qualified_summary"] = if c_passed && language_passes == 2
                                       "C, Crystal, and Adamas core DAP control/locals probes passed; value coverage is adapter-specific and does not certify native formatters"
                                     elsif c_passed && language_passes > 0
                                       "C reference control passed; at least one language core probe passed; target results remain separate and adapter values do not certify native formatters"
                                     elsif c_passed
                                       "C reference control passed; target-language probes did not pass; generic DAP foundation only"
                                     else
                                       "C reference control failed; no compatibility admission"
                                     end
      @report["exit_policy"] = {
        "nonzero_when" => ["harness error", "C reference control failed"] + (@options[:require_language] ? ["no language target probe passed"] : []),
        "require_language" => @options[:require_language]
      }
    end
  end

  def self.parse_options(argv)
    options = {
      adapter: nil,
      cc: nil,
      crystal_bin: nil,
      adamas_bin: nil,
      step_timeout: 5.0,
      process_timeout: 45.0,
      require_language: false
    }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: probe_debugger_controls.sh --adapter PATH --cc PATH --crystal-bin PATH --adamas-bin PATH [options]"
      opts.on("--adapter PATH", "Explicit stdio DAP adapter executable") { |value| options[:adapter] = value }
      opts.on("--cc PATH", "Explicit C compiler executable") { |value| options[:cc] = value }
      opts.on("--crystal-bin PATH", "Explicit stock Crystal compiler executable") { |value| options[:crystal_bin] = value }
      opts.on("--adamas-bin PATH", "Explicit prebuilt Adamas compiler executable") { |value| options[:adamas_bin] = value }
      opts.on("--step-timeout SECONDS", Float, "Per DAP step deadline (default 5)") { |value| options[:step_timeout] = value }
      opts.on("--process-timeout SECONDS", Float, "Compiler/adapter process deadline (default 45)") { |value| options[:process_timeout] = value }
      opts.on("--require-language", "Exit nonzero unless Crystal or Adamas core probe passes") { options[:require_language] = true }
      opts.on("-h", "--help", "Show this help") do
        puts opts
        exit 0
      end
    end
    parser.parse!(argv)
    missing = %i[adapter cc crystal_bin adamas_bin].reject { |key| !options[key].to_s.empty? }
    raise OptionParser::MissingArgument, "required explicit paths: #{missing.join(', ')}" unless missing.empty?
    raise OptionParser::InvalidArgument, "timeouts must be positive and finite" unless options[:step_timeout].finite? && options[:process_timeout].finite? && options[:step_timeout] > 0 && options[:process_timeout] > 0
    raise OptionParser::InvalidArgument, "step timeout cannot exceed process timeout" if options[:step_timeout] > options[:process_timeout]
    options
  end

  def self.main(argv)
    options = parse_options(argv)
    report = Harness.new(options).run
    puts JSON.pretty_generate(report)
    c_failed = report["reference_control"] != "PASS"
    language_failed = options[:require_language] && report["language_probes_passed"].to_i == 0
    c_failed || language_failed ? 1 : 0
  rescue OptionParser::ParseError, ProbeError => error
    warn "debugger probe: #{text_excerpt(error.message, 300)}"
    2
  rescue StandardError => error
    warn "debugger probe: harness error #{error.class}: #{text_excerpt(error.message, 260)}"
    2
  end
end

if $PROGRAM_NAME == __FILE__
  exit(DebuggerProbe.main(ARGV))
end
