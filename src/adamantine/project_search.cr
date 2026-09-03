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

      def initialize(@matches : Array(Match), @files_scanned : Int32, @truncated : Bool)
        @incomplete = @truncated
      end

      def incomplete? : Bool
        @incomplete
      end
    end

    def self.search(root : Path, needle : String, *, ignore_case : Bool = false) : Result
      matches = [] of Match
      return Result.new(matches, 0, false) if needle.empty?

      root = root.expand
      needle_cmp = ignore_case ? needle.downcase : needle
      files_scanned = 0
      truncated = false

      traversal_truncated = walk_files(root) do |path|
        if matches.size >= MAX_MATCHES || files_scanned >= MAX_FILES
          truncated = true
          false
        else
          case text_file_status(path)
          when .text?
            files_scanned += 1
            truncated = true unless scan_file(path, needle_cmp, ignore_case, matches)
            if matches.size >= MAX_MATCHES || files_scanned >= MAX_FILES
              truncated = true
              false
            else
              true
            end
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

      Result.new(matches, files_scanned, truncated)
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

    private def self.walk_files(root : Path, & : Path -> Bool) : Bool
      stack = [{root, 0}] of {Path, Int32}
      truncated = false
      while item = stack.pop?
        dir, depth = item
        if depth > MAX_DEPTH
          truncated = true
          next
        end

        begin
          Dir.each_child(dir.to_s) do |name|
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
              return truncated unless yield path
            end
          end
        rescue
          truncated = true
        end
      end
      truncated
    end

    private enum TextFileStatus
      Text
      Binary
      Oversized
      Unreadable
    end

    private def self.text_file_status(path : Path) : TextFileStatus
      size = File.size(path)
      return TextFileStatus::Oversized if size > MAX_FILE_BYTES
      return TextFileStatus::Text if size == 0

      File.open(path, "rb") do |file|
        buf = Bytes.new(READ_CHUNK_BYTES)
        loop do
          read = file.read(buf)
          break if read == 0
          return TextFileStatus::Binary if buf[0, read].includes?(0_u8)
        end
      end
      TextFileStatus::Text
    rescue
      TextFileStatus::Unreadable
    end

    private def self.text_file?(path : Path) : Bool
      text_file_status(path).text?
    end

    private def self.scan_file(path : Path, needle_cmp : String, ignore_case : Bool, matches : Array(Match)) : Bool
      line_no = 0
      File.each_line(path.to_s, chomp: true) do |line|
        break if matches.size >= MAX_MATCHES
        scan_line(path, line, line_no, needle_cmp, ignore_case, matches, MAX_MATCHES)
        line_no += 1
      end
      true
    rescue
      false
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
