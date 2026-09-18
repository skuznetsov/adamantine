module Adamantine
  struct EditingSettings
    DEFAULT_INDENT_WIDTH = 2
    DEFAULT_AUTO_INDENT  = true
    MIN_INDENT_WIDTH     = 1
    MAX_INDENT_WIDTH     = 8

    getter indent_width : Int32
    getter auto_indent : Bool

    def initialize(@indent_width : Int32 = DEFAULT_INDENT_WIDTH, @auto_indent : Bool = DEFAULT_AUTO_INDENT)
      validate_indent_width(@indent_width)
    end

    private def validate_indent_width(value : Int32) : Nil
      unless value >= MIN_INDENT_WIDTH && value <= MAX_INDENT_WIDTH
        raise ArgumentError.new("indent_width must be between #{MIN_INDENT_WIDTH} and #{MAX_INDENT_WIDTH}")
      end
    end
  end
end
