module Adamantine
  module Snippet
    # This is an editor-internal subset parser. It does not implement the
    # complete LSP snippet grammar or imply snippetSupport capability.
    enum ParseError
      Malformed
      UnsupportedSyntax
      RepeatedIndex
      TooManyTabstops
      SourceTooLarge
      ExpandedTextTooLarge
      IndexTooLarge
      InvalidEscape
    end

    struct Tabstop
      getter index : Int32
      getter start_offset : Int32
      getter end_offset : Int32

      # Offsets are Unicode codepoint offsets in the final inserted text.
      def initialize(@index : Int32, @start_offset : Int32, @end_offset : Int32)
      end
    end

    struct ParseResult
      getter text : String
      getter tabstops : Array(Tabstop)
      getter explicit_final_stop : Bool

      def initialize(@text : String, @tabstops : Array(Tabstop), @explicit_final_stop : Bool)
      end

      def explicit_final_stop? : Bool
        @explicit_final_stop
      end
    end

    struct ParseOutcome
      getter result : ParseResult?
      getter error : ParseError?

      def initialize(@result : ParseResult?, @error : ParseError?)
      end

      def success? : Bool
        !@result.nil?
      end
    end

    class Parser
      # Keep parsing independent of the LSP transport's separate completion cap.
      MAX_SOURCE_BYTES        = 65_536
      MAX_EXPANDED_TEXT_BYTES = 65_536
      MAX_TABSTOPS            =     64
      MAX_INDEX               =    999

      @characters : Array(Char)
      @cursor : Int32
      @output : String::Builder
      @output_bytes : Int32
      @output_codepoints : Int32
      @tabstops : Array(Tabstop)
      @error : ParseError?
      @explicit_final_stop : Bool

      def self.parse(source : String) : ParseOutcome
        new(source).parse
      end

      def initialize(@source : String)
        @characters = [] of Char
        @cursor = 0
        @output = String::Builder.new
        @output_bytes = 0
        @output_codepoints = 0
        @tabstops = [] of Tabstop
        @error = nil
        @explicit_final_stop = false
      end

      def parse : ParseOutcome
        return failure(ParseError::SourceTooLarge) if @source.bytesize > MAX_SOURCE_BYTES

        @characters = @source.each_char.to_a
        while @cursor < @characters.size
          char = @characters[@cursor]
          case char
          when '\\'
            return failure(@error.not_nil!) unless parse_escape
          when '$'
            return failure(@error.not_nil!) unless parse_dollar
          else
            return failure(@error.not_nil!) unless append(char)
            @cursor += 1
          end
        end

        return failure(@error.not_nil!) if @error

        unless @explicit_final_stop
          return failure(ParseError::TooManyTabstops) if @tabstops.size >= MAX_TABSTOPS
          @tabstops << Tabstop.new(0, @output_codepoints, @output_codepoints)
        end

        @tabstops.sort_by! { |tabstop| tabstop.index == 0 ? Int32::MAX : tabstop.index }
        success(ParseResult.new(@output.to_s, @tabstops, @explicit_final_stop))
      end

      private def parse_dollar : Bool
        @cursor += 1
        return set_error(ParseError::Malformed) if @cursor >= @characters.size

        next_char = @characters[@cursor]
        if next_char.ascii_number?
          index = parse_index
          return false unless index
          return add_tabstop(index.not_nil!, @output_codepoints, @output_codepoints)
        end

        return set_error(ParseError::UnsupportedSyntax) unless next_char == '{'

        @cursor += 1
        return set_error(ParseError::Malformed) if @cursor >= @characters.size
        char = @characters[@cursor]
        unless char.ascii_number?
          return set_error(ParseError::Malformed) if char == '}'
          return set_error(ParseError::UnsupportedSyntax)
        end

        index = parse_index
        return false unless index
        return set_error(ParseError::Malformed) if @cursor >= @characters.size

        case @characters[@cursor]
        when '}'
          @cursor += 1
          add_tabstop(index.not_nil!, @output_codepoints, @output_codepoints)
        when ':'
          @cursor += 1
          parse_default(index.not_nil!)
        when '|', '/'
          set_error(ParseError::UnsupportedSyntax)
        else
          set_error(ParseError::Malformed)
        end
      end

      private def parse_index : Int32?
        value = 0
        while @cursor < @characters.size && (char = @characters[@cursor]).ascii_number?
          digit = char.ord - '0'.ord
          return error_value(ParseError::IndexTooLarge) if value > (MAX_INDEX - digit) // 10
          value = value * 10 + digit
          @cursor += 1
        end
        value
      end

      private def parse_default(index : Int32) : Bool
        start_offset = @output_codepoints
        while @cursor < @characters.size
          char = @characters[@cursor]
          case char
          when '\\'
            return false unless parse_escape
          when '$'
            # Nested tabstops, variables, and transformations need more grammar
            # and linked-edit behavior than this bounded parser provides.
            return set_error(ParseError::UnsupportedSyntax)
          when '}'
            @cursor += 1
            return add_tabstop(index, start_offset, @output_codepoints)
          else
            return false unless append(char)
            @cursor += 1
          end
        end

        set_error(ParseError::Malformed)
      end

      private def parse_escape : Bool
        return set_error(ParseError::InvalidEscape) if @cursor + 1 >= @characters.size

        escaped = @characters[@cursor + 1]
        unless escaped == '$' || escaped == '}' || escaped == '\\'
          return set_error(ParseError::InvalidEscape)
        end

        return false unless append(escaped)
        @cursor += 2
        true
      end

      private def append(char : Char) : Bool
        bytesize = char.to_s.bytesize
        if @output_bytes + bytesize > MAX_EXPANDED_TEXT_BYTES
          return set_error(ParseError::ExpandedTextTooLarge)
        end

        @output << char
        @output_bytes += bytesize
        @output_codepoints += 1
        true
      end

      private def add_tabstop(index : Int32, start_offset : Int32, end_offset : Int32) : Bool
        if @tabstops.any? { |tabstop| tabstop.index == index }
          return set_error(ParseError::RepeatedIndex)
        end
        return set_error(ParseError::TooManyTabstops) if @tabstops.size >= MAX_TABSTOPS

        @tabstops << Tabstop.new(index, start_offset, end_offset)
        @explicit_final_stop = true if index == 0
        true
      end

      private def set_error(error : ParseError) : Bool
        @error = error
        false
      end

      private def error_value(error : ParseError) : Int32?
        @error = error
        nil
      end

      private def success(result : ParseResult) : ParseOutcome
        ParseOutcome.new(result, nil)
      end

      private def failure(error : ParseError) : ParseOutcome
        ParseOutcome.new(nil, error)
      end
    end
  end
end
