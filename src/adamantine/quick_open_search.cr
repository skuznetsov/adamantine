require "./project_search"

module Adamantine
  # Bounded, path-only indexing and ranking for the quick-open modal.
  #
  # The index deliberately does not inspect file contents.  Opening a selected
  # path remains the editor's ordinary guarded file-open operation.
  module QuickOpenSearch
    MAX_ENTRIES             = 10_000
    MAX_DEPTH               =     16
    MAX_PATH_BYTES          =   4096
    MAX_QUERY_CODEPOINTS    =    256
    MAX_RESULTS             =    100
    MAX_RETAINED_PATH_BYTES = 4 * 1024 * 1024
    MAX_CHECKPOINT_INTERVAL = 64

    # Keep the existing project-search cancellation token as the shared
    # cooperative cancellation surface for filesystem workers.
    alias Cancellation = ProjectSearch::Cancellation

    struct Limits
      getter max_entries : Int32
      getter max_depth : Int32
      getter max_path_bytes : Int32
      getter max_query_codepoints : Int32
      getter max_results : Int32
      getter max_retained_path_bytes : Int64
      getter checkpoint_interval : Int32

      def initialize(
        @max_entries : Int32 = MAX_ENTRIES,
        @max_depth : Int32 = MAX_DEPTH,
        @max_path_bytes : Int32 = MAX_PATH_BYTES,
        @max_query_codepoints : Int32 = MAX_QUERY_CODEPOINTS,
        @max_results : Int32 = MAX_RESULTS,
        max_retained_path_bytes : Int32 | Int64 = MAX_RETAINED_PATH_BYTES,
        @checkpoint_interval : Int32 = MAX_CHECKPOINT_INTERVAL,
      )
        @max_retained_path_bytes = max_retained_path_bytes.to_i64
        validate!
      end

      def self.production : Limits
        new
      end

      private def validate! : Nil
        unless 0 <= @max_entries <= MAX_ENTRIES
          raise ArgumentError.new("max_entries exceeds the quick-open bound")
        end
        unless 0 <= @max_depth <= MAX_DEPTH
          raise ArgumentError.new("max_depth exceeds the quick-open bound")
        end
        unless 0 <= @max_path_bytes <= MAX_PATH_BYTES
          raise ArgumentError.new("max_path_bytes exceeds the quick-open bound")
        end
        unless 0 <= @max_query_codepoints <= MAX_QUERY_CODEPOINTS
          raise ArgumentError.new("max_query_codepoints exceeds the quick-open bound")
        end
        unless 0 <= @max_results <= MAX_RESULTS
          raise ArgumentError.new("max_results exceeds the quick-open bound")
        end
        unless 0_i64 <= @max_retained_path_bytes <= MAX_RETAINED_PATH_BYTES
          raise ArgumentError.new("max_retained_path_bytes exceeds the quick-open bound")
        end
        unless 1 <= @checkpoint_interval <= MAX_CHECKPOINT_INTERVAL
          raise ArgumentError.new("checkpoint_interval exceeds the quick-open bound")
        end
      end
    end

    struct FileEntry
      getter path : Path
      getter relative_path : String
      getter depth : Int32

      def initialize(@path : Path, @relative_path : String, @depth : Int32)
      end
    end

    struct FileIndex
      getter root : Path
      getter generation : UInt64
      getter entries : Array(FileEntry)
      getter entries_seen : Int32
      getter retained_path_bytes : Int64
      getter partial : Bool
      getter cancelled : Bool

      def initialize(
        @root : Path,
        @generation : UInt64,
        @entries : Array(FileEntry),
        @entries_seen : Int32,
        @retained_path_bytes : Int64,
        @partial : Bool,
        @cancelled : Bool,
      )
      end

      def partial? : Bool
        @partial
      end

      def cancelled? : Bool
        @cancelled
      end

      def incomplete? : Bool
        @partial
      end
    end

    struct Rank
      getter basename_kind : Int32
      getter prefix : Bool
      getter boundary_hits : Int32
      getter contiguous_pairs : Int32
      getter gap_codepoints : Int32
      getter first_match : Int32
      getter path_codepoints : Int32

      def initialize(
        @basename_kind : Int32,
        @prefix : Bool,
        @boundary_hits : Int32,
        @contiguous_pairs : Int32,
        @gap_codepoints : Int32,
        @first_match : Int32,
        @path_codepoints : Int32,
      )
      end
    end

    struct FileMatch
      getter entry : FileEntry
      getter rank : Rank

      def initialize(@entry : FileEntry, @rank : Rank)
      end

      def path : Path
        @entry.path
      end

      def relative_path : String
        @entry.relative_path
      end
    end

    # The UI-facing names are intentionally explicit about the path-only
    # contract.  Keep the shorter internal names as aliases for callers that
    # adopted the initial API proposal.
    alias FilePathMatch = FileMatch

    struct Result
      getter root : Path
      getter generation : UInt64
      getter query : String?
      getter matches : Array(FileMatch)
      getter partial : Bool
      getter cancelled : Bool
      getter query_too_long : Bool

      def initialize(
        @root : Path,
        @generation : UInt64,
        @query : String?,
        @matches : Array(FileMatch),
        @partial : Bool,
        @cancelled : Bool = false,
        @query_too_long : Bool = false,
      )
      end

      def partial? : Bool
        @partial
      end

      def cancelled? : Bool
        @cancelled
      end

      def query_too_long? : Bool
        @query_too_long
      end

      def incomplete? : Bool
        @partial
      end
    end

    alias FilePathResult = Result

    # Walk only directory metadata and file paths.  The stack carries the
    # relative path so path limits can be checked before constructing a model
    # object for an overlong entry.
    def self.index_file_paths(
      root : Path,
      *,
      generation : UInt64,
      limits : Limits = Limits.production,
      cancellation : Cancellation? = nil,
      checkpoint : Proc(Nil)? = nil,
    ) : FileIndex
      expanded_root = root.expand
      entries = [] of FileEntry
      entries_seen = 0
      retained_path_bytes = 0_i64
      partial = false
      cancelled = false
      units = 0

      if cancellation && cancellation.cancelled?
        return FileIndex.new(expanded_root, generation, entries, entries_seen, retained_path_bytes, true, true)
      end

      # Give a modal worker an early cooperative turn so cancellation can
      # invalidate a just-opened popup before even a tiny root is enumerated.
      if cancellation || checkpoint
        if checkpoint_cancelled?(cancellation, checkpoint)
          return FileIndex.new(expanded_root, generation, entries, entries_seen, retained_path_bytes, true, true)
        end
      end

      root_info = File.info?(expanded_root, follow_symlinks: false)
      unless root_info && !root_info.symlink? && root_info.directory?
        return FileIndex.new(expanded_root, generation, entries, entries_seen, retained_path_bytes, true, false)
      end

      stack = [{expanded_root, "", 0_i32}] of {Path, String, Int32}
      stop = false
      while item = stack.pop?
        break if stop
        dir, relative_dir, depth = item

        begin
          Dir.each_child(dir.to_s) do |name|
            break if stop

            # Do not examine beyond the entry bound.  The omitted next name is
            # still evidence of a partial traversal, but is not counted.
            if entries_seen >= limits.max_entries
              partial = true
              stop = true
              break
            end
            entries_seen += 1
            units += 1

            if units % limits.checkpoint_interval == 0
              if checkpoint_cancelled?(cancellation, checkpoint)
                cancelled = true
                partial = true
                stop = true
                break
              end
            elsif cancellation && cancellation.cancelled?
              cancelled = true
              partial = true
              stop = true
              break
            end

            if ProjectSearch::SKIP_DIR_NAMES.includes?(name)
              next
            end

            relative_size = relative_dir.bytesize + name.bytesize
            relative_size += 1 unless relative_dir.empty?
            if relative_size > limits.max_path_bytes
              partial = true
              next
            end

            relative_path = relative_dir.empty? ? name : "#{relative_dir}/#{name}"
            path = dir / name
            path_string = path.to_s
            if path_string.bytesize > limits.max_path_bytes
              partial = true
              next
            end
            info = File.info?(path, follow_symlinks: false)
            unless info
              partial = true
              next
            end
            next if info.symlink?

            if info.directory?
              if depth >= limits.max_depth
                partial = true
              else
                path_bytes = path_string.bytesize.to_i64 + relative_path.bytesize.to_i64
                if retained_path_bytes + path_bytes > limits.max_retained_path_bytes
                  partial = true
                  stop = true
                  break
                end
                retained_path_bytes += path_bytes
                stack << {path, relative_path, depth + 1}
              end
            elsif info.file?
              path_bytes = path_string.bytesize.to_i64 + relative_path.bytesize.to_i64
              if retained_path_bytes + path_bytes > limits.max_retained_path_bytes
                partial = true
                stop = true
                break
              end

              entries << FileEntry.new(path, relative_path, depth)
              retained_path_bytes += path_bytes
            end
          end
        rescue
          partial = true
        end
      end

      if cancellation && cancellation.cancelled?
        cancelled = true
        partial = true
      end
      FileIndex.new(expanded_root, generation, entries, entries_seen, retained_path_bytes, partial, cancelled)
    end

    # Rank the already bounded path index.  At most max_results candidates are
    # retained while scanning; insertion is bounded by the 100-row result cap.
    def self.rank_file_paths(
      index : FileIndex,
      query : String,
      *,
      generation : UInt64,
      max_results : Int32 = MAX_RESULTS,
      limits : Limits = Limits.production,
      cancellation : Cancellation? = nil,
      checkpoint : Proc(Nil)? = nil,
    ) : Result
      query_codepoints = codepoint_count_bounded(query, limits.max_query_codepoints)
      if query_codepoints > limits.max_query_codepoints
        return Result.new(index.root, generation, nil, [] of FileMatch, true, false, true)
      end

      if index.cancelled?
        return Result.new(index.root, generation, query, [] of FileMatch, true, true)
      end

      result_limit = max_results
      result_limit = 0 if result_limit < 0
      result_limit = limits.max_results if result_limit > limits.max_results
      result_limit = MAX_RESULTS if result_limit > MAX_RESULTS
      matches = [] of FileMatch
      partial = index.partial?
      cancelled = false
      units = 0
      empty_query = query.empty?

      if cancellation && cancellation.cancelled?
        return Result.new(index.root, generation, query, matches, true, true)
      end

      if cancellation || checkpoint
        if checkpoint_cancelled?(cancellation, checkpoint)
          return Result.new(index.root, generation, query, matches, true, true)
        end
      end

      if result_limit > 0
        index.entries.each do |entry|
          units += 1
          if units % limits.checkpoint_interval == 0
            if checkpoint_cancelled?(cancellation, checkpoint)
              cancelled = true
              partial = true
              break
            end
          elsif cancellation && cancellation.cancelled?
            cancelled = true
            partial = true
            break
          end

          rank = score(entry.relative_path, query)
          next unless rank
          candidate = FileMatch.new(entry, rank)
          insert_ranked(matches, candidate, result_limit, empty_query)
        end
      end

      if cancellation && cancellation.cancelled?
        cancelled = true
        partial = true
      end
      Result.new(index.root, generation, query, matches, partial, cancelled)
    end

    private def self.codepoint_count_bounded(value : String, limit : Int32) : Int32
      count = 0
      value.each_char do
        count += 1
        break if count > limit
      end
      count
    end

    private def self.checkpoint_cancelled?(cancellation : Cancellation?, checkpoint : Proc(Nil)?) : Bool
      checkpoint.try &.call
      # Yield even without a token so a caller-provided scheduler can make
      # progress at the declared checkpoint cadence.
      Fiber.yield
      if cancellation
        cancellation.cancelled?
      else
        false
      end
    end

    private def self.insert_ranked(matches : Array(FileMatch), candidate : FileMatch, limit : Int32, empty_query : Bool) : Nil
      index = 0
      while index < matches.size && !better?(candidate, matches[index], empty_query)
        index += 1
      end
      matches.insert(index, candidate)
      matches.pop if matches.size > limit
    end

    private def self.better?(left : FileMatch, right : FileMatch, empty_query : Bool) : Bool
      if empty_query
        return left.relative_path < right.relative_path
      end

      left_rank = left.rank
      right_rank = right.rank
      if left_rank.basename_kind != right_rank.basename_kind
        return left_rank.basename_kind > right_rank.basename_kind
      end
      # Once a query is represented by the basename, the basename match is
      # the discriminating signal; retain the original relative-path order for
      # deterministic ties instead of letting a shorter parent directory win.
      if left_rank.basename_kind > 0
        return left.relative_path < right.relative_path
      end
      if left_rank.prefix != right_rank.prefix
        return left_rank.prefix
      end
      if left_rank.boundary_hits != right_rank.boundary_hits
        return left_rank.boundary_hits > right_rank.boundary_hits
      end
      if left_rank.contiguous_pairs != right_rank.contiguous_pairs
        return left_rank.contiguous_pairs > right_rank.contiguous_pairs
      end
      if left_rank.gap_codepoints != right_rank.gap_codepoints
        return left_rank.gap_codepoints < right_rank.gap_codepoints
      end
      if left_rank.first_match != right_rank.first_match
        return left_rank.first_match < right_rank.first_match
      end
      if left_rank.path_codepoints != right_rank.path_codepoints
        return left_rank.path_codepoints < right_rank.path_codepoints
      end
      left.relative_path < right.relative_path
    end

    private def self.score(path : String, query : String) : Rank?
      path_cmp = path.downcase
      query_cmp = query.downcase
      path_chars = path_cmp.chars
      query_chars = query_cmp.chars
      if query_chars.empty?
        return Rank.new(0, false, 0, 0, 0, 0, path_chars.size)
      end

      basename_kind = basename_kind(path_cmp, query_cmp)
      query_index = 0
      first_match = -1
      previous_match = -1
      boundary_hits = 0
      contiguous_pairs = 0
      gap_codepoints = 0
      path_chars.each_with_index do |character, path_index|
        break if query_index >= query_chars.size
        next unless character == query_chars[query_index]

        first_match = path_index if first_match < 0
        if path_index == 0 || path_separator?(path_chars[path_index - 1])
          boundary_hits += 1
        end
        if previous_match >= 0
          if path_index == previous_match + 1
            contiguous_pairs += 1
          else
            gap_codepoints += path_index - previous_match - 1
          end
        end
        previous_match = path_index
        query_index += 1
      end

      return nil unless query_index == query_chars.size
      Rank.new(
        basename_kind,
        first_match == 0,
        boundary_hits,
        contiguous_pairs,
        gap_codepoints,
        first_match,
        path_chars.size
      )
    end

    private def self.basename_kind(path : String, query : String) : Int32
      slash = path.rindex('/')
      basename = slash ? path[(slash + 1)..] : path
      dot = basename.index('.')
      stem = dot ? basename[0, dot] : basename
      return 4 if basename == query
      return 3 if stem == query
      return 2 if basename.starts_with?(query) || stem.starts_with?(query)
      return 1 if subsequence?(stem, query)
      0
    end

    private def self.subsequence?(path : String, query : String) : Bool
      return true if query.empty?
      query_chars = query.chars
      query_index = 0
      path.each_char do |character|
        if character == query_chars[query_index]
          query_index += 1
          return true if query_index == query_chars.size
        end
      end
      false
    end

    private def self.path_separator?(character : Char) : Bool
      character == '/' || character == '\\' || character == '.' || character == '_' || character == '-' || character == ' '
    end
  end
end
