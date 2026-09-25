module Adamantine
  # A deliberately small, fail-closed EditorConfig reader.  It only reads
  # regular .editorconfig files and never executes or expands configuration
  # expressions outside the bounded glob subset below.
  module EditorConfig
    MAX_FILE_BYTES       = 64_i64 * 1024
    MAX_PATH_BYTES       =          4096
    MAX_ANCESTORS        =            32
    MAX_SECTIONS         =           128
    MAX_PATTERNS         =           256
    MAX_PATTERN_BYTES    =           256
    MAX_LINE_BYTES       =          4096
    MAX_LINES            =          4096
    MAX_MATCH_WORK       = 2_000_000_i64
    MAX_BRACE_EXPANSIONS =            16
    MAX_WARNINGS         =            64
    MAX_WARNING_BYTES    =           512
    DEFAULT_INDENT_WIDTH =             2
    MIN_INDENT_WIDTH     =             1
    MAX_INDENT_WIDTH     =             8

    # The nullable fields are overrides.  A nil value means that the global
    # editor default remains in force.  indent_size_tab preserves the valid
    # EditorConfig spelling "tab", which has no numeric representation.
    struct Resolution
      getter indent_style : String?
      getter indent_size : Int32?
      getter indent_size_tab : Bool
      getter tab_width : Int32?
      getter end_of_line : String?
      getter warnings : Array(String)

      def initialize(
        @indent_style : String? = nil,
        @indent_size : Int32? = nil,
        @indent_size_tab : Bool = false,
        @tab_width : Int32? = nil,
        @end_of_line : String? = nil,
        warnings : Array(String) = [] of String,
      )
        @warnings = warnings.dup
      end
    end

    alias Resolved = Resolution

    private class WarningSink
      getter values : Array(String)

      def initialize
        @values = [] of String
      end

      def add(message : String)
        return if @values.size >= MAX_WARNINGS
        clipped = message
        if clipped.bytesize > MAX_WARNING_BYTES
          clipped = String.build do |io|
            bytes = 0
            clipped.each_char do |char|
              break if bytes + char.bytesize > MAX_WARNING_BYTES
              io << char
              bytes += char.bytesize
            end
          end
        end
        @values << clipped
      end
    end

    private struct Property
      getter name : String
      getter value : String

      def initialize(@name : String, @value : String)
      end
    end

    private struct Section
      getter pattern : String
      getter properties : Array(Property)

      def initialize(@pattern : String, @properties : Array(Property))
      end
    end

    private struct ParsedConfig
      getter root : Bool
      getter sections : Array(Section)

      def initialize(@root : Bool, @sections : Array(Section))
      end
    end

    private class EffectiveValues
      property indent_style : String?
      property indent_size : Int32?
      property indent_size_tab : Bool
      property tab_width : Int32?
      property end_of_line : String?

      def initialize
        @indent_style = nil
        @indent_size = nil
        @indent_size_tab = false
        @tab_width = nil
        @end_of_line = nil
      end
    end

    private class MatchBudget
      getter exhausted : Bool

      def initialize(@remaining : Int64 = MAX_MATCH_WORK)
        @exhausted = false
      end

      def spend : Bool
        if @remaining <= 0
          @exhausted = true
          false
        else
          @remaining -= 1
          true
        end
      end
    end

    private struct GlobToken
      getter kind : Symbol
      getter value : Char?
      getter class_chars : String
      getter class_negated : Bool

      def initialize(
        @kind : Symbol,
        @value : Char? = nil,
        @class_chars : String = "",
        @class_negated : Bool = false,
      )
      end

      def epsilon? : Bool
        @kind == :star || @kind == :globstar || @kind == :globstar_dirs_start
      end
    end

    def self.resolve(path : String, default_width : Int32 = DEFAULT_INDENT_WIDTH) : Resolution
      resolve(Path.new(path), default_width)
    end

    def self.resolve(path : Path, default_width : Int32 = DEFAULT_INDENT_WIDTH) : Resolution
      warnings = WarningSink.new
      effective_default_width = default_width
      unless valid_width?(effective_default_width)
        warnings.add("default indent width is invalid; using #{DEFAULT_INDENT_WIDTH}")
        effective_default_width = DEFAULT_INDENT_WIDTH
      end

      expanded = path.expand
      if expanded.to_s.bytesize > MAX_PATH_BYTES
        warnings.add("EditorConfig path exceeds #{MAX_PATH_BYTES} bytes")
        return Resolution.new(warnings: warnings.values)
      end

      # The default width is intentionally validated even though this backend
      # returns only overrides.  It makes a caller's fallback choice explicit
      # and prevents an invalid global value from silently crossing the API.
      effective_default_width = effective_default_width.clamp(MIN_INDENT_WIDTH, MAX_INDENT_WIDTH)
      _ = effective_default_width

      target = expanded
      start_dir = target.parent
      if (info = File.info?(target.to_s, follow_symlinks: false)) && info.directory?
        start_dir = target
      end

      configs = [] of {Path, ParsedConfig}
      current = start_dir
      ancestor_truncated = true
      MAX_ANCESTORS.times do
        parsed = read_config(current / ".editorconfig", warnings)
        configs << {current, parsed}
        if parsed.root
          ancestor_truncated = false
          break
        end
        parent = current.parent
        if parent == current
          ancestor_truncated = false
          break
        end
        current = parent
      end
      warnings.add("EditorConfig ancestor limit reached") if ancestor_truncated

      values = EffectiveValues.new
      budget = MatchBudget.new
      patterns_seen = 0

      # configs is nearest-first.  Reverse order gives standard ancestor
      # precedence, while section order remains the source order in each file.
      configs.reverse_each do |entry|
        config_dir = entry[0]
        parsed = entry[1]
        relative = relative_path(config_dir, target)
        basename = basename_of(relative)

        parsed.sections.each do |section|
          if patterns_seen >= MAX_PATTERNS
            warnings.add("EditorConfig pattern limit reached")
            break
          end
          patterns_seen += 1

          if pattern_matches?(section.pattern, relative, basename, budget, warnings)
            section.properties.each do |property|
              apply_property(values, property, warnings)
            end
          end

          if budget.exhausted
            warnings.add("EditorConfig matching work limit reached")
            break
          end
        end

        break if patterns_seen >= MAX_PATTERNS || budget.exhausted
      end

      Resolution.new(
        indent_style: values.indent_style,
        indent_size: values.indent_size,
        indent_size_tab: values.indent_size_tab,
        tab_width: values.tab_width,
        end_of_line: values.end_of_line,
        warnings: warnings.values,
      )
    end

    private def self.valid_width?(width : Int32) : Bool
      width >= MIN_INDENT_WIDTH && width <= MAX_INDENT_WIDTH
    end

    private def self.read_config(path : Path, warnings : WarningSink) : ParsedConfig
      info = File.info?(path.to_s, follow_symlinks: false)
      return ParsedConfig.new(false, [] of Section) unless info

      if info.symlink?
        warnings.add("EditorConfig path is a symlink and was ignored: #{path}")
        return ParsedConfig.new(false, [] of Section)
      end
      unless info.file?
        warnings.add("EditorConfig path is not a regular file and was ignored: #{path}")
        return ParsedConfig.new(false, [] of Section)
      end
      if info.size > MAX_FILE_BYTES
        warnings.add("EditorConfig file exceeds #{MAX_FILE_BYTES} bytes: #{path}")
        return ParsedConfig.new(false, [] of Section)
      end

      bytes = Bytes.new((MAX_FILE_BYTES + 1).to_i)
      count = 0
      begin
        File.open(path.to_s, "rb") do |io|
          while count < bytes.size
            read = io.read(bytes[count, bytes.size - count])
            break if read == 0
            count += read
          end
        end
      rescue ex
        warnings.add("EditorConfig file could not be read: #{path}")
        return ParsedConfig.new(false, [] of Section)
      end

      if count > MAX_FILE_BYTES
        warnings.add("EditorConfig file exceeds #{MAX_FILE_BYTES} bytes: #{path}")
        return ParsedConfig.new(false, [] of Section)
      end

      text = String.new(bytes[0, count])
      unless text.valid_encoding?
        warnings.add("EditorConfig file is not valid UTF-8: #{path}")
        return ParsedConfig.new(false, [] of Section)
      end
      parse_config(text, path, warnings)
    end

    private def self.parse_config(text : String, path : Path, warnings : WarningSink) : ParsedConfig
      root = false
      sections = [] of Section
      current_pattern : String? = nil
      current_properties = [] of Property
      section_count = 0
      line_count = 0
      seen_section_header = false

      finish_section = -> do
        if pattern = current_pattern
          sections << Section.new(pattern, current_properties)
        end
        current_pattern = nil
        current_properties = [] of Property
      end

      text.each_line do |raw_line|
        line_count += 1
        if line_count > MAX_LINES
          warnings.add("EditorConfig line limit reached: #{path}")
          break
        end
        if raw_line.bytesize > MAX_LINE_BYTES
          warnings.add("EditorConfig line exceeds #{MAX_LINE_BYTES} bytes: #{path}")
          next
        end

        line = raw_line.strip
        if line_count == 1 && line.starts_with?("\uFEFF")
          line = line.byte_slice("\uFEFF".bytesize).not_nil!
        end
        next if line.empty? || line.starts_with?("#") || line.starts_with?(";")

        if line.starts_with?("[")
          seen_section_header = true
          finish_section.call
          unless line.ends_with?(']')
            warnings.add("EditorConfig section header is malformed: #{path}")
            next
          end
          pattern = line.byte_slice(1, line.bytesize - 2).not_nil!.strip
          if pattern.empty?
            warnings.add("EditorConfig section pattern is empty: #{path}")
            next
          end
          if pattern.bytesize > MAX_PATTERN_BYTES
            warnings.add("EditorConfig section pattern is too long: #{path}")
            next
          end
          section_count += 1
          if section_count > MAX_SECTIONS
            warnings.add("EditorConfig section limit reached: #{path}")
            next
          end
          current_pattern = pattern
          next
        end

        separator = line.index('=')
        unless separator
          warnings.add("EditorConfig property line is malformed: #{path}")
          next
        end
        key = line.byte_slice(0, separator).not_nil!.strip.downcase
        value = line.byte_slice(separator + 1).not_nil!.strip.downcase

        if !seen_section_header
          if key == "root"
            if value == "true"
              root = true
            elsif value == "false"
              root = false
            else
              warnings.add("EditorConfig root value is invalid: #{path}")
            end
          end
          next
        end

        if supported_property?(key)
          current_properties << Property.new(key, value)
        end
      end
      finish_section.call

      ParsedConfig.new(root, sections)
    end

    private def self.supported_property?(key : String) : Bool
      key == "indent_style" || key == "indent_size" || key == "tab_width" || key == "end_of_line"
    end

    private def self.apply_property(values : EffectiveValues, property : Property, warnings : WarningSink)
      name = property.name
      value = property.value
      case name
      when "indent_style"
        if value == "unset"
          values.indent_style = nil
        elsif value == "space" || value == "tab"
          values.indent_style = value
        else
          warnings.add("EditorConfig indent_style value is invalid: #{value}")
        end
      when "indent_size"
        if value == "unset"
          values.indent_size = nil
          values.indent_size_tab = false
        elsif value == "tab"
          values.indent_size = nil
          values.indent_size_tab = true
        elsif (parsed = small_integer(value))
          values.indent_size = parsed
          values.indent_size_tab = false
        else
          warnings.add("EditorConfig indent_size value is invalid or outside 1..8: #{value}")
        end
      when "tab_width"
        if value == "unset"
          values.tab_width = nil
        elsif (parsed = small_integer(value))
          values.tab_width = parsed
        else
          warnings.add("EditorConfig tab_width value is invalid or outside 1..8: #{value}")
        end
      when "end_of_line"
        if value == "unset"
          values.end_of_line = nil
        elsif value == "lf" || value == "crlf" || value == "cr"
          values.end_of_line = value
        else
          warnings.add("EditorConfig end_of_line value is invalid: #{value}")
        end
      end
    end

    private def self.small_integer(value : String) : Int32?
      return nil if value.empty? || value.bytesize > 3
      parsed = 0
      value.each_byte do |byte|
        return nil unless byte >= '0'.ord && byte <= '9'.ord
        parsed = parsed * 10 + (byte - '0'.ord)
        return nil if parsed > MAX_INDENT_WIDTH
      end
      return nil if parsed < MIN_INDENT_WIDTH
      parsed.to_i32
    end

    private def self.relative_path(base : Path, target : Path) : String
      base_string = base.to_s
      target_string = target.to_s
      if base_string == "/"
        target_string = target_string.byte_slice(1).not_nil! if target_string.starts_with?("/")
        return target_string
      end
      prefix = base_string.ends_with?("/") ? base_string : "#{base_string}/"
      if target_string.starts_with?(prefix)
        target_string.byte_slice(prefix.bytesize).not_nil!
      else
        basename_of(target_string)
      end
    end

    private def self.basename_of(path : String) : String
      slash = path.rindex('/')
      slash ? path.byte_slice(slash + 1).not_nil! : path
    end

    private def self.pattern_matches?(
      pattern : String,
      relative : String,
      basename : String,
      budget : MatchBudget,
      warnings : WarningSink,
    ) : Bool
      if pattern.includes?("\\")
        warnings.add("EditorConfig pattern uses unsupported escaping and was ignored: #{pattern}")
        return false
      end
      expanded_patterns = expand_braces(pattern, warnings)
      return false unless expanded_patterns

      expanded_patterns.not_nil!.each do |expanded|
        candidate = pattern_has_path_separator?(expanded) ? relative : basename
        tokens = tokenize(expanded, warnings)
        next unless tokens
        return true if glob_match(tokens.not_nil!, candidate, budget)
        return false if budget.exhausted
      end
      false
    end

    private def self.expand_braces(pattern : String, warnings : WarningSink) : Array(String)?
      return [pattern] of String unless braces_outside_class?(pattern)

      open = brace_open_index(pattern)
      unless open
        warnings.add("EditorConfig brace pattern is malformed and was ignored: #{pattern}")
        return nil
      end
      close = brace_close_index(pattern, open)
      unless close
        warnings.add("EditorConfig brace pattern is malformed and was ignored: #{pattern}")
        return nil
      end
      body = pattern.byte_slice(open + 1, close - open - 1).not_nil!
      if body.includes?("{") || body.includes?("}") || body.includes?("..")
        warnings.add("EditorConfig numeric or nested brace pattern is unsupported: #{pattern}")
        return nil
      end
      parts = body.split(',')
      if parts.size < 2 || parts.size > MAX_BRACE_EXPANSIONS
        warnings.add("EditorConfig brace expansion is unsupported or too large: #{pattern}")
        return nil
      end

      prefix = pattern.byte_slice(0, open).not_nil!
      suffix = pattern.byte_slice(close + 1).not_nil!
      result = [] of String
      parts.each do |part|
        nested = expand_braces("#{prefix}#{part}#{suffix}", warnings)
        return nil unless nested
        nested.not_nil!.each do |value|
          return nil if result.size >= MAX_BRACE_EXPANSIONS
          result << value
        end
      end
      result
    end

    private def self.braces_outside_class?(pattern : String) : Bool
      in_class = false
      pattern.each_char do |char|
        if char == '['
          in_class = true
        elsif char == ']'
          in_class = false
        elsif (char == '{' || char == '}') && !in_class
          return true
        end
      end
      false
    end

    private def self.brace_open_index(pattern : String) : Int32?
      in_class = false
      offset = 0
      pattern.each_char do |char|
        if char == '['
          in_class = true
        elsif char == ']'
          in_class = false
        elsif char == '{' && !in_class
          return offset
        end
        offset += char.bytesize
      end
      nil
    end

    private def self.brace_close_index(pattern : String, open : Int32) : Int32?
      in_class = false
      offset = open + 1
      pattern.byte_slice(open + 1).not_nil!.each_char do |char|
        if char == '['
          in_class = true
        elsif char == ']'
          in_class = false
        elsif char == '}' && !in_class
          return offset
        end
        offset += char.bytesize
      end
      nil
    end

    private def self.pattern_has_path_separator?(pattern : String) : Bool
      in_class = false
      pattern.each_char do |char|
        if char == '['
          in_class = true
        elsif char == ']'
          in_class = false
        elsif char == '/' && !in_class
          return true
        end
      end
      false
    end

    private def self.tokenize(pattern : String, warnings : WarningSink) : Array(GlobToken)?
      normalized = pattern.starts_with?("/") ? pattern.byte_slice(1).not_nil! : pattern
      tokens = [] of GlobToken
      chars = normalized.chars
      index = 0
      while index < chars.size
        char = chars[index]
        case char
        when '*'
          if index + 1 < chars.size && chars[index + 1] == '*'
            if index + 2 < chars.size && chars[index + 2] == '*'
              warnings.add("EditorConfig pattern has an unsupported wildcard run: #{pattern}")
              return nil
            end
            if index + 2 < chars.size && chars[index + 2] == '/'
              tokens << GlobToken.new(:globstar_dirs_start)
              tokens << GlobToken.new(:globstar_dirs_body)
              index += 3
            else
              tokens << GlobToken.new(:globstar)
              index += 2
            end
          else
            tokens << GlobToken.new(:star)
            index += 1
          end
        when '?'
          tokens << GlobToken.new(:any)
          index += 1
        when '['
          close = index + 1
          while close < chars.size && chars[close] != ']'
            close += 1
          end
          if close >= chars.size
            warnings.add("EditorConfig character class is malformed and was ignored: #{pattern}")
            return nil
          end
          body = String.build do |io|
            chars[(index + 1)...close].each { |body_char| io << body_char }
          end
          if body.empty?
            warnings.add("EditorConfig character class is empty and was ignored: #{pattern}")
            return nil
          end
          negated = body.starts_with?("!")
          body = body.byte_slice(1).not_nil! if negated
          if body.empty?
            warnings.add("EditorConfig character class is empty and was ignored: #{pattern}")
            return nil
          end
          # EditorConfig classes enumerate characters; a hyphen is literal,
          # not a range operator.  This avoids implicit range expansion.
          tokens << GlobToken.new(:class, nil, body, negated)
          index = close + 1
        else
          tokens << GlobToken.new(:literal, char)
          index += 1
        end
      end
      tokens
    end

    private def self.glob_match(tokens : Array(GlobToken), text : String, budget : MatchBudget) : Bool
      active = Array(Bool).new(tokens.size + 1, false)
      active[0] = true
      epsilon_closure!(active, tokens, budget)
      return false if budget.exhausted

      text.each_char do |char|
        next_active = Array(Bool).new(tokens.size + 1, false)
        index = 0
        while index < tokens.size
          unless budget.spend
            return false
          end
          if active[index]
            token = tokens[index]
            case token.kind
            when :literal
              next_active[index + 1] = true if token.value == char
            when :any
              next_active[index + 1] = true unless char == '/'
            when :class
              next_active[index + 1] = true if class_matches?(token, char)
            when :star
              next_active[index] = true unless char == '/'
            when :globstar
              next_active[index] = true
            when :globstar_dirs_start
              if char == '/'
                # A leading separator can be consumed by the directory
                # wildcard itself; the following pattern starts afterwards.
                next_active[index + 2] = true
              else
                next_active[index + 1] = true
              end
            when :globstar_dirs_body
              if char == '/'
                # A directory boundary makes the following pattern eligible,
                # while the start state permits another directory segment.
                next_active[index - 1] = true
                next_active[index + 1] = true
              else
                next_active[index] = true
              end
            end
          end
          index += 1
        end
        epsilon_closure!(next_active, tokens, budget)
        return false if budget.exhausted
        active = next_active
      end

      epsilon_closure!(active, tokens, budget)
      !budget.exhausted && active[tokens.size]
    end

    private def self.epsilon_closure!(active : Array(Bool), tokens : Array(GlobToken), budget : MatchBudget)
      index = 0
      while index < tokens.size
        unless budget.spend
          return
        end
        if active[index] && tokens[index].epsilon?
          if tokens[index].kind == :globstar_dirs_start
            active[index + 2] = true
          else
            active[index + 1] = true
          end
        end
        index += 1
      end
    end

    private def self.class_matches?(token : GlobToken, char : Char) : Bool
      matched = token.class_chars.includes?(char)
      token.class_negated ? !matched && char != '/' : matched
    end
  end
end
