require "json"
require "set"

module Adamantine
  module EditorTools
    MAX_REQUEST_BYTES        = 8 * 1024
    MAX_JSON_DEPTH           = 16
    MAX_CALLS                = 64
    MAX_RESPONSE_BYTES       = 64 * 1024
    MAX_TOTAL_RESPONSE_BYTES = 512 * 1024
    MAX_DELEGATION_DEPTH     =    4
    MAX_CHILD_SESSIONS       =   16
    MAX_DEFINITION_RESPONSE  = 2048
    MAX_SAFE_DATA_BYTES      = MAX_RESPONSE_BYTES - MAX_DEFINITION_RESPONSE

    enum Consumer
      Chat
      Lua
      Interactive
    end

    enum Capability
      ReadEditor
      ReadDebugger
      Navigate

      def wire_name : String
        case self
        when ReadEditor   then "read_editor"
        when ReadDebugger then "read_debugger"
        when Navigate     then "navigate"
        else
          raise "invalid editor tool capability"
        end
      end
    end

    enum Status
      Ok
      InvalidRequest
      Denied
      Stale
      NotFound
      Unavailable
      LimitExceeded
      Busy
      DuplicateCall

      def wire_name : String
        case self
        when Ok             then "ok"
        when InvalidRequest then "invalid_request"
        when Denied         then "denied"
        when Stale          then "stale"
        when NotFound       then "not_found"
        when Unavailable    then "unavailable"
        when LimitExceeded  then "limit_exceeded"
        when Busy           then "busy"
        when DuplicateCall  then "duplicate_call"
        else
          raise "invalid editor tool status"
        end
      end
    end

    class Failure < Exception
      getter status : Status

      def initialize(@status : Status, message : String)
        super(message)
      end
    end

    struct Context
      @project_root : String
      @epoch : String

      def initialize(project_root : String, epoch : String)
        @project_root = project_root.dup
        @epoch = epoch.dup
      end

      def project_root : String
        @project_root.dup
      end

      def epoch : String
        @epoch.dup
      end

      def ==(other : Context) : Bool
        @project_root == other.@project_root && @epoch == other.@epoch
      end

      def hash(hasher)
        @project_root.hash(hasher)
        @epoch.hash(hasher)
      end
    end

    struct ListBuffersRequest
      getter offset : Int32
      getter limit : Int32

      def initialize(@offset : Int32 = 0, @limit : Int32 = 32)
      end
    end

    struct ReadBufferRequest
      getter buffer_id : String
      getter revision : String
      getter start_line : Int32
      getter line_count : Int32
      getter start_column : Int32
      getter max_columns : Int32

      def initialize(@buffer_id : String, @revision : String,
                     @start_line : Int32 = 1, @line_count : Int32 = 16,
                     @start_column : Int32 = 0, @max_columns : Int32 = 512)
      end
    end

    struct FindFilesRequest
      getter query : String
      getter limit : Int32

      def initialize(@query : String, @limit : Int32 = 32)
      end
    end

    struct OpenFileRequest
      getter path : String

      def initialize(@path : String)
      end
    end

    struct FocusBufferRequest
      getter buffer_id : String
      getter revision : String

      def initialize(@buffer_id : String, @revision : String)
      end
    end

    struct DebugSnapshotRequest
      getter limit : Int32

      def initialize(@limit : Int32 = 32)
      end
    end

    alias Request = ListBuffersRequest | ReadBufferRequest | FindFilesRequest |
                    OpenFileRequest | FocusBufferRequest | DebugSnapshotRequest

    # A backend receives only the captured project context and a revocable
    # lifetime predicate, never the Session or its capability grant.
    class ExecutionPermit
      @context : Context
      @active_check : Proc(Bool)

      def initialize(context : Context, @active_check : Proc(Bool))
        @context = context
      end

      def context : Context
        @context
      end

      def active? : Bool
        @active_check.call
      rescue
        false
      end
    end

    abstract class Backend
      abstract def context : Context
      abstract def execute(request : Request, permit : ExecutionPermit) : JSON::Any
    end

    # The limits constructor permits tests and trusted in-process hosts to
    # tighten, but never widen, the hard protocol ceilings.
    struct Limits
      getter max_calls : Int32
      getter max_response_bytes : Int32
      getter max_total_response_bytes : Int32
      getter max_children : Int32
      getter max_depth : Int32

      def initialize(@max_calls : Int32 = MAX_CALLS,
                     @max_response_bytes : Int32 = MAX_RESPONSE_BYTES,
                     @max_total_response_bytes : Int32 = MAX_TOTAL_RESPONSE_BYTES,
                     @max_children : Int32 = MAX_CHILD_SESSIONS,
                     @max_depth : Int32 = MAX_DELEGATION_DEPTH)
        minimum_terminal = Result.terminal.encoded_bytes
        unless @max_calls.in?(1..MAX_CALLS) &&
               @max_response_bytes.in?(minimum_terminal..MAX_RESPONSE_BYTES) &&
               @max_total_response_bytes.in?(minimum_terminal..MAX_TOTAL_RESPONSE_BYTES) &&
               @max_children.in?(0..MAX_CHILD_SESSIONS) &&
               @max_depth.in?(0..MAX_DELEGATION_DEPTH)
          raise ArgumentError.new("editor tool limits must be positive and within hard ceilings")
        end
      end
    end

    class ToolDefinition
      @name : String
      @description : String
      @capability : Capability
      @parameters_json : String

      def initialize(name : String, description : String, @capability : Capability,
                     parameters_json : String)
        @name = name.dup
        @description = description.dup
        @parameters_json = parameters_json.dup
      end

      def name : String
        @name.dup
      end

      def description : String
        @description.dup
      end

      def capability : Capability
        @capability
      end

      def parameters : JSON::Any
        JSON.parse(@parameters_json)
      end

      def to_json : String
        {
          "name"        => @name,
          "description" => @description,
          "capability"  => @capability.wire_name,
          "parameters"  => parameters,
        }.to_json
      end
    end

    private enum ToolKind
      ListBuffers
      ReadBuffer
      FindFiles
      OpenFile
      FocusBuffer
      DebugSnapshot
    end

    private struct ToolCatalogEntry
      getter name : String
      getter description : String
      getter capability : Capability
      getter kind : ToolKind
      getter parameters_json : String

      def initialize(@name : String, @description : String,
                     @capability : Capability, @kind : ToolKind,
                     @parameters_json : String)
      end

      def definition : ToolDefinition
        ToolDefinition.new(@name, @description, @capability, @parameters_json)
      end
    end

    private TOOL_CATALOG = [
      ToolCatalogEntry.new(
        "editor.list_buffers",
        "List a bounded page of live editor buffers without document text.",
        Capability::ReadEditor,
        ToolKind::ListBuffers,
        %({"type":"object","properties":{"offset":{"type":"integer","minimum":0,"maximum":2147483647,"default":0},"limit":{"type":"integer","minimum":1,"maximum":64,"default":32}},"additionalProperties":false})
      ),
      ToolCatalogEntry.new(
        "editor.read_buffer",
        "Read a bounded fragment from a live buffer revision.",
        Capability::ReadEditor,
        ToolKind::ReadBuffer,
        %({"type":"object","properties":{"buffer_id":{"type":"string","minLength":1,"maxLength":128},"revision":{"type":"string","minLength":1,"maxLength":128},"start_line":{"type":"integer","minimum":1,"maximum":2147483647,"default":1},"line_count":{"type":"integer","minimum":1,"maximum":64,"default":16},"start_column":{"type":"integer","minimum":0,"maximum":2147483647,"default":0},"max_columns":{"type":"integer","minimum":1,"maximum":1024,"default":512}},"required":["buffer_id","revision"],"additionalProperties":false})
      ),
      ToolCatalogEntry.new(
        "editor.find_files",
        "Find in-project paths using a bounded query and result page.",
        Capability::ReadEditor,
        ToolKind::FindFiles,
        %({"type":"object","properties":{"query":{"type":"string","maxLength":256},"limit":{"type":"integer","minimum":1,"maximum":64,"default":32}},"required":["query"],"additionalProperties":false})
      ),
      ToolCatalogEntry.new(
        "editor.open_file",
        "Open one guarded in-project file in the existing editor.",
        Capability::Navigate,
        ToolKind::OpenFile,
        %({"type":"object","properties":{"path":{"type":"string","minLength":1,"maxLength":4096}},"required":["path"],"additionalProperties":false})
      ),
      ToolCatalogEntry.new(
        "editor.focus_buffer",
        "Focus an existing live editor buffer at its current revision.",
        Capability::Navigate,
        ToolKind::FocusBuffer,
        %({"type":"object","properties":{"buffer_id":{"type":"string","minLength":1,"maxLength":128},"revision":{"type":"string","minLength":1,"maxLength":128}},"required":["buffer_id","revision"],"additionalProperties":false})
      ),
      ToolCatalogEntry.new(
        "debug.snapshot",
        "Read bounded retained debugger state without polling or target evaluation.",
        Capability::ReadDebugger,
        ToolKind::DebugSnapshot,
        %({"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":64,"default":32}},"additionalProperties":false})
      ),
    ]

    class Result
      @id : String?
      @status : Status
      @data_json : String?
      @message : String?
      @wire_json : String

      def initialize(id : String?, status : Status, data : JSON::Any? = nil,
                     message : String? = nil)
        @id = EditorTools.bounded_result_id(id)
        @status = status
        @data_json = nil
        @message = safe_message(message)

        if data
          begin
            @data_json = EditorTools.encode_bounded_json(data, MAX_SAFE_DATA_BYTES)
          rescue Failure
            @status = Status::LimitExceeded
            @message = "tool result exceeds response limit"
          rescue
            @status = Status::Unavailable
            @message = "tool result could not be serialized"
          end
        end

        @wire_json = serialize(@id, @status, @data_json, @message)
        if @wire_json.bytesize > MAX_RESPONSE_BYTES
          @status = Status::LimitExceeded
          @data_json = nil
          @message = "tool result exceeds response limit"
          @wire_json = serialize(@id, @status, nil, @message)
        end
      end

      def self.terminal : Result
        new(nil, Status::LimitExceeded, nil, "session response budget exhausted")
      end

      def id : String?
        @id.try(&.dup)
      end

      def status : Status
        @status
      end

      def data : JSON::Any?
        @data_json.try { |json| JSON.parse(json) }
      end

      def message : String?
        @message.try(&.dup)
      end

      def ok? : Bool
        @status == Status::Ok
      end

      def encoded_bytes : Int32
        @wire_json.bytesize
      end

      # A copy prevents callers from mutating the byte sequence used by the
      # shared budget or changing later serialization.
      def to_json : String
        @wire_json.dup
      end

      private def serialize(id : String?, status : Status,
                            data_json : String?, message : String?) : String
        fields = {
          "id"      => JSON::Any.new(id),
          "status"  => JSON::Any.new(status.wire_name),
          "data"    => data_json ? JSON.parse(data_json) : JSON::Any.new(nil),
          "message" => JSON::Any.new(message),
        } of String => JSON::Any
        JSON::Any.new(fields).to_json
      end

      private def safe_message(message : String?) : String?
        return unless message
        return "tool failure" unless message.valid_encoding?

        String.build do |io|
          count = 0
          message.each_char do |char|
            break if count >= 256
            if EditorTools.control_char?(char)
              io << ' '
            else
              io << char
            end
            count += 1
          end
        end
      end
    end

    private class SharedBudget
      getter limits : Limits

      @calls = 0
      @response_bytes = 0
      @children = 0
      @call_ids = Set(String).new
      @exhausted = false
      @terminal : Result?
      @terminal_bytes : Int32

      def initialize(@limits : Limits)
        @terminal_bytes = Result.terminal.encoded_bytes
      end

      def begin_call : Result?
        return terminal_result if @exhausted
        if @calls >= @limits.max_calls
          return exhaust
        end
        @calls += 1
        nil
      end

      def register_call_id(id : String) : Nil
        if @call_ids.includes?(id)
          raise Failure.new(Status::DuplicateCall, "call id has already been used")
        end
        @call_ids << id.dup
      end

      def finish(result : Result) : Result
        return terminal_result if @exhausted

        bytes = result.encoded_bytes
        if bytes > @limits.max_response_bytes ||
           @response_bytes + bytes + @terminal_bytes > @limits.max_total_response_bytes
          return exhaust
        end

        @response_bytes += bytes
        result
      end

      def reserve_child! : Nil
        if @children >= @limits.max_children
          raise Failure.new(Status::LimitExceeded, "delegation child limit reached")
        end
        @children += 1
      end

      def exhausted? : Bool
        @exhausted
      end

      private def exhaust : Result
        @exhausted = true
        unless @terminal
          @terminal = Result.terminal
          @response_bytes += @terminal.not_nil!.encoded_bytes
        end
        @terminal.not_nil!
      end

      private def terminal_result : Result
        @terminal ||= Result.terminal
      end
    end

    class Session
      @backend : Backend
      @context : Context
      @capabilities : Set(Capability)
      @budget : SharedBudget
      @parent : Session?
      @depth : Int32
      @closed_local = false

      protected def initialize(@backend : Backend, @context : Context,
                               capabilities : Array(Capability), @budget : SharedBudget,
                               @parent : Session?, @depth : Int32,
                               @consumer : Consumer)
        @capabilities = capabilities.to_set
      end

      def invoke_json(raw : String) : Result
        if terminal = @budget.begin_call
          return terminal
        end

        id : String? = nil
        result = begin
          raise Failure.new(Status::Denied, "tool session is closed") if closed?
          raise Failure.new(Status::LimitExceeded, "request exceeds byte limit") if raw.bytesize > MAX_REQUEST_BYTES
          raise Failure.new(Status::InvalidRequest, "request must be valid UTF-8") unless raw.valid_encoding?

          parsed = EditorTools.parse_bounded_json(raw)
          envelope = parsed.as_h? || raise Failure.new(Status::InvalidRequest, "request must be an object")
          raw_id = envelope["id"]? || raise Failure.new(Status::InvalidRequest, "call id is required")
          id = EditorTools.identifier(raw_id, "call id")
          @budget.register_call_id(id.not_nil!)

          EditorTools.exact_keys!(envelope, ["id", "name", "arguments"], "request")
          name = EditorTools.string_value(envelope["name"]?, "tool name")
          arguments = envelope["arguments"]?.try(&.as_h?) ||
                      raise Failure.new(Status::InvalidRequest, "arguments must be an object")
          request, capability = EditorTools.build_request(name, arguments)

          raise Failure.new(Status::Stale, "tool session context changed") unless context_current?
          raise Failure.new(Status::Denied, "tool capability is not granted") unless @capabilities.includes?(capability)

          permit_lifetime = [true]
          permit = ExecutionPermit.new(@context, -> {
            if permit_lifetime[0] && permit_context_current?
              true
            else
              permit_lifetime[0] = false
              false
            end
          })
          begin
            data = @backend.execute(request, permit)
            execution_result(id, data, nil, permit)
          rescue failure : Failure
            execution_result(id, nil, failure, permit)
          rescue
            execution_result(id, nil, nil, permit)
          ensure
            permit_lifetime[0] = false
          end
        rescue failure : Failure
          Result.new(id, failure.status, nil, failure.message)
        rescue
          Result.new(id, Status::InvalidRequest, nil, "invalid tool request")
        end

        @budget.finish(result)
      end

      def definitions : Array(ToolDefinition)
        return [] of ToolDefinition if closed?

        TOOL_CATALOG.compact_map do |entry|
          entry.definition if @capabilities.includes?(entry.capability)
        end
      end

      def delegate(consumer : Consumer, capabilities : Array(Capability)) : Session
        raise Failure.new(Status::Denied, "tool session is closed") if closed?
        raise Failure.new(Status::LimitExceeded, "delegation depth limit reached") if @depth >= @budget.limits.max_depth
        raise Failure.new(Status::LimitExceeded, "tool session budget is exhausted") if @budget.exhausted?

        @budget.reserve_child!
        effective = capabilities.select { |capability| @capabilities.includes?(capability) }.uniq
        SessionBuilder.child(@backend, @context, effective, @budget, self, @depth + 1, consumer)
      end

      def close : Nil
        @closed_local = true
      end

      def closed? : Bool
        @closed_local || (@parent.try(&.closed?) || false)
      end

      def exhausted? : Bool
        @budget.exhausted?
      end

      def consumer : Consumer
        @consumer
      end

      @consumer : Consumer

      private def active? : Bool
        !closed?
      end

      private def context_current? : Bool
        @backend.context == @context
      rescue
        false
      end

      private def permit_context_current? : Bool
        !closed? && context_current?
      end

      private def execution_result(id : String?, data : JSON::Any?, failure : Failure?,
                                   permit : ExecutionPermit) : Result
        if closed?
          Result.new(id, Status::Denied, nil, "tool session closed during execution")
        elsif !context_current?
          Result.new(id, Status::Stale, nil, "tool session context changed during execution")
        elsif !permit.active?
          Result.new(id, Status::Stale, nil, "tool invocation was revoked during execution")
        elsif failure
          Result.new(id, failure.status, nil, failure.message)
        elsif data
          Result.new(id, Status::Ok, data)
        else
          Result.new(id, Status::Unavailable, nil, "tool execution failed")
        end
      end
    end

    class Host
      @backend : Backend
      @limits : Limits

      def initialize(@backend : Backend, @limits : Limits = Limits.new)
      end

      def open_session(consumer : Consumer, capabilities : Array(Capability)) : Session
        context = @backend.context
        SessionBuilder.root(@backend, context, capabilities.uniq, @limits, consumer)
      end
    end

    private class SessionBuilder < Session
      def self.root(backend : Backend, context : Context, capabilities : Array(Capability),
                    limits : Limits, consumer : Consumer) : Session
        new(backend, context, capabilities, SharedBudget.new(limits), nil, 0, consumer)
      end

      def self.child(backend : Backend, context : Context, capabilities : Array(Capability),
                     budget : SharedBudget, parent : Session, depth : Int32,
                     consumer : Consumer) : Session
        new(backend, context, capabilities, budget, parent, depth, consumer)
      end

      def initialize(backend : Backend, context : Context, capabilities : Array(Capability),
                     budget : SharedBudget, parent : Session?, depth : Int32,
                     consumer : Consumer)
        super(backend, context, capabilities, budget, parent, depth, consumer)
      end
    end

    def self.control_char?(char : Char) : Bool
      codepoint = char.ord
      codepoint < 0x20 || codepoint.in?(0x7f..0x9f)
    end

    def self.exact_keys!(object : Hash(String, JSON::Any), allowed : Array(String),
                         label : String) : Nil
      object.each_key do |key|
        unless allowed.includes?(key)
          raise Failure.new(Status::InvalidRequest, "unexpected #{label} field")
        end
      end
    end

    def self.string_value(value : JSON::Any?, label : String) : String
      value.try(&.as_s?) || raise Failure.new(Status::InvalidRequest, "#{label} must be a string")
    end

    private def self.checked_string(value : JSON::Any?, label : String,
                                    min_chars : Int32, max_chars : Int32,
                                    max_bytes : Int32) : String
      string = string_value(value, label)
      unless string.valid_encoding?
        raise Failure.new(Status::InvalidRequest, "#{label} must be valid UTF-8")
      end
      char_count = 0
      string.each_char do |char|
        raise Failure.new(Status::InvalidRequest, "#{label} contains a control character") if control_char?(char)
        char_count += 1
        if char_count > max_chars
          raise Failure.new(Status::LimitExceeded, "#{label} exceeds its length limit")
        end
      end
      if char_count < min_chars
        raise Failure.new(Status::InvalidRequest, "#{label} must not be empty")
      end
      if string.bytesize > max_bytes
        raise Failure.new(Status::LimitExceeded, "#{label} exceeds its byte limit")
      end
      string
    end

    def self.identifier(value : JSON::Any?, label : String) : String
      checked_string(value, label, 1, 128, 512)
    end

    def self.bounded_result_id(id : String?) : String?
      return unless id
      return unless id.valid_encoding?
      return if id.bytesize > 512

      count = 0
      id.each_char do |char|
        return if control_char?(char)
        count += 1
        return if count > 128
      end
      return if count == 0

      id.dup
    end

    private def self.path_value(value : JSON::Any?) : String
      checked_string(value, "path", 1, Int32::MAX, 4096)
    end

    private def self.query_value(value : JSON::Any?) : String
      checked_string(value, "query", 0, 256, 1024)
    end

    private def self.integer_value(value : JSON::Any?, label : String,
                                   default : Int32, min : Int32, max : Int32) : Int32
      return default unless value
      integer = value.as_i64? || raise Failure.new(Status::InvalidRequest, "#{label} must be an integer")
      unless integer >= min && integer <= max
        raise Failure.new(Status::LimitExceeded, "#{label} is outside its allowed range")
      end
      integer.to_i32
    end

    private def self.required_identifier(arguments : Hash(String, JSON::Any), key : String) : String
      identifier(arguments[key]?, key)
    end

    def self.build_request(name : String,
                           arguments : Hash(String, JSON::Any)) : Tuple(Request, Capability)
      entry = TOOL_CATALOG.find { |candidate| candidate.name == name }
      unless entry
        raise Failure.new(Status::InvalidRequest, "unknown tool name")
      end

      request : Request = case entry.kind
      when ToolKind::ListBuffers
        exact_keys!(arguments, ["offset", "limit"], "arguments")
        request = ListBuffersRequest.new(
          integer_value(arguments["offset"]?, "offset", 0, 0, Int32::MAX),
          integer_value(arguments["limit"]?, "limit", 32, 1, 64)
        )
        request
      when ToolKind::ReadBuffer
        exact_keys!(arguments, ["buffer_id", "revision", "start_line", "line_count", "start_column", "max_columns"], "arguments")
        request = ReadBufferRequest.new(
          required_identifier(arguments, "buffer_id"),
          required_identifier(arguments, "revision"),
          integer_value(arguments["start_line"]?, "start_line", 1, 1, Int32::MAX),
          integer_value(arguments["line_count"]?, "line_count", 16, 1, 64),
          integer_value(arguments["start_column"]?, "start_column", 0, 0, Int32::MAX),
          integer_value(arguments["max_columns"]?, "max_columns", 512, 1, 1024)
        )
        request
      when ToolKind::FindFiles
        exact_keys!(arguments, ["query", "limit"], "arguments")
        query = query_value(arguments["query"]?)
        request = FindFilesRequest.new(query, integer_value(arguments["limit"]?, "limit", 32, 1, 64))
        request
      when ToolKind::OpenFile
        exact_keys!(arguments, ["path"], "arguments")
        OpenFileRequest.new(path_value(arguments["path"]?))
      when ToolKind::FocusBuffer
        exact_keys!(arguments, ["buffer_id", "revision"], "arguments")
        request = FocusBufferRequest.new(
          required_identifier(arguments, "buffer_id"),
          required_identifier(arguments, "revision")
        )
        request
      when ToolKind::DebugSnapshot
        exact_keys!(arguments, ["limit"], "arguments")
        request = DebugSnapshotRequest.new(integer_value(arguments["limit"]?, "limit", 32, 1, 64))
        request
      else
        raise Failure.new(Status::InvalidRequest, "unknown tool name")
      end
      {request, entry.capability}
    end

    def self.parse_bounded_json(raw : String) : JSON::Any
      parser = JSON::PullParser.new(raw)
      validate_json_value!(parser, 0)
      unless parser.kind.eof?
        raise Failure.new(Status::InvalidRequest, "request has trailing JSON data")
      end
      JSON.parse(raw)
    rescue failure : Failure
      raise failure
    rescue
      raise Failure.new(Status::InvalidRequest, "request is not valid bounded JSON")
    end

    private def self.validate_json_value!(parser : JSON::PullParser, depth : Int32) : Nil
      case parser.kind
      when .begin_object?
        raise Failure.new(Status::LimitExceeded, "request JSON is too deeply nested") if depth >= MAX_JSON_DEPTH
        seen = Set(String).new
        parser.read_object do |key, _|
          if seen.includes?(key)
            raise Failure.new(Status::InvalidRequest, "request contains a duplicate object key")
          end
          seen << key
          validate_json_value!(parser, depth + 1)
        end
      when .begin_array?
        raise Failure.new(Status::LimitExceeded, "request JSON is too deeply nested") if depth >= MAX_JSON_DEPTH
        parser.read_array do
          validate_json_value!(parser, depth + 1)
        end
      when .string?
        parser.read_string
      when .int?
        parser.read_int
      when .float?
        parser.read_float
      when .bool?
        parser.read_bool
      when .null?
        parser.read_null
      else
        raise Failure.new(Status::InvalidRequest, "request must contain one JSON value")
      end
    end

    def self.encode_bounded_json(value : JSON::Any, max_bytes : Int32) : String
      io = IO::Memory.new
      append_json_value(io, value, max_bytes, 0)
      io.to_s
    rescue failure : Failure
      raise failure
    rescue
      raise Failure.new(Status::Unavailable, "tool result is not valid JSON")
    end

    private def self.append_json_value(io : IO::Memory, value : JSON::Any,
                                       max_bytes : Int32, depth : Int32) : Nil
      raise Failure.new(Status::LimitExceeded, "tool result is too deeply nested") if depth > MAX_JSON_DEPTH

      case raw = value.raw
      when Nil
        append_limited(io, "null", max_bytes)
      when Bool
        append_limited(io, raw ? "true" : "false", max_bytes)
      when Int64
        append_limited(io, raw.to_s, max_bytes)
      when Float64
        append_limited(io, raw.to_json, max_bytes)
      when String
        raise Failure.new(Status::Unavailable, "tool result contains invalid UTF-8") unless raw.valid_encoding?
        raise Failure.new(Status::LimitExceeded, "tool result string exceeds response limit") if raw.bytesize > max_bytes
        append_limited(io, JSON::Any.new(raw).to_json, max_bytes)
      when Array
        append_limited(io, "[", max_bytes)
        raw.each_with_index do |child, index|
          append_limited(io, ",", max_bytes) unless index == 0
          append_json_value(io, child, max_bytes, depth + 1)
        end
        append_limited(io, "]", max_bytes)
      when Hash
        append_limited(io, "{", max_bytes)
        raw.each_with_index do |(key, child), index|
          append_limited(io, ",", max_bytes) unless index == 0
          raise Failure.new(Status::Unavailable, "tool result contains invalid UTF-8") unless key.valid_encoding?
          raise Failure.new(Status::LimitExceeded, "tool result key exceeds response limit") if key.bytesize > max_bytes
          append_limited(io, JSON::Any.new(key).to_json, max_bytes)
          append_limited(io, ":", max_bytes)
          append_json_value(io, child, max_bytes, depth + 1)
        end
        append_limited(io, "}", max_bytes)
      else
        raise Failure.new(Status::Unavailable, "tool result contains an unsupported JSON value")
      end
    end

    private def self.append_limited(io : IO::Memory, text : String, max_bytes : Int32) : Nil
      if io.size + text.bytesize > max_bytes
        raise Failure.new(Status::LimitExceeded, "tool result exceeds response limit")
      end
      io << text
    end
  end
end
