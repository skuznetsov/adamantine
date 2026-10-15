#!/usr/bin/env ruby
require "json"
require "minitest/autorun"
require "open3"
require "optparse"
require "timeout"

options = {editor_bin: nil, library_path: nil}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/test_luna_lua_inspector.rb --editor-bin PATH --library-path PATH"
  parser.on("--editor-bin PATH", "Privately built production editor executable") { |path| options[:editor_bin] = path }
  parser.on("--library-path PATH", "Trusted compatible Lua 5.4 shared library") { |path| options[:library_path] = path }
  parser.on("-h", "--help") { puts parser; exit 0 }
end.parse!

abort "--editor-bin and --library-path are required" unless options[:editor_bin] && options[:library_path]

EDITOR_BIN = File.expand_path(options[:editor_bin]).freeze
LIBRARY_PATH = File.expand_path(options[:library_path]).freeze
INSPECTOR_PATH = File.expand_path("../examples/luna_lua_demo/config/scripts/inspect_pagination.lua", __dir__).freeze
WORKER_FLAG = "--internal-lua-worker".freeze

class LunaLuaInspectorTest < Minitest::Test
  def test_complete_ascii_unicode_and_empty_rows_use_host_half_open_columns
    rows = [
      {line: 1, start_column: 0, end_column: 5, text: "  abc", complete: true},
      {line: 2, start_column: 0, end_column: 2, text: "λ猫", complete: true},
      {line: 3, start_column: 0, end_column: 0, text: "", complete: true},
    ]
    output, arguments = run_inspector(rows, partial: false)

    assert_equal({
      "buffer_id" => "buffer-17", "revision" => "rev-opaque-42",
      "start_line" => 1, "line_count" => 64, "start_column" => 0, "max_columns" => 160,
    }, arguments)
    assert_includes output, "Approved buffer: buffer-17 revision rev-opaque-42"
    assert_includes output, "Project-relative path: src/pagination.cr; first line: 1"
    assert_includes output, "1:   abc"
    assert_includes output, "2: λ猫"
    assert_includes output, "3: "
    assert_span output, 1, 5
    assert_span output, 2, 2
    assert_span output, 3, 0
    assert_includes output, "leading indentation in new_text"
    assert_includes output, "do not add a newline"
  end

  def test_partial_result_reports_complete_lines_but_no_span_for_truncated_row
    rows = [
      {line: 1, start_column: 0, end_column: 8, text: "complete", complete: true},
      {line: 2, start_column: 0, end_column: 160, text: "x" * 160, complete: false},
    ]
    output, = run_inspector(rows, partial: true,
      continuation: {start_line: 2, start_column: 160})

    assert_includes output, "1: complete"
    assert_span output, 1, 8
    assert_includes output, "2: #{'x' * 160} [partial line; trailing columns not included]"
    refute span_reported?(output, 2)
    assert_includes output, "Read is partial; next fragment begins at line 2, column 160."
  end

  def test_missing_metadata_and_nonzero_start_never_claim_a_safe_span
    rows = [
      {line: 1, start_column: 0, end_column: 2, text: "ok"}, # missing complete
      {line: 2, start_column: 0, text: "end missing", complete: true}, # missing end_column
      {line: 3, start_column: 1, end_column: 4, text: "art", complete: true},
    ]
    output, = run_inspector(rows, partial: false)

    assert_includes output, "1: ok"
    assert_includes output, "2: end missing"
    assert_includes output, "3: art"
    rows.each { |row| refute span_reported?(output, row.fetch(:line)) }
    assert_includes output, "Approved buffer: buffer-17 revision rev-opaque-42"
  end

  def test_receipt_identity_and_requested_start_line_must_match
    row = {line: 1, start_column: 0, end_column: 6, text: "secret", complete: true}
    mutations = [
      [{buffer_id: "other-buffer"}, []],
      [{revision: "other-revision"}, []],
      [{start_line: 2}, []],
      [{}, [:buffer_id]],
      [{}, [:revision]],
      [{}, [:start_line]],
    ]

    mutations.each do |overrides, omitted|
      output, = run_inspector([row], partial: false,
        data_overrides: overrides, omit_data_keys: omitted)

      assert_includes output, "Selected-buffer read returned inconsistent receipt or completion metadata",
        "metadata mutation #{overrides.inspect}/#{omitted.inspect} should fail closed"
      refute_includes output, "1: secret"
      refute_includes output, "Span:"
    end
  end

  def test_result_complete_and_partial_must_be_boolean_complements
    row = {line: 1, start_column: 0, end_column: 6, text: "secret", complete: true}
    mutations = [
      [{complete: true, partial: true}, []],
      [{complete: false, partial: false}, []],
      [{complete: "true"}, []],
      [{partial: 0}, []],
      [{}, [:complete]],
      [{}, [:partial]],
    ]

    mutations.each do |overrides, omitted|
      output, = run_inspector([row], partial: false,
        data_overrides: overrides, omit_data_keys: omitted)

      assert_includes output, "Selected-buffer read returned inconsistent receipt or completion metadata",
        "completion mutation #{overrides.inspect}/#{omitted.inspect} should fail closed"
      refute_includes output, "1: secret"
      refute_includes output, "Span:"
    end
  end

  def test_safe_span_rows_must_match_order_and_stay_within_requested_range
    rows = [
      {line: 1, start_column: 0, end_column: 4, text: "safe", complete: true},
      {line: 3, start_column: 0, end_column: 8, text: "out of order", complete: true},
      {line: 65, start_column: 0, end_column: 9, text: "out of range", complete: true},
    ]
    output, = run_inspector(rows, partial: false)

    assert_span output, 1, 4
    refute span_reported?(output, 3)
    refute span_reported?(output, 65)
    assert_includes output, "3: out of order"
    assert_includes output, "65: out of range"
  end

  def test_all_64_complete_128_column_ascii_rows_fit_both_worker_output_budgets
    rows = (1..64).map do |line|
      {line: line, start_column: 0, end_column: 128,
       text: format("%02d", line) + ("x" * 126), complete: true}
    end
    output, arguments, event_count, terminal = run_inspector(rows, partial: false)

    assert_equal "buffer-17", arguments.fetch("buffer_id")
    assert_includes output, "Approved buffer: buffer-17 revision rev-opaque-42"
    assert_includes output, "Project-relative path: src/pagination.cr; first line: 1"
    assert_includes output, "Preserve leading indentation in new_text"
    assert_includes output, "do not add a newline"
    rows.each do |row|
      assert_includes output, "#{row.fetch(:line)}: #{row.fetch(:text)}"
      assert_span output, row.fetch(:line), 128
    end
    assert_equal 1, event_count, "the complete bounded report should be one worker output event"
    assert_operator output.bytesize, :<=, 16 * 1024
    assert_equal "complete", terminal.fetch("kind")
  end

  def test_report_that_exceeds_the_byte_limit_fails_without_silent_truncation
    rows = (1..64).map do |line|
      {line: line, start_column: 0, end_column: 160, text: "界" * 160, complete: true}
    end
    output, _arguments, event_count, terminal = run_inspector(rows,
      partial: false, expected_failure: "output_limit")

    assert_empty output, "an over-limit aggregate report must not be partially presented as complete"
    assert_equal 0, event_count
    assert_equal "failed", terminal.fetch("kind")
    assert_equal "output_limit", terminal.fetch("code")
  end

  private

  def assert_span(output, line, end_column)
    assert_includes output, "Span: start_line=#{line},start_column=0,end_line=#{line},end_column=#{end_column}"
  end

  def span_reported?(output, line)
    output.include?("Span: start_line=#{line},")
  end

  def run_inspector(rows, partial:, continuation: nil, expected_failure: nil,
    data_overrides: {}, omit_data_keys: [])
    source = File.read(INSPECTOR_PATH)
    context = {selected_buffer: {buffer_id: "buffer-17", revision: "rev-opaque-42"}}
    response = {
      status: "ok",
      data: {
        buffer_id: "buffer-17", revision: "rev-opaque-42",
        path: "src/pagination.cr", start_line: 1,
        lines: rows, complete: !partial, partial: partial, continuation: continuation,
      },
    }
    response[:data].merge!(data_overrides)
    omit_data_keys.each { |key| response[:data].delete(key) }

    output = +""
    arguments = nil
    output_events = 0
    terminal = nil
    env = {"ADAMANTINE_LUA_LIBRARY" => LIBRARY_PATH}
    Open3.popen3(env, EDITOR_BIN, WORKER_FLAG, unsetenv_others: true, chdir: "/") do |stdin, stdout, stderr, wait_thread|
      stdin.sync = true
      stdin.write(JSON.generate({
        kind: "start", version: 1, script_id: "inspect-pagination",
        source: source, context: context,
        limits: {lua_heap_bytes: 8 * 1024 * 1024, output_bytes: 16 * 1024, output_events: 64},
      }) + "\n")

      tool = read_frame(stdout)
      assert_equal "tool", tool.fetch("kind")
      assert_equal "editor.read_buffer", tool.fetch("name")
      arguments = tool.fetch("arguments")
      assert_equal "buffer-17", arguments.fetch("buffer_id")
      assert_equal "rev-opaque-42", arguments.fetch("revision")

      stdin.write(JSON.generate({
        kind: "reply", id: tool.fetch("id"), response: JSON.generate(response),
      }) + "\n")

      loop do
        frame = read_frame(stdout)
        case frame.fetch("kind")
        when "output"
          output_events += 1
          output << frame.fetch("text")
        when "complete"
          terminal = frame
          break
        when "failed"
          if expected_failure
            assert_equal expected_failure, frame.fetch("code")
            terminal = frame
            break
          end
          flunk "Lua worker failed: #{frame.inspect}; stderr=#{stderr.read.inspect}"
        when "tool"
          flunk "inspector made an unexpected extra tool call: #{frame.inspect}"
        else
          flunk "unexpected worker frame: #{frame.inspect}"
        end
      end

      stdin.close
      status = wait_thread.value
      if expected_failure
        refute status.success?, "worker unexpectedly succeeded despite the expected output limit"
      else
        assert status.success?, "Lua worker exited #{status.exitstatus}; stderr=#{stderr.read.inspect}"
      end
    ensure
      [stdin, stdout, stderr].each { |io| io.close unless io.closed? }
      if wait_thread && wait_thread.alive?
        Process.kill("TERM", wait_thread.pid) rescue nil
        Timeout.timeout(2) { wait_thread.value } rescue nil
      end
    end

    [output, arguments, output_events, terminal]
  end

  def read_frame(stdout)
    line = Timeout.timeout(10) { stdout.gets }
    raise "Lua worker closed stdout before a terminal frame" unless line

    JSON.parse(line)
  end
end
