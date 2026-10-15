require "json"
require "socket"
require "uri"

module Adamantine
  module Chat
    # Immutable settings for the explicitly configured Chat Completions
    # transport. This object stores a credential *name*, never a credential.
    class ProviderConfig
      DEFAULT_ENDPOINT              = "https://api.openai.com/v1/chat/completions"
      DEFAULT_KEY_ENV               = "OPENAI_API_KEY"
      DEFAULT_MAX_COMPLETION_TOKENS = 4096
      REASONING_EFFORTS             = {"none", "minimal", "low", "medium", "high", "xhigh", "max"}
      MAX_ENDPOINT_BYTES            =  2048
      MAX_MODEL_BYTES               =   256
      MAX_KEY_ENV_BYTES             =   128
      MIN_COMPLETION_TOKENS         =     1
      MAX_COMPLETION_TOKENS         = 32768

      @enabled : Bool
      @endpoint : String
      @model : String
      @key_env : String
      @max_completion_tokens : Int32
      @reasoning_effort : String?
      @invalid_persisted_data : Bool

      def initialize(@enabled : Bool = false,
                     endpoint : String = DEFAULT_ENDPOINT,
                     model : String = "",
                     key_env : String = DEFAULT_KEY_ENV,
                     max_completion_tokens : Int32 = DEFAULT_MAX_COMPLETION_TOKENS,
                     reasoning_effort : String? = nil,
                     @invalid_persisted_data : Bool = false)
        @endpoint = endpoint.dup
        @model = model.dup
        @key_env = key_env.dup
        @max_completion_tokens = max_completion_tokens
        @reasoning_effort = reasoning_effort.try(&.dup)
      end

      def enabled : Bool
        @enabled
      end

      def endpoint : String
        @endpoint.dup
      end

      def model : String
        @model.dup
      end

      def key_env : String
        @key_env.dup
      end

      def max_completion_tokens : Int32
        @max_completion_tokens
      end

      def reasoning_effort : String?
        @reasoning_effort.try(&.dup)
      end

      # Static validation text only. Never includes the endpoint, model,
      # credential reference, provider error, or any credential value.
      def validation_error : String?
        return "Saved provider settings are invalid; review them before enabling Chat." if @invalid_persisted_data
        return "Provider endpoint is invalid." unless valid_endpoint?
        return "Model name must be non-empty when Chat is enabled." if @enabled && @model.empty?
        return "Model name is invalid or too long." unless valid_model?
        return "Credential environment-variable name is invalid." unless valid_key_env?
        return "Output-token limit must be between 1 and 32768." unless @max_completion_tokens.in?(MIN_COMPLETION_TOKENS..MAX_COMPLETION_TOKENS)
        return "Reasoning effort is invalid." if @reasoning_effort && !REASONING_EFFORTS.includes?(@reasoning_effort.not_nil!)
        nil
      end

      def to_json : String
        JSON.build do |json|
          json.object do
            # Invalid values must never become an enabled, valid configuration
            # merely because serialization omitted the field that made them
            # invalid (for example, an unsupported reasoning effort).
            json.field "enabled", @enabled && validation_error.nil?
            # Do not persist an unsafe URI in the event an invalid settings
            # object is serialized before the settings UI reports the error.
            json.field "endpoint", valid_endpoint? ? @endpoint : DEFAULT_ENDPOINT
            json.field "model", valid_model? ? @model : ""
            json.field "key_env", valid_key_env? ? @key_env : DEFAULT_KEY_ENV
            json.field "max_completion_tokens", @max_completion_tokens
            json.field "reasoning_effort", @reasoning_effort if @reasoning_effort && REASONING_EFFORTS.includes?(@reasoning_effort.not_nil!)
          end
        end
      end

      def self.from_json(value : JSON::Any) : ProviderConfig
        object = value.as_h?
        return invalid_config unless object

        enabled_value = object["enabled"]?
        endpoint_value = object["endpoint"]?
        model_value = object["model"]?
        key_env_value = object["key_env"]?
        tokens_value = object["max_completion_tokens"]?
        effort_value = object["reasoning_effort"]?

        enabled = enabled_value.try(&.as_bool?)
        endpoint = endpoint_value.try(&.as_s?)
        model = model_value.try(&.as_s?)
        key_env = key_env_value.try(&.as_s?)
        tokens = tokens_value.try(&.as_i64?)
        reasoning_effort = effort_value.try(&.as_s?)

        malformed = (enabled_value && enabled.nil?) ||
                    (endpoint_value && !endpoint) ||
                    (model_value && !model) ||
                    (key_env_value && !key_env) ||
                    (tokens_value && !tokens) ||
                    (object.has_key?("reasoning_effort") && !reasoning_effort) ||
                    (tokens && (tokens < Int32::MIN || tokens > Int32::MAX))

        return invalid_config if malformed

        new(
          enabled: enabled || false,
          endpoint: endpoint || DEFAULT_ENDPOINT,
          model: model || "",
          key_env: key_env || DEFAULT_KEY_ENV,
          max_completion_tokens: (tokens || DEFAULT_MAX_COMPLETION_TOKENS).to_i32,
          reasoning_effort: reasoning_effort
        )
      rescue
        invalid_config
      end

      private def self.invalid_config : ProviderConfig
        new(enabled: false, invalid_persisted_data: true)
      end

      private def valid_endpoint? : Bool
        return false if @endpoint.empty? || @endpoint.bytesize > MAX_ENDPOINT_BYTES
        return false unless @endpoint.valid_encoding?
        return false if @endpoint.each_char.any? { |char| char.ord <= 0x20 || char.ord == 0x7f }

        uri = URI.parse(@endpoint)
        scheme = uri.scheme
        host = uri.host
        return false unless scheme && host && !host.empty?
        return false unless uri.user.nil? && uri.password.nil?
        return false unless uri.query.nil? && uri.fragment.nil?
        scheme_end = @endpoint.index("://")
        return false unless scheme_end
        authority_start = scheme_end + 3
        authority_end = @endpoint.index('/', authority_start) || @endpoint.bytesize
        authority = @endpoint.byte_slice(authority_start, authority_end - authority_start)
        return false unless valid_authority?(authority)
        raw_path = @endpoint.byte_slice(authority_end, @endpoint.bytesize - authority_end)
        return false if raw_path.empty? || !raw_path.starts_with?('/')
        return false if raw_path.includes?('\\')

        # Avoid paths whose effective target can differ after intermediary
        # normalization or percent-decoding.
        lower_path = raw_path.downcase
        return false if lower_path.includes?("%2e") || lower_path.includes?("%2f") || lower_path.includes?("%5c")
        return false if raw_path.split('/').any? { |segment| segment == "." || segment == ".." }

        case scheme.downcase
        when "https"
          true
        when "http"
          host_name = authority_hostname(authority)
          host_name == "127.0.0.1" || host_name == "::1"
        else
          false
        end
      rescue
        false
      end

      private def valid_authority?(authority : String) : Bool
        return false if authority.empty? || authority.includes?('@') || authority.includes?('\\') || authority.includes?('%')

        host : String
        port_text : String?
        if authority.starts_with?('[')
          close = authority.index(']')
          return false unless close
          host = authority.byte_slice(1, close - 1)
          suffix = authority.byte_slice(close + 1, authority.bytesize - close - 1)
          if suffix.empty?
            port_text = nil
          elsif suffix.starts_with?(':')
            port_text = suffix.byte_slice(1, suffix.bytesize - 1)
          else
            return false
          end
          return false if host.empty?
          Socket::IPAddress.parse("http://[#{host}]:80")
        else
          colon = authority.index(':')
          if colon
            host = authority.byte_slice(0, colon)
            port_text = authority.byte_slice(colon + 1, authority.bytesize - colon - 1)
          else
            host = authority
            port_text = nil
          end
          return false unless valid_domain_host?(host)
        end

        if port = port_text
          return false if port.empty? || port.bytesize > 5 || !port.each_byte.all? { |byte| byte >= '0'.ord && byte <= '9'.ord }
          numeric_port = port.to_i?
          return false unless numeric_port && numeric_port.in?(1..65535)
        end
        true
      rescue
        false
      end

      private def valid_domain_host?(host : String) : Bool
        return false if host.empty? || host.bytesize > 253 || !host.ascii_only?
        return false if host.includes?('[') || host.includes?(']')

        labels = host.split('.')
        labels.pop if host.ends_with?('.')
        return false if labels.empty?
        return false unless labels.all? do |label|
                              !label.empty? && label.bytesize <= 63 && label.byte_at(0) != '-'.ord && label.byte_at(label.bytesize - 1) != '-'.ord &&
                              label.each_byte.all? do |byte|
                                byte.unsafe_chr.ascii_letter? || byte.unsafe_chr.ascii_number? || byte == '-'.ord
                              end
                            end

        # Numeric dotted hosts are IPv4 literals, so do not let malformed
        # address spellings fall through as DNS names.
        if host.each_byte.all? { |byte| (byte >= '0'.ord && byte <= '9'.ord) || byte == '.'.ord }
          Socket::IPAddress.parse("http://#{host}:80")
        end
        true
      rescue
        false
      end

      private def authority_hostname(authority : String) : String
        if authority.starts_with?('[')
          close = authority.index(']').not_nil!
          authority.byte_slice(1, close - 1)
        else
          authority.split(':', 2)[0]
        end
      end

      private def valid_model? : Bool
        return false if @model.bytesize > MAX_MODEL_BYTES || !@model.valid_encoding?
        !@model.each_char.any? { |char| char.ord < 0x20 || char.ord == 0x7f }
      end

      private def valid_key_env? : Bool
        return false if @key_env.bytesize > MAX_KEY_ENV_BYTES
        if @key_env.empty?
          return loopback_endpoint?
        end
        return false unless @key_env.byte_at(0).unsafe_chr.ascii_letter? || @key_env.byte_at(0) == '_'.ord
        @key_env.each_byte.all? do |byte|
          byte.unsafe_chr.ascii_letter? || byte.unsafe_chr.ascii_number? || byte == '_'.ord
        end
      end

      private def loopback_endpoint? : Bool
        uri = URI.parse(@endpoint)
        return false unless uri.scheme.try(&.downcase) == "http"
        host_name = uri.hostname
        host_name == "127.0.0.1" || host_name == "::1"
      rescue
        false
      end
    end
  end
end
