#!/usr/bin/env ruby

require "digest"
require "fiddle"
require "fileutils"
require "io/console"
require "json"
require "open3"
require "optparse"
require "pathname"
require "pty"
require "tmpdir"
require_relative "lib/pty_screen"

STDOUT.sync = true

module AdamantineChatLuaDemo
  class Failure < StandardError; end

  # The production Tui::Log success level and inline-preview navigation use
  # these measured single-cell glyphs. Normalize only those display markers
  # for the bounded PTY screen model; unknown Unicode still fails closed.
  class SuccessMarkerNormalizer
    MAPPINGS = {
      "\u2713".b.freeze => "+".b.freeze,
      "\u2190".b.freeze => "<".b.freeze,
      "\u2192".b.freeze => ">".b.freeze,
    }.freeze

    def initialize
      @carry = +"".b
    end

    def feed(bytes)
      combined = @carry + bytes.b
      prefixes = MAPPINGS.keys.flat_map do |marker|
        (1...marker.bytesize).map do |length|
          length if combined.end_with?(marker.byteslice(0, length))
        end
      end
      carry_length = prefixes.compact.max || 0
      output = combined.byteslice(0, combined.bytesize - carry_length).to_s.b
      @carry = combined.byteslice(combined.bytesize - carry_length, carry_length).to_s.b
      MAPPINGS.each { |marker, replacement| output.gsub!(marker, replacement) }
      output
    end

    def finish
      pending = @carry
      @carry = +"".b
      pending
    end
  end

  # Track only the ChatPanel tab's bold bit alongside PtyScreen's bounded
  # current-cell grid. A tab is trusted only when one live header row contains
  # the full tab labels and context marker, and both tab styles plus the
  # separator are known. This intentionally is not a general style emulator.
  class ActiveTabProbe < PtyScreen
    HEADER = " Chat   Log ".freeze

    def initialize(width, height)
      super
      @bold_cells = style_grid
      @bold = false
      @primary_bold_cells = nil
    end

    def active_header
      candidates = []
      @cells.each_index do |row_index|
        row = @cells[row_index]
        row.each_index do |column|
          next unless row[column, HEADER.length] == HEADER.chars

          tail = row[(column + HEADER.length)..].map do |cell|
            cell.equal?(WIDE_CONTINUATION) ? "" : cell
          end.join
          next unless tail.include?("Ctx:")

          candidates << [row_index, column, styled_tab_at(row_index, column)]
        end
      end
      return nil unless candidates.length == 1

      header = candidates.first
      return nil unless header[2]

      header
    end

    def active_tab
      active_header&.last
    end

    def resize(width, height)
      super
      @bold_cells = style_grid
      @primary_bold_cells = nil
    end

    private

    def style_grid
      Array.new(@height) { Array.new(@width) }
    end

    def styled_tab_at(row, column)
      styles = @bold_cells[row][column, HEADER.length]
      return nil unless styles && styles.length == HEADER.length && styles.none?(&:nil?)

      chat = styles[0, 6]
      separator = styles[6]
      log = styles[7, 5]
      return nil unless separator == false
      return :chat if chat.all? && log.none?
      return :log if chat.none? && log.all?

      nil
    end

    def apply_csi(final)
      update_bold(final) if final == "m"
      super
    end

    def update_bold(final)
      return unless final == "m"
      # The production UI also emits a private CSI >4m mode. PtyScreen treats
      # that extension as non-cell state; it does not encode SGR bold.
      return if @csi.match?(/\A[?>!<]/)

      params = @csi.empty? ? [0] : @csi.split(";").map do |part|
        part.empty? ? 0 : (part.match?(/\A\d+\z/) ? part.to_i : nil)
      end
      previous = @bold
      index = 0
      while index < params.length
        param = params[index]
        if param.nil?
          index += 1
          next
        end
        if [38, 48, 58].include?(param)
          index += (params[index + 1] == 2 ? 5 : 3)
          next
        end
        @bold = false if param == 0 || param == 22
        @bold = true if param == 1
        index += 1
      end
      if @bold != previous
        @revision += 1
        record_all_watched_rows
      end
    end

    def apply_mode(prefix, params, final)
      modes = params.reject(&:zero?)
      if prefix == "?" && modes.include?(1049)
        if final == "h" && !@primary_state
          @primary_bold_cells = @bold_cells
          @bold_cells = style_grid
        elsif final == "l" && @primary_state
          @bold_cells = @primary_bold_cells || style_grid
          @primary_bold_cells = nil
        end
      end
      super
    end

    def put_character(glyph)
      width = glyph_width(glyph)
      x = @x
      y = @y
      if width.positive? && (x >= @width || width > @width - x)
        x = 0
        y = [y + 1, @height - 1].min
      end
      super
      return if width.zero? || x.negative? || y.negative? || x >= @width || y >= @height

      @bold_cells[y][x, width] = Array.new(width, @bold)
    end

    def clear_character_at(row, column)
      if row >= 0 && row < @height
        columns = [column]
        cell = @cells[row][column] if column >= 0 && column < @width
        if wide_continuation?(cell) && column.positive?
          columns << column - 1
        elsif cell.is_a?(String) && WIDE_CODEPOINTS.include?(cell.codepoints.first) && column + 1 < @width
          columns << column + 1
        end
        columns.each { |index| @bold_cells[row][index] = nil }
      end
      super
    end

    def clear_cells(row, from, to)
      if row >= 0 && row < @height
        left = from.clamp(0, @width)
        right = to.clamp(left, @width)
        left -= 1 if left.positive? && left < @width && wide_continuation?(@cells[row][left])
        right += 1 if right < @width && wide_continuation?(@cells[row][right])
        @bold_cells[row][left...right] = Array.new(right - left) if right > left
      end
      super
    end

    def erase_line(mode)
      row = @y
      x = @x
      super
      if mode == 2 && row >= 0 && row < @height
        @bold_cells[row].fill(nil)
      else
        # Modes 0 and 1 flow through clear_cells above.
        clear_style_range(row, mode == 1 ? 0 : x, mode == 1 ? x + 1 : @width) if [0, 1].include?(mode)
      end
    end

    def erase_display(mode)
      row = @y
      x = @x
      super
      case mode
      when 0
        clear_style_range(row, x, @width)
        ((row + 1)...@height).each { |index| @bold_cells[index].fill(nil) }
      when 1
        (0...row).each { |index| @bold_cells[index].fill(nil) }
        clear_style_range(row, 0, x + 1)
      when 2, 3
        @bold_cells.each { |line| line.fill(nil) }
      end
    end

    def line_feed
      scrolls = @y >= @height - 1
      super
      if scrolls
        @bold_cells.shift
        @bold_cells << Array.new(@width)
      end
    end

    def reverse_index
      scrolls = @y <= 0
      super
      if scrolls
        @bold_cells.pop
        @bold_cells.unshift(Array.new(@width))
      end
    end

    def reset_screen
      super
      @bold_cells = style_grid
      @primary_bold_cells = nil
      @bold = false
    end

    def clear_style_range(row, from, to)
      return if row.negative? || row >= @height

      left = from.clamp(0, @width)
      right = to.clamp(left, @width)
      @bold_cells[row][left...right] = Array.new(right - left) if right > left
    end
  end

  class Deadline
    def initialize(seconds)
      @at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    end

    def remaining
      @at - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def check!(label)
      raise Failure, "deadline exceeded while #{label}" unless remaining.positive?
    end
  end

  class Driver
    WIDTH = 160
    HEIGHT = 32
    REVIEW_MODAL_X = 32
    REVIEW_MODAL_Y = 4
    REVIEW_MODAL_WIDTH = 96
    REVIEW_MODAL_HEIGHT = 24
    REVIEW_BODY_X = REVIEW_MODAL_X + 2
    REVIEW_BODY_Y = REVIEW_MODAL_Y + 1
    REVIEW_BODY_WIDTH = REVIEW_MODAL_WIDTH - 4
    REVIEW_BODY_HEIGHT = REVIEW_MODAL_HEIGHT - 4
    REVIEW_STABLE_SAMPLES = 4
    REVIEW_STABILITY_POLLS = 60
    REVIEW_STABILITY_INTERVAL = 0.05
    REVIEW_SCROLL_ATTEMPTS = 2
    ENDPOINT = "https://api.openai.com/v1/chat/completions".freeze
    MODEL = "gpt-6-luna".freeze
    SCRIPT_NAME = "Inspect selected pagination source".freeze
    SCRIPT_ID = "inspect-pagination".freeze
    COMPLETION_MARKER = "Chat Lua complete: #{SCRIPT_NAME}".freeze
    PREVIEW_STABLE_SAMPLES = 4
    PREVIEW_STABILITY_POLLS = 60
    PREVIEW_STABILITY_INTERVAL = 0.05
    LUA_LIMITS = "Limits: 64 KiB source, 8 MiB tracked Lua heap, 5 s, 16 KiB output; Chat shares 16 calls / 512 KiB result budget".freeze
    STATUS_EVENT = /(?:Chat Lua complete:|Chat (?:request|provider request|transport) failed|Chat Lua (?:failed|editor call refused)|Chat provider could not start)/i.freeze
    PROMPT = [
      "Diagnose the pagination defect in the currently selected source buffer.",
      "The contract is zero-based offset and a count-valued limit: return at most limit items, with the final page shortened at the end.",
      "The measured failures are: on red, green, blue, amber, indigo, (offset=1, limit=2) returns green, blue, amber instead of green, blue; (offset=2, limit=1) returns blue, amber instead of blue.",
      "Use only the approved read-only selected-buffer script to inspect the source, then propose a minimal fix to this buffer.",
      "Use the inspector's exact full-line edit span for any changed line, replacing the whole line with its original leading indentation and no trailing newline; do not guess substring columns.",
      "Do not inspect or request the spec, do not claim to run tests, and explain the boundary reasoning so I can review it manually.",
      "Reply in plain ASCII English only; do not use typographic punctuation or non-ASCII symbols.",
    ].join(" ").freeze
    ENTER = "\e[13u".freeze
    ESCAPE = "\e[27u".freeze
    F1 = "\eOP".freeze
    DOWN = "\e[B".freeze
    CTRL_S = "\e[115;5u".freeze

    DEMO_FILES = %w[
      README.md
      src/pagination.cr
      spec/pagination_spec.cr
      config/manifest.json
      config/scripts/inspect_pagination.lua
    ].freeze

    def initialize(editor_bin:, library_path:, timeout_seconds:)
      @editor_bin = validate_absolute_file(editor_bin, executable: true, label: "editor binary")
      @library_path = validate_absolute_file(library_path, executable: false, label: "Lua library")
      @deadline = Deadline.new(timeout_seconds)
      @provider_key = ENV["OPENAI_API_KEY"]
      raise Failure, "OPENAI_API_KEY is required in the invoking environment (value not shown)" if @provider_key.nil? || @provider_key.empty?

      @project_source_root = File.expand_path("../examples/luna_lua_demo", __dir__)
      @state = {
        mutex: Mutex.new,
        screen: ActiveTabProbe.new(WIDTH, HEIGHT),
        frames: [],
        milestones: {},
        status_history: [],
        success_marker_normalizer: SuccessMarkerNormalizer.new,
        screen_error: nil,
        reaped: false,
        status: nil,
        last_revision: -1,
      }
      @child_pid = nil
      @reader = @slave = @terminal_probe = nil
      @drain = nil
      @root = nil
      @review_text = nil
      @original_source_digest = nil
      @original_spec_digest = nil
      @private_source_digest = nil
      @private_spec_digest = nil
      @script_digest = nil
      @buffer_proposals_selected = false
    end

    def run
      prepare_private_demo
      validate_lua_library!
      puts "Private demo and sanitized captures: #{@root}"
      puts "Provider: #{MODEL} via #{ENDPOINT}; one reviewed turn, <=4 requests/turn, 2048 output tokens/request."
      puts "No provider request occurs until the explicit stdin command 'send'."

      red = run_spec("RED baseline")
      print_child_output("RED baseline", red[:output])
      validate_red_baseline!(red)

      start_app
      wait_for_app
      open_selected_source
      select_buffer_proposals_and_lua
      open_review
      @review_text = collect_review
      save_capture("Send-review.txt", @review_text)
      save_terminal_evidence("send-review")
      validate_review!(@review_text)
      assert_private_state!(before_save: true)
      puts "\n===== COMPLETE SEND REVIEW (sanitized; not yet submitted) ====="
      puts sanitize(@review_text)
      puts "===== END SEND REVIEW ====="
      print_checkpoint("SEND CONSENT CHECKPOINT", screen_text,
        "Send review: #{File.join(@root, "Send-review.txt")}",
        "Terminal frames: #{File.join(@root, "send-review-frames.json")}")
      command = wait_for_control(["send"], "Send review consent")
      raise Failure, "Send was not explicitly authorized" unless command == "send"

      assert_private_state!(before_save: true)
      press("y")
      puts "Send authorized once. Waiting for the real provider, Lua completion, and manual proposal preview."
      palette_action("Switch Chat / Log")
      await("Log tab active before provider output", seconds: 3) do
        @state[:mutex].synchronize { @state[:screen].active_tab == :log }
      end
      proposal = wait_for_model_proposal
      save_capture("proposal-preview.txt", proposal)
      save_terminal_evidence("proposal")
      save_completion_evidence!
      assert_private_state!(before_save: true)
      puts "\n===== MODEL PROPOSAL (sanitized; manual decision required) ====="
      puts sanitize(proposal)
      puts "===== END PROPOSAL ====="
      print_checkpoint("PROPOSAL DECISION CHECKPOINT", proposal,
        "Proposal preview: #{File.join(@root, "proposal-preview.txt")}",
        "Lua completion/status: #{File.join(@root, "Chat-Lua-completion.txt")}",
        "Terminal frames: #{File.join(@root, "proposal-frames.json")}")

      decision = wait_for_control(%w[accept reject], "proposal decision")
      if decision == "reject"
        press(ESCAPE)
        await("proposal rejection", seconds: 8) { !preview_visible?(screen_text) }
        assert_private_state!(before_save: true)
        save_capture("rejected.txt", screen_text)
        puts "Proposal rejected. The private source/spec remain unchanged; artifacts preserved at #{@root}."
        return
      end

      press(ENTER)
      await("manual proposal acceptance", seconds: 8) do
        !preview_visible?(screen_text) && screen_text.downcase.include?("chat proposed edits accepted")
      end
      assert_private_state!(before_save: true)
      puts "Proposal accepted in the editor but not saved. Saving now with the normal Ctrl+S action to the isolated demo copy."
      press(CTRL_S)
      await("explicit normal save", seconds: 12) do
        File.file?(@private_source) && Digest::SHA256.file(@private_source).hexdigest != @private_source_digest
      end
      assert_private_state!(before_save: false)
      save_capture("saved-buffer.txt", screen_text)

      green = run_spec("GREEN after-save")
      print_child_output("GREEN after-save", green[:output])
      unless green[:status].success? && spec_summary(green[:output]) == [10, 0, 0, 0]
        raise Failure, "post-save spec did not report 10 examples / 0 failures; private demo and captures preserved"
      end
      assert_private_state!(before_save: false)
      puts "PASS: one reviewed real-model turn completed; the proposal was manually accepted and saved only in #{@private_source}."
      puts "The original demo source/spec are unchanged. Private evidence remains at #{@root}."
    ensure
      begin
        terminate_app
      ensure
        persist_final_evidence
      end
    end

    def safe_error(message)
      detail = sanitize(message.to_s)
      if @root && File.directory?(@root)
        detail = "#{detail}\nPrivate demo/captures preserved at #{@root}"
      end
      detail
    end

    private

    def validate_absolute_file(path, executable:, label:)
      raise Failure, "#{label} path must be explicitly absolute" unless path && Pathname.new(path).absolute?
      real = File.realpath(path)
      raise Failure, "#{label} must be a regular file" unless File.file?(real)
      raise Failure, "#{label} must be executable" if executable && !File.executable?(real)
      real
    rescue Errno::ENOENT
      raise Failure, "#{label} does not exist"
    end

    def prepare_private_demo
      @deadline.check!("preparing isolated workspace")
      @root = Dir.mktmpdir("adamantine-chat-lua-demo-")
      File.chmod(0o700, @root)
      @root = File.realpath(@root)
      @project = File.join(@root, "project")
      @home = File.join(@root, "home")
      @state_home = File.join(@root, "state")
      @cache = File.join(@root, "crystal-cache")
      @tmp = File.join(@root, "tmp")
      @config = File.join(@root, "chat-config.json")
      @crystal_config = File.join(@root, "no-crystal-config.json")
      @private_source = File.join(@project, "src", "pagination.cr")
      @private_spec = File.join(@project, "spec", "pagination_spec.cr")
      @private_lua = File.join(@home, ".config", "adamantine", "lua")
      @private_script = File.join(@private_lua, "scripts", "inspect_pagination.lua")
      @crystal = find_executable("crystal")

      [@project, @home, @state_home, @cache, @tmp].each { |dir| FileUtils.mkdir_p(dir, mode: 0o700) }
      [@project, @home, @state_home, @cache, @tmp].each { |dir| File.chmod(0o700, dir) }

      source_root = File.realpath(@project_source_root)
      expected = {}
      DEMO_FILES.each do |relative|
        path = File.join(source_root, relative)
        info = File.lstat(path)
        raise Failure, "demo input is not a regular non-symlink file: #{relative}" unless info.file? && !info.symlink?
        expected[relative] = File.binread(path)
      end
      @original_source_digest = Digest::SHA256.hexdigest(expected.fetch("src/pagination.cr"))
      @original_spec_digest = Digest::SHA256.hexdigest(expected.fetch("spec/pagination_spec.cr"))
      @script_digest = Digest::SHA256.hexdigest(expected.fetch("config/scripts/inspect_pagination.lua"))

      DEMO_FILES.each do |relative|
        destination = File.join(@project, relative)
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        write_private(destination, expected.fetch(relative))
      end
      FileUtils.mkdir_p(File.join(@private_lua, "scripts"), mode: 0o700)
      write_private(File.join(@private_lua, "manifest.json"), expected.fetch("config/manifest.json"))
      write_private(@private_script, expected.fetch("config/scripts/inspect_pagination.lua"))
      @private_source_digest = Digest::SHA256.file(@private_source).hexdigest
      @private_spec_digest = Digest::SHA256.file(@private_spec).hexdigest
      raise Failure, "private demo copy does not match the original source/spec" unless
        @private_source_digest == @original_source_digest && @private_spec_digest == @original_spec_digest

      config = {
        "chat" => {
          "enabled" => true,
          "endpoint" => ENDPOINT,
          "model" => MODEL,
          "key_env" => "OPENAI_API_KEY",
          "max_completion_tokens" => 2048,
          "reasoning_effort" => "none",
        },
      }
      write_private(@config, JSON.pretty_generate(config) + "\n")
      File.chmod(0o600, @config)
      File.chmod(0o700, @private_lua)
      File.chmod(0o700, File.join(@private_lua, "scripts"))
    end

    def validate_lua_library!
      handle = Fiddle::Handle.new(@library_path)
      required = %w[luaL_newstate lua_newuserdatauv lua_resetthread lua_close]
      missing = required.reject do |name|
        begin
          handle.sym(name)
          true
        rescue Fiddle::DLError
          false
        end
      end
      raise Failure, "Lua library is missing Lua 5.4 runtime symbols: #{missing.join(", ")}" unless missing.empty?
    rescue Fiddle::DLError
      raise Failure, "Lua shared library could not be loaded; provider was not contacted"
    ensure
      handle&.close
    end

    def write_private(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
      File.chmod(0o600, path)
    end

    def find_executable(name)
      ENV.fetch("PATH", "/usr/bin:/bin").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return File.realpath(path) if File.file?(path) && File.executable?(path)
      end
      raise Failure, "required local executable #{name} was not found in PATH"
    end

    def app_environment
      {
        "TERM" => "xterm-256color",
        "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"),
        "LANG" => "C.UTF-8",
        "HOME" => @home,
        "XDG_CONFIG_HOME" => File.join(@home, ".config"),
        "XDG_CACHE_HOME" => File.join(@state_home, "cache"),
        "XDG_STATE_HOME" => @state_home,
        "ADAMANTINE_STATE_HOME" => @state_home,
        "ADAMANTINE_SESSION" => "0",
        "ADAMANTINE_RECOVERY" => "0",
        "ADAMANTINE_LUA_WORKER" => @editor_bin,
        "ADAMANTINE_LUA_LIBRARY" => @library_path,
        "ADAMANTINE_CONFIG" => @config,
        # The bounded PTY parser and production status glyphs assume the
        # success check mark occupies one cell. The pinned TUI treats this
        # ambiguous-width glyph as wide by default, then erases it when the
        # adjacent status cell is drawn.
        "TUI_AMBIGUOUS_WIDE" => "0",
        "CRYSTAL_EDITOR_CONFIG" => "",
        "TMPDIR" => @tmp,
        "OPENAI_API_KEY" => @provider_key,
      }
    end

    def test_environment
      {
        "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"),
        "LANG" => "C.UTF-8",
        "HOME" => @home,
        "XDG_CONFIG_HOME" => File.join(@home, ".config"),
        "XDG_CACHE_HOME" => File.join(@state_home, "cache"),
        "XDG_STATE_HOME" => @state_home,
        "ADAMANTINE_STATE_HOME" => @state_home,
        "ADAMANTINE_CONFIG" => @crystal_config,
        "CRYSTAL_EDITOR_CONFIG" => "",
        "CRYSTAL_CACHE_DIR" => @cache,
        "TMPDIR" => @tmp,
      }
    end

    def run_spec(label)
      @deadline.check!(label)
      args = [@crystal, "spec", "--error-trace"]
      args << "--link-flags=-fuse-ld=/usr/bin/ld" if RUBY_PLATFORM.include?("darwin")
      args << "spec/pagination_spec.cr"
      output = +""
      status = nil
      Open3.popen3(test_environment, *args, chdir: @project, unsetenv_others: true, pgroup: true) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        readers = [stdout, stderr].map do |io|
          Thread.new do
            begin
              loop do
                chunk = io.readpartial(4096)
                output << chunk if output.bytesize < 128 * 1024
              end
            rescue EOFError, IOError
            end
          end
        end
        unless wait_thread.join(@deadline.remaining)
          begin
            Process.kill("TERM", -wait_thread.pid)
          rescue Errno::ESRCH
          end
          wait_thread.join(1)
          begin
            Process.kill("KILL", -wait_thread.pid) if wait_thread.alive?
          rescue Errno::ESRCH
          end
          wait_thread.join
          raise Failure, "deadline exceeded running #{label} spec"
        end
        status = wait_thread.value
        readers.each(&:join)
      ensure
        stdout&.close rescue nil
        stderr&.close rescue nil
      end
      {status: status, output: sanitize(output)}
    rescue Errno::ENOENT => error
      raise Failure, "could not start Crystal spec: #{error.message}"
    end

    def print_child_output(label, output)
      puts "\n===== #{label} ====="
      puts output
      puts "===== END #{label} ====="
    end

    def spec_summary(output)
      line = output.lines.find do |candidate|
        candidate.match?(/^\d+ examples?, \d+ failures?, \d+ errors?, \d+ pending\s*$/)
      end
      match = line&.match(/^(\d+) examples?, (\d+) failures?, (\d+) errors?, (\d+) pending\s*$/)
      match && match.captures.map(&:to_i)
    end

    def validate_red_baseline!(result)
      output = result[:output]
      expected_titles = [
        "LunaLuaDemo::Pagination returns no more than the requested count for an interior page",
        "LunaLuaDemo::Pagination returns one item for an interior one-item page",
      ]
      actual_titles = output.lines.map do |line|
        line.match(/^\s+\d+\) (.+)$/)&.captures&.first
      end.compact
      normalized = output.gsub(/\s+/, " ")
      expected_values = [
        'got: ["green", "blue", "amber"]',
        'got: ["blue", "amber"]',
      ]
      unless !result[:status].success? && spec_summary(output) == [10, 2, 0, 0] &&
             actual_titles == expected_titles && expected_values.all? { |value| normalized.include?(value) }
        raise Failure, "baseline was not exactly the two intended pagination failures (10 examples, 2 failures, 0 errors, 0 pending); provider was not contacted"
      end
    end

    def start_app
      @deadline.check!("starting the App")
      @reader, @slave = PTY.open
      @slave.winsize = [HEIGHT, WIDTH]
      @terminal_probe = @slave.dup
      @child_pid = Process.spawn(app_environment, @editor_bin, @project, "--config", @config, "--no-lsp",
        in: @slave, out: @slave, err: @slave, pgroup: true, unsetenv_others: true)
      @slave.close
      @slave = nil
      @drain = Thread.new do
        begin
          loop do
            bytes = @reader.readpartial(16 * 1024)
            bytes = @state[:success_marker_normalizer].feed(bytes)
            next if bytes.empty?
            @state[:mutex].synchronize do
              @state[:screen].feed(bytes)
              revision = @state[:screen].revision
              if revision != @state[:last_revision]
                rows = @state[:screen].rows
                @state[:frames] << rows
                @state[:frames].shift while @state[:frames].length > 600
                if @state[:screen].active_tab == :log && !@state[:milestones].key?(:log_view_selected)
                  @state[:milestones][:log_view_selected] = {
                    revision: revision,
                    active_tab: :log,
                    rows: rows,
                  }
                end
                visible_log_rows = status_log_rows(rows)
                started_row = visible_log_rows.find { |row| chat_lua_started_row?(row) }
                if started_row && !@state[:milestones].key?(:chat_lua_started)
                  @state[:milestones][:chat_lua_started] = {
                    revision: revision,
                    status_row: started_row.strip,
                    rows: rows,
                  }
                end
                completion_row = visible_log_rows.find { |row| chat_lua_completion_row?(row) }
                if completion_row && !@state[:milestones].key?(:chat_lua_complete)
                  @state[:milestones][:chat_lua_complete] = {
                    revision: revision,
                    status_row: completion_row.strip,
                    rows: rows,
                  }
                end
                visible_log_rows.each do |row|
                  next unless row.match?(STATUS_EVENT)
                  @state[:status_history] << row.strip
                end
                @state[:status_history].shift while @state[:status_history].length > 128
                @state[:last_revision] = revision
              end
            end
          end
        rescue EOFError, IOError, Errno::EIO
          @state[:mutex].synchronize do
            begin
              tail = @state[:success_marker_normalizer].finish
              @state[:screen].feed(tail) unless tail.empty?
              @state[:screen].finish!
            rescue StandardError => error
              @state[:screen_error] ||= "#{error.class}: #{error.message}"
            end
          end
        rescue PtyScreen::UnsupportedSequence => error
          @state[:mutex].synchronize { @state[:screen_error] ||= error.message }
        rescue StandardError => error
          @state[:mutex].synchronize { @state[:screen_error] ||= "#{error.class}: #{error.message}" }
        end
      end
    end

    def wait_for_app
      await("production App readiness", seconds: 20) do
        current = screen_snapshot
        current[:rows].join("\n").include?("Adamantine") &&
          @state[:mutex].synchronize { @state[:screen].alternate_screen? && @state[:screen].kitty_keyboard_enabled? }
      end
      deadline = [@deadline.remaining, 6].min
      loop do
        @deadline.check!("waiting for PTY raw mode")
        mode = IO.popen(["/bin/stty", "-a"], "r", in: @terminal_probe, err: File::NULL, &:read).strip
        status = $?
        raise Failure, "could not inspect App PTY mode" unless status.success?
        return if mode.match?(/(?:\A|[;\s])-echo(?:[;\s]|\z)/) && mode.match?(/(?:\A|[;\s])-icanon(?:[;\s]|\z)/)
        raise Failure, "timed out waiting for App raw PTY mode" if @deadline.remaining <= 0 || deadline <= 0
        sleep 0.02
        deadline -= 0.02
      end
    end

    def open_selected_source
      palette_action("open file path")
      type_text("src/pagination.cr")
      press(ENTER)
      await("selected src/pagination.cr buffer", seconds: 12) do
        text = screen_text
        text.include?("def self.page") || text.include?("last_index")
      end
      assert_private_state!(before_save: true)
      assert_spec_never_opened!
    end

    def select_buffer_proposals_and_lua
      palette_action("Chat context")
      await("Chat context menu", seconds: 8) do
        text = screen_text.downcase
        text.include?("buffer read tools") && text.include?("selection proposals (read + propose)") &&
          text.include?("whole-file proposals")
      end
      # Menu order is None, Selection, Active buffer, Buffer read tools,
      # Selection proposals, Whole-file proposals. Keep this demo's existing
      # broad proposal scenario on the explicit whole-file permission.
      5.times { press(DOWN) }
      press(ENTER)
      await("Whole-file proposals context selection", seconds: 8) do
        history_text.include?("Chat context set to Whole-file proposals for the next accepted send")
      end
      @buffer_proposals_selected = true
      palette_action("Choose Lua script for next Chat turn")
      await("named read-only Lua catalog entry", seconds: 8) { screen_text.include?(SCRIPT_NAME) }
      type_text(SCRIPT_NAME)
      await("filtered read-only Lua catalog entry", seconds: 8) { screen_text.include?(SCRIPT_NAME) }
      press(ENTER)
      await("Lua picker close", seconds: 8) { !screen_text.include?("Choose Lua script for next Chat turn") }
      assert_private_state!(before_save: true)
      assert_spec_never_opened!
    end

    def open_review
      palette_action("Focus Chat")
      type_text(PROMPT)
      press(ENTER)
      await("Send review", seconds: 12) do
        text = screen_text.downcase
        text.include?("review chat send") || (text.include?("send this prompt") && text.include?("visible history"))
      end
    end

    def palette_action(label)
      press(F1)
      type_text(label)
      await("command palette entry #{label}", seconds: 10) do
        screen_text.include?(label) && child_alive?
      end
      press(ENTER)
    end

    def collect_review
      snapshots = []
      prior = wait_for_stable_review_panel
      snapshots << prior
      120.times do
        @deadline.check!("collecting the complete Send review")
        break if review_prompt_visible?(prior)

        # The screen revision also changes for SGR-only style updates. Wait for
        # the actual modal body to change and then settle before sending another
        # key, so a transient style redraw cannot masquerade as scroll progress.
        snapshot = scroll_review_body(prior)
        if snapshot.nil?
          unless review_prompt_visible?(prior)
            raise Failure, "Send review stopped scrolling before the full current prompt was visible"
          end
          break
        end
        snapshots << snapshot
        prior = snapshot
        break if review_prompt_visible?(snapshot)
      end
      unless review_prompt_visible?(prior)
        raise Failure, "Send review did not expose the full current prompt within the bounded modal scroll"
      end
      snapshots.join("\n")
    end

    def wait_for_stable_review_panel
      previous = nil
      stable_samples = 0

      REVIEW_STABILITY_POLLS.times do |poll|
        @deadline.check!("waiting for the Send review panel to settle")
        rows = screen_snapshot[:rows]
        title = rows[REVIEW_MODAL_Y]&.[](REVIEW_MODAL_X, REVIEW_MODAL_WIDTH)
        if title&.include?("Review Chat send")
          current = review_panel_text(rows)
          if current == previous
            stable_samples += 1
          else
            previous = current
            stable_samples = 1
          end
          return current if stable_samples >= REVIEW_STABLE_SAMPLES
        else
          previous = nil
          stable_samples = 0
        end

        sleep(REVIEW_STABILITY_INTERVAL) if poll + 1 < REVIEW_STABILITY_POLLS
      end

      raise Failure, "Send review panel did not settle into #{REVIEW_STABLE_SAMPLES} identical body snapshots"
    end

    def scroll_review_body(previous)
      REVIEW_SCROLL_ATTEMPTS.times do
        press(DOWN)
        snapshot = wait_for_review_body_change(previous, seconds: 0.8)
        return snapshot if snapshot
      end
      nil
    end

    def review_prompt_visible?(review)
      expected = normalize_review_text("Current prompt: #{PROMPT}")
      normalize_review_text(review).include?(expected)
    end

    def source_receipt_visible?(review)
      review.match?(/Model may read and send bounded excerpts from exact buffer src\/pagination\.cr(?: \(unsaved buffer\))?, revision [^\s]{1,128}(?=\s|$)/)
    end

    def wait_for_review_body_change(previous, seconds:)
      end_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + [seconds, @deadline.remaining].min
      changed_body = nil
      stable_since = nil
      loop do
        @deadline.check!("waiting for Send review body redraw")
        current = review_panel_text(screen_snapshot[:rows])
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if current != previous
          if current != changed_body
            changed_body = current
            stable_since = now
          elsif now - stable_since >= 0.06
            return current
          end
        end
        return nil if now >= end_at

        sleep 0.01
      end
    end

    def validate_review!(review)
      normalized = normalize_review_text(review)
      down = normalized.downcase
      exact = [
        "Send this prompt and visible history to #{MODEL}",
        "Destination: #{ENDPOINT}",
        "Credential: environment variable OPENAI_API_KEY (value not shown)",
        "Output limit: 2048 tokens/request; at most 4 requests/turn",
        "Reasoning effort: none",
        "History: 0 previous messages, 0 bytes",
        "Initial editor context: 0 bytes",
        "Named Lua: one execution this turn only; output is returned to #{MODEL}",
        "Read scope: 64 KiB/result, 512 KiB/session; max 16 calls, 4 requests, 4 calls/round",
        "One proposal attempt: at most 32 edits / 8 KiB tool request; manual review only; never auto-applied/saved",
        "Frozen script: #{SCRIPT_NAME} (ID #{SCRIPT_ID})",
        "SHA-256: #{@script_digest}",
        "Requested capabilities: read_editor",
        "Effective capabilities: read_editor",
        "Excluded capabilities: none",
        LUA_LIMITS,
        "Script source (frozen locally; not sent to provider):",
        "Current prompt: #{PROMPT.gsub(/\s+/, " ")}",
      ]
      raise Failure, "Whole-file proposals context was not selected before review" unless @buffer_proposals_selected
      exact.each do |fragment|
        raise Failure, "Send review omitted required disclosure: #{fragment}" unless normalized.include?(fragment)
      end
      unless source_receipt_visible?(normalized)
        raise Failure, "Send review did not bind the read authority to the selected source revision"
      end
      source = File.binread(@private_script).lines.map { |line| line.strip.gsub(/\s+/, " ") }.reject(&:empty?)
      cursor = normalized.index("Script source (frozen locally; not sent to provider):")
      raise Failure, "Send review omitted frozen Lua source heading" unless cursor
      source.each_with_index do |line, index|
        location = normalized.index(line, cursor)
        raise Failure, "Send review omitted Lua source line #{index + 1}" unless location
        cursor = location + line.length
      end
      raise Failure, "Send review mentioned the unopened spec" if down.include?("pagination_spec.cr")
      assert_spec_never_opened!
    end

    def normalize_review_text(review)
      review.gsub(/\s+/, " ")
    end

    def review_panel_text(rows)
      title_row = rows[REVIEW_MODAL_Y]
      title = title_row && title_row[REVIEW_MODAL_X, REVIEW_MODAL_WIDTH]
      unless rows.length == HEIGHT && title&.include?("Review Chat send")
        raise Failure, "Send review modal geometry changed; refusing to validate clipped text"
      end

      body_rows = rows[REVIEW_BODY_Y, REVIEW_BODY_HEIGHT]
      unless body_rows && body_rows.length == REVIEW_BODY_HEIGHT
        raise Failure, "Send review body was not fully visible"
      end

      body_rows.map do |row|
        content = row[REVIEW_BODY_X, REVIEW_BODY_WIDTH]
        unless content && content.length == REVIEW_BODY_WIDTH
          raise Failure, "Send review body row was clipped; refusing to validate it"
        end

        visible = content.rstrip
        if visible.length == REVIEW_BODY_WIDTH
          visible + (content.end_with?(" ") ? " " : "")
        else
          visible + "\n"
        end
      end.join
    end

    def wait_for_model_proposal
      await("real Chat Lua completion and proposal preview", seconds: @deadline.remaining) do
        current = screen_text
        terminal_events = @state[:mutex].synchronize { @state[:status_history].dup }
        success_seen = @state[:mutex].synchronize do
          @state[:milestones].key?(:log_view_selected) &&
            @state[:milestones].key?(:chat_lua_started) && @state[:milestones].key?(:chat_lua_complete)
        end
        fail_row = terminal_events.find { |line| line.match?(/Chat (?:request|provider request|transport) failed|Chat Lua (?:failed|editor call refused)|Chat provider could not start/i) }
        raise Failure, "provider/worker reported failure: #{sanitize(fail_row)}" if fail_row
        success_seen && preview_visible?(current) && current.include?("src/pagination.cr")
      end
      proposal = collect_stable_preview_text
      raise Failure, "model proposal omitted manual accept/reject controls" unless proposal.downcase.include?("apply") && proposal.downcase.match?(/esc.{0,8}reject/)
      raise Failure, "model proposal did not identify src/pagination.cr" unless proposal.include?("src/pagination.cr")
      assert_spec_never_opened!
      proposal
    end

    def collect_stable_preview_text
      previous_rows = nil
      stable_samples = 0

      PREVIEW_STABILITY_POLLS.times do |poll|
        @deadline.check!("waiting for proposal preview to settle")
        rows = screen_snapshot[:rows]
        text = rows.join("\n")
        if preview_visible?(text) && text.include?("src/pagination.cr")
          if rows == previous_rows
            stable_samples += 1
          else
            previous_rows = rows
            stable_samples = 1
          end
          return text if stable_samples >= PREVIEW_STABLE_SAMPLES
        else
          previous_rows = nil
          stable_samples = 0
        end

        sleep(PREVIEW_STABILITY_INTERVAL) if poll + 1 < PREVIEW_STABILITY_POLLS
      end

      raise Failure, "proposal preview did not settle into #{PREVIEW_STABLE_SAMPLES} identical full-screen frames; no decision checkpoint was opened"
    end

    def preview_visible?(text)
      down = text.downcase
      down.include?("chat proposed edits") && down.include?("selected 1/") &&
        down.include?("group 1/") && down.include?("apply") && down.match?(/esc.{0,8}reject/)
    end

    def wait_for_control(choices, phase)
      puts "\nAwaiting explicit stdin command for #{phase}: #{choices.join(" or ")}. EOF, timeout, or any other input refuses the action."
      loop do
        @deadline.check!("waiting for #{phase} input")
        ready = IO.select([STDIN], nil, nil, [@deadline.remaining, 1.0].min)
        next unless ready
        line = STDIN.gets
        raise Failure, "stdin closed during #{phase}; no consent was granted" if line.nil?
        command = line.strip.downcase
        return command if choices.include?(command)
        raise Failure, "invalid #{phase} command; no action was taken"
      end
    end

    def await(label, seconds:)
      end_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + [seconds, @deadline.remaining].min
      loop do
        @deadline.check!(label)
        raise Failure, "timed out waiting for #{label}; latest sanitized screen saved in #{@root}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= end_at
        raise Failure, "editor exited while waiting for #{label}" unless child_alive?
        return if yield
        sleep 0.02
      end
    end

    def screen_snapshot
      @state[:mutex].synchronize do
        raise Failure, "PTY tracker failed closed: #{@state[:screen_error]}" if @state[:screen_error]
        {revision: @state[:screen].revision, rows: @state[:screen].rows}
      end
    end

    def screen_text
      screen_snapshot[:rows].join("\n")
    end

    def status_log_rows(rows)
      header = @state[:screen].active_header
      return [] unless header && header[2] == :log
      header_index = header[0]

      # The fixed 160x32 demo has a bottom command row. The selected Log view
      # occupies only the rows between its current header and that footer.
      footer_index = rows.index { |row| row.match?(/\A1Commands\s+2Tree\s+3Editor\s/) }
      return [] unless footer_index && footer_index > header_index

      rows[(header_index + 1)...footer_index].to_a.map do |row|
        # Tui::Log draws its scrollbar in the widget's final cell. Do not let
        # that real UI cell invalidate an otherwise exact full-row status
        # marker. A row with a different width remains untouched and fails the
        # anchored status checks below.
        if row.length == WIDTH && ["│", "█"].include?(row[-1])
          row[0...-1]
        else
          row
        end
      end
    end

    def chat_lua_started_row?(row)
      row.strip.match?(/\A\d{2}:\d{2}:\d{2} I Chat Lua started: #{Regexp.escape(SCRIPT_NAME)} \[#{Regexp.escape(@script_digest.to_s[0, 12])}\]\z/)
    end

    def chat_lua_completion_row?(row)
      row.strip.match?(/\A\d{2}:\d{2}:\d{2} \+ #{Regexp.escape(COMPLETION_MARKER)}\z/)
    end

    def history_text
      @state[:mutex].synchronize { @state[:frames].map { |frame| frame.join("\n") }.join("\n") }
    end

    def save_terminal_evidence(label)
      snapshot = @state[:mutex].synchronize do
        {
          frames: @state[:frames].map { |rows| rows.join("\n") },
          milestones: @state[:milestones].transform_values do |event|
            {revision: event[:revision], active_tab: event[:active_tab], status_row: event[:status_row], frame: event[:rows].join("\n")}
          end,
          status_history: @state[:status_history].dup,
        }
      end
      save_capture("#{label}-frames.json", JSON.pretty_generate(snapshot))
    end

    def save_completion_evidence!
      event = @state[:mutex].synchronize { @state[:milestones][:chat_lua_complete] }
      log_view = @state[:mutex].synchronize { @state[:milestones][:log_view_selected] }
      raise Failure, "no captured production Chat Lua completion status" unless event
      raise Failure, "Log tab was not confirmed active before status capture" unless log_view && log_view[:active_tab] == :log
      raise Failure, "captured completion marker did not match the selected script" unless chat_lua_completion_row?(event[:status_row])
      save_capture("Chat-Lua-completion.txt", [
        "Evidence source: visible Chat / Log region from the production App status log.",
        "Active view: Log; confirmed by the production ChatPanel active-tab bold SGR style before the completion status was accepted.",
        "PTY-only normalization: Tui::Log success glyph U+2713 is rendered as + for the bounded screen parser.",
        event[:status_row],
        "",
        *event[:rows],
      ].join("\n"))
    end

    def print_checkpoint(title, frame, *artifacts)
      puts "\n===== #{title} ====="
      artifacts.each { |artifact| puts artifact }
      puts "Current frame (sanitized):"
      puts concise_frame(sanitize(frame))
      puts "===== END #{title} ====="
    end

    def concise_frame(text)
      rows = text.lines.map(&:rstrip).reject(&:empty?)
      relevant = rows.select do |row|
        row.match?(/Chat|Lua|proposal|src\/pagination|selected|group|apply|reject|pagination|complete|error/i)
      end
      chosen = (relevant.empty? ? rows.last(12) : relevant.last(16))
      chosen.join("\n").byteslice(0, 3000).to_s
    end

    def persist_final_evidence
      return unless @root && File.directory?(@root)
      begin
        snapshot = @state[:mutex].synchronize { @state[:screen].rows.join("\n") }
        save_capture("latest-screen.txt", snapshot)
      rescue StandardError
        # Keep best-effort evidence failures from masking the original result.
      end
      begin
        save_terminal_evidence("sanitized-pty")
      rescue StandardError
        # The primary review/proposal captures remain the evidence source.
      end
      begin
        save_completion_evidence! if @state[:mutex].synchronize { @state[:milestones].key?(:chat_lua_complete) }
      rescue StandardError
        # A missing completion capture is reported by the run's explicit gate.
      end
    end

    def type_text(text)
      text.each_codepoint { |codepoint| press("\e[#{codepoint}u") }
    end

    def press(sequence)
      @deadline.check!("writing a PTY input")
      raise Failure, "App input is not ready" unless @reader && @child_pid && child_alive?
      @reader.write(sequence)
      @reader.flush
    rescue Errno::EIO, IOError
      raise Failure, "App PTY closed before the requested UI action"
    end

    def child_alive?
      return false unless @child_pid
      !reap_child_nonblocking!
    end

    def reap_child_nonblocking!
      return true if @state[:reaped]
      waited = Process.waitpid(@child_pid, Process::WNOHANG)
      return false unless waited
      @state[:reaped] = true
      @state[:status] = $?
      true
    rescue Errno::ECHILD
      @state[:reaped] = true
      true
    end

    def assert_private_state!(before_save:)
      expected = before_save ? @private_source_digest : nil
      if expected && Digest::SHA256.file(@private_source).hexdigest != expected
        raise Failure, "private source changed before explicit Save"
      end
      if Digest::SHA256.file(@private_spec).hexdigest != @private_spec_digest
        raise Failure, "unopened private spec changed"
      end
      if Digest::SHA256.file(File.join(@project_source_root, "src/pagination.cr")).hexdigest != @original_source_digest ||
         Digest::SHA256.file(File.join(@project_source_root, "spec/pagination_spec.cr")).hexdigest != @original_spec_digest
        raise Failure, "original example source/spec changed outside the isolated copy"
      end
      assert_spec_never_opened!
    end

    def assert_spec_never_opened!
      if history_text.include?("pagination_spec.cr") || screen_text.include?("pagination_spec.cr")
        raise Failure, "the App exposed the unopened spec path"
      end
    end

    def save_capture(name, text)
      path = File.join(@root, name)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(sanitize(text))
        file.write("\n") unless text.end_with?("\n")
      end
      File.chmod(0o600, path)
    end

    def sanitize(text)
      result = text.to_s.dup
      result.gsub!(@provider_key, "[REDACTED]") if @provider_key && !@provider_key.empty?
      result.gsub!(/\bsk-[A-Za-z0-9_-]{16,}\b/, "[REDACTED]")
      result.gsub!(/\bBearer\s+[^\s\"']+/i, "Bearer [REDACTED]")
      result
    end

    def terminate_app
      return unless @child_pid
      pid = @child_pid
      if process_group_alive?(pid)
        signal_process_group("TERM", pid)
        wait_for_group_exit(pid, 2.0)
        if process_group_alive?(pid)
          # The group is the one created for this driver-owned App; verify it
          # still exists immediately before escalation to avoid signaling a
          # process group that has already exited.
          signal_process_group("KILL", pid) if process_group_alive?(pid)
          wait_for_group_exit(pid, 2.0)
        end
      end
      reap_child_nonblocking! unless @state[:reaped]
      unless @state[:reaped]
        begin
          Process.waitpid(pid)
          @state[:status] = $?
        rescue Errno::ECHILD
          # Another wait path already consumed the only child status.
        ensure
          @state[:reaped] = true
        end
      end
      @slave&.close rescue nil
      @terminal_probe&.close rescue nil
      @drain&.join(1)
      @drain&.kill if @drain&.alive?
      @drain&.join(1)
      @reader&.close rescue nil
      @child_pid = nil
    end

    def process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def signal_process_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      false
    end

    def wait_for_group_exit(pid, seconds)
      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      while process_group_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < ending
        reap_child_nonblocking! unless @state[:reaped]
        sleep 0.02
      end
      reap_child_nonblocking! unless @state[:reaped]
    end
  end

  def self.parse_options(argv)
    options = {editor_bin: nil, library_path: nil, allow_paid: false, timeout: 300.0}
    parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/demo_chat_lua.rb --editor-bin ABSOLUTE_PATH --library-path ABSOLUTE_PATH --allow-paid [--timeout SECONDS]\nOPENAI_API_KEY must already exist in the invoking environment; do not put it in command arguments or shell history."
      opts.on("--editor-bin PATH", "Absolute path to the privately built production editor") { |value| options[:editor_bin] = value }
      opts.on("--library-path PATH", "Absolute compatible Lua 5.4 shared library") { |value| options[:library_path] = value }
      opts.on("--allow-paid", "Required explicit opt-in; this demo can send one paid provider turn") { options[:allow_paid] = true }
      opts.on("--timeout SECONDS", Float, "Whole-run deadline, 30..300 seconds (default 300)") { |value| options[:timeout] = value }
      opts.on("-h", "--help", "Show this help") { puts opts; return nil }
    end
    begin
      parser.parse!(argv)
    rescue OptionParser::ParseError
      raise Failure, "invalid command-line options; see --help"
    end
    raise Failure, "unexpected positional arguments; see --help" unless argv.empty?
    raise Failure, "--editor-bin and --library-path are required" unless options[:editor_bin] && options[:library_path]
    raise Failure, "--timeout must be between 30 and 300 seconds" unless options[:timeout].between?(30.0, 300.0)
    raise Failure, "--allow-paid is required; no provider call was made" unless options[:allow_paid]
    options
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = AdamantineChatLuaDemo.parse_options(ARGV)
    exit 0 unless options
    driver = AdamantineChatLuaDemo::Driver.new(
      editor_bin: options.fetch(:editor_bin),
      library_path: options.fetch(:library_path),
      timeout_seconds: options.fetch(:timeout)
    )
    driver.run
  rescue Interrupt
    warn "Interrupted. No implicit consent was granted; the private demo/capture directory is preserved."
    exit 130
  rescue StandardError => error
    message = defined?(driver) && driver ? driver.safe_error(error.message) : error.message
    warn "FAIL: #{message}"
    exit 1
  end
end
