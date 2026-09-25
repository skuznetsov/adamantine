#!/usr/bin/env ruby

require "csv"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "time"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SCHEMA = "adamantine.responsiveness"
SCHEMA_VERSION = 1
MAX_CAPTURE_BYTES = 64 * 1024
MAX_EXCERPT_BYTES = 4096
DEFAULT_TIMEOUT_SECONDS = 180.0
TERM_GRACE_SECONDS = 0.75
POLL_INTERVAL_SECONDS = 0.05
OUTPUT_DRAIN_GRACE_SECONDS = 0.5
# Probe timing, allocation, GC/fiber-gap, and sampled RSS values are
# observations only; pass/fail is structural/behavioral plus watchdog-based.

ProbeResult = Struct.new(
  :status,
  :stdout,
  :stderr,
  :stdout_bytes,
  :stderr_bytes,
  :stdout_truncated,
  :stderr_truncated,
  :exit_status,
  :signal,
  :timed_out,
  :reaped,
  :duration_ms,
  :peak_rss_kb,
  :rss_samples,
  :pid,
  :error,
  keyword_init: true
)

class ValidationError < StandardError
end

def monotonic_seconds
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def excerpt(value)
  value.to_s.byteslice(0, MAX_EXCERPT_BYTES).to_s.scrub
end

def bounded_read(io)
  retained = +""
  total_bytes = 0
  truncated = false

  begin
    loop do
      chunk = io.readpartial(16 * 1024)
      total_bytes += chunk.bytesize
      unless truncated
        remaining = MAX_CAPTURE_BYTES - retained.bytesize
        if chunk.bytesize <= remaining
          retained << chunk
        else
          retained << chunk.byteslice(0, remaining) if remaining.positive?
          truncated = true
        end
      end
    end
  rescue EOFError, IOError, SystemCallError
    # Closing a pipe after process-group cleanup is an expected end state.
  ensure
    io.close unless io.closed?
  end

  {
    value: retained.scrub,
    bytes: total_bytes,
    truncated: truncated,
  }
end

def sample_rss_kb(pid)
  stdout, _stderr, status = Open3.capture3("ps", "-o", "rss=", "-p", pid.to_s)
  return nil unless status.success?

  values = stdout.lines.map do |line|
    value = line.strip
    next if value.empty? || !value.match?(/\A\d+\z/)

    Integer(value, 10)
  rescue ArgumentError
    nil
  end.compact
  values.max
rescue StandardError
  # RSS is an observation only. A missing ps, a permission error, or a race
  # with process exit must never change a scenario's pass/fail result.
  nil
end

def terminate_process_group(pid, signal)
  Process.kill(signal, -pid)
rescue Errno::ESRCH, Errno::EPERM
  nil
end

def finish_capture_threads(stdout_thread, stderr_thread, stdout_io, stderr_io)
  threads = [stdout_thread, stderr_thread]
  deadline = monotonic_seconds + OUTPUT_DRAIN_GRACE_SECONDS
  threads.each do |thread|
    remaining = deadline - monotonic_seconds
    thread.join(remaining) if remaining.positive?
  end

  unless threads.none?(&:alive?)
    # A successful direct child can still leave a detached descendant holding
    # inherited output descriptors. Bound the drain independently of the
    # process watchdog, then interrupt the local readers if close is not enough.
    stdout_io.close unless stdout_io.closed?
    stderr_io.close unless stderr_io.closed?
    threads.each do |thread|
      next if thread.join(OUTPUT_DRAIN_GRACE_SECONDS)

      thread.kill
      thread.join
    end
  end

  empty = {value: "", bytes: 0, truncated: false}
  [stdout_thread.value || empty, stderr_thread.value || empty]
end

def run_process(argv, env:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, sample_rss: false)
  started_at = monotonic_seconds
  peak_rss_kb = nil
  rss_samples = 0
  timed_out = false
  reaped = false
  pid = nil

  begin
    stdin, stdout_io, stderr_io, waiter = Open3.popen3(
      env,
      *argv,
      chdir: ROOT,
      pgroup: true
    )
    pid = waiter.pid
    stdin.close
    stdout_thread = Thread.new { bounded_read(stdout_io) }
    stderr_thread = Thread.new { bounded_read(stderr_io) }

    sample = lambda do
      next unless sample_rss

      value = sample_rss_kb(pid)
      next unless value

      rss_samples += 1
      peak_rss_kb = value if !peak_rss_kb || value > peak_rss_kb
    end

    sample.call
    deadline = started_at + timeout_seconds
    until waiter.join(POLL_INTERVAL_SECONDS)
      sample.call
      next unless monotonic_seconds >= deadline

      timed_out = true
      terminate_process_group(pid, "TERM")
      grace_deadline = monotonic_seconds + TERM_GRACE_SECONDS
      until waiter.join(POLL_INTERVAL_SECONDS)
        break if monotonic_seconds >= grace_deadline
      end
      # The direct child may exit after TERM while a descendant still holds a
      # pipe or keeps doing work. Always issue the group KILL after the grace
      # window; ESRCH is harmless when the whole group already exited.
      terminate_process_group(pid, "KILL")
      # A descendant can escape the process group with setsid while retaining
      # the inherited output descriptors. Close our read ends so such a process
      # cannot keep the capture threads blocked after the direct child is dead.
      stdout_io.close unless stdout_io.closed?
      stderr_io.close unless stderr_io.closed?
      break
    end

    status = waiter.value
    reaped = true
    stdout_result, stderr_result = finish_capture_threads(stdout_thread, stderr_thread, stdout_io, stderr_io)
    ProbeResult.new(
      status: timed_out ? :timeout : (status.success? ? :success : :failure),
      stdout: stdout_result[:value],
      stderr: stderr_result[:value],
      stdout_bytes: stdout_result[:bytes],
      stderr_bytes: stderr_result[:bytes],
      stdout_truncated: stdout_result[:truncated],
      stderr_truncated: stderr_result[:truncated],
      exit_status: status.exitstatus,
      signal: status.termsig,
      timed_out: timed_out,
      reaped: reaped,
      duration_ms: ((monotonic_seconds - started_at) * 1000.0).round(3),
      peak_rss_kb: peak_rss_kb,
      rss_samples: rss_samples,
      pid: pid
    )
  rescue StandardError => error
    terminate_process_group(pid, "TERM") if pid
    terminate_process_group(pid, "KILL") if pid
    ProbeResult.new(
      status: :error,
      stdout: "",
      stderr: "",
      stdout_bytes: 0,
      stderr_bytes: 0,
      stdout_truncated: false,
      stderr_truncated: false,
      exit_status: nil,
      signal: nil,
      timed_out: false,
      reaped: false,
      duration_ms: ((monotonic_seconds - started_at) * 1000.0).round(3),
      peak_rss_kb: peak_rss_kb,
      rss_samples: rss_samples,
      pid: pid,
      error: error
    )
  end
end

def positive_integer!(value, label)
  raise ValidationError, "#{label} must be a positive integer" unless value.match?(/\A[1-9]\d*\z/)

  Integer(value, 10)
rescue ArgumentError
  raise ValidationError, "#{label} must be a positive integer"
end

def nonnegative_integer!(value, label)
  raise ValidationError, "#{label} must be a nonnegative integer" unless value.match?(/\A\d+\z/)

  Integer(value, 10)
rescue ArgumentError
  raise ValidationError, "#{label} must be a nonnegative integer"
end

def nonnegative_float!(value, label)
  unless value.match?(/\A(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/)
    raise ValidationError, "#{label} must be a nonnegative finite number"
  end

  number = Float(value)
  raise ValidationError, "#{label} must be a nonnegative finite number" unless number.finite? && number >= 0

  number
rescue ArgumentError
  raise ValidationError, "#{label} must be a nonnegative finite number"
end

def csv_rows!(stdout, expected_header, numeric_fields, label)
  raise ValidationError, "#{label} produced no output" if stdout.nil? || stdout.empty?

  parsed = CSV.parse(stdout)
  raise ValidationError, "#{label} produced no CSV rows" if parsed.empty?

  header = parsed.shift
  actual_header = header
  unless actual_header == expected_header
    raise ValidationError, "#{label} header mismatch: expected #{expected_header.inspect}, got #{actual_header.inspect}"
  end
  raise ValidationError, "#{label} produced zero data rows" if parsed.empty?

  parsed.map.with_index do |row, index|
    if row.size != expected_header.size
      raise ValidationError, "#{label} row #{index + 1} has #{row.size} fields, expected #{expected_header.size}"
    end

    values = row
    expected_header.each_with_index do |field, field_index|
      if values[field_index].nil? || values[field_index].empty?
        raise ValidationError, "#{label} row #{index + 1} has an empty #{field}"
      end
    end
    numeric_fields.each do |field, kind|
      field_index = expected_header.index(field)
      values[field_index] = kind == :integer ? nonnegative_integer!(values[field_index], "#{label} #{field}") : nonnegative_float!(values[field_index], "#{label} #{field}")
    end
    expected_header.each_with_index.to_h { |field, field_index| [field, values[field_index]] }
  rescue CSV::MalformedCSVError => error
    raise ValidationError, "#{label} malformed CSV row #{index + 1}: #{error.message}"
  end
rescue CSV::MalformedCSVError => error
  raise ValidationError, "#{label} malformed CSV: #{error.message}"
end

def validate_fixture_rows!(rows, label, expected_mode, expected_fixtures)
  raise ValidationError, "#{label} produced zero rows" if rows.empty?

  modes = rows.map { |row| row.fetch("mode") }.uniq
  raise ValidationError, "#{label} mode mismatch: #{modes.inspect}" unless modes == [expected_mode]

  actual_fixtures = rows.map { |row| row.fetch("fixture") }.uniq.sort
  missing = expected_fixtures - actual_fixtures
  unexpected = actual_fixtures - expected_fixtures
  unless missing.empty? && unexpected.empty?
    raise ValidationError, "#{label} fixture mismatch: missing=#{missing.inspect} unexpected=#{unexpected.inspect}"
  end
  expected_fixtures.each do |fixture|
    count = rows.count { |row| row.fetch("fixture") == fixture }
    raise ValidationError, "#{label} fixture #{fixture} has no positive row count" unless count.positive?
  end
end

def parse_search(stdout, label)
  rows = csv_rows!(
    stdout,
    %w[mode fixture bytes iteration scan_ms allocated_bytes max_fiber_gap_ms],
    {
      "bytes" => :integer,
      "iteration" => :integer,
      "scan_ms" => :float,
      "allocated_bytes" => :integer,
      "max_fiber_gap_ms" => :float,
    },
    label
  )
  validate_fixture_rows!(rows, label, "buffer", ["many-lines", "single-line"])
  rows
end

def parse_replace(stdout, label)
  rows = csv_rows!(
    stdout,
    %w[mode fixture bytes iteration replace_ms allocated_bytes],
    {
      "bytes" => :integer,
      "iteration" => :integer,
      "replace_ms" => :float,
      "allocated_bytes" => :integer,
    },
    label
  )
  validate_fixture_rows!(rows, label, "buffer", ["dense", "sparse-lines", "sparse-long-line"])
  rows
end

def parse_lexical(stdout, label)
  rows = csv_rows!(
    stdout,
    %w[bytes lines batches elapsed_ms max_batch_ms gross_allocated_bytes live_gc_delta_bytes],
    {
      "bytes" => :integer,
      "lines" => :integer,
      "batches" => :integer,
      "elapsed_ms" => :float,
      "max_batch_ms" => :float,
      "gross_allocated_bytes" => :integer,
      "live_gc_delta_bytes" => :integer,
    },
    label
  )
  rows.each do |row|
    positive_integer!(row.fetch("lines").to_s, "#{label} lines")
    positive_integer!(row.fetch("batches").to_s, "#{label} batches")
  end
  rows
end

def parse_inline_preview(stdout, label)
  csv_rows!(
    stdout,
    %w[source_bytes prepare_ms preview_and_200_jumps_ms gross_preview_allocated_bytes virtual_rows initial_top],
    {
      "source_bytes" => :integer,
      "prepare_ms" => :float,
      "preview_and_200_jumps_ms" => :float,
      "gross_preview_allocated_bytes" => :integer,
      "virtual_rows" => :integer,
      "initial_top" => :integer,
    },
    label
  ).tap do |rows|
    rows.each do |row|
      positive_integer!(row.fetch("source_bytes").to_s, "#{label} source_bytes")
      positive_integer!(row.fetch("virtual_rows").to_s, "#{label} virtual_rows")
    end
  end
end

def parse_spec_output(stdout, stderr, label)
  text = [stdout, stderr].join("\n")
  match = text.match(/(\d+) examples?,\s*0 failures?,\s*0 errors?/)
  raise ValidationError, "#{label} did not report a zero-failure spec summary" unless match

  examples = Integer(match[1], 10)
  raise ValidationError, "#{label} reported zero examples" unless examples.positive?

  {"examples" => examples, "summary" => match[0]}
rescue ArgumentError
  raise ValidationError, "#{label} reported an invalid example count"
end

def crystal_version(crystal)
  result = run_process([crystal, "--version"], env: ENV.to_h, timeout_seconds: 10, sample_rss: false)
  return nil unless result.status == :success

  [result.stdout, result.stderr].join("\n").lines.first&.strip
rescue StandardError
  nil
end

def platform_report
  {
    "ruby_platform" => RUBY_PLATFORM,
    "host_os" => RbConfig::CONFIG["host_os"],
    "host_cpu" => RbConfig::CONFIG["host_cpu"],
  }
end

def darwin_link_flags
  RbConfig::CONFIG["host_os"].to_s.include?("darwin") ? ["--link-flags=-fuse-ld=/usr/bin/ld"] : []
end

def build_argv(crystal, script, output)
  [crystal, "build", "--release", script, "-o", output, *darwin_link_flags]
end

def runtime_argv(binary, args = [])
  [binary, *args]
end

def spec_argv(crystal, paths)
  [crystal, "spec", *paths, *darwin_link_flags]
end

def base_report(crystal)
  {
    "schema" => SCHEMA,
    "version" => SCHEMA_VERSION,
    "status" => "PASS",
    "generated_at" => Time.now.utc.iso8601,
    "toolchain" => {
      "ruby" => RUBY_DESCRIPTION,
      "crystal" => crystal_version(crystal),
    },
    "platform" => platform_report,
    "scenarios" => [],
  }
end

def process_observations(result)
  observations = {
    "duration_ms" => result.duration_ms,
    "captured_stdout_bytes" => result.stdout_bytes,
    "captured_stderr_bytes" => result.stderr_bytes,
    "stdout_truncated" => result.stdout_truncated,
    "stderr_truncated" => result.stderr_truncated,
    "exit_status" => result.exit_status,
    "signal" => result.signal,
    "timed_out" => result.timed_out,
    "reaped" => result.reaped,
  }
  observations["peak_rss_kb"] = result.peak_rss_kb
  observations["rss_samples"] = result.rss_samples
  observations
end

def process_observations_with_excerpts(result)
  observations = process_observations(result)
  observations["stdout_excerpt"] = excerpt(result.stdout) unless result.stdout.empty?
  observations["stderr_excerpt"] = excerpt(result.stderr) unless result.stderr.empty?
  observations
end

def process_failure_message(result)
  return "#{result.error.class}: #{result.error.message}" if result.respond_to?(:error) && result.error

  result.timed_out ? "process watchdog timed out" : "child exited unsuccessfully"
end

def build_failure_scenario(name, argv, result)
  {
    "name" => "#{name}_build",
    "kind" => "probe-build",
    "argv" => argv,
    "status" => "FAIL",
    "observations" => process_observations_with_excerpts(result),
    "error" => process_failure_message(result),
  }
end

def scenario_result(name, argv, result, parser = nil, build: nil)
  scenario = {
    "name" => name,
    "kind" => parser ? "probe" : "spec",
    "argv" => argv,
    "status" => "FAIL",
    "observations" => process_observations_with_excerpts(result),
  }
  if build
    build_argv, build_result = build
    build_observations = process_observations_with_excerpts(build_result)
    build_observations["argv"] = build_argv
    build_observations["status"] = build_result.status.to_s
    scenario["observations"]["build"] = build_observations
  end
  if result.respond_to?(:error) && result.error
    scenario["error"] = process_failure_message(result)
    return scenario
  end
  unless result.status == :success
    scenario["error"] = process_failure_message(result)
    return scenario
  end
  begin
    scenario["observations"]["metrics"] = parser.call(result.stdout, name) if parser
    scenario["observations"]["metrics"] = parse_spec_output(result.stdout, result.stderr, name) unless parser
    scenario["status"] = "PASS"
  rescue ValidationError => error
    scenario["error"] = error.message
  end
  scenario
end

def list_entries
  [
    ["buffer_search_many_and_single_line", "scripts/benchmark_buffer_search.cr buffer"],
    ["lexical_highlighting_many_lines", "scripts/benchmark_lexical_highlighting.cr"],
    ["lexical_highlighting_single_line", "scripts/benchmark_lexical_highlighting.cr --single-line"],
    ["buffer_replace_dense_and_sparse", "scripts/benchmark_buffer_replace.cr buffer"],
    ["inline_preview_many_lines", "scripts/benchmark_inline_preview.cr"],
    ["inline_preview_single_line", "scripts/benchmark_inline_preview.cr --single-line"],
    ["lsp_async_and_write_queue", "spec/lsp_async_*.cr spec/lsp_write_queue_spec.cr"],
  ]
end

def print_list
  list_entries.each do |name, command|
    suffix = if name == "lsp_async_and_write_queue" && !File.file?(File.join(ROOT, "spec/lsp_write_queue_spec.cr"))
               " (missing required spec/lsp_write_queue_spec.cr)"
             else
               ""
             end
    puts "#{name}: #{command}#{suffix}"
  end
end

def self_test_report
  failures = []
  malformed_rejected = begin
    csv_rows!("mode,fixture\nbuffer,only-one-field\n", %w[mode fixture bytes], {"bytes" => :integer}, "self-test malformed")
    false
  rescue ValidationError
    true
  end
  failures << "malformed CSV was accepted" unless malformed_rejected

  escaped_output_holder = lambda do |parent_statement, timeout_seconds|
    escaped_pid = nil
    result = nil
    Dir.mktmpdir("adamantine-watchdog-self-test-") do |directory|
      pid_path = File.join(directory, "escaped.pid")
      escaped_descendant_script = <<~RUBY
        fork do
          Process.setsid
          STDOUT.sync = true
          File.write(ARGV.fetch(0), Process.pid)
          loop do
            STDOUT.write(".")
            sleep 0.05
          end
        rescue Errno::EPIPE, IOError
          exit! 0
        end
        #{parent_statement}
      RUBY
      result = run_process(
        [RbConfig.ruby, "-e", escaped_descendant_script, pid_path],
        env: {},
        timeout_seconds: timeout_seconds,
        sample_rss: false
      )
      escaped_pid = Integer(File.read(pid_path), 10) if File.file?(pid_path)
    ensure
      begin
        Process.kill("KILL", escaped_pid) if escaped_pid
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
    raise "watchdog self-test did not produce a result" unless result

    result
  end

  timeout_result = escaped_output_holder.call('trap("TERM", "IGNORE"); sleep 10', 0.2)
  timeout_rejected = timeout_result.status == :timeout &&
                     timeout_result.timed_out &&
                     timeout_result.reaped &&
                     timeout_result.duration_ms < 2_000
  failures << "timed-out child or escaped output holder was not bounded and reaped" unless timeout_rejected
  begin
    Process.waitpid(timeout_result.pid, Process::WNOHANG) if timeout_result.pid
    failures << "timed-out direct child remained waitable" if timeout_result.pid
  rescue Errno::ECHILD
    # The watchdog's wait thread already reaped the direct child.
  rescue Errno::ESRCH
    # A missing process is also a successful cleanup signal.
  end

  exited_result = escaped_output_holder.call("exit! 0", 5.0)
  exited_output_bounded = exited_result.status == :success &&
                          !exited_result.timed_out &&
                          exited_result.reaped &&
                          exited_result.duration_ms < 2_000
  failures << "escaped output holder stranded capture after direct child exit" unless exited_output_bounded

  {
    "schema" => SCHEMA,
    "version" => SCHEMA_VERSION,
    "status" => failures.empty? ? "PASS" : "FAIL",
    "generated_at" => Time.now.utc.iso8601,
    "toolchain" => {
      "ruby" => RUBY_DESCRIPTION,
      "crystal" => nil,
    },
    "platform" => platform_report,
    "scenarios" => [
      {
        "name" => "self_test_malformed_output",
        "kind" => "validator",
        "status" => malformed_rejected ? "PASS" : "FAIL",
        "observations" => {"rejected" => malformed_rejected},
      },
      {
        "name" => "self_test_timeout_and_escaped_output_bounded",
        "kind" => "watchdog",
        "status" => timeout_rejected ? "PASS" : "FAIL",
        "observations" => process_observations(timeout_result),
        "error" => (timeout_rejected ? nil : "timed-out child or escaped output holder was not bounded and reaped"),
      },
      {
        "name" => "self_test_exited_parent_escaped_output_bounded",
        "kind" => "watchdog",
        "status" => exited_output_bounded ? "PASS" : "FAIL",
        "observations" => process_observations(exited_result),
        "error" => (exited_output_bounded ? nil : "escaped output holder stranded capture after direct child exit"),
      },
    ],
    "error" => (failures.empty? ? nil : failures.join("; ")),
  }
end

def run_full
  crystal = ENV.fetch("CRYSTAL", "crystal")
  report = base_report(crystal)
  write_queue_spec = File.join(ROOT, "spec/lsp_write_queue_spec.cr")
  unless File.file?(write_queue_spec)
    report["status"] = "FAIL"
    report["scenarios"] << {
      "name" => "lsp_async_and_write_queue",
      "kind" => "spec",
      "status" => "FAIL",
      "observations" => {},
      "error" => "required spec/lsp_write_queue_spec.cr is missing; full run cannot claim write-queue coverage",
    }
    return report
  end

  cache_dir = Dir.mktmpdir("adamantine-responsiveness-cache-")
  env = ENV.to_h.merge("CRYSTAL_CACHE_DIR" => cache_dir)
  build_dir = nil
  begin
    build_dir = Dir.mktmpdir("adamantine-responsiveness-probes-", cache_dir)
    probe_specs = [
      ["buffer_search_many_and_single_line", "scripts/benchmark_buffer_search.cr", ["buffer"], method(:parse_search)],
      ["lexical_highlighting_many_lines", "scripts/benchmark_lexical_highlighting.cr", [], method(:parse_lexical)],
      ["lexical_highlighting_single_line", "scripts/benchmark_lexical_highlighting.cr", ["--single-line"], method(:parse_lexical)],
      ["buffer_replace_dense_and_sparse", "scripts/benchmark_buffer_replace.cr", ["buffer"], method(:parse_replace)],
      ["inline_preview_many_lines", "scripts/benchmark_inline_preview.cr", [], method(:parse_inline_preview)],
      ["inline_preview_single_line", "scripts/benchmark_inline_preview.cr", ["--single-line"], method(:parse_inline_preview)],
    ]
    probe_specs.each_with_index do |(name, script, args, parser), index|
      binary = File.join(build_dir, "probe-#{index + 1}-#{name}")
      build_command = build_argv(crystal, script, binary)
      build_result = run_process(build_command, env: env, sample_rss: false)
      unless build_result.status == :success
        report["scenarios"] << build_failure_scenario(name, build_command, build_result)
        next
      end

      runtime_command = runtime_argv(binary, args)
      result = run_process(runtime_command, env: env, sample_rss: true)
      report["scenarios"] << scenario_result(name, runtime_command, result, parser, build: [build_command, build_result])
    end

    async_specs = %w[
      spec/lsp_async_spec.cr
      spec/lsp_async_lifecycle_spec.cr
      spec/lsp_async_navigation_spec.cr
      spec/lsp_async_transport_spec.cr
      spec/lsp_write_queue_spec.cr
    ]
    argv = spec_argv(crystal, async_specs)
    result = run_process(argv, env: env, sample_rss: false)
    report["scenarios"] << scenario_result("lsp_async_and_write_queue", argv, result)
  ensure
    FileUtils.remove_entry(cache_dir) if cache_dir && File.exist?(cache_dir)
  end
  report["status"] = "FAIL" if report["scenarios"].any? { |scenario| scenario["status"] != "PASS" }
  report
end

def failure_report(error)
  {
    "schema" => SCHEMA,
    "version" => SCHEMA_VERSION,
    "status" => "FAIL",
    "generated_at" => Time.now.utc.iso8601,
    "toolchain" => {"ruby" => RUBY_DESCRIPTION, "crystal" => nil},
    "platform" => platform_report,
    "scenarios" => [],
    "error" => "#{error.class}: #{error.message}",
  }
end

mode = ARGV.shift
if ARGV.any?
  puts JSON.generate(failure_report(ArgumentError.new("unexpected arguments: #{ARGV.inspect}")))
  exit 2
end

begin
  case mode
  when "--list"
    print_list
  when "--self-test"
    report = self_test_report
    puts JSON.generate(report)
    exit(report["status"] == "PASS" ? 0 : 1)
  when nil
    report = run_full
    puts JSON.generate(report)
    exit(report["status"] == "PASS" ? 0 : 1)
  else
    puts JSON.generate(failure_report(ArgumentError.new("usage: ruby scripts/verify_responsiveness.rb [--list|--self-test]")))
    exit 2
  end
rescue StandardError => error
  puts JSON.generate(failure_report(error))
  exit 1
end
