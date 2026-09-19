require "atomic"

module Adamantine
  # Bounded, read-only access to the Git worktree selected by the editor.
  #
  # This deliberately owns the process boundary and the untrusted-output
  # boundary.  The TUI consumes the value objects below; it never constructs a
  # Git command from a display string.
  module GitRepository
    MAX_COMMITS         = 200
    MAX_GRAPH_LANES     =   8
    MAX_RUNTIME         = 3.seconds
    MAX_OUTPUT_BYTES    = 512 * 1024
    MAX_DIFF_LINES      = 4_000
    MAX_DIFF_LINE_CHARS =   512
    MAX_DISPLAY_CHARS   = 4_096
    MAX_FIELD_CHARS     =   512
    MAX_FILES           = 2_000

    # All errors are intentionally raised.  An empty result is a valid empty
    # repository, never a substitute for a failed command.
    class Error < Exception
    end

    class RepositoryError < Error
    end

    class CommandError < Error
      getter command : Array(String)
      getter stderr : String

      def initialize(message : String, @command : Array(String), stderr : String = "")
        @stderr = GitRepository.display(stderr, max_chars: 2_048)
        detail = @stderr.empty? ? message : "#{message}: #{@stderr}"
        super(GitRepository.display(detail, max_chars: 4_096))
      end
    end

    class CancellationError < Error
      def initialize(message : String = "Git request cancelled")
        super(message)
      end
    end

    class DeadlineExceededError < Error
      def initialize(message : String = "Git request exceeded the 3 second deadline")
        super(message)
      end
    end

    class OutputLimitError < Error
      def initialize(message : String = "Git output exceeded the 512 KiB limit")
        super(message)
      end
    end

    class ProcessIOError < Error
      def initialize(message : String = "Git output stream failed")
        super(message)
      end
    end

    class ParseError < Error
    end

    class UnsupportedDiffError < Error
      def initialize(message : String = "Diff for untracked files is unsupported")
        super(message)
      end
    end

    # Cancellation is shared by a controller request and all of the bounded
    # child commands that make up that request.
    class Cancellation
      @cancelled = Atomic(Bool).new(false)

      def cancel : Nil
        @cancelled.set(true)
      end

      def cancelled? : Bool
        @cancelled.get
      end
    end

    class Commit
      getter hash : String
      getter short_hash : String
      getter message : String
      getter author : String
      getter date : String
      getter refs : Array(String)
      getter parents : Array(String)
      getter graph : String
      setter graph : String

      def initialize(
        @hash : String,
        @short_hash : String,
        @message : String,
        @author : String,
        @date : String,
        @refs : Array(String),
        @parents : Array(String),
        @graph : String = "",
      )
      end

      def merge? : Bool
        @parents.size > 1
      end
    end

    class FileStatus
      getter path : String
      getter status : String
      getter display : String
      getter old_path : String?

      def initialize(@path : String, @status : String, @display : String, @old_path : String? = nil)
      end
    end

    class Snapshot
      getter root : Path
      getter commits : Array(Commit)
      getter files : Array(FileStatus)
      getter notices : Array(String)
      getter branch : String

      def initialize(
        @root : Path,
        @commits : Array(Commit),
        @files : Array(FileStatus),
        @notices : Array(String),
        @branch : String,
      )
      end
    end

    # Keep terminal control characters out of every user-visible value.  This
    # is also used for diagnostics from Git, which can be configured by the
    # repository owner.
    def self.display(text : String, max_chars : Int32 = MAX_DISPLAY_CHARS) : String
      # Callers may use the sanitizer for a whole bounded diff, not only for
      # a compact label.  Keep one absolute ceiling while honoring the
      # requested limit above the label-sized default.
      limit = max_chars.clamp(0, MAX_OUTPUT_BYTES.to_i32)
      return "" if limit == 0

      source = text.valid_encoding? ? text : text.scrub
      builder = String::Builder.new
      count = 0
      truncated = false

      source.each_char do |char|
        if count >= limit
          truncated = true
          break
        end

        safe = safe_display_char(char).to_s
        if builder.bytesize + safe.bytesize > limit
          truncated = true
          break
        end

        builder << safe
        count += 1
      end

      value = builder.to_s
      return value unless truncated

      append_marker(value, "[truncated]", limit)
    end

    def self.snapshot(root : Path, cancellation : Cancellation) : Snapshot
      deadline = Time.instant + MAX_RUNTIME
      ensure_not_cancelled(cancellation)
      requested_root = canonical_directory(root)
      repository_root = resolve_repository_root(requested_root, cancellation, deadline)

      ensure_not_cancelled(cancellation)
      branch_result = run_command(repository_root, ["branch", "--show-current"], cancellation, deadline)
      branch = display(branch_result.output.strip, max_chars: MAX_FIELD_CHARS)

      ensure_not_cancelled(cancellation)
      log_result = run_command(repository_root, log_arguments, cancellation, deadline)
      notices = [] of String
      commits = parse_log(log_result.output, notices)
      if commits.size > MAX_COMMITS
        commits = commits[0, MAX_COMMITS]
        notices << "History truncated at #{MAX_COMMITS} commits"
      end
      calculate_graph_columns(commits, notices)

      ensure_not_cancelled(cancellation)
      status_result = run_command(repository_root, status_arguments, cancellation, deadline)
      files = parse_status(status_result.output, notices)

      Snapshot.new(repository_root, commits, files, notices, branch)
    end

    def self.commit_diff(root : Path, hash : String, cancellation : Cancellation) : String
      validate_hash!(hash)
      deadline = Time.instant + MAX_RUNTIME
      ensure_not_cancelled(cancellation)
      repository_root = resolve_repository_root(canonical_directory(root), cancellation, deadline)
      result = run_command(repository_root, commit_diff_arguments(hash), cancellation, deadline)
      format_diff(result.output, result.truncated)
    end

    def self.file_diff(root : Path, path : String, cancellation : Cancellation) : String
      path = validate_path!(path)
      deadline = Time.instant + MAX_RUNTIME
      ensure_not_cancelled(cancellation)
      repository_root = resolve_repository_root(canonical_directory(root), cancellation, deadline)
      status_result = run_command(repository_root, status_arguments(path), cancellation, deadline)
      statuses = parse_status(status_result.output)
      if statuses.any? { |file| file.path == path && file.status == "??" }
        raise UnsupportedDiffError.new("Diff for untracked file #{display(path)} is unsupported")
      end

      pathspec = pathspec(path)
      # Keep the combined result within the same output budget as a single
      # diff.  Each command gets half the budget, while the shared deadline
      # and per-command stderr cap still apply.
      per_section_limit = MAX_OUTPUT_BYTES // 2
      staged = run_command(repository_root, file_diff_arguments(staged: true, pathspec: pathspec), cancellation, deadline, per_section_limit)
      unstaged = run_command(repository_root, file_diff_arguments(staged: false, pathspec: pathspec), cancellation, deadline, per_section_limit)

      combined = "[staged]\n#{staged.output}\n[unstaged]\n#{unstaged.output}"
      format_diff(combined, staged.truncated || unstaged.truncated)
    end

    private struct CommandResult
      getter output : String
      getter error : String
      getter truncated : Bool
      getter status : Process::Status

      def initialize(@output : String, @error : String, @truncated : Bool, @status : Process::Status)
      end
    end

    # Atomic is a value type in Crystal.  Keeping each atomic inside this
    # reference object is essential: passing an Atomic directly to a reader
    # fiber would copy the atomic and make cancellation/limits invisible to
    # the monitor and sibling reader.
    private class CommandState
      @total_bytes = Atomic(Int32).new(0)
      @truncated = Atomic(Bool).new(false)
      @stop_reason = Atomic(Int32).new(STOP_NONE)
      @process_done = Atomic(Bool).new(false)

      def add_bytes(count : Int32) : Int32
        @total_bytes.add(count)
      end

      def mark_truncated : Nil
        @truncated.set(true)
      end

      def truncated? : Bool
        @truncated.get
      end

      def stop_reason : Int32
        @stop_reason.get
      end

      def mark_stop(candidate : Int32) : Bool
        _old, changed = @stop_reason.compare_and_set(STOP_NONE, candidate)
        changed
      end

      def process_done? : Bool
        @process_done.get
      end

      def process_done : Nil
        @process_done.set(true)
      end
    end

    private STOP_NONE        = 0
    private STOP_CANCEL      = 1
    private STOP_DEADLINE    = 2
    private STOP_OUTPUT      = 3
    private STOP_IO          = 4
    private MONITOR_INTERVAL = 10.milliseconds

    private def self.canonical_directory(root : Path) : Path
      info = File.info(root)
      raise RepositoryError.new("Git root is not a directory: #{display(root.to_s)}") unless info.directory?
      Path.new(File.realpath(root.to_s))
    rescue ex : RepositoryError
      raise ex
    rescue ex
      raise RepositoryError.new("Cannot access Git root #{display(root.to_s)}: #{display(ex.message || ex.class.to_s)}")
    end

    private def self.resolve_repository_root(root : Path, cancellation : Cancellation, deadline : Time::Instant) : Path
      # Read the path and the boolean independently.  Splitting a combined
      # response on LF would corrupt a legal worktree path containing LF.
      reported_result = run_command(root, ["rev-parse", "--show-toplevel"], cancellation, deadline)
      inside_result = run_command(root, ["rev-parse", "--is-inside-work-tree"], cancellation, deadline)
      reported_text = remove_git_final_lf(reported_result.output)
      inside_text = remove_git_final_lf(inside_result.output)
      raise RepositoryError.new("Git did not report a worktree") if reported_text.empty?
      raise RepositoryError.new("Git path is not a worktree") unless inside_text == "true"

      Path.new(File.realpath(reported_text))
    rescue ex : RepositoryError
      raise ex
    rescue ex : CancellationError | DeadlineExceededError | OutputLimitError | ProcessIOError
      raise ex
    rescue ex : CommandError
      raise RepositoryError.new("Not a readable Git worktree: #{ex.message}")
    rescue ex
      raise RepositoryError.new("Cannot resolve Git worktree: #{display(ex.message || ex.class.to_s)}")
    end

    private def self.log_arguments : Array(String)
      # Git's tformat appends one LF after each record.  The final NUL is the
      # seventh field delimiter; the parser explicitly consumes that LF.
      format = "%H%x00%h%x00%s%x00%an%x00%ad%x00%D%x00%P%x00"
      ["log", "--all", "--date=iso-strict", "--format=#{format}", "-n", (MAX_COMMITS + 1).to_s]
    end

    private def self.status_arguments(path : String? = nil) : Array(String)
      args = ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=all"]
      if path
        args << "--"
        args << pathspec(path)
      end
      args
    end

    private def self.commit_diff_arguments(hash : String) : Array(String)
      ["show", "--format=", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=all", "--end-of-options", hash, "--"]
    end

    private def self.file_diff_arguments(*, staged : Bool, pathspec : String) : Array(String)
      args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all"]
      args << "--cached" if staged
      args << "--"
      args << pathspec
      args
    end

    private def self.pathspec(path : String) : String
      # `--literal-pathspecs` is installed in the process-wide Git options;
      # keeping this helper separate makes the `--` boundary obvious at call
      # sites and prevents future callers from passing a raw revspec.
      path
    end

    private def self.validate_hash!(hash : String) : Nil
      unless hash.size == 40 && hash.each_byte.all? { |byte| hex_byte?(byte) }
        raise ArgumentError.new("Git commit hash must be exactly 40 hexadecimal characters")
      end
    end

    private def self.validate_path!(path : String) : String
      raise ArgumentError.new("Git path must not be empty") if path.empty?
      raise ArgumentError.new("Git path must be relative") if path.starts_with?('/')
      raise ArgumentError.new("Git path must not contain NUL") if path.includes?('\0')
      raise ArgumentError.new("Git path must not escape the worktree") if path.split('/').any? { |part| part == ".." }
      path
    end

    private def self.hex_byte?(byte : UInt8) : Bool
      (byte >= '0'.ord && byte <= '9'.ord) ||
        (byte >= 'a'.ord && byte <= 'f'.ord) ||
        (byte >= 'A'.ord && byte <= 'F'.ord)
    end

    private def self.parse_log(output : String, notices : Array(String)) : Array(Commit)
      fields = [] of String
      current = String::Builder.new
      commits = [] of Commit
      at_record_boundary = false

      output.to_slice.each do |byte|
        if byte == 0_u8
          fields << current.to_s
          current = String::Builder.new
          if fields.size == 7
            commits << commit_from_fields(fields)
            fields.clear
            at_record_boundary = true
          end
        elsif at_record_boundary && (byte == '\n'.ord.to_u8 || byte == '\r'.ord.to_u8)
          # `--format`/tformat emits a line terminator after the final NUL.
          # Ignore only that terminator; all field content remains byte-exact.
          next
        else
          at_record_boundary = false
          current.write_byte(byte)
        end
      end

      unless current.to_s.empty? && fields.empty?
        raise ParseError.new("Git log returned an incomplete structured record")
      end
      commits
    end

    private def self.remove_git_final_lf(output : String) : String
      raise ParseError.new("Git returned an unterminated line") unless output.ends_with?('\n')
      output.byte_slice(0, output.bytesize - 1)
    end

    private def self.commit_from_fields(fields : Array(String)) : Commit
      hash = fields[0]
      short_hash = fields[1]
      validate_hash!(hash)
      unless short_hash.size > 0 && short_hash.each_byte.all? { |byte| hex_byte?(byte) }
        raise ParseError.new("Git returned an invalid abbreviated commit hash")
      end

      refs = fields[5].split(", ").reject(&.empty?).map do |ref|
        display(ref, max_chars: MAX_FIELD_CHARS)
      end
      parents = fields[6].split(' ').reject(&.empty?)
      parents.each { |parent| validate_hash!(parent) }

      Commit.new(
        hash,
        display(short_hash, max_chars: MAX_FIELD_CHARS),
        display(fields[2], max_chars: MAX_FIELD_CHARS),
        display(fields[3], max_chars: MAX_FIELD_CHARS),
        display(fields[4], max_chars: MAX_FIELD_CHARS),
        refs,
        parents
      )
    end

    private def self.parse_status(output : String, notices : Array(String)? = nil) : Array(FileStatus)
      records = output.split('\0', remove_empty: false)
      files = [] of FileStatus
      index = 0

      while index < records.size
        record = records[index]
        index += 1
        next if record.empty?

        case record[0]
        when '1'
          tokens = record.split(' ', limit: 9)
          raise ParseError.new("Git returned a malformed status record") if tokens.size < 9
          files << file_status(tokens[8], tokens[1])
        when '2'
          tokens = record.split(' ', limit: 10)
          raise ParseError.new("Git returned a malformed rename status record") if tokens.size < 10
          raise ParseError.new("Git returned a missing rename source") if index >= records.size
          old_path = records[index]
          index += 1
          files << file_status(tokens[9], tokens[1], old_path)
        when 'u'
          tokens = record.split(' ', limit: 11)
          raise ParseError.new("Git returned a malformed unmerged status record") if tokens.size < 11
          files << file_status(tokens[10], tokens[1])
        when '?', '!'
          raise ParseError.new("Git returned a malformed untracked status record") if record.size < 3
          status = record[0] == '?' ? "??" : "!!"
          files << file_status(record[2..], status)
        when '#'
          # Branch headers are intentionally not requested, but accepting a
          # future header keeps status parsing forward-compatible.
        else
          raise ParseError.new("Git returned an unknown status record")
        end

        if files.size >= MAX_FILES
          if notices && !notices.includes?("File status truncated at #{MAX_FILES}")
            notices << "File status truncated at #{MAX_FILES}"
          end
          break
        end
      end

      files
    end

    private def self.file_status(path : String, status : String, old_path : String? = nil) : FileStatus
      raise ParseError.new("Git returned an invalid XY status") unless status.size == 2
      shown_path = display(path, max_chars: MAX_FIELD_CHARS)
      shown = if old_path
                "#{status} #{shown_path} <- #{display(old_path, max_chars: MAX_FIELD_CHARS)}"
              else
                "#{status} #{shown_path}"
              end
      FileStatus.new(path, status, shown, old_path)
    end

    # Adapted from crystal_ball/src/tui/git_browser.cr's active-branch lane
    # model (calculate_graph_columns, draw_graph_line).  It is deliberately
    # bounded and precomputed: the modal never performs O(n^2) topology scans
    # while rendering a row.
    private def self.calculate_graph_columns(commits : Array(Commit), notices : Array(String)) : Nil
      lanes = [] of String?
      lane_truncated = false

      commits.each do |commit|
        column = lanes.index(commit.hash)
        unless column
          column = lanes.index(nil)
          if column
            lanes[column] = commit.hash
          elsif lanes.size < MAX_GRAPH_LANES
            column = lanes.size
            lanes << commit.hash
          else
            column = MAX_GRAPH_LANES - 1
            lane_truncated = true
          end
        end

        commit.graph = graph_row(lanes, column, commit.merge?, lane_truncated)
        update_lanes(lanes, column, commit.parents, notices, lane_truncated)
        lane_truncated = lane_truncated || lanes.size >= MAX_GRAPH_LANES && commit.parents.size > 1
      end

      notices << "Graph lanes truncated at #{MAX_GRAPH_LANES}" if lane_truncated && !notices.includes?("Graph lanes truncated at #{MAX_GRAPH_LANES}")
    end

    private def self.update_lanes(lanes : Array(String?), column : Int32, parents : Array(String), notices : Array(String), lane_truncated : Bool) : Nil
      return if column >= lanes.size

      if parents.empty?
        lanes[column] = nil
      else
        lanes[column] = parents[0]
        parents[1..].each do |parent|
          next if lanes.any? { |lane| lane == parent }
          if lanes.size < MAX_GRAPH_LANES
            lanes.insert(column + 1, parent)
          elsif !lane_truncated
            notices << "Graph lanes truncated at #{MAX_GRAPH_LANES}" unless notices.includes?("Graph lanes truncated at #{MAX_GRAPH_LANES}")
          end
        end
      end

      while !lanes.empty? && lanes[-1].nil?
        lanes.pop
      end
    end

    private def self.graph_row(lanes : Array(String?), column : Int32, merge : Bool, truncated : Bool) : String
      width = {lanes.size, MAX_GRAPH_LANES}.min
      cells = Array(String).new(width) do |index|
        if index == column
          merge ? "M" : "*"
        elsif lanes[index]
          "|"
        else
          " "
        end
      end
      graph = cells.join(" ")
      truncated ? "#{graph} …" : graph
    end

    private def self.format_diff(raw : String, raw_truncated : Bool) : String
      source = raw.valid_encoding? ? raw : raw.scrub
      lines = [] of String
      truncated = raw_truncated
      source.each_line do |line|
        if lines.size >= MAX_DIFF_LINES
          truncated = true
          break
        end
        line = line.chomp('\n').chomp('\r')
        clipped = clip_line(line)
        truncated = true if clipped != line
        lines << clipped
      end

      if lines.empty?
        return raw_truncated ? "[diff truncated]" : "(no changes)"
      end

      value = lines.join('\n')
      value += "\n[diff truncated]" if truncated
      bounded_diff_display(value)
    end

    private def self.clip_line(line : String) : String
      safe = display(line, max_chars: MAX_DIFF_LINE_CHARS)
      safe
    end

    private def self.safe_display_char(char : Char) : Char
      codepoint = char.ord
      if codepoint < 0x20 || (codepoint >= 0x7f && codepoint <= 0x9f)
        '�'
      else
        char
      end
    end

    private def self.bounded_diff_display(value : String) : String
      return value if value.bytesize <= MAX_OUTPUT_BYTES

      marker = "\n[diff truncated]"
      limit = MAX_OUTPUT_BYTES - marker.bytesize
      clipped = value.byte_slice(0, limit)
      # Do not return a partial UTF-8 sequence from a byte budget.  The
      # sanitizer has already removed terminal controls, so scrubbing the
      # boundary is sufficient and preserves the visible truncation marker.
      "#{clipped.scrub}#{marker}"
    end

    private def self.append_marker(value : String, marker : String, limit : Int32) : String
      return marker.byte_slice(0, limit).scrub if limit <= marker.bytesize
      keep = limit - marker.bytesize
      clipped = value.byte_slice(0, keep).scrub
      "#{clipped}#{marker}"
    end

    private def self.ensure_not_cancelled(cancellation : Cancellation) : Nil
      raise CancellationError.new if cancellation.cancelled?
    end

    private def self.run_command(
      root : Path,
      arguments : Array(String),
      cancellation : Cancellation,
      deadline : Time::Instant,
      output_limit : Int32 = MAX_OUTPUT_BYTES,
    ) : CommandResult
      ensure_not_cancelled(cancellation)
      raise DeadlineExceededError.new if Time.instant >= deadline

      command = ["git"] + global_arguments + arguments
      process = begin
        Process.new(
          "git",
          global_arguments + arguments,
          env: process_environment,
          clear_env: true,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe,
          chdir: root.to_s
        )
      rescue ex
        raise CommandError.new("Unable to start Git", command, ex.message || ex.class.to_s)
      end

      output = process.output.not_nil!
      error = process.error.not_nil!
      stdout_memory = IO::Memory.new
      stderr_memory = IO::Memory.new
      state = CommandState.new
      readers_done = Channel(Nil).new(2)
      monitor_done = Channel(Nil).new(1)

      spawn(name: "git-stdout-reader") do
        read_stream(output, stdout_memory, state, process, output_limit)
      ensure
        readers_done.send(nil) rescue nil
      end

      spawn(name: "git-stderr-reader") do
        read_stream(error, stderr_memory, state, process, output_limit)
      ensure
        readers_done.send(nil) rescue nil
      end

      spawn(name: "git-deadline-monitor") do
        begin
          loop do
            break if state.process_done?
            if state.stop_reason != STOP_NONE
              terminate(process)
              close_pipes(output, error)
              break
            end
            if cancellation.cancelled?
              state.mark_stop(STOP_CANCEL)
              terminate(process)
              close_pipes(output, error)
              break
            end
            if Time.instant >= deadline
              state.mark_stop(STOP_DEADLINE)
              terminate(process)
              close_pipes(output, error)
              break
            end
            sleep MONITOR_INTERVAL
          end
        ensure
          monitor_done.send(nil) rescue nil
        end
      end

      status : Process::Status? = nil
      begin
        2.times { readers_done.receive }
        status = process.wait
      ensure
        state.process_done
        if status.nil?
          terminate(process)
          process.wait rescue nil
        end
        monitor_done.receive rescue nil
      end

      reason = state.stop_reason
      raise CancellationError.new if reason == STOP_CANCEL || cancellation.cancelled?
      raise DeadlineExceededError.new if reason == STOP_DEADLINE
      raise OutputLimitError.new if reason == STOP_OUTPUT
      raise ProcessIOError.new if reason == STOP_IO

      final_status = status.not_nil!
      stderr_text = stderr_memory.to_s
      unless final_status.success?
        raise CommandError.new("Git command failed (#{final_status.description})", command, stderr_text)
      end

      CommandResult.new(stdout_memory.to_s, stderr_text, state.truncated?, final_status)
    end

    private def self.read_stream(
      io : IO,
      memory : IO::Memory,
      state : CommandState,
      process : Process,
      output_limit : Int32,
    ) : Nil
      chunk = Bytes.new(16 * 1024)
      loop do
        count = io.read(chunk)
        break if count == 0

        previous = state.add_bytes(count)
        available = output_limit - previous
        if available > 0
          memory.write(chunk[0, {count, available}.min])
        end
        if previous + count > output_limit
          state.mark_truncated
          state.mark_stop(STOP_OUTPUT)
          terminate(process)
          break
        end
      end
    rescue IO::Error
      # Termination closes the pipe while the reader is draining it.  The
      # stop reason is authoritative; normal command errors are raised later.
      unless state.stop_reason != STOP_NONE
        state.mark_stop(STOP_IO)
        terminate(process)
      end
    ensure
      io.close rescue nil
    end

    private def self.terminate(process : Process) : Nil
      process.terminate(graceful: false) rescue nil
    end

    private def self.close_pipes(output : IO, error : IO) : Nil
      output.close rescue nil
      error.close rescue nil
    end

    private def self.global_arguments : Array(String)
      [
        "--no-pager",
        "--no-optional-locks",
        "--literal-pathspecs",
        "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false",
        "-c", "core.pager=cat",
        "-c", "color.ui=false",
        "-c", "core.attributesFile=/dev/null",
        "-c", "diff.external=",
      ]
    end

    private def self.process_environment : Hash(String, String)
      {
        "PATH"                  => (ENV["PATH"]? || "/usr/bin:/bin:/usr/local/bin"),
        "HOME"                  => (ENV["HOME"]? || "/"),
        "LANG"                  => "C",
        "LC_ALL"                => "C",
        "GIT_TERMINAL_PROMPT"   => "0",
        "GIT_PAGER"             => "cat",
        "GIT_OPTIONAL_LOCKS"    => "0",
        "GIT_NO_LAZY_FETCH"     => "1",
        "GIT_CONFIG_NOSYSTEM"   => "1",
        "GIT_CONFIG_GLOBAL"     => "/dev/null",
        "GIT_CONFIG_SYSTEM"     => "/dev/null",
        "GIT_LITERAL_PATHSPECS" => "1",
        "NO_COLOR"              => "1",
      }
    end
  end
end
