module CrystalEditor
  module ProjectSearch
    SKIP_DIR_NAMES = Set{
      ".git", ".hg", ".svn",
      ".crystal-cache", ".agents", ".crystal_ball",
      "node_modules", "target", "vendor", ".build",
    }

    MAX_DEPTH      =        16
    MAX_FILE_BYTES = 1_048_576
    MAX_FILES      =      1500
    MAX_MATCHES    =        40
    MAX_MENU       =        12
    SNIPPET_MAX    =        72
    SAMPLE_BYTES   =       512

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

      def initialize(@matches : Array(Match), @files_scanned : Int32, @truncated : Bool)
      end
    end

    def self.search(root : Path, needle : String, *, ignore_case : Bool = false) : Result
      matches = [] of Match
      return Result.new(matches, 0, false) if needle.empty?

      root = root.expand
      needle_cmp = ignore_case ? needle.downcase : needle
      files_scanned = 0
      truncated = false

      walk_files(root) do |path|
        break if matches.size >= MAX_MATCHES || files_scanned >= MAX_FILES

        unless text_file?(path)
          next
        end

        files_scanned += 1
        scan_file(path, needle_cmp, ignore_case, matches)
        if matches.size >= MAX_MATCHES || files_scanned >= MAX_FILES
          truncated = true
        end
      end

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

    private def self.walk_files(root : Path, & : Path ->) : Nil
      stack = [{root, 0}] of {Path, Int32}
      while item = stack.pop?
        dir, depth = item
        next if depth > MAX_DEPTH

        begin
          Dir.each_child(dir.to_s) do |name|
            next if SKIP_DIR_NAMES.includes?(name)

            path = dir / name
            info = File.info?(path, follow_symlinks: false)
            next unless info
            next if info.symlink?

            if info.directory?
              stack << {path, depth + 1}
            elsif info.file?
              yield path
            end
          end
        rescue
        end
      end
    end

    private def self.text_file?(path : Path) : Bool
      size = File.size(path)
      return false if size > MAX_FILE_BYTES
      return true if size == 0

      File.open(path, "rb") do |file|
        sample = [size, SAMPLE_BYTES.to_i64].min
        buf = Bytes.new(sample)
        read = file.read(buf)
        return false if buf[0, read].includes?(0_u8)
      end
      true
    rescue
      false
    end

    private def self.scan_file(path : Path, needle_cmp : String, ignore_case : Bool, matches : Array(Match)) : Nil
      line_no = 0
      File.each_line(path.to_s, chomp: true) do |line|
        break if matches.size >= MAX_MATCHES
        scan_line(path, line, line_no, needle_cmp, ignore_case, matches, MAX_MATCHES)
        line_no += 1
      end
    rescue
    end

    private def self.scan_line(path : Path, line : String, line_no : Int32, needle_cmp : String, ignore_case : Bool, matches : Array(Match), limit : Int32) : Nil
      if line.size > 4096
        line = line[0, 4096]
      end

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
      stripped.size <= SNIPPET_MAX ? stripped : stripped[0, SNIPPET_MAX]
    end
  end
end
