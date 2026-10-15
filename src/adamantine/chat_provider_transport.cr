require "http/client"
require "json"
require "mutex"
require "set"
require "uri"
require "./chat_frontend"
require "./chat_provider_config"

module Adamantine
  module Chat
    class ProviderTransport < Transport
      alias KeyResolver = Proc(String, String?)

      MAX_KEY_BYTES              = 8 * 1024
      MAX_REQUEST_BODY_BYTES     = 256 * 1024
      MAX_SSE_EVENT_BYTES        = 64 * 1024
      MAX_STREAM_BYTES           = 1024 * 1024
      MAX_TOOL_CALLS             = 4
      MAX_TOOL_RESULT_BYTES      = 64 * 1024
      MAX_TOOL_ARGUMENTS         = 8 * 1024
      INVALID_PROVIDER_TOOL_NAME = "provider.invalid_tool"
      MAX_HTTP_ROUNDS            = 4
      MAX_ASSISTANT_ROUND_BYTES  = 64 * 1024
      TOTAL_TIMEOUT              = 120.seconds
      CONNECT_TIMEOUT            = 5.seconds
      IDLE_READ_TIMEOUT          = 15.seconds
      WRITE_TIMEOUT              = 10.seconds

      class ProviderFailure < Exception
      end

      private struct ToolCall
        getter index : Int32
        getter id : String
        getter name : String
        getter arguments : String

        def initialize(@index : Int32, @id : String, @name : String, @arguments : String)
        end
      end

      private class ToolFragment
        property id : String = ""
        property name : String = ""
        property arguments : String = ""
      end

      private class RoundState
        getter tools = {} of Int32 => ToolFragment
        getter finish_reason : String?
        setter finish_reason : String?
        property done : Bool = false
        @assistant_text = IO::Memory.new
        @assistant_text_bytes = 0

        def append_assistant_text(text : String) : Nil
          return if text.empty?
          if @assistant_text_bytes + text.bytesize > MAX_ASSISTANT_ROUND_BYTES
            raise ProviderFailure.new("Provider exceeded the assistant-text round limit.")
          end
          @assistant_text.write(text.to_slice)
          @assistant_text_bytes += text.bytesize
        end

        def assistant_text : String
          @assistant_text.to_s
        end

        def add_tool_chunk(chunk : JSON::Any) : Nil
          calls = chunk.as_a? || raise ProviderFailure.new("Provider returned an invalid tool-call stream.")
          raise ProviderFailure.new("Provider exceeded the per-round tool-call limit.") if calls.size > MAX_TOOL_CALLS
          seen = Set(Int32).new

          calls.each do |call_value|
            call = call_value.as_h? || raise ProviderFailure.new("Provider returned an invalid tool-call stream.")
            index_value = call["index"]?.try(&.as_i64?) || raise ProviderFailure.new("Provider returned an invalid tool-call index.")
            unless index_value.in?(0_i64...MAX_TOOL_CALLS.to_i64)
              raise ProviderFailure.new("Provider returned an out-of-range tool-call index.")
            end
            index = index_value.to_i32
            unless seen.add?(index)
              raise ProviderFailure.new("Provider repeated a tool-call index in one event.")
            end

            fragment = @tools[index]? || begin
              raise ProviderFailure.new("Provider exceeded the per-round tool-call limit.") if @tools.size >= MAX_TOOL_CALLS
              @tools[index] = ToolFragment.new
            end

            if id = call["id"]?
              fragment.id = fragment.id + (id.as_s? || raise ProviderFailure.new("Provider returned an invalid tool-call ID."))
              bound_fragment!(fragment.id, MAX_TOOL_ARGUMENTS)
            end
            if type = call["type"]?
              unless type.as_s? == "function"
                raise ProviderFailure.new("Provider returned an unsupported tool-call type.")
              end
            end
            if function_value = call["function"]?
              function = function_value.as_h? || raise ProviderFailure.new("Provider returned an invalid function call.")
              if name = function["name"]?
                fragment.name = fragment.name + (name.as_s? || raise ProviderFailure.new("Provider returned an invalid function name."))
                bound_fragment!(fragment.name, 128)
              end
              if arguments = function["arguments"]?
                fragment.arguments = fragment.arguments + (arguments.as_s? || raise ProviderFailure.new("Provider returned invalid function arguments."))
                bound_fragment!(fragment.arguments, MAX_TOOL_ARGUMENTS)
              end
            end
          end
        end

        def finalized_tools : Array(ToolCall)
          reason = @finish_reason
          raise ProviderFailure.new("Provider response omitted its finish marker.") unless reason
          if reason == "stop"
            raise ProviderFailure.new("Provider returned tools with an incompatible finish marker.") unless @tools.empty?
            return [] of ToolCall
          end
          raise ProviderFailure.new("Provider returned an unsupported finish marker.") unless reason == "tool_calls"
          raise ProviderFailure.new("Provider returned no tool calls.") if @tools.empty?

          indexes = @tools.keys.sort
          unless indexes == (0...indexes.size).to_a
            raise ProviderFailure.new("Provider returned non-contiguous tool-call indexes.")
          end

          @tools.map do |index, fragment|
            {index, fragment}
          end.sort_by(&.[0]).map do |index, fragment|
            if fragment.id.empty? || fragment.name.empty? || fragment.arguments.empty?
              raise ProviderFailure.new("Provider returned an incomplete tool call.")
            end
            unless fragment.arguments.valid_encoding?
              raise ProviderFailure.new("Provider returned invalid function arguments.")
            end
            {index, fragment.id, fragment.name, fragment.arguments}
          end.map { |entry| ToolCall.new(entry[0], entry[1], entry[2], entry[3]) }
        end

        private def bound_fragment!(value : String, max_bytes : Int32) : Nil
          if value.bytesize > max_bytes || !value.valid_encoding?
            raise ProviderFailure.new("Provider exceeded a tool-call field limit.")
          end
        end
      end

      private struct WireToolCall
        getter id : String
        getter name : String
        getter arguments : String

        def initialize(@id : String, @name : String, @arguments : String)
        end

        def to_json(json : JSON::Builder) : Nil
          json.object do
            json.field "id", @id
            json.field "type", "function"
            json.field "function" do
              json.object do
                json.field "name", @name
                json.field "arguments", @arguments
              end
            end
          end
        end
      end

      private struct WireMessage
        getter role : String
        getter content : String?
        getter tool_call_id : String?
        getter tool_calls : Array(WireToolCall)?

        def initialize(@role : String, @content : String? = nil,
                       @tool_call_id : String? = nil,
                       @tool_calls : Array(WireToolCall)? = nil)
        end

        def to_json(json : JSON::Builder) : Nil
          json.object do
            json.field "role", @role
            if content = @content
              json.field "content", content
            end
            if tool_call_id = @tool_call_id
              json.field "tool_call_id", tool_call_id
            end
            if tool_calls = @tool_calls
              json.field "tool_calls" do
                json.array do
                  tool_calls.each(&.to_json(json))
                end
              end
            end
          end
        end
      end

      private class ProviderHandle < Handle
        getter deadline : Time::Instant

        @lock = Mutex.new
        @cancelled = false
        @client : HTTP::Client?
        @pending_ids = Set(String).new
        @results = {} of String => String
        @used_ids = Set(String).new
        @tool_failure = false
        @wake = Channel(Nil).new(8)
        @deadline_stop = Channel(Nil).new(1)
        @deadline_done = Channel(Nil).new(1)
        @watchdog_lock = Mutex.new
        @watchdog_started = false
        @incoming_bytes = 0

        def initialize(@deadline : Time::Instant)
        end

        def start_deadline_watchdog : Nil
          started = @watchdog_lock.synchronize do
            if @watchdog_started
              false
            else
              @watchdog_started = true
              true
            end
          end
          raise ProviderFailure.new("Chat request watchdog was already started.") unless started

          remaining = @deadline - Time.instant
          spawn do
            begin
              if remaining.positive?
                select
                when @deadline_stop.receive
                when timeout(remaining)
                  expire_deadline
                end
              else
                expire_deadline
              end
            ensure
              @deadline_done.send(nil)
            end
          end
          nil
        end

        def cancel : Nil
          client = @lock.synchronize do
            @cancelled = true
            @client
          end
          safe_close(client)
          signal
        end

        def cancelled? : Bool
          @lock.synchronize { @cancelled }
        end

        def check_active : Nil
          raise ProviderFailure.new("Chat request was cancelled.") if cancelled?
          raise ProviderFailure.new("Chat request exceeded its 120-second limit.") unless (@deadline - Time.instant).positive?
        end

        def stop_deadline_watchdog : Nil
          started = @watchdog_lock.synchronize { @watchdog_started }
          return unless started
          select
          when @deadline_stop.send(nil)
          else
          end
          @deadline_done.receive
        end

        def attach_client(client : HTTP::Client) : Bool
          accepted = @lock.synchronize do
            if @cancelled
              false
            else
              @client = client
              true
            end
          end
          safe_close(client) unless accepted
          accepted
        end

        def detach_client(client : HTTP::Client) : Nil
          @lock.synchronize do
            @client = nil if @client.try(&.same?(client))
          end
          safe_close(client)
        end

        def add_incoming_bytes(bytes : Int32) : Nil
          @lock.synchronize do
            if @incoming_bytes + bytes > MAX_STREAM_BYTES
              raise ProviderFailure.new("Provider exceeded the total response-size limit.")
            end
            @incoming_bytes += bytes
          end
        end

        def incoming_bytes : Int32
          @lock.synchronize { @incoming_bytes }
        end

        def register_tools(calls : Array(ToolCall)) : Nil
          @lock.synchronize do
            raise ProviderFailure.new("Chat request was cancelled.") if @cancelled
            calls.each do |call|
              if @used_ids.includes?(call.id) || !@used_ids.add?(call.id)
                raise ProviderFailure.new("Provider repeated a tool-call ID.")
              end
            end
            @pending_ids = calls.map(&.id).to_set
            @results.clear
            @tool_failure = false
          end
        end

        def deliver_tool_result(call_id : String, result_json : String) : Nil
          if result_json.bytesize > MAX_TOOL_RESULT_BYTES || !result_json.valid_encoding?
            fail_tool_wait(call_id)
            return
          end
          parsed = EditorTools.parse_bounded_json(result_json)
          normalized = parsed.to_json
          if normalized.bytesize > MAX_TOOL_RESULT_BYTES
            fail_tool_wait(call_id)
            return
          end

          accepted = @lock.synchronize do
            if @cancelled || !@pending_ids.includes?(call_id) || @results.has_key?(call_id)
              false
            else
              @results[call_id] = normalized
              true
            end
          end
          signal if accepted
        rescue
          fail_tool_wait(call_id)
        end

        def await_tool_results(calls : Array(ToolCall)) : Hash(String, String)
          expected = calls.map(&.id).to_set
          loop do
            state = @lock.synchronize do
              if @cancelled
                :cancelled
              elsif @tool_failure
                :invalid
              elsif @results.size == expected.size && expected.all? { |id| @results.has_key?(id) }
                @results.dup
              else
                :waiting
              end
            end

            case state
            when Hash(String, String)
              return state
            when :cancelled
              raise ProviderFailure.new("Chat request was cancelled.")
            when :invalid
              raise ProviderFailure.new("Owner returned an invalid tool result.")
            else
              remaining = @deadline - Time.instant
              raise ProviderFailure.new("Chat request exceeded its 120-second limit.") unless remaining.positive?
              select
              when @wake.receive
              when timeout(remaining)
                raise ProviderFailure.new("Chat request exceeded its 120-second limit.")
              end
            end
          end
        end

        private def fail_tool_wait(call_id : String) : Nil
          changed = @lock.synchronize do
            if !@cancelled && @pending_ids.includes?(call_id) && !@results.has_key?(call_id)
              @tool_failure = true
              true
            else
              false
            end
          end
          signal if changed
        end

        private def signal : Nil
          select
          when @wake.send(nil)
          else
          end
        end

        private def expire_deadline : Nil
          client = @lock.synchronize { @client }
          safe_close(client)
          signal
        end

        private def safe_close(client : HTTP::Client?) : Nil
          client.try(&.close)
        rescue
          nil
        end
      end

      @config : ProviderConfig
      @key_resolver : KeyResolver
      @lock = Mutex.new
      @active_handle : ProviderHandle?

      def initialize(@config : ProviderConfig,
                     key_resolver : KeyResolver? = nil)
        @key_resolver = key_resolver || ->(name : String) { ENV[name]? }
      end

      def external? : Bool
        true
      end

      def available? : Bool
        @config.enabled && @config.validation_error.nil?
      end

      protected def total_timeout : Time::Span
        TOTAL_TIMEOUT
      end

      def start(request : Request, on_event : Proc(Event, Nil)) : Handle
        unless available?
          raise ProviderFailure.new("Chat provider is disabled or its settings are invalid.")
        end

        handle : ProviderHandle? = nil
        @lock.synchronize do
          raise ProviderFailure.new("A previous chat request is still shutting down.") if @active_handle
          handle = ProviderHandle.new(Time.instant + total_timeout)
          @active_handle = handle
        end
        active_handle = handle.not_nil!

        begin
          active_handle.start_deadline_watchdog
          key = resolve_key
          spawn(name: "adamantine-chat-provider") do
            begin
              execute_turn(request, key, active_handle, on_event)
            rescue failure : ProviderFailure
              emit_failure(active_handle, on_event, failure.message || "Chat provider request failed.")
            rescue
              emit_failure(active_handle, on_event, "Chat provider request failed; check the configured endpoint and connection.")
            ensure
              active_handle.stop_deadline_watchdog
              release(active_handle)
            end
          end
          active_handle
        rescue failure : ProviderFailure
          active_handle.stop_deadline_watchdog
          release(active_handle)
          raise failure
        rescue
          active_handle.stop_deadline_watchdog
          release(active_handle)
          raise ProviderFailure.new("Configured chat credentials could not be loaded.")
        end
      end

      private def resolve_key : String?
        name = @config.key_env
        return nil if name.empty?

        key = @key_resolver.call(name)
        unless key && !key.empty? && key.bytesize <= MAX_KEY_BYTES && key.valid_encoding? &&
               key.each_byte.all? { |byte| byte >= 0x21 && byte <= 0x7e }
          raise ProviderFailure.new("Configured API key is missing or invalid; draft retained.")
        end
        key.dup
      rescue failure : ProviderFailure
        raise failure
      rescue
        raise ProviderFailure.new("Configured chat credentials could not be loaded.")
      end

      private def release(handle : ProviderHandle) : Nil
        @lock.synchronize do
          @active_handle = nil if @active_handle.try(&.same?(handle))
        end
      end

      private def emit_failure(handle : ProviderHandle, callback : Proc(Event, Nil), message : String) : Nil
        return if handle.cancelled?
        callback.call(Event.failure(message))
      rescue
        nil
      end

      private def emit(handle : ProviderHandle, callback : Proc(Event, Nil), event : Event) : Nil
        raise ProviderFailure.new("Chat request was cancelled.") if handle.cancelled?
        raise ProviderFailure.new("Chat request exceeded its 120-second limit.") unless (handle.deadline - Time.instant).positive?
        callback.call(event)
      rescue failure : ProviderFailure
        raise failure
      rescue
        raise ProviderFailure.new("Chat event delivery failed; request cancelled.")
      end

      private def execute_turn(request : Request, key : String?, handle : ProviderHandle,
                               callback : Proc(Event, Nil)) : Nil
        messages = [] of WireMessage
        request.history.each do |message|
          role = message.role.user? ? "user" : "assistant"
          messages << WireMessage.new(role, message.text)
        end
        messages << WireMessage.new("user", user_content(request))

        round = 1
        loop do
          raise ProviderFailure.new("Chat request was cancelled.") if handle.cancelled?
          raise ProviderFailure.new("Chat request exceeded its 120-second limit.") unless (handle.deadline - Time.instant).positive?

          body = request_body(request, messages)
          response_round = send_round(body, key, handle, callback, request.context)
          if response_round.finish_reason == "stop"
            emit(handle, callback, Event.complete)
            return
          end

          calls = response_round.calls
          unless (request.context.mode.buffer_tools? || request.context.mode.buffer_proposals?) && !calls.empty?
            raise ProviderFailure.new("Provider requested a tool outside the approved context.")
          end
          if round >= MAX_HTTP_ROUNDS
            raise ProviderFailure.new("Provider exceeded the four-request turn limit.")
          end
          handle.register_tools(calls)
          calls.each do |call|
            envelope = tool_envelope(call, request.context)
            emit(handle, callback, Event.tool_request(call.id, envelope))
          end
          results = handle.await_tool_results(calls)

          messages << WireMessage.new("assistant", response_round.assistant_text, nil,
            calls.map { |call| WireToolCall.new(call.id, call.name, call.arguments) })
          calls.each do |call|
            result = results[call.id]?
            raise ProviderFailure.new("Owner omitted a tool result.") unless result
            messages << WireMessage.new("tool", result, call.id)
          end
          round += 1
        end
      end

      private def user_content(request : Request) : String
        String.build do |io|
          io << "User request:\n" << request.text
          context = request.context
          case context.mode
          when ContextMode::None
            # No implicit context is sent.
          when ContextMode::Selection, ContextMode::ActiveBuffer
            io << "\n\nUser-selected source data (" << context.label << "):\n" << context.text
          when ContextMode::BufferTools
            io << "\n\nUser-selected source data (approved read scope): buffer ID "
            io << context.buffer_id.not_nil! << ", revision " << context.revision.not_nil!
          when ContextMode::BufferProposals
            io << "\n\nUser-selected source data (" << context.label << "): buffer ID "
            io << context.buffer_id.not_nil! << ", revision " << context.revision.not_nil!
          end
          if grant = context.lua_script_grant
            io << "\n\nApproved named Lua script for this request: ID " << grant.id
            io << ", name " << grant.name << ", SHA-256 " << grant.digest
            io << ", effective capabilities "
            io << grant.effective_capabilities.map(&.wire_name).join(", ")
            io << ". The run_approved_lua_script tool can be called once; its arguments must be empty."
          end
        end
      end

      private def request_body(request : Request, messages : Array(WireMessage)) : String
        String.build do |io|
          JSON.build(io) do |json|
            json.object do
              json.field "model", @config.model
              json.field "max_completion_tokens", @config.max_completion_tokens
              if effort = @config.reasoning_effort
                json.field "reasoning_effort", effort
              end
              json.field "n", 1
              json.field "store", false
              json.field "stream", true
              json.field "messages" do
                json.array do
                  messages.each(&.to_json(json))
                end
              end
              if request.context.mode.buffer_tools? || request.context.mode.buffer_proposals?
                json.field "tools" do
                  json.array do
                    write_read_buffer_tool(json, request.context)
                    write_propose_edits_tool(json, request.context) if request.context.mode.buffer_proposals?
                    write_approved_lua_script_tool(json, request.context) if request.context.lua_script_grant
                  end
                end
                json.field "tool_choice", "auto"
              end
            end
          end
        end.tap do |body|
          if body.bytesize > MAX_REQUEST_BODY_BYTES
            raise ProviderFailure.new("Outgoing chat request exceeded the 256 KiB limit.")
          end
        end
      end

      private def write_read_buffer_tool(json : JSON::Builder, context : SubmissionContext) : Nil
        json.object do
          json.field "type", "function"
          json.field "function" do
            json.object do
              json.field "name", "editor_read_buffer"
              json.field "description", "Read only the user-selected active buffer and revision. The owner rechecks this exact scope."
              json.field "parameters" do
                json.object do
                  json.field "type", "object"
                  json.field "properties" do
                    json.object do
                      json.field "buffer_id" do
                        json.object do
                          json.field "type", "string"
                          json.field "description", "Approved buffer ID: #{context.buffer_id.not_nil!}"
                        end
                      end
                      json.field "revision" do
                        json.object do
                          json.field "type", "string"
                          json.field "description", "Approved revision: #{context.revision.not_nil!}"
                        end
                      end
                      json.field "start_line" do
                        json.object do
                          json.field "type", "integer"
                          json.field "minimum", 1
                        end
                      end
                      json.field "line_count" do
                        json.object do
                          json.field "type", "integer"
                          json.field "minimum", 1
                          json.field "maximum", 64
                        end
                      end
                      json.field "start_column" do
                        json.object do
                          json.field "type", "integer"
                          json.field "minimum", 0
                        end
                      end
                      json.field "max_columns" do
                        json.object do
                          json.field "type", "integer"
                          json.field "minimum", 1
                          json.field "maximum", 1024
                        end
                      end
                    end
                  end
                  json.field "required" do
                    json.array do
                      {"buffer_id", "revision", "start_line", "line_count", "start_column", "max_columns"}.each { |key| json.string(key) }
                    end
                  end
                  json.field "additionalProperties", false
                end
              end
            end
          end
        end
      end

      private def write_propose_edits_tool(json : JSON::Builder, context : SubmissionContext) : Nil
        json.object do
          json.field "type", "function"
          json.field "function" do
            json.object do
              json.field "name", "editor_propose_edits"
              json.field "description", "Propose a bounded edit batch for explicit manual review in the user-selected buffer. The host validates the exact buffer revision; edits are never applied or saved automatically."
              json.field "parameters" do
                json.object do
                  json.field "type", "object"
                  json.field "properties" do
                    json.object do
                      json.field "buffer_id" do
                        json.object do
                          json.field "type", "string"
                          json.field "description", "Approved buffer ID: #{context.buffer_id.not_nil!}"
                        end
                      end
                      json.field "revision" do
                        json.object do
                          json.field "type", "string"
                          json.field "description", "Approved revision: #{context.revision.not_nil!}"
                        end
                      end
                      json.field "edits" do
                        json.object do
                          json.field "type", "array"
                          json.field "minItems", 1
                          json.field "maxItems", EditorTools::MAX_PROPOSED_EDITS
                          json.field "description", "One to 32 non-overlapping edits; lines are one-based and columns are zero-based Unicode codepoints."
                          json.field "items" do
                            json.object do
                              json.field "type", "object"
                              json.field "properties" do
                                json.object do
                                  {"start_line", "end_line"}.each do |field|
                                    json.field field do
                                      json.object do
                                        json.field "type", "integer"
                                        json.field "minimum", 1
                                        json.field "maximum", Int32::MAX
                                      end
                                    end
                                  end
                                  {"start_column", "end_column"}.each do |field|
                                    json.field field do
                                      json.object do
                                        json.field "type", "integer"
                                        json.field "minimum", 0
                                        json.field "maximum", Int32::MAX
                                      end
                                    end
                                  end
                                  json.field "new_text" do
                                    json.object do
                                      json.field "type", "string"
                                      json.field "maxLength", EditorTools::MAX_REQUEST_BYTES
                                      json.field "description", "Replacement text; at most 8 KiB UTF-8 bytes, may be empty or contain newlines."
                                    end
                                  end
                                end
                              end
                              json.field "required" do
                                json.array do
                                  {"start_line", "start_column", "end_line", "end_column", "new_text"}.each { |field| json.string(field) }
                                end
                              end
                              json.field "additionalProperties", false
                            end
                          end
                        end
                      end
                    end
                  end
                  json.field "required" do
                    json.array do
                      {"buffer_id", "revision", "edits"}.each { |field| json.string(field) }
                    end
                  end
                  json.field "additionalProperties", false
                end
              end
            end
          end
        end
      end

      private def write_approved_lua_script_tool(json : JSON::Builder, context : SubmissionContext) : Nil
        grant = context.lua_script_grant.not_nil!
        description = "Run only the named script approved for this Send. ID: #{grant.id}; name: #{grant.name}; SHA-256: #{grant.digest}; effective capabilities: #{grant.effective_capabilities.map(&.wire_name).join(", ")}. No arguments are accepted."
        json.object do
          json.field "type", "function"
          json.field "function" do
            json.object do
              json.field "name", "run_approved_lua_script"
              json.field "description", description
              json.field "parameters" do
                json.object do
                  json.field "type", "object"
                  json.field "properties" do
                    json.object { }
                  end
                  json.field "required" do
                    json.array { }
                  end
                  json.field "additionalProperties", false
                end
              end
            end
          end
        end
      end

      private struct RoundResponse
        getter finish_reason : String
        getter calls : Array(ToolCall)
        getter assistant_text : String

        def initialize(@finish_reason : String, @calls : Array(ToolCall), @assistant_text : String)
        end
      end

      private def send_round(body : String, key : String?, handle : ProviderHandle,
                             callback : Proc(Event, Nil), context : SubmissionContext) : RoundResponse
        uri = URI.parse(@config.endpoint)
        tls = uri.scheme == "https"
        client = HTTP::Client.new(uri.hostname.not_nil!, uri.port, tls: tls)
        client.compress = false
        timeout = bounded_timeout(handle, CONNECT_TIMEOUT)
        client.connect_timeout = timeout
        client.dns_timeout = timeout
        client.read_timeout = bounded_timeout(handle, IDLE_READ_TIMEOUT)
        client.write_timeout = bounded_timeout(handle, WRITE_TIMEOUT)
        unless handle.attach_client(client)
          raise ProviderFailure.new("Chat request was cancelled.")
        end

        headers = HTTP::Headers.new
        headers["Host"] = uri.authority.not_nil!
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "text/event-stream"
        headers["Accept-Encoding"] = "identity"
        headers["Connection"] = "close"
        headers["Authorization"] = "Bearer #{key}" if key
        request = HTTP::Request.new("POST", uri.request_target, headers, body)

        response_value : RoundResponse? = nil
        client.exec(request) do |response|
          begin
            unless response.status.success?
              raise ProviderFailure.new("Provider returned an unsuccessful status; response details were withheld.")
            end
            content_type = response.headers["Content-Type"]?.try(&.split(';', 2)[0].strip.downcase)
            unless content_type == "text/event-stream"
              raise ProviderFailure.new("Provider response was not a text event stream.")
            end
            if content_length = response.headers["Content-Length"]?
              length = content_length.to_i?
              unless length && length >= 0 && length <= MAX_STREAM_BYTES - handle.incoming_bytes
                raise ProviderFailure.new("Provider exceeded the total response-size limit.")
              end
            end
            response_value = read_round(response.body_io, handle, callback, context)
          ensure
            # Close the client before leaving the response callback, including
            # on early [DONE], so peer work cannot outlive this round.
            client.close
          end
        end
        response_value || raise ProviderFailure.new("Provider response was empty.")
      rescue failure : ProviderFailure
        raise failure
      rescue
        # Distinguish an absolute-deadline or cancellation close from an
        # unrelated connection failure before returning a static diagnostic.
        handle.check_active
        raise ProviderFailure.new("Chat provider connection failed; response details were withheld.")
      ensure
        handle.detach_client(client) if client
      end

      private def bounded_timeout(handle : ProviderHandle, maximum : Time::Span) : Time::Span
        remaining = handle.deadline - Time.instant
        raise ProviderFailure.new("Chat request exceeded its 120-second limit.") unless remaining.positive?
        remaining < maximum ? remaining : maximum
      end

      private def read_round(io : IO, handle : ProviderHandle,
                             callback : Proc(Event, Nil), context : SubmissionContext) : RoundResponse
        state = RoundState.new
        line_buffer = Bytes.new(MAX_SSE_EVENT_BYTES)
        line_size = 0
        event_data = IO::Memory.new
        event_data_bytes = 0
        event_has_data = false
        frame_bytes = 0
        chunk = Bytes.new(4096)

        loop do
          handle.check_active
          remaining = MAX_STREAM_BYTES - handle.incoming_bytes
          read_size = remaining > 0 ? {chunk.size, remaining}.min : 1
          count = io.read(chunk[0, read_size])
          handle.check_active
          break if count == 0
          raise ProviderFailure.new("Provider exceeded the total response-size limit.") if remaining == 0
          handle.add_incoming_bytes(count)

          count.times do |index|
            byte = chunk[index]
            frame_bytes += 1
            if frame_bytes > MAX_SSE_EVENT_BYTES
              raise ProviderFailure.new("Provider exceeded the 64 KiB event-size limit.")
            end
            if byte == '\n'.ord
              line_size -= 1 if line_size > 0 && line_buffer[line_size - 1] == '\r'.ord
              line = String.new(line_buffer[0, line_size])
              line_size = 0
              if line.empty?
                if event_has_data
                  raise ProviderFailure.new("Provider sent data after its completion marker.") if state.done
                  process_sse_data(event_data.to_s, state, callback, handle, context)
                  if state.done
                    return finalized_round_response(state)
                  end
                end
                event_data.clear
                event_data_bytes = 0
                event_has_data = false
                frame_bytes = 0
              else
                unless line.valid_encoding?
                  raise ProviderFailure.new("Provider event contained invalid UTF-8.")
                end
                if line.starts_with?(':')
                  # SSE comments carry no model data.
                else
                  field, value = sse_field(line)
                  case field
                  when "data"
                    if event_has_data
                      event_data << '\n'
                      event_data_bytes += 1
                    end
                    event_data.write(value.to_slice)
                    event_data_bytes += value.bytesize
                    event_has_data = true
                    if event_data_bytes > MAX_SSE_EVENT_BYTES
                      raise ProviderFailure.new("Provider exceeded the 64 KiB event-size limit.")
                    end
                  when "event"
                    # Event names do not change the JSON contract; keep bounded and ignore.
                  when "id", "retry"
                    raise ProviderFailure.new("Provider returned unsupported event metadata.")
                  else
                    raise ProviderFailure.new("Provider returned an unsupported event field.")
                  end
                end
              end
            else
              if line_size >= line_buffer.size
                raise ProviderFailure.new("Provider exceeded the 64 KiB event-size limit.")
              end
              line_buffer[line_size] = byte
              line_size += 1
            end
          end
        end

        unless line_size == 0 && !event_has_data && state.done && state.finish_reason
          raise ProviderFailure.new("Provider stream ended without a complete finish marker.")
        end
        finalized_round_response(state)
      end

      private def finalized_round_response(state : RoundState) : RoundResponse
        finish = state.finish_reason.not_nil!
        case finish
        when "length"
          raise ProviderFailure.new("Provider reached the configured output-token limit; the partial reply is retained. Adjust the token limit or continue manually.")
        when "content_filter"
          raise ProviderFailure.new("Provider filtered the reply; no tool request was executed.")
        end
        calls = state.finalized_tools
        if finish == "stop" && !calls.empty?
          raise ProviderFailure.new("Provider returned tools with an incompatible finish marker.")
        end
        RoundResponse.new(finish, calls, state.assistant_text)
      end

      private def sse_field(line : String) : Tuple(String, String)
        colon = line.index(':')
        return {line, ""} unless colon
        field = line.byte_slice(0, colon)
        value = line.byte_slice(colon + 1, line.bytesize - colon - 1)
        value = value.byte_slice(1, value.bytesize - 1) if value.starts_with?(' ')
        {field, value}
      end

      private def process_sse_data(data : String, state : RoundState,
                                   callback : Proc(Event, Nil), handle : ProviderHandle,
                                   context : SubmissionContext) : Nil
        raise ProviderFailure.new("Provider event contained invalid UTF-8.") unless data.valid_encoding?
        if data == "[DONE]"
          unless state.finish_reason
            raise ProviderFailure.new("Provider stream ended without a finish marker.")
          end
          state.done = true
          return
        end
        raise ProviderFailure.new("Provider sent data after its completion marker.") if state.done

        event = begin
          EditorTools.parse_bounded_json(data)
        rescue
          raise ProviderFailure.new("Provider returned malformed bounded JSON.")
        end
        payload = event.as_h? || raise ProviderFailure.new("Provider returned an invalid completion event.")
        choices = payload["choices"]?.try(&.as_a?) || raise ProviderFailure.new("Provider returned an invalid choices field.")
        unless choices.size == 1
          raise ProviderFailure.new("Provider response must contain exactly one choice.")
        end
        choice = choices[0].as_h? || raise ProviderFailure.new("Provider returned an invalid choice.")
        index = choice["index"]?.try(&.as_i64?)
        raise ProviderFailure.new("Provider returned an invalid choice index.") unless index == 0
        delta = choice["delta"]?.try(&.as_h?) || raise ProviderFailure.new("Provider returned an invalid delta.")
        unless choice.has_key?("finish_reason")
          raise ProviderFailure.new("Provider choice omitted its finish marker.")
        end

        if state.finish_reason
          raise ProviderFailure.new("Provider sent data after its finish marker.")
        end
        if role = delta["role"]?
          raise ProviderFailure.new("Provider returned a non-assistant role.") unless role.as_s? == "assistant"
        end
        if content = delta["content"]?
          unless content.raw.nil? || content.as_s?
            raise ProviderFailure.new("Provider returned invalid assistant text.")
          end
          if text = content.as_s?
            state.append_assistant_text(text)
            emit(handle, callback, Event.delta(text)) unless text.empty?
          end
        end
        if tool_calls = delta["tool_calls"]?
          raise ProviderFailure.new("Tools are disabled for this context.") unless context.mode.buffer_tools? || context.mode.buffer_proposals?
          state.add_tool_chunk(tool_calls)
        end

        finish_value = choice["finish_reason"]?
        if finish = finish_value.try(&.as_s?)
          unless finish.in?("stop", "tool_calls", "length", "content_filter")
            raise ProviderFailure.new("Provider stopped before a complete response.")
          end
          state.finish_reason = finish
        elsif finish_value && !finish_value.raw.nil?
          raise ProviderFailure.new("Provider returned an invalid finish marker.")
        end
      end

      private def tool_envelope(call : ToolCall, context : SubmissionContext) : String
        tool_name = case call.name
                    when "editor_read_buffer"
                      "editor.read_buffer"
                    when "editor_propose_edits"
                      "editor.propose_edits"
                    when "run_approved_lua_script"
                      "lua.run_script"
                    else
                      INVALID_PROVIDER_TOOL_NAME
                    end
        arguments = begin
          EditorTools.parse_bounded_json(call.arguments)
        rescue
          return "{"
        end
        if tool_name == "lua.run_script"
          if arguments.as_h? == ({} of String => JSON::Any)
            script_id = context.lua_script_grant.try(&.id) || ""
            arguments = JSON.parse({"script_id" => script_id}.to_json)
          else
            # The public function is no-argument. Use a stable invalid key so
            # Session charges and rejects any model-supplied argument payload.
            arguments = JSON.parse({"unexpected_provider_arguments" => true}.to_json)
          end
        end

        String.build do |io|
          JSON.build(io) do |json|
            json.object do
              json.field "id", call.id
              json.field "name", tool_name
              json.field "arguments", arguments
            end
          end
        end
      end
    end
  end
end
