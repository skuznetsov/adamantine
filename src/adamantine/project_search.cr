module Adamantine
  module ProjectSearch
    SKIP_DIR_NAMES = Set{
      ".git", ".hg", ".svn",
      ".crystal-cache", ".agents", ".crystal_ball",
      "node_modules", "target", "vendor", ".build",
    }

    MAX_DEPTH        =        16
    MAX_FILE_BYTES   = 1_048_576
    MAX_FILES        =      1500
    MAX_MATCHES      =        40
    MAX_MENU         =        12
    SNIPPET_MAX      =        72
    READ_CHUNK_BYTES = 16 * 1024

    class Cancellation
      @cancelled = Atomic(Bool).new(false)

      def cancel : Nil
        @cancelled.set(true)
      end

      def cancelled? : Bool
        @cancelled.get
      end
    end

    struct Match
      getter path : Path
      getter line : Int32
      getter col : Int32
      getter snippet : String

      def initialize(@path : Path, @line : Int32, @col : Int32, @snippet : String)
      end
    end

    struct Result
      getter matches : Array(Match)
      getter files_scanned : Int32
      getter truncated : Bool
      getter incomplete : Bool
      getter cancelled : Bool

      def initialize(@matches : Array(Match), @files_scanned : Int32, @truncated : Bool, @cancelled : Bool = false)
        @incomplete = @truncated || @cancelled
      end

      def incomplete? : Bool
        @incomplete
      end

      def cancelled? : Bool
        @cancelled
      end
    end

    def self.search(root : Path, needle : String, *, ignore_case : Bool = false, cancellation : Cancellation? = nil) : Result
      matches = [] of Match
      return Result.new(matches, 0, false) if needle.empty?

      root = root.expand
      needle_cmp = ignore_case ? needle.downcase : needle
      files_scanned = 0
      truncated = false
      cancelled = false

      traversal_truncated, traversal_cancelled = walk_files(root, cancellation) do |path|
        if matches.size >= MAX_MATCHES || files_scanned >= MAX_FILES
          truncated = true
          false
        else
          case text_file_status(path, cancellation)
          when .text?
            files_scanned += 1
            case scan_file(path, needle_cmp, ignore_case, matches, cancellation)
            when .unreadable?
              truncated = true
            when .cancelled?
              cancelled = true
              next false
            else
            end
            if matches.size >= MAX_MATCHES || files_scanned >= MAX_FILES
              truncated = true
              false
            else
              true
            end
          when .cancelled?
            cancelled = true
            false
          when .binary?
            true
          when .oversized?, .unreadable?
            truncated = true
            true
          else
            true
          end
        end
      end
      truncated ||= traversal_truncated
      cancelled ||= traversal_cancelled

      Result.new(matches, files_scanned, truncated, cancelled)
    end

    def self.search_text(text : String, needle : String, *, ignore_case : Bool = false, path : Path = Path.new(""), max_matches : Int32 = 200) : Array(Match)
      matches = [] of Match
      return matches if needle.empty?

      needle_cmp = ignore_case ? needle.downcase : needle
      text.split('\n').each_with_index do |line, line_no|
        break if matches.size >= max_matches
        scan_line(path, line, line_no, needle_cmp, ignore_case, matches, max_matches)
      end
      matches
    end

    private def self.walk_files(root : Path, cancellation : Cancellation?, & : Path -> Bool) : {Bool, Bool}
      stack = [{root, 0}] of {Path, Int32}
      truncated = false
      while item = stack.pop?
        return {truncated, true} if cancelled_at_checkpoint?(cancellation)

        dir, depth = item
        if depth > MAX_DEPTH
          truncated = true
          next
        end

        begin
          Dir.each_child(dir.to_s) do |name|
            return {truncated, true} if cancelled_at_checkpoint?(cancellation)
            next if SKIP_DIR_NAMES.includes?(name)

            path = dir / name
            info = File.info?(path, follow_symlinks: false)
            unless info
              truncated = true
              next
            end
            next if info.symlink?

            if info.directory?
              if depth >= MAX_DEPTH
                truncated = true
              else
                stack << {path, depth + 1}
              end
            elsif info.file?
              return {truncated, false} unless yield path
            end
          end
        rescue
          truncated = true
        end
      end
      {truncated, false}
    end

    private enum TextFileStatus
      Text
      Binary
      Oversized
      Unreadable
      Cancelled
    end

    private def self.text_file_status(path : Path, cancellation : Cancellation?) : TextFileStatus
      size = File.size(path)
      return TextFileStatus::Oversized if size > MAX_FILE_BYTES
      return TextFileStatus::Text if size == 0

      File.open(path, "rb") do |file|
        buf = Bytes.new(READ_CHUNK_BYTES)
        loop do
          return TextFileStatus::Cancelled if cancelled_at_checkpoint?(cancellation)
          read = file.read(buf)
          break if read == 0
          return TextFileStatus::Binary if buf[0, read].includes?(0_u8)
        end
      end
      TextFileStatus::Text
    rescue
      TextFileStatus::Unreadable
    end

    private enum ScanStatus
      Complete
      Unreadable
      Cancelled
    end

    private def self.scan_file(path : Path, needle_cmp : String, ignore_case : Bool, matches : Array(Match), cancellation : Cancellation?) : ScanStatus
      line_no = 0
      status = ScanStatus::Complete
      File.each_line(path.to_s, chomp: true) do |line|
        break if matches.size >= MAX_MATCHES
        if line_no % 64 == 0 && cancelled_at_checkpoint?(cancellation)
          status = ScanStatus::Cancelled
          break
        end
        scan_line(path, line, line_no, needle_cmp, ignore_case, matches, MAX_MATCHES)
        line_no += 1
      end
      status
    rescue
      ScanStatus::Unreadable
    end

    private def self.cancelled_at_checkpoint?(cancellation : Cancellation?) : Bool
      return false unless cancellation

      Fiber.yield
      cancellation.cancelled?
    end

    private def self.scan_line(path : Path, line : String, line_no : Int32, needle_cmp : String, ignore_case : Bool, matches : Array(Match), limit : Int32) : Nil
      return if limit <= 0

      haystack = ignore_case ? line.downcase : line
      col = 0
      while found = haystack.index(needle_cmp, col)
        matches << Match.new(path, line_no, found, snippet(line, found))
        break if matches.size >= limit
        col = found + [needle_cmp.size, 1].max
      end
    end

    private def self.snippet(line : String, _col : Int32) : String
      stripped = line.gsub('\t', " ").strip
      String.build do |builder|
        count = 0
        stripped.each_grapheme do |grapheme|
          break if count >= SNIPPET_MAX
          builder << grapheme
          count += 1
        end
      end
    end
  end
end
