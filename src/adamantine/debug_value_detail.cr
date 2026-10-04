require "json"

module Adamantine::Debugging
  enum DebugValueFormat
    Summary
    Hex
    Raw
    JsonInterpretation
  end

  enum DebugValueAvailability
    Available
    Unavailable
  end

  class DebugValueRender
    getter availability : DebugValueAvailability
    getter format : DebugValueFormat
    getter truncated : Bool
    @label : String
    @text : String
    @reason : String?

    def initialize(@availability : DebugValueAvailability, @format : DebugValueFormat,
                   label : String, text : String, @truncated : Bool = false,
                   reason : String? = nil)
      @label = label.dup
      @text = text.dup
      @reason = reason.try(&.dup)
    end

    def available? : Bool
      @availability == DebugValueAvailability::Available
    end

    def truncated? : Bool
      @truncated
    end

    def label : String
      @label.dup
    end

    def text : String
      @text.dup
    end

    def reason : String?
      @reason.try(&.dup)
    end
  end

  # Renders already-owned representations only; it never fetches or derives
  # one. Standard DAP Hex is supplied by an explicit controller request, and
  # DAP defines no generic Raw field. JSON mode is local interpretation.
  class DebugValueDetail
    DEFAULT_MAX_BYTES = 64 * 1024
    MAX_BYTES         = 64 * 1024

    @summary : String
    @json_source : String?
    @supports_hex : Bool
    @hex_value : String?
    @raw_value : String?
    @summary_truncated : Bool
    @hex_truncated : Bool
    @raw_truncated : Bool
    @max_bytes : Int32
    @max_json_depth : Int32

    def initialize(summary : String, *, json_source : String? = nil,
                   json_source_complete : Bool = true, summary_truncated : Bool = false,
                   supports_hex : Bool = false,
                   hex_value : String? = nil, raw_value : String? = nil,
                   max_bytes : Int32 = DEFAULT_MAX_BYTES, max_json_depth : Int32 = 16)
      raise ArgumentError.new("detail byte limit must be positive and at most 64 KiB") unless max_bytes.in?(1..MAX_BYTES)
      raise ArgumentError.new("JSON detail depth must be between 1 and 32") unless max_json_depth.in?(1..32)
      @max_bytes = max_bytes
      original_json = json_source || (json_source_complete ? summary : nil)
      @json_source = if json_source_complete && original_json && original_json.not_nil!.valid_encoding? && original_json.not_nil!.bytesize <= max_bytes
                       original_json.not_nil!.dup
                     else
                       nil
                     end
      @summary, clipped_summary = bounded_display(summary, max_bytes)
      @summary_truncated = summary_truncated || clipped_summary
      @supports_hex = supports_hex
      @hex_value, @hex_truncated = optional_display(hex_value, max_bytes)
      @raw_value, @raw_truncated = optional_display(raw_value, max_bytes)
      @max_json_depth = max_json_depth
    end

    def render(format : DebugValueFormat = DebugValueFormat::Summary) : DebugValueRender
      case format
      when .summary?
        available(format, "Adapter summary", @summary, @summary_truncated)
      when .hex?
        if value = @hex_value
          if @supports_hex
            available(format, "Adapter-provided hexadecimal", value, @hex_truncated)
          else
            unavailable(format, "adapter does not provide hexadecimal representation")
          end
        else
          unavailable(format, "adapter does not provide hexadecimal representation")
        end
      when .raw?
        if value = @raw_value
          available(format, "Adapter-provided raw representation", value, @raw_truncated)
        else
          unavailable(format, "adapter does not provide a raw representation")
        end
      when .json_interpretation?
        render_json
      else
        unavailable(format, "unsupported display format")
      end
    end

    private def render_json : DebugValueRender
      source = @json_source
      unless source
        return unavailable(DebugValueFormat::JsonInterpretation, "truncated summary cannot be interpreted as complete JSON")
      end
      unless json_depth_within_limit?(source.not_nil!)
        return unavailable(DebugValueFormat::JsonInterpretation, "JSON interpretation exceeds the local depth limit")
      end
      value = JSON.parse(source.not_nil!)
      # Serialize only a parsed, already bounded value for display. This is a
      # local formatting operation; no adapter request or target evaluation.
      rendered = safe_json_controls(value.to_json)
      if rendered.bytesize > @max_bytes
        return unavailable(DebugValueFormat::JsonInterpretation, "serialized JSON exceeds the selected detail byte limit")
      end
      text, truncated = bounded_display(rendered, @max_bytes)
      DebugValueRender.new(DebugValueAvailability::Available, DebugValueFormat::JsonInterpretation,
        "JSON interpretation (local display)", text, truncated)
    rescue
      unavailable(DebugValueFormat::JsonInterpretation, "adapter summary is not valid bounded JSON")
    end

    private def json_depth_within_limit?(value : String) : Bool
      depth = 0
      in_string = false
      escaped = false
      value.each_char do |char|
        if in_string
          if escaped
            escaped = false
          elsif char == '\\'
            escaped = true
          elsif char == '"'
            in_string = false
          end
        else
          case char
          when '"'
            in_string = true
          when '{', '['
            depth += 1
            return false if depth > @max_json_depth
          when '}', ']'
            depth -= 1
            return false if depth < 0
          end
        end
      end
      !in_string && depth == 0
    end

    # JSON permits C1 code points in strings, but a terminal must never receive
    # them as raw controls. Escaping only serialized JSON string contents keeps
    # the displayed document valid JSON without changing its parsed meaning.
    private def safe_json_controls(value : String) : String
      String.build do |builder|
        value.each_char do |char|
          code = char.ord
          if code.in?(0x80..0x9f)
            builder << "\\u" << code.to_s(16).rjust(4, '0')
          else
            builder << char
          end
        end
      end
    end

    private def available(format : DebugValueFormat, label : String, text : String,
                          truncated : Bool) : DebugValueRender
      reason = truncated ? "display clipped to the configured byte limit" : nil
      DebugValueRender.new(DebugValueAvailability::Available, format, label, text, truncated, reason)
    end

    private def unavailable(format : DebugValueFormat, reason : String) : DebugValueRender
      DebugValueRender.new(DebugValueAvailability::Unavailable, format, "Unavailable", "", false, reason)
    end

    private def optional_display(value : String?, limit : Int32) : Tuple(String?, Bool)
      return {nil, false} unless value
      bounded_display(value.not_nil!, limit)
    end

    private def bounded_display(value : String, limit : Int32) : Tuple(String, Bool)
      return {"?", true} unless value.valid_encoding?
      truncated = false
      output = String.build do |builder|
        bytes = 0
        value.each_char do |char|
          safe = visible_char(char)
          if bytes + safe.bytesize > limit
            truncated = true
            break
          end
          builder << safe
          bytes += safe.bytesize
        end
      end
      {output, truncated}
    end

    private def visible_char(char : Char) : String
      case char.ord
      when 0x1b       then "␛"
      when 0x00..0x08 then "�"
      when 0x09       then "⇥"
      when 0x0a       then "↵"
      when 0x0b..0x1f then "�"
      when 0x7f       then "�"
      when 0x80..0x9f then "�"
      else                 char.to_s
      end
    end
  end
end
