require "json"
require "set"

require "./editor_tools"

module Adamantine
  module LuaScripts
    class RuntimeError < Exception
    end

    struct Limits
      getter source_bytes : Int32
      getter lua_heap_bytes : Int32
      getter wall_time : Time::Span
      getter output_bytes : Int32
      getter output_events : Int32

      def initialize(@source_bytes : Int32 = 64 * 1024,
                     @lua_heap_bytes : Int32 = 8 * 1024 * 1024,
                     @wall_time : Time::Span = 5.seconds,
                     @output_bytes : Int32 = 16 * 1024,
                     @output_events : Int32 = 64)
        raise ArgumentError.new("Lua source limit must be 1..64 KiB") unless @source_bytes.in?(1..(64 * 1024))
        raise ArgumentError.new("Lua heap limit must be 1..8 MiB") unless @lua_heap_bytes.in?(1..(8 * 1024 * 1024))
        raise ArgumentError.new("Lua wall limit must be 1..5 seconds") unless @wall_time > Time::Span.zero && @wall_time <= 5.seconds
        raise ArgumentError.new("Lua output byte limit must be 1..16 KiB") unless @output_bytes.in?(1..(16 * 1024))
        raise ArgumentError.new("Lua output event limit must be 1..64") unless @output_events.in?(1..64)
      end
    end

    enum EventKind
      ToolRequest
      Output
      Complete
      Failed

      def tool_request? : Bool
        self == EventKind::ToolRequest
      end

      def output? : Bool
        self == EventKind::Output
      end

      def complete? : Bool
        self == EventKind::Complete
      end

      def failed? : Bool
        self == EventKind::Failed
      end
    end

    class Event
      getter kind : EventKind
      getter call_id : String?
      getter request_json : String?
      getter text : String?
      getter failure_code : String?
      getter failure_message : String?

      def initialize(@kind : EventKind, @call_id : String? = nil,
                     @request_json : String? = nil, @text : String? = nil,
                     @failure_code : String? = nil,
                     @failure_message : String? = nil)
      end
    end

    class Runner
      getter worker_path : String
      getter library_path : String
      getter limits : Limits

      def initialize(worker_path : String? = nil, library_path : String? = nil,
                     @limits : Limits = Limits.new)
        @worker_path = resolve_worker_path(worker_path)
        @library_path = resolve_library_path(library_path)
      end

      def start(script_id : String, source : String, context : JSON::Any) : Run
        raise RuntimeError.new("Lua script ID is invalid") unless script_id.valid_encoding? && script_id.bytesize.in?(1..64)
        raise RuntimeError.new("Lua script source is invalid UTF-8 or exceeds #{limits.source_bytes} bytes") unless source.valid_encoding? && source.bytesize <= limits.source_bytes
        context_json = context.to_json
        raise RuntimeError.new("Lua run context exceeds 32 KiB") if context_json.bytesize > 32 * 1024
        begin
          EditorTools.parse_bounded_json(context_json)
        rescue
          raise RuntimeError.new("Lua run context is not bounded JSON")
        end

        Run.new(worker_path, library_path, limits, script_id, source, context)
      end

      private def resolve_worker_path(path : String?) : String
        candidate = path || ENV["ADAMANTINE_LUA_WORKER"]? || Process.executable_path
        unless candidate
          raise RuntimeError.new("Adamantine Lua worker executable is unavailable; set ADAMANTINE_LUA_WORKER")
        end
        unless File.file?(candidate) && File::Info.executable?(candidate)
          raise RuntimeError.new("Adamantine Lua worker executable is unavailable; rebuild the editor and set ADAMANTINE_LUA_WORKER")
        end
        File.realpath(candidate)
      rescue ex : RuntimeError
        raise ex
      rescue
        raise RuntimeError.new("Adamantine Lua worker executable path is invalid")
      end

      private def resolve_library_path(path : String?) : String
        candidate = path || ENV["ADAMANTINE_LUA_LIBRARY"]?
        unless candidate && Path.new(candidate).absolute? && File.file?(candidate)
          raise RuntimeError.new("Lua 5.4 is optional; configure ADAMANTINE_LUA_LIBRARY with an absolute Lua 5.4 shared-library path")
        end
        File.realpath(candidate)
      rescue ex : RuntimeError
        raise ex
      rescue
        raise RuntimeError.new("ADAMANTINE_LUA_LIBRARY must be an absolute path to a compatible Lua 5.4 shared library")
      end
    end

    class Run
      # 64 KiB source may expand to six bytes per source byte in JSON; context
      # is independently bounded to 32 KiB. Keep a finite envelope for both.
      # Source and context are each JSON-escaped in the envelope. A control
      # byte can expand to six bytes at both string boundaries.
      MAX_START_FRAME_BYTES = 640 * 1024
      # JSON escaping expands a 16 KiB print event by up to sixfold.
      MAX_PROTOCOL_FRAME_BYTES = 128 * 1024
      MAX_REPLY_FRAME_BYTES    = 512 * 1024
      MAX_STDERR_BYTES         = 8 * 1024
      MAX_TOOL_CALLS           = 64
      MAX_BUFFERED_EVENTS      = MAX_TOOL_CALLS + 64
      MONITOR_INTERVAL         = 5.milliseconds

      getter process_pid : Int64?
      getter failure_code : String?
      getter failure_message : String?

      @process : Process
      @limits : Limits
      @deadline : Time::Instant
      @events : Array(Event)
      @terminal_event : Event?
      @failure_message : String?
      @lock : Mutex
      @write_lock : Mutex
      @stop_requested : String?
      @terminal : Bool
      @reaped : Bool
      @worker_complete : Bool
      @stdout_eof : Bool
      @stderr_eof : Bool
      @stderr_bytes : Int32
      @output_bytes : Int32
      @output_events : Int32
      @tool_calls : Int32
      @pending_call_id : String?
      @reply_ids : Set(String)
      @stdout_done : Channel(Nil)
      @stderr_done : Channel(Nil)

      def initialize(worker_path : String, library_path : String, @limits : Limits,
                     script_id : String, source : String, context : JSON::Any)
        @deadline = Time.instant + @limits.wall_time
        @events = [] of Event
        @terminal_event = nil
        @failure_message = nil
        @lock = Mutex.new
        @write_lock = Mutex.new
        @stop_requested = nil
        @terminal = false
        @reaped = false
        @worker_complete = false
        @stdout_eof = false
        @stderr_eof = false
        @stderr_bytes = 0
        @output_bytes = 0
        @output_events = 0
        @tool_calls = 0
        @pending_call_id = nil
        @reply_ids = Set(String).new
        @stdout_done = Channel(Nil).new(1)
        @stderr_done = Channel(Nil).new(1)

        @process = Process.new(
          [worker_path, "--internal-lua-worker"],
          env: {"ADAMANTINE_LUA_LIBRARY" => library_path},
          clear_env: true,
          chdir: "/",
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe
        )
        @process_pid = @process.pid
        spawn { read_stdout }
        spawn { read_stderr }
        spawn { supervise }
        begin
          write_start_frame(script_id, source, context)
        rescue
          request_stop("worker_start_failed")
        end
      end

      def drain_events : Array(Event)
        @lock.synchronize do
          current = @events
          @events = [] of Event
          if terminal = @terminal_event
            current << terminal
            @terminal_event = nil
          end
          current
        end
      end

      # The response must be the existing EditorTools::Result JSON envelope.
      def reply(call_id : String, response_json : String) : Bool
        return false unless active?
        return false if response_json.bytesize > EditorTools::MAX_RESPONSE_BYTES
        response = begin
          EditorTools.parse_bounded_json(response_json)
        rescue
          return false
        end
        object = response.as_h?
        return false unless object && object["id"]?.try(&.as_s?) == call_id

        accepted = @lock.synchronize do
          next false if @terminal || @stop_requested || @pending_call_id != call_id || @reply_ids.includes?(call_id)
          @reply_ids << call_id
          @pending_call_id = nil
          true
        end
        return false unless accepted

        frame = JSON.build do |json|
          json.object do
            json.field "kind", "reply"
            json.field "id", call_id
            json.field "response", response_json
          end
        end
        if frame.bytesize > MAX_REPLY_FRAME_BYTES
          request_stop("reply_frame_limit")
          return false
        end
        begin
          @write_lock.synchronize do
            @process.input << frame << '\n'
            @process.input.flush
          end
          true
        rescue
          request_stop("worker_pipe_failed")
          false
        end
      end

      def cancel : Nil
        request_stop("cancelled")
      end

      # Shutdown paths may wait briefly for the supervisor to kill and reap
      # the owned child, but must never block the App owner indefinitely.
      def cancel_and_wait(timeout : Time::Span = 1.second) : Bool
        cancel
        return reaped? if timeout <= Time::Span.zero
        deadline = Time.instant + timeout
        until reaped?
          remaining = deadline - Time.instant
          return false if remaining <= Time::Span.zero
          sleep [MONITOR_INTERVAL, remaining].min
        end
        true
      end

      def active? : Bool
        if Time.instant >= @deadline
          request_stop("wall_time_limit")
        end
        @lock.synchronize { !@terminal && @stop_requested.nil? }
      end

      def reaped? : Bool
        @lock.synchronize { @reaped }
      end

      # Read-only queue observation used by bounded owner/shutdown tests; it
      # never consumes or acknowledges an event.
      def events_pending? : Bool
        @lock.synchronize { !@events.empty? || @terminal_event != nil }
      end

      private def write_start_frame(script_id : String, source : String, context : JSON::Any) : Nil
        frame = JSON.build do |json|
          json.object do
            json.field "kind", "start"
            json.field "version", 1
            json.field "script_id", script_id
            json.field "source", source
            json.field "context" do
              context.to_json(json)
            end
            json.field "limits" do
              json.object do
                json.field "lua_heap_bytes", @limits.lua_heap_bytes
                json.field "output_bytes", @limits.output_bytes
                json.field "output_events", @limits.output_events
              end
            end
          end
        end
        raise RuntimeError.new("Lua startup frame exceeds #{MAX_START_FRAME_BYTES} bytes") if frame.bytesize > MAX_START_FRAME_BYTES
        @process.input << frame << '\n'
        @process.input.flush
      end

      private def read_stdout : Nil
        io = @process.output
        while line = io.gets(MAX_PROTOCOL_FRAME_BYTES + 1, chomp: false)
          unless line.ends_with?('\n') && line.bytesize <= MAX_PROTOCOL_FRAME_BYTES
            protocol_failure("protocol_frame_limit")
            break
          end
          handle_frame(line[0, line.bytesize - 1]) || break
        end
      rescue
        protocol_failure("worker_pipe_failed") unless stopped_or_terminal?
      ensure
        @lock.synchronize { @stdout_eof = true }
        @stdout_done.send(nil) rescue nil
      end

      private def read_stderr : Nil
        io = @process.error
        buffer = Bytes.new(1024)
        loop do
          count = io.read(buffer)
          break if count == 0
          overflow = @lock.synchronize do
            @stderr_bytes += count
            @stderr_bytes > MAX_STDERR_BYTES
          end
          if overflow
            protocol_failure("worker_stderr_limit")
            break
          end
        end
      rescue
        protocol_failure("worker_pipe_failed") unless stopped_or_terminal?
      ensure
        @lock.synchronize { @stderr_eof = true }
        @stderr_done.send(nil) rescue nil
      end

      private def handle_frame(line : String) : Bool
        return protocol_failure("protocol_frame_invalid") && false unless line.valid_encoding?
        frame = begin
          EditorTools.parse_bounded_json(line).as_h?
        rescue
          nil
        end
        return protocol_failure("protocol_frame_invalid") && false unless frame
        kind = frame["kind"]?.try(&.as_s?)
        case kind
        when "output"
          handle_output(frame)
        when "tool"
          handle_tool_request(frame)
        when "complete"
          invalid_order = @lock.synchronize do
            @worker_complete || @failure_code != nil || @pending_call_id != nil
          end
          if frame.keys.to_set != Set{"kind"} || invalid_order
            protocol_failure("protocol_frame_invalid")
            false
          else
            @lock.synchronize { @worker_complete = true }
            true
          end
        when "failed"
          code = frame["code"]?.try(&.as_s?)
          has_message = frame.has_key?("message")
          message = frame["message"]?.try(&.as_s?)
          expected_keys = has_message ? Set{"kind", "code", "message"} : Set{"kind", "code"}
          unless frame.keys.to_set == expected_keys && code && code.bytesize <= 64 && code.matches?(/\A[a-z0-9_]+\z/) && (!has_message || !message.nil?)
            protocol_failure("protocol_frame_invalid")
            return false
          end
          if diagnostic = message
            unless valid_failure_message?(code.not_nil!, diagnostic)
              protocol_failure("protocol_frame_invalid")
              return false
            end
          end
          terminal_preceded = @lock.synchronize { @worker_complete || @failure_code != nil }
          if terminal_preceded
            protocol_failure("protocol_frame_invalid")
            return false
          end
          @lock.synchronize do
            @failure_code ||= code
            @failure_message ||= message
          end
          true
        else
          protocol_failure("protocol_frame_invalid")
          false
        end
      end

      private def handle_output(frame : Hash(String, JSON::Any)) : Bool
        terminal_preceded = @lock.synchronize { @worker_complete || @failure_code != nil }
        if terminal_preceded
          protocol_failure("protocol_frame_invalid")
          return false
        end
        text = frame["text"]?.try(&.as_s?)
        unless text && frame.keys.to_set == Set{"kind", "text"} && text.valid_encoding?
          protocol_failure("protocol_frame_invalid")
          return false
        end
        sanitized = sanitize_output(text)
        overflow = @lock.synchronize do
          @output_events += 1
          @output_bytes += sanitized.bytesize
          @output_events > @limits.output_events || @output_bytes > @limits.output_bytes || @events.size >= MAX_BUFFERED_EVENTS
        end
        if overflow
          protocol_failure("output_limit")
          return false
        end
        push_event(Event.new(EventKind::Output, text: sanitized))
        true
      end

      private def handle_tool_request(frame : Hash(String, JSON::Any)) : Bool
        terminal_preceded = @lock.synchronize { @worker_complete || @failure_code != nil }
        if terminal_preceded
          protocol_failure("protocol_frame_invalid")
          return false
        end
        id = frame["id"]?.try(&.as_s?)
        name = frame["name"]?.try(&.as_s?)
        arguments = frame["arguments"]?
        unless id && id.bytesize.in?(1..64) && name && name.bytesize.in?(1..128) && arguments && arguments.as_h? && frame.keys.to_set == Set{"kind", "id", "name", "arguments"}
          protocol_failure("protocol_frame_invalid")
          return false
        end
        over_limit = @lock.synchronize do
          @tool_calls += 1
          @tool_calls > MAX_TOOL_CALLS || @pending_call_id != nil || @events.size >= MAX_BUFFERED_EVENTS
        end
        if over_limit
          protocol_failure("tool_call_limit")
          return false
        end

        request_json = JSON.build do |json|
          json.object do
            json.field "id", id
            json.field "name", name
            json.field "arguments" do
              arguments.to_json(json)
            end
          end
        end
        @lock.synchronize { @pending_call_id = id unless @terminal || @stop_requested }
        push_event(Event.new(EventKind::ToolRequest, call_id: id, request_json: request_json))
        true
      end

      private def supervise : Nil
        status_channel : Channel(Process::Status)? = nil
        loop do
          reason = @lock.synchronize { @stop_requested }
          if reason
            terminate_and_reap(reason)
            return
          end
          if Time.instant >= @deadline
            request_stop("wall_time_limit")
            next
          end
          break if @stdout_eof && @stderr_eof
          sleep MONITOR_INTERVAL
        end

        # Start wait only after both pipes reached EOF because Process#wait
        # closes its pipe handles. Keep the deadline active while wait is in
        # progress: a worker may close both streams and still hang.
        status_channel = Channel(Process::Status).new(1)
        spawn do
          begin
            status_channel.send(@process.wait)
          rescue
            status_channel.send(Process::Status.new(system_exit_status: 1)) rescue nil
          end
        end
        loop do
          reason = @lock.synchronize { @stop_requested }
          if reason
            begin
              @process.terminate(graceful: false)
            rescue
            end
          elsif Time.instant >= @deadline
            request_stop("wall_time_limit")
          end
          select
          when status = status_channel.receive
            request_stop("wall_time_limit") if Time.instant >= @deadline
            @lock.synchronize { @reaped = true }
            reason = @lock.synchronize { @stop_requested }
            failure = @lock.synchronize { @failure_code }
            if reason
              finish_failure(reason)
            elsif failure
              finish_failure(failure)
            elsif @worker_complete && status.success?
              finish_terminal(Event.new(EventKind::Complete))
            else
              finish_failure(status.success? ? "worker_missing_complete" : "worker_failed")
            end
            return
          when timeout(MONITOR_INTERVAL)
          end
        end
      rescue
        request_stop("worker_reap_failed")
        if waiter = status_channel
          begin
            @process.terminate(graceful: false)
          rescue
          end
          begin
            waiter.receive
          rescue
          end
          @lock.synchronize { @reaped = true }
          finish_failure("worker_reap_failed")
        else
          terminate_and_reap("worker_reap_failed")
        end
      end

      private def terminate_and_reap(reason : String) : Nil
        begin
          @process.terminate(graceful: false)
        rescue
        end
        begin
          @process.input.close
        rescue
        end
        status = begin
          @process.wait
        rescue
          nil
        end
        begin
          @process.output.close
          @process.error.close
        rescue
        end
        @lock.synchronize { @reaped = true }
        finish_failure(reason, status)
      end

      private def protocol_failure(code : String) : Bool
        request_stop(code)
        false
      end

      private def request_stop(code : String) : Nil
        should_signal = @lock.synchronize do
          next false if @terminal || @reaped
          if @stop_requested.nil?
            @stop_requested = code
            @failure_code = code
            true
          else
            false
          end
        end
        if should_signal
          begin
            @process.terminate(graceful: false)
          rescue
          end
        end
      end

      private def stopped_or_terminal? : Bool
        @lock.synchronize { @terminal || @stop_requested != nil }
      end

      private def push_event(event : Event) : Nil
        @lock.synchronize do
          return if @terminal || @stop_requested
          if @events.size < MAX_BUFFERED_EVENTS
            @events << event
          else
            @stop_requested ||= "event_queue_limit"
            @failure_code ||= "event_queue_limit"
          end
        end
      end

      private def finish_failure(code : String, status : Process::Status? = nil) : Nil
        actual, message = @lock.synchronize do
          actual = @stop_requested || @failure_code || code
          {actual, actual == @failure_code ? @failure_message : nil}
        end
        finish_terminal(Event.new(EventKind::Failed, failure_code: actual, failure_message: message))
      end

      private def finish_terminal(event : Event) : Nil
        @lock.synchronize do
          return if @terminal
          @terminal = true
          @failure_code = event.failure_code if event.kind.failed?
          @failure_message = event.failure_message if event.kind.failed?
          @terminal_event = event
          @pending_call_id = nil
        end
      end

      private def sanitize_output(text : String) : String
        String.build do |io|
          text.each_char do |char|
            if char == '\n' || char == '\t' || !EditorTools.control_char?(char)
              io << char
            else
              io << '�'
            end
          end
        end
      end

      private def valid_failure_message?(code : String, message : String) : Bool
        return false unless code.in?("script_error", "lua_compile_error")
        return false unless message.valid_encoding? && message.bytesize <= 512
        message.each_char.none? { |char| EditorTools.control_char?(char) }
      end
    end
  end
end
