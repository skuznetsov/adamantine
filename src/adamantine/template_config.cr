require "json"
require "set"
require "./snippet_parser"

module Adamantine
  # Read-only loader for user and project editor templates.
  #
  # The JSON format is `{"version":1,"templates":[...]}`. Each template
  # requires a `trigger` and a `body`; optional `label`, `description`, and
  # `languages` fields supply display and language-filter metadata. Bodies are
  # parsed by the editor's bounded snippet subset parser and must use LF line
  # endings, because the editor normalizes CRLF before applying parsed offsets.
  # This loader never evaluates configuration text or writes config files.
  module TemplateConfig
    MAX_FILE_BYTES        = 65_536
    MAX_JSON_DEPTH        =     32
    MAX_PATH_BYTES        =  4_096
    MAX_TEMPLATES         =    128
    MAX_TRIGGER_BYTES     =     64
    MAX_BODY_BYTES        = 16_384
    MAX_LABEL_BYTES       =    128
    MAX_DESCRIPTION_BYTES =    512
    MAX_LANGUAGES         =     32
    MAX_LANGUAGE_BYTES    =     64
    MAX_DIAGNOSTICS       =     64
    MAX_DIAGNOSTIC_BYTES  =    512
    MAX_DIAGNOSTIC_PATH   =    256

    struct Entry
      getter trigger : String
      getter body : String
      getter label : String
      getter description : String
      @parsed : Snippet::ParseResult
      @languages : Array(String)

      def initialize(
        @trigger : String,
        @body : String,
        @parsed : Snippet::ParseResult,
        @label : String,
        @description : String,
        languages : Array(String),
      )
        @languages = languages.dup
      end

      def parsed : Snippet::ParseResult
        Snippet::ParseResult.new(@parsed.text, @parsed.tabstops.dup, @parsed.explicit_final_stop?)
      end

      def languages : Array(String)
        @languages.dup
      end

      def supports_language?(language : String) : Bool
        @languages.empty? || @languages.includes?(language.downcase)
      end
    end

    struct Diagnostic
      getter source : String
      getter path : String
      getter message : String

      def initialize(@source : String, path : String, message : String)
        @path = clip(path, MAX_DIAGNOSTIC_PATH)
        @message = clip(message, MAX_DIAGNOSTIC_BYTES)
      end

      private def clip(value : String, max_bytes : Int32) : String
        return value if value.bytesize <= max_bytes
        String.build do |io|
          bytes = 0
          value.each_char do |char|
            break if bytes + char.bytesize > max_bytes - 3
            io << char
            bytes += char.bytesize
          end
          io << "..."
        end
      end
    end

    struct LoadResult
      @entries : Array(Entry)
      @diagnostics : Array(Diagnostic)

      def initialize(entries : Array(Entry), diagnostics : Array(Diagnostic))
        @entries = entries.dup
        @diagnostics = diagnostics.dup
      end

      def entries : Array(Entry)
        @entries.dup
      end

      def diagnostics : Array(Diagnostic)
        @diagnostics.dup
      end

      # Project entries precede user entries in the merged list. Return one
      # entry per trigger, so a project-specific template wins over a
      # user-defined all-language fallback only for the selected language.
      def for_language(language : String) : Array(Entry)
        selected = [] of Entry
        seen_triggers = Set(String).new
        @entries.each do |entry|
          next unless entry.supports_language?(language)
          next unless seen_triggers.add?(entry.trigger)
          selected << entry
        end
        selected
      end
    end

    private class FileTooLarge < Exception
    end

    def self.user_path(home : String? = ENV["HOME"]?) : String?
      return nil unless home && !home.empty?
      Path.new(home, ".config", "adamantine", "templates.json").to_s
    end

    def self.project_path(project_root : String?) : String?
      return nil unless project_root && !project_root.empty?
      Path.new(project_root, ".adamantine", "templates.json").to_s
    end

    # Load optional files with project precedence for overlapping
    # trigger/language scopes. A project entry narrows a user's explicit
    # language list; an all-language user entry remains as fallback beneath a
    # project-specific override. Invalid project entries are skipped.
    def self.load(user_path : String? = nil, project_path : String? = nil) : LoadResult
      user_entries, user_diagnostics = read_source(user_path, "user")
      project_entries, project_diagnostics = read_source(project_path, "project")

      remaining_user_entries = user_entries.reject do |user_entry|
        overridden_languages = project_entries.select { |entry| entry.trigger == user_entry.trigger }
        overridden_languages.any? { |project_entry| project_entry.languages.empty? }
      end
      remaining_user_entries = remaining_user_entries.flat_map do |user_entry|
        overrides = project_entries.select { |entry| entry.trigger == user_entry.trigger }
        if user_entry.languages.empty? || overrides.empty?
          [user_entry]
        else
          remaining_languages = user_entry.languages.reject do |language|
            overrides.any? { |entry| entry.languages.includes?(language) }
          end
          if remaining_languages.empty?
            [] of Entry
          elsif remaining_languages == user_entry.languages
            [user_entry]
          else
            [Entry.new(
              user_entry.trigger,
              user_entry.body,
              user_entry.parsed,
              user_entry.label,
              user_entry.description,
              remaining_languages
            )]
          end
        end
      end
      entries = project_entries + remaining_user_entries

      diagnostics = user_diagnostics + project_diagnostics
      LoadResult.new(entries, diagnostics)
    end

    private def self.read_source(path : String?, source : String) : {Array(Entry), Array(Diagnostic)}
      entries = [] of Entry
      diagnostics = [] of Diagnostic
      return {entries, diagnostics} unless path
      return {entries, diagnostics} if path.empty?

      if path.bytesize > MAX_PATH_BYTES
        add_diagnostic(diagnostics, source, path, "template config path exceeds #{MAX_PATH_BYTES} bytes")
        return {entries, diagnostics}
      end

      return {entries, diagnostics} unless File.exists?(path)
      unless File.file?(path)
        add_diagnostic(diagnostics, source, path, "template config path is not a regular file")
        return {entries, diagnostics}
      end

      begin
        data = read_bounded_file(path)
        parse_source(data, path, source, entries, diagnostics)
      rescue FileTooLarge
        add_diagnostic(diagnostics, source, path, "template config exceeds #{MAX_FILE_BYTES} bytes")
      rescue
        add_diagnostic(diagnostics, source, path, "template config could not be read as JSON")
      end

      {entries, diagnostics}
    end

    private def self.read_bounded_file(path : String) : String
      data = Bytes.new(MAX_FILE_BYTES + 1)
      bytes_read = 0
      File.open(path, "r") do |file|
        while bytes_read < data.size
          count = file.read(data[bytes_read, data.size - bytes_read])
          break if count == 0
          bytes_read += count
        end
      end
      raise FileTooLarge.new if bytes_read > MAX_FILE_BYTES
      String.new(data[0, bytes_read])
    end

    private def self.parse_source(
      data : String,
      path : String,
      source : String,
      entries : Array(Entry),
      diagnostics : Array(Diagnostic),
    ) : Nil
      if json_depth_exceeded?(data)
        add_diagnostic(diagnostics, source, path, "template config nesting depth exceeds #{MAX_JSON_DEPTH}")
        return
      end

      root = JSON.parse(data).as_h?
      unless root
        add_diagnostic(diagnostics, source, path, "template config root must be an object")
        return
      end

      unknown_root_key = root.keys.find { |key| key != "version" && key != "templates" }
      if unknown_root_key
        add_diagnostic(diagnostics, source, path, "unknown template config field: #{unknown_root_key}")
        return
      end

      version = root["version"]?.try(&.as_i?)
      unless version == 1
        add_diagnostic(diagnostics, source, path, "template config version must be 1")
        return
      end

      raw_templates = root["templates"]?.try(&.as_a?)
      unless raw_templates
        add_diagnostic(diagnostics, source, path, "template config templates must be an array")
        return
      end
      if raw_templates.size > MAX_TEMPLATES
        add_diagnostic(diagnostics, source, path, "template count exceeds #{MAX_TEMPLATES}")
        return
      end

      seen_entries = [] of Entry
      raw_templates.each_with_index do |raw_entry, index|
        parse_entry(raw_entry, index + 1, path, source, seen_entries, entries, diagnostics)
      end
    rescue JSON::ParseException
      add_diagnostic(diagnostics, source, path, "template config contains invalid JSON")
    end

    private def self.json_depth_exceeded?(data : String) : Bool
      depth = 0
      in_string = false
      escaped = false
      data.each_byte do |byte|
        if in_string
          if escaped
            escaped = false
          elsif byte == 92
            escaped = true
          elsif byte == 34
            in_string = false
          end
          next
        end

        case byte
        when 34
          in_string = true
        when 91, 123
          depth += 1
          return true if depth > MAX_JSON_DEPTH
        when 93, 125
          depth -= 1 if depth > 0
        end
      end
      false
    end

    private def self.parse_entry(
      raw_entry : JSON::Any,
      index : Int32,
      path : String,
      source : String,
      seen_entries : Array(Entry),
      entries : Array(Entry),
      diagnostics : Array(Diagnostic),
    ) : Nil
      object = raw_entry.as_h?
      unless object
        add_entry_diagnostic(diagnostics, source, path, index, "expected an object")
        return
      end

      unknown_key = object.keys.find do |key|
        key != "trigger" && key != "body" && key != "label" && key != "description" && key != "languages"
      end
      if unknown_key
        add_entry_diagnostic(diagnostics, source, path, index, "unknown field #{unknown_key}")
        return
      end

      trigger = object["trigger"]?.try(&.as_s?)
      unless trigger && valid_trigger?(trigger)
        add_entry_diagnostic(diagnostics, source, path, index, "trigger must be 1-#{MAX_TRIGGER_BYTES} ASCII letters, digits, dot, underscore, or hyphen, starting with a letter or digit")
        return
      end

      body = object["body"]?.try(&.as_s?)
      unless body && !body.strip.empty? && body.bytesize <= MAX_BODY_BYTES
        add_entry_diagnostic(diagnostics, source, path, index, "body must be non-empty and at most #{MAX_BODY_BYTES} bytes")
        return
      end
      if body.includes?('\r')
        add_entry_diagnostic(diagnostics, source, path, index, "body must not contain a carriage return; use LF line endings")
        return
      end
      if body.each_char.any? { |char| forbidden_control?(char) }
        add_entry_diagnostic(diagnostics, source, path, index, "body must not contain a terminal control character; tabs and LF are allowed")
        return
      end

      label = trigger
      if raw_label = object["label"]?
        parsed_label = raw_label.as_s?
        unless parsed_label && !parsed_label.empty? && parsed_label.bytesize <= MAX_LABEL_BYTES
          add_entry_diagnostic(diagnostics, source, path, index, "label must be a non-empty string of at most #{MAX_LABEL_BYTES} bytes")
          return
        end
        if parsed_label.each_char.any? { |char| picker_control?(char) }
          add_entry_diagnostic(diagnostics, source, path, index, "label must not contain a terminal control character")
          return
        end
        label = parsed_label
      end

      description = ""
      if raw_description = object["description"]?
        parsed_description = raw_description.as_s?
        unless parsed_description && parsed_description.bytesize <= MAX_DESCRIPTION_BYTES
          add_entry_diagnostic(diagnostics, source, path, index, "description must be a string of at most #{MAX_DESCRIPTION_BYTES} bytes")
          return
        end
        if parsed_description.each_char.any? { |char| picker_control?(char) }
          add_entry_diagnostic(diagnostics, source, path, index, "description must not contain a terminal control character")
          return
        end
        description = parsed_description
      end

      languages = parse_languages(object["languages"]?, index, path, source, diagnostics)
      return unless languages

      outcome = Snippet::Parser.parse(body)
      unless parsed = outcome.result
        reason = outcome.error.to_s.downcase
        add_entry_diagnostic(diagnostics, source, path, index, "snippet body is unsupported or invalid (#{reason})")
        return
      end

      entry = Entry.new(trigger, body, parsed, label, description, languages)
      if seen_entries.any? { |seen| duplicate_scope?(seen, entry) }
        add_entry_diagnostic(diagnostics, source, path, index, "duplicate trigger #{trigger} in an overlapping language scope; the first valid entry wins")
        return
      end

      seen_entries << entry
      entries << entry
    end

    private def self.duplicate_scope?(left : Entry, right : Entry) : Bool
      return false unless left.trigger == right.trigger
      return true if left.languages.empty? || right.languages.empty?
      left.languages.any? { |language| right.languages.includes?(language) }
    end

    private def self.parse_languages(
      raw_languages : JSON::Any?,
      index : Int32,
      path : String,
      source : String,
      diagnostics : Array(Diagnostic),
    ) : Array(String)?
      return [] of String unless raw_languages
      values = raw_languages.as_a?
      unless values
        add_entry_diagnostic(diagnostics, source, path, index, "languages must be an array of language identifiers")
        return nil
      end
      if values.size > MAX_LANGUAGES
        add_entry_diagnostic(diagnostics, source, path, index, "languages may contain at most #{MAX_LANGUAGES} identifiers")
        return nil
      end

      languages = [] of String
      values.each do |raw_language|
        language = raw_language.as_s?
        unless language && valid_language?(language)
          add_entry_diagnostic(diagnostics, source, path, index, "languages must use valid identifiers of at most #{MAX_LANGUAGE_BYTES} bytes")
          return nil
        end
        normalized = language.downcase
        if languages.includes?(normalized)
          add_entry_diagnostic(diagnostics, source, path, index, "languages contains duplicate identifier #{normalized}")
          return nil
        end
        languages << normalized
      end
      languages
    end

    private def self.valid_trigger?(value : String) : Bool
      return false if value.empty? || value.bytesize > MAX_TRIGGER_BYTES
      first = value.byte_at(0)
      return false unless ascii_letter?(first) || ascii_digit?(first)
      value.each_byte.all? { |byte| ascii_letter?(byte) || ascii_digit?(byte) || byte == '.'.ord || byte == '_'.ord || byte == '-'.ord }
    end

    private def self.valid_language?(value : String) : Bool
      return false if value.empty? || value.bytesize > MAX_LANGUAGE_BYTES
      first = value.byte_at(0)
      return false unless ascii_letter?(first)
      value.each_byte.all? do |byte|
        ascii_letter?(byte) || ascii_digit?(byte) || byte == '_'.ord || byte == '-'.ord || byte == '+'.ord || byte == '#'.ord || byte == '.'.ord
      end
    end

    private def self.forbidden_control?(char : Char) : Bool
      codepoint = char.ord
      (codepoint < 0x20 && char != '\n' && char != '\t') || (0x7f..0x9f).includes?(codepoint)
    end

    private def self.picker_control?(char : Char) : Bool
      char.ord < 0x20 || (0x7f..0x9f).includes?(char.ord)
    end

    private def self.ascii_letter?(byte : UInt8) : Bool
      (byte >= 'a'.ord && byte <= 'z'.ord) || (byte >= 'A'.ord && byte <= 'Z'.ord)
    end

    private def self.ascii_digit?(byte : UInt8) : Bool
      byte >= '0'.ord && byte <= '9'.ord
    end

    private def self.add_entry_diagnostic(
      diagnostics : Array(Diagnostic),
      source : String,
      path : String,
      index : Int32,
      message : String,
    ) : Nil
      add_diagnostic(diagnostics, source, path, "entry #{index}: #{message}")
    end

    private def self.add_diagnostic(diagnostics : Array(Diagnostic), source : String, path : String, message : String) : Nil
      if diagnostics.size < MAX_DIAGNOSTICS - 1
        diagnostics << Diagnostic.new(source, path, message)
      elsif diagnostics.size == MAX_DIAGNOSTICS - 1
        diagnostics << Diagnostic.new(source, path, "additional template diagnostics omitted")
      end
    end
  end
end
