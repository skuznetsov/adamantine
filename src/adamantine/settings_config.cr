require "json"
require "./editing_settings"

module Adamantine
  # Persistence for editor settings that share the keymap config file.
  #
  # This module deliberately treats the config as an object and updates only
  # the setting it owns.  KeyConfig.save uses the same read/write helpers so
  # either kind of F10 change keeps the other config sections intact.
  module SettingsConfig
    DEFAULT_MAX_RESPONSE_MIB =        16
    MIN_MAX_RESPONSE_MIB     =         1
    MAX_MAX_RESPONSE_MIB     =        64
    MAX_CONFIG_FILE_BYTES    = 1_048_576

    def self.load_editing(path : String?, on_warning : Proc(String, Nil)? = nil) : EditingSettings
      defaults = EditingSettings.new
      config_path = String.new
      config_path = path if path
      return defaults if config_path.empty?
      return defaults unless File.file?(config_path)

      root = read_config_root(config_path)
      editor_value = root["editor"]?
      return defaults unless editor_value

      editor = editor_value.as_h?
      unless editor
        warn_invalid_editing(config_path, "editor", "expected an object", on_warning)
        return defaults
      end

      indent_width = defaults.indent_width
      if raw_indent_width = editor["indent_width"]?
        value = raw_indent_width.as_i64?
        if value && value >= EditingSettings::MIN_INDENT_WIDTH && value <= EditingSettings::MAX_INDENT_WIDTH
          indent_width = value.to_i32
        else
          warn_invalid_editing(
            config_path,
            "editor.indent_width",
            "expected an integer from #{EditingSettings::MIN_INDENT_WIDTH} through #{EditingSettings::MAX_INDENT_WIDTH}",
            on_warning
          )
        end
      end

      auto_indent = defaults.auto_indent
      if raw_auto_indent = editor["auto_indent"]?
        value = raw_auto_indent.as_bool?
        if value.nil?
          warn_invalid_editing(config_path, "editor.auto_indent", "expected a boolean", on_warning)
        else
          auto_indent = value
        end
      end

      EditingSettings.new(indent_width: indent_width, auto_indent: auto_indent)
    rescue ex
      warn_invalid_editing(path || String.new, "editor", "could not read the JSON config", on_warning, ex)
      EditingSettings.new
    end

    def self.save_editing(path : String, settings : EditingSettings) : Nil
      root = read_config_root_for_update(path)
      editor = if existing = root["editor"]?
                 existing.as_h? || raise "config key editor must be an object: #{path}"
               else
                 {} of String => JSON::Any
               end
      editor["indent_width"] = JSON::Any.new(settings.indent_width)
      editor["auto_indent"] = JSON::Any.new(settings.auto_indent)
      root["editor"] = JSON::Any.new(editor)
      write_config_root(path, root)
    end

    def self.load(path : String?, on_warning : Proc(String, Nil)? = nil) : Int32
      config_path = String.new
      config_path = path if path
      return DEFAULT_MAX_RESPONSE_MIB if config_path.empty?
      return DEFAULT_MAX_RESPONSE_MIB unless File.file?(config_path)

      root = read_config_root(config_path)
      lsp_value = root["lsp"]?
      return DEFAULT_MAX_RESPONSE_MIB unless lsp_value
      lsp = lsp_value.as_h?
      unless lsp
        warn_invalid(config_path, on_warning)
        return DEFAULT_MAX_RESPONSE_MIB
      end

      raw_value = lsp["max_response_mib"]?
      return DEFAULT_MAX_RESPONSE_MIB unless raw_value
      value = raw_value.as_i?

      if value && value >= MIN_MAX_RESPONSE_MIB && value <= MAX_MAX_RESPONSE_MIB
        return value
      end

      warn_invalid(config_path, on_warning)
      DEFAULT_MAX_RESPONSE_MIB
    rescue ex
      warn_invalid(path.to_s, on_warning, ex)
      DEFAULT_MAX_RESPONSE_MIB
    end

    def self.save(path : String, max_response_mib : Int32) : Nil
      validate_max_response_mib(max_response_mib)
      root = read_config_root_for_update(path)
      lsp = if existing = root["lsp"]?
              existing.as_h? || raise "config key lsp must be an object: #{path}"
            else
              {} of String => JSON::Any
            end
      lsp["max_response_mib"] = JSON::Any.new(max_response_mib)
      root["lsp"] = JSON::Any.new(lsp)
      write_config_root(path, root)
    end

    def self.validate_max_response_mib(value : Int32) : Int32
      unless value >= MIN_MAX_RESPONSE_MIB && value <= MAX_MAX_RESPONSE_MIB
        raise ArgumentError.new("LSP response limit must be between #{MIN_MAX_RESPONSE_MIB} and #{MAX_MAX_RESPONSE_MIB} MiB")
      end
      value
    end

    def self.max_response_bytes(max_response_mib : Int32) : Int32
      validate_max_response_mib(max_response_mib)
      max_response_mib * 1024 * 1024
    end

    # Read an existing JSON object before an update.  Missing files start with
    # an empty object; malformed, oversized, or non-object files raise before
    # any write occurs so a settings action cannot destroy user configuration.
    def self.read_config_root_for_update(path : String) : Hash(String, JSON::Any)
      return {} of String => JSON::Any unless File.file?(path)
      read_config_root(path)
    end

    def self.write_config_root(path : String, root : Hash(String, JSON::Any)) : Nil
      config_path = Path.new(path)
      parent = config_path.parent.to_s
      Dir.mkdir_p(parent) unless parent.empty? || parent == "."

      temporary_file = File.tempfile(".#{config_path.basename}.tmp-", dir: parent.empty? ? "." : parent)
      temporary_path = temporary_file.path
      begin
        serialized = JSON::Any.new(root).to_json
        if serialized.bytesize > MAX_CONFIG_FILE_BYTES
          raise "serialized config file too large (limit #{MAX_CONFIG_FILE_BYTES} bytes): #{path}"
        end
        # File.tempfile creates an exclusive 0600 file in the target directory;
        # close it before the atomic rename.
        temporary_file.write(serialized.to_slice)
        temporary_file.close
        File.rename(temporary_path, config_path.to_s)
      rescue ex
        temporary_file.close rescue nil
        File.delete(temporary_path) if File.exists?(temporary_path)
        raise ex
      end
    end

    private def self.read_config_root(path : String) : Hash(String, JSON::Any)
      raw = read_json_with_limit(path)
      raw.as_h? || raise "config root must be a JSON object: #{path}"
    end

    private def self.warn_invalid_editing(path : String, field : String, reason : String, on_warning : Proc(String, Nil)?, error : Exception? = nil) : Nil
      detail = error ? " (#{error.class}: #{error.message})" : ""
      message = "Invalid editing setting #{field} in #{path}: #{reason}; using the safe default. Open F10 Settings to change it.#{detail}"
      on_warning.try &.call(message)
      STDERR.puts(message)
    end

    private def self.read_json_with_limit(path : String) : JSON::Any
      data = Bytes.new(MAX_CONFIG_FILE_BYTES + 1)
      bytes_read = 0
      File.open(path, "r") do |file|
        while bytes_read < data.size
          count = file.read(data[bytes_read, data.size - bytes_read])
          break if count == 0
          bytes_read += count
        end
      end
      raise "config file too large (limit #{MAX_CONFIG_FILE_BYTES} bytes): #{path}" if bytes_read > MAX_CONFIG_FILE_BYTES
      JSON.parse(String.new(data[0, bytes_read]))
    end

    private def self.warn_invalid(path : String, on_warning : Proc(String, Nil)?, error : Exception? = nil) : Nil
      detail = error ? " (#{error.class}: #{error.message})" : ""
      hint = "Invalid LSP response size setting; using #{DEFAULT_MAX_RESPONSE_MIB} MiB. Open F10 Settings to change it.#{detail}"
      location = "LSP settings config: #{path}"
      on_warning.try &.call(hint)
      on_warning.try &.call(location)
      STDERR.puts(hint)
      STDERR.puts(location)
    end
  end
end
