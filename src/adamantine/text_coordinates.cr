require "crystal_tui"

module Adamantine
  # Conversion at the LSP boundary.  Editor columns remain codepoint indexes;
  # only the values sent to or consumed from LSP are UTF-16 code-unit columns.
  module TextCoordinates
    # App-owned editors implement this with a one-line PieceTree lookup.  Do
    # not implement it with TextEditor#text or TextEditor#lines: those are
    # compatibility materializers for the whole document.
    module LineProvider
      abstract def line_text(line : Int32) : String
    end

    # Optional hot-path adapter for codepoint -> UTF-16 conversion.  The
    # PieceTree implementation can answer this without materializing the line
    # or scanning every preceding character for each visible cell.
    module Utf16ColumnProvider
      abstract def line_utf16_column(line : Int32, column : Int32) : Int32
    end

    struct Position
      getter line : Int32
      getter column : Int32

      def initialize(@line : Int32, @column : Int32)
      end
    end

    # Convert an editor codepoint column to the UTF-16 column expected by LSP.
    # This strict form is used for mutation/request coordinates and therefore
    # rejects negative and out-of-range columns.
    def self.codepoint_to_utf16(line : String, column : Int32) : Int32
      validate_line!(line)
      raise ArgumentError.new("negative codepoint column") if column < 0
      raise ArgumentError.new("codepoint column outside line") if column > line.size

      units = 0_i64
      codepoints = 0
      line.each_char do |char|
        break if codepoints == column
        units += char.ord > 0xffff ? 2 : 1
        codepoints += 1
      end
      raise ArgumentError.new("codepoint column outside line") unless codepoints == column
      raise ArgumentError.new("UTF-16 column exceeds Int32") if units > Int32::MAX
      units.to_i32
    end

    # Convert an LSP UTF-16 column back to an editor codepoint column.
    # `clamp: true` is reserved for read-only navigation/display consumers:
    # an oversized column maps to the line end, while a column in the middle
    # of a surrogate pair remains malformed and is rejected.
    def self.utf16_to_codepoint(line : String, column : Int32, *, clamp : Bool = false) : Int32
      validate_line!(line)
      raise ArgumentError.new("negative UTF-16 column") if column < 0

      target = column.to_i64
      units = 0_i64
      codepoints = 0
      line.each_char do |char|
        return codepoints if units == target

        width = char.ord > 0xffff ? 2_i64 : 1_i64
        if target < units + width
          raise ArgumentError.new("UTF-16 column falls inside a surrogate pair")
        end

        units += width
        codepoints += 1
      end

      return codepoints if units == target
      return codepoints if clamp && target > units
      raise ArgumentError.new("UTF-16 column outside line")
    end

    # The editor overloads are deliberately adapter-based.  A caller that has
    # only a bare Tui::TextEditor must opt into a one-line provider rather than
    # silently paying for a document-sized `lines` snapshot.
    def self.codepoint_to_utf16(editor : Tui::TextEditor, line : Int32, column : Int32) : Int32
      raise ArgumentError.new("negative line") if line < 0
      raise ArgumentError.new("negative codepoint column") if column < 0

      if provider = editor.as?(Utf16ColumnProvider)
        return provider.line_utf16_column(line, column)
      end

      codepoint_to_utf16(line_text(editor, line), column)
    end

    def self.utf16_to_codepoint(
      editor : Tui::TextEditor,
      line : Int32,
      column : Int32,
      *,
      clamp : Bool = false,
    ) : Int32
      raise ArgumentError.new("negative line") if line < 0
      utf16_to_codepoint(line_text(editor, line), column, clamp: clamp)
    end

    def self.position(
      editor : Tui::TextEditor,
      line : Int32,
      character : Int32,
      *,
      clamp : Bool = false,
    ) : Position
      Position.new(line, utf16_to_codepoint(editor, line, character, clamp: clamp))
    end

    private def self.line_text(editor : Tui::TextEditor, line : Int32) : String
      provider = editor.as?(LineProvider)
      raise ArgumentError.new("editor does not expose a one-line coordinate adapter") unless provider

      begin
        provider.line_text(line)
      rescue IndexError
        raise ArgumentError.new("line outside editor")
      end
    end

    private def self.validate_line!(line : String) : Nil
      raise ArgumentError.new("line is not valid UTF-8") unless line.valid_encoding?
    end
  end
end
