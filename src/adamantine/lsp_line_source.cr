require "crystal_tui"

module Adamantine
  # A read-only view of one document revision for LSP post-processing.  The
  # array constructor keeps the existing helper APIs compatible; the snapshot
  # constructor retains only the persistent piece-tree root and emits one
  # logical line at a time when a consumer asks for it.
  module BufferLines
    class Source
      alias Snapshot = Tui::PieceTreeBuffer::Snapshot

      @lines : Array(String)?
      @snapshot : Snapshot?

      def initialize(lines : Array(String))
        @lines = lines
        @snapshot = nil
      end

      def initialize(snapshot : Snapshot)
        @lines = nil
        @snapshot = snapshot
      end

      # Yield each logical line with its zero-based line number.  The snapshot
      # path does not retain emitted lines after the callback returns.
      def each_line(&block : String, Int32 -> Nil) : Nil
        if lines = @lines
          lines.each_with_index { |line, index| yield line, index }
        elsif snapshot = @snapshot
          reader = LineReader.new(block)
          snapshot.write_to(reader)
          reader.finish
        end
      end

      # Yield line lengths without constructing line strings.  This is the
      # normal path for overlay storage, whose rows need only their lengths.
      def each_line_length(&block : Int32, Int32 -> Nil) : Nil
        if lines = @lines
          lines.each_with_index { |line, index| yield line.size, index }
        elsif snapshot = @snapshot
          reader = LineLengthReader.new(block)
          snapshot.write_to(reader)
          reader.finish
        end
      end

      def line_count : Int32
        count = 0
        each_line_length { |_length, _index| count += 1 }
        count
      end

      private class LineReader < IO
        CR = '\r'.ord.to_u8
        LF = '\n'.ord.to_u8

        def initialize(@callback : Proc(String, Int32, Nil))
          @line = IO::Memory.new
          @line_index = 0
          @pending_cr = false
        end

        def read(slice : Bytes) : Int32
          raise IO::Error.new("line reader is write-only")
        end

        def write(slice : Bytes) : Nil
          slice.each do |byte|
            if @pending_cr
              if byte == LF
                emit_line
                @pending_cr = false
                next
              end

              emit_line
              @pending_cr = false
            end

            case byte
            when CR
              @pending_cr = true
            when LF
              emit_line
            else
              @line.write_byte(byte)
            end
          end
        end

        def finish : Nil
          emit_line if @pending_cr
          @pending_cr = false
          # A document always has a final logical line, including after a
          # final LF, CRLF, or lone CR.
          emit_line
        end

        private def emit_line : Nil
          @callback.call(@line.to_s, @line_index)
          @line_index += 1
          @line.clear
        end
      end

      private class LineLengthReader < IO
        CR = '\r'.ord.to_u8
        LF = '\n'.ord.to_u8

        def initialize(@callback : Proc(Int32, Int32, Nil))
          @line_index = 0
          @length = 0
          @pending_cr = false
        end

        def read(slice : Bytes) : Int32
          raise IO::Error.new("line-length reader is write-only")
        end

        def write(slice : Bytes) : Nil
          slice.each do |byte|
            if @pending_cr
              if byte == LF
                emit_line
                @pending_cr = false
                next
              end

              emit_line
              @pending_cr = false
            end

            case byte
            when CR
              @pending_cr = true
            when LF
              emit_line
            else
              @length += 1 unless byte & 0xc0 == 0x80
            end
          end
        end

        def finish : Nil
          emit_line if @pending_cr
          @pending_cr = false
          emit_line
        end

        private def emit_line : Nil
          @callback.call(@length, @line_index)
          @line_index += 1
          @length = 0
        end
      end
    end
  end
end
