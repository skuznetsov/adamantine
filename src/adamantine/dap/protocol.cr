require "json"
require "set"

module Adamantine::Dap
  class ProtocolError < Exception
  end

  class ClientError < Exception
  end

  struct Limits
    getter max_header_bytes : Int32
    getter max_message_bytes : Int32
    getter max_aggregate_inbound_bytes : Int64
    getter max_decoded_queue_bytes : Int64
    getter max_decoded_queue_items : Int32
    getter max_pending_requests : Int32
    getter max_writer_queue_bytes : Int64
    getter max_writer_queue_frames : Int32
    getter max_timeout_tombstones : Int32
    getter max_json_depth : Int32
    getter max_json_tokens : Int32
    # Bounds a started but incomplete stdio frame; a wholly idle adapter is not timed out.
    getter incomplete_frame_timeout : Time::Span

    def initialize(@max_header_bytes : Int32 = Protocol::MAX_HEADER_BYTES,
                   @max_message_bytes : Int32 = Protocol::MAX_MESSAGE_BYTES,
                   @max_aggregate_inbound_bytes : Int64 = 32_i64 * 1024 * 1024,
                   @max_decoded_queue_bytes : Int64 = 64_i64 * 1024 * 1024,
                   @max_decoded_queue_items : Int32 = 128,
                   @max_pending_requests : Int32 = 64,
                   @max_writer_queue_bytes : Int64 = 16_i64 * 1024 * 1024,
                   @max_writer_queue_frames : Int32 = 64,
                   @max_timeout_tombstones : Int32 = 64,
                   @max_json_depth : Int32 = Protocol::MAX_JSON_DEPTH,
                   @max_json_tokens : Int32 = Protocol::MAX_JSON_TOKENS,
                   @incomplete_frame_timeout : Time::Span = 5.seconds)
      unless @max_header_bytes.in?(1..Protocol::MAX_HEADER_BYTES) &&
             @max_message_bytes.in?(1..Protocol::MAX_CONFIGURABLE_MESSAGE_BYTES) &&
             @max_aggregate_inbound_bytes >= @max_message_bytes &&
             @max_decoded_queue_bytes >= @max_message_bytes &&
             @max_decoded_queue_items > 0 && @max_decoded_queue_items <= 4096 &&
             @max_pending_requests > 0 && @max_pending_requests <= 64 &&
             @max_writer_queue_bytes >= @max_message_bytes &&
             @max_writer_queue_frames > 0 && @max_writer_queue_frames <= 4096 &&
             @max_timeout_tombstones > 0 && @max_timeout_tombstones <= 64 &&
             @max_json_depth.in?(1..Protocol::MAX_JSON_DEPTH) &&
             @max_json_tokens.in?(1..Protocol::MAX_JSON_TOKENS) &&
             @incomplete_frame_timeout > Time::Span.zero && @incomplete_frame_timeout <= 5.minutes
        raise ArgumentError.new("invalid DAP resource limits")
      end
    end
  end

  struct Message
    getter sequence : Int32
    getter kind : String
    getter command : String?
    getter event : String?
    getter request_sequence : Int32?
    getter success : Bool?
    getter message : String?
    getter arguments : JSON::Any?
    getter body : JSON::Any?
    getter payload : JSON::Any
    getter wire_bytes : Int32
    getter decoded_charge : Int64

    def initialize(@sequence : Int32, @kind : String, @command : String?, @event : String?,
                   @request_sequence : Int32?, @success : Bool?, @message : String?,
                   @arguments : JSON::Any?, @body : JSON::Any?, @payload : JSON::Any,
                   @wire_bytes : Int32, @decoded_charge : Int64)
    end
  end

  module Protocol
    MAX_HEADER_BYTES               = 8 * 1024
    MAX_MESSAGE_BYTES              = 16 * 1024 * 1024
    MAX_CONFIGURABLE_MESSAGE_BYTES = 64 * 1024 * 1024
    MAX_JSON_DEPTH                 =      64
    MAX_JSON_TOKENS                = 250_000

    private class JsonBudget
      property tokens = 0
      property charge = 0_i64
      getter max_tokens : Int32
      getter max_depth : Int32

      def initialize(@max_tokens : Int32, @max_depth : Int32)
      end

      def count_token! : Nil
        @tokens += 1
        raise ProtocolError.new("DAP JSON token budget exceeded") if @tokens > @max_tokens
      end

      def add_charge(bytes : Int64) : Nil
        @charge += bytes
      end
    end

    def self.encode_frame(payload : JSON::Any, *, max_message_bytes : Int32 = MAX_MESSAGE_BYTES) : String
      validate_payload!(payload)
      json = payload.to_json
      raise ProtocolError.new("DAP message exceeds configured byte limit") if json.bytesize > max_message_bytes
      "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
    rescue ex : ProtocolError
      raise ex
    rescue
      raise ProtocolError.new("invalid DAP message")
    end

    def self.decode_payload(json : String, *, max_json_depth : Int32 = MAX_JSON_DEPTH,
                            max_json_tokens : Int32 = MAX_JSON_TOKENS,
                            wire_bytes : Int32 = json.bytesize,
                            preflight_charge : Int64? = nil) : Message
      raise ProtocolError.new("invalid UTF-8 in DAP payload") unless json.valid_encoding?
      charge = preflight_charge || preflight_json(json, max_json_depth, max_json_tokens)
      payload = JSON.parse(json)
      validate_payload!(payload, wire_bytes, charge)
    rescue ex : ProtocolError
      raise ex
    rescue
      raise ProtocolError.new("invalid DAP JSON payload")
    end

    def self.validate_payload!(payload : JSON::Any, wire_bytes : Int32 = 0, charge_override : Int64? = nil) : Message
      object = payload.as_h?
      raise ProtocolError.new("DAP message must be a JSON object") unless object

      sequence = required_int32(object, "seq")
      kind = required_string(object, "type")

      command = nil.as(String?)
      event = nil.as(String?)
      request_sequence = nil.as(Int32?)
      success = nil.as(Bool?)
      message_text = nil.as(String?)
      arguments = object["arguments"]?
      body = object["body"]?

      case kind
      when "request"
        command = required_nonempty_string(object, "command")
        if args = arguments
          raise ProtocolError.new("DAP request arguments must be an object") unless args.as_h?
        end
      when "response"
        request_sequence = required_int32(object, "request_seq")
        success_value = object["success"]?.try(&.as_bool?)
        raise ProtocolError.new("DAP response success must be boolean") if success_value.nil?
        success = success_value
        command = required_nonempty_string(object, "command")
        if response_message = object["message"]?
          message_text = response_message.as_s?
          raise ProtocolError.new("DAP response message must be a string") unless message_text
        end
        if response_body = body
          raise ProtocolError.new("DAP response body must be an object") unless response_body.as_h?
        end
      when "event"
        event = required_nonempty_string(object, "event")
        if event_body = body
          raise ProtocolError.new("DAP event body must be an object") unless event_body.as_h?
        end
      else
        raise ProtocolError.new("unsupported DAP message type")
      end

      Message.new(sequence, kind, command, event, request_sequence, success,
        message_text, arguments, body, payload, wire_bytes,
        charge_override || self.decoded_charge(payload))
    rescue ex : ProtocolError
      raise ex
    rescue
      raise ProtocolError.new("invalid DAP message envelope")
    end

    def self.decoded_charge(payload : JSON::Any) : Int64
      charge_value(payload)
    end

    private def self.required_int32(object : Hash(String, JSON::Any), key : String) : Int32
      value = object[key]?.try(&.as_i64?)
      unless value && value > 0 && value <= Int32::MAX
        raise ProtocolError.new("DAP #{key} must be a positive Int32")
      end
      value.to_i32
    end

    private def self.required_string(object : Hash(String, JSON::Any), key : String) : String
      value = object[key]?.try(&.as_s?)
      raise ProtocolError.new("DAP #{key} must be a string") unless value
      value
    end

    private def self.required_nonempty_string(object : Hash(String, JSON::Any), key : String) : String
      nonempty_string(object[key]?, key)
    end

    private def self.nonempty_string(value : JSON::Any?, key : String) : String
      result = value.try(&.as_s?)
      raise ProtocolError.new("DAP #{key} must be a non-empty string") unless result && !result.empty?
      result
    end

    def self.preflight_json(json : String, max_depth : Int32 = MAX_JSON_DEPTH, max_tokens : Int32 = MAX_JSON_TOKENS) : Int64
      raise ProtocolError.new("invalid UTF-8 in DAP payload") unless json.valid_encoding?
      raise ProtocolError.new("invalid DAP JSON limits") unless max_depth.in?(1..MAX_JSON_DEPTH) && max_tokens.in?(1..MAX_JSON_TOKENS)
      parser = JSON::PullParser.new(json)
      parser.max_nesting = MAX_JSON_DEPTH
      budget = JsonBudget.new(max_tokens, max_depth)
      consume_json_value(parser, budget, 0)
      raise ProtocolError.new("trailing data after DAP JSON value") unless parser.kind.eof?
      budget.charge
    rescue ex : ProtocolError
      raise ex
    rescue
      raise ProtocolError.new("invalid or over-nested DAP JSON payload")
    end

    private def self.consume_json_value(parser : JSON::PullParser, budget : JsonBudget, depth : Int32) : Nil
      budget.count_token!
      case parser.kind
      when .begin_object?
        next_depth = depth + 1
        raise ProtocolError.new("DAP JSON depth budget exceeded") if next_depth > budget.max_depth
        budget.add_charge(48_i64)
        seen = Set(String).new
        parser.read_object do |key, _location|
          budget.count_token!
          budget.add_charge(40_i64 + key.bytesize)
          raise ProtocolError.new("duplicate key in DAP JSON object") unless seen.add?(key)
          consume_json_value(parser, budget, next_depth)
        end
      when .begin_array?
        next_depth = depth + 1
        raise ProtocolError.new("DAP JSON depth budget exceeded") if next_depth > budget.max_depth
        budget.add_charge(32_i64)
        parser.read_array { consume_json_value(parser, budget, next_depth) }
      when .string?
        budget.add_charge(32_i64 + parser.string_value.bytesize)
        parser.read_string
      when .int?
        budget.add_charge(16_i64)
        parser.read_int
      when .float?
        budget.add_charge(16_i64)
        parser.read_float
      when .bool?
        budget.add_charge(16_i64)
        parser.read_bool
      when .null?
        budget.add_charge(16_i64)
        parser.read_null
      else
        raise ProtocolError.new("invalid DAP JSON token")
      end
    end

    private def self.charge_value(value : JSON::Any) : Int64
      case raw = value.raw
      when String
        32_i64 + raw.bytesize
      when Array(JSON::Any)
        32_i64 + raw.sum(0_i64) { |child| charge_value(child) }
      when Hash(String, JSON::Any)
        48_i64 + raw.sum(0_i64) { |key, child| 40_i64 + key.bytesize + charge_value(child) }
      else
        16_i64
      end
    end
  end

  class FrameDecoder
    alias WireDelta = Proc(Int32, Nil)
    alias BeforeDecode = Proc(Int32, Int64, Nil)
    alias ReleaseReservation = Proc(Int64, Nil)
    alias OnMessage = Proc(Message, Nil)

    getter buffered_bytes : Int32
    getter incomplete_since : Time::Instant?

    def initialize(@max_header_bytes : Int32 = Protocol::MAX_HEADER_BYTES,
                   @max_message_bytes : Int32 = Protocol::MAX_MESSAGE_BYTES,
                   @max_json_depth : Int32 = Protocol::MAX_JSON_DEPTH,
                   @max_json_tokens : Int32 = Protocol::MAX_JSON_TOKENS,
                   @wire_delta : WireDelta? = nil,
                   @before_decode : BeforeDecode? = nil,
                   @release_reservation : ReleaseReservation? = nil,
                   @on_message : OnMessage? = nil)
      unless @max_header_bytes.in?(1..Protocol::MAX_HEADER_BYTES) &&
             @max_message_bytes.in?(1..Protocol::MAX_CONFIGURABLE_MESSAGE_BYTES) &&
             @max_json_depth.in?(1..Protocol::MAX_JSON_DEPTH) &&
             @max_json_tokens.in?(1..Protocol::MAX_JSON_TOKENS)
        raise ArgumentError.new("invalid DAP frame limits")
      end
      @header = IO::Memory.new
      @body = IO::Memory.new
      @expected_length = nil.as(Int32?)
      @header_bytes = 0
      @buffered_bytes = 0
      @incomplete_since = nil.as(Time::Instant?)
    end

    def feed(bytes : Bytes) : Array(Message)
      messages = [] of Message
      offset = 0
      reservation = nil.as(Tuple(Int32, Int64)?)
      while offset < bytes.size
        if expected_length = @expected_length
          remaining = expected_length - @body.size
          take = Math.min(remaining, bytes.size - offset)
          @wire_delta.try &.call(take)
          @incomplete_since ||= Time.instant
          @body.write(bytes[offset, take])
          @buffered_bytes += take
          offset += take
          if @body.size == expected_length
            @incomplete_since = nil
            wire_bytes = @header_bytes + expected_length
            json = @body.to_s
            charge = Protocol.preflight_json(json, @max_json_depth, @max_json_tokens)
            @before_decode.try &.call(wire_bytes, charge)
            reservation = {wire_bytes, charge} if @before_decode
            message = Protocol.decode_payload(json, max_json_depth: @max_json_depth,
              max_json_tokens: @max_json_tokens, wire_bytes: wire_bytes, preflight_charge: charge)
            if handler = @on_message
              handler.call(message)
              reservation = nil
            else
              messages << message
            end
            reset_frame
          end
        else
          byte = bytes[offset]
          raise ProtocolError.new("non-ASCII byte in DAP header") if byte > 0x7f
          @wire_delta.try &.call(1)
          @incomplete_since ||= Time.instant
          @header.write_byte(byte)
          @header_bytes += 1
          @buffered_bytes += 1
          offset += 1
          raise ProtocolError.new("DAP header exceeds configured byte limit") if @header_bytes > @max_header_bytes
          if header_complete?
            parse_header!
          end
        end
      end
      messages
    rescue ex : ProtocolError
      release_reservation(reservation)
      release_buffered_wire
      reset_all
      raise ex
    rescue
      release_reservation(reservation)
      release_buffered_wire
      reset_all
      raise ProtocolError.new("invalid DAP frame")
    end

    def finish! : Nil
      return if @buffered_bytes == 0
      release_buffered_wire
      reset_all
      raise ProtocolError.new("truncated DAP frame at EOF")
    end

    # Discards an incomplete frame when the owned transport is shut down.
    # Successfully charged wire bytes are released; bytes rejected by the
    # transport's aggregate budget are never included in this counter.
    def discard! : Nil
      release_buffered_wire
      reset_all
    end

    private def parse_header! : Nil
      header = @header.to_s
      lines = header[0, header.bytesize - 4].split("\r\n")
      content_length = nil.as(Int32?)
      content_type_seen = false
      lines.each do |line|
        key, value = line.split(":", 2)
        raise ProtocolError.new("malformed DAP header") unless key && value
        header_key = key.downcase
        case header_key
        when "content-length"
          raise ProtocolError.new("duplicate DAP Content-Length") if content_length
          text = value.strip
          raise ProtocolError.new("invalid DAP Content-Length") unless text.matches?(/\A[0-9]+\z/)
          parsed = text.to_i64?
          raise ProtocolError.new("invalid DAP Content-Length") unless parsed && parsed > 0 && parsed <= @max_message_bytes
          content_length = parsed.to_i32
        when "content-type"
          raise ProtocolError.new("duplicate DAP Content-Type") if content_type_seen
          content_type_seen = true
          text = value.strip.downcase
          unless text.starts_with?("application/vscode-jsonrpc") || text.starts_with?("application/json")
            raise ProtocolError.new("unsupported DAP Content-Type")
          end
        else
          raise ProtocolError.new("unsupported DAP header")
        end
      end
      @expected_length = content_length || raise(ProtocolError.new("missing DAP Content-Length"))
    end

    private def reset_frame : Nil
      @header = IO::Memory.new
      @body = IO::Memory.new
      @expected_length = nil
      @header_bytes = 0
      @buffered_bytes = 0
      @incomplete_since = nil
    end

    private def reset_all : Nil
      reset_frame
    end

    private def release_reservation(reservation : Tuple(Int32, Int64)?) : Nil
      return unless reservation
      @release_reservation.try &.call(reservation[1])
    end

    private def release_buffered_wire : Nil
      @wire_delta.try &.call(-@buffered_bytes) if @buffered_bytes > 0
    end

    private def header_complete? : Bool
      return false if @header_bytes < 4
      bytes = @header.to_slice
      offset = bytes.size - 4
      bytes[offset] == 0x0d && bytes[offset + 1] == 0x0a &&
        bytes[offset + 2] == 0x0d && bytes[offset + 3] == 0x0a
    end
  end
end
