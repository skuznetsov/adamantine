#!/usr/bin/env ruby

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class BuildDependenciesTest < Minitest::Test
  MAKEFILE = File.expand_path("../Makefile", __dir__)
  COMPILE_TARGETS = %w[build release run spec spec-smoke].freeze
  NON_COMPILE_TARGETS = %w[fmt fmt-check help].freeze

  def setup
    @workspace = Dir.mktmpdir("adamantine-build-dependencies-")
    @bin = File.join(@workspace, "fake-bin")
    @call_log = File.join(@workspace, "calls.log")
    FileUtils.mkdir_p(@bin)

    write_executable("shards", <<~SH)
      #!/bin/sh
      printf 'shards %s\\n' "$*" >> "$CALL_LOG"
      if [ "$1" = "check" ] && [ "${SHARDS_CHECK_EXIT:-0}" -ne 0 ]; then
        printf '%s\\n' "Dependencies aren't satisfied" >&2
        exit "$SHARDS_CHECK_EXIT"
      fi
      exit 0
    SH

    write_executable("crystal", <<~SH)
      #!/bin/sh
      printf 'crystal %s\\n' "$*" >> "$CALL_LOG"
      exit 0
    SH
  end

  def teardown
    FileUtils.remove_entry(@workspace) if @workspace && File.exist?(@workspace)
  end

  def test_stale_dependencies_stop_each_compile_target_before_crystal
    COMPILE_TARGETS.each do |target|
      clear_call_log
      stdout, stderr, status = run_make(target, shards_check_exit: 17)
      output = stdout + stderr

      refute status.success?, "#{target} unexpectedly passed with stale dependencies"
      assert_match(/shards install --frozen/, output, "#{target} omitted frozen-install guidance")
      assert_equal ["shards check"], calls, "#{target} did not stop at the dependency check"
      refute_match(/shards (install|update)/, File.read(@call_log))
    end
  end

  def test_satisfied_dependencies_allow_each_compile_target_without_installing
    COMPILE_TARGETS.each do |target|
      clear_call_log
      stdout, stderr, status = run_make(target)

      assert status.success?, "#{target} failed with satisfied dependencies: #{stdout}#{stderr}"
      assert_equal "shards check", calls.first, "#{target} skipped the dependency check"
      assert calls.drop(1).any? { |call| call.start_with?("crystal ") },
        "#{target} did not invoke the compiler"
      refute calls.any? { |call| call.start_with?("shards install", "shards update") },
        "#{target} attempted to change dependencies"
    end
  end

  def test_bare_make_keeps_build_as_default_and_omits_linux_link_flags
    stdout, stderr, status = run_make(nil, make_vars: ["ADAMANTINE_BUILD_OS=Linux"])

    assert status.success?, "bare make failed: #{stdout}#{stderr}"
    assert_equal [
      "shards check",
      "crystal build src/adamantine.cr -o bin/adamantine"
    ], calls
  end

  def test_dependency_gate_is_phony_even_when_a_same_named_file_exists
    File.write(File.join(@workspace, "deps-check"), "stale target file")
    stdout, stderr, status = run_make("build", shards_check_exit: 17)

    refute status.success?
    assert_match(/shards install --frozen/, stdout + stderr)
    assert_equal ["shards check"], calls
  end

  def test_darwin_link_flags_keep_default_override_and_blank_override_behavior
    cases = [
      ["default", ["ADAMANTINE_BUILD_OS=Darwin"], "--link-flags=-fuse-ld=/usr/bin/ld"],
      ["custom", ["ADAMANTINE_BUILD_OS=Darwin", "CRYSTAL_LINK_FLAGS=-fuse-ld=custom"],
        "--link-flags=-fuse-ld=custom"],
      ["blank", ["ADAMANTINE_BUILD_OS=Darwin", "CRYSTAL_LINK_FLAGS="], nil]
    ]

    cases.each do |label, make_vars, expected_flag|
      clear_call_log
      stdout, stderr, status = run_make("build", make_vars: make_vars)

      assert status.success?, "#{label} linker case failed: #{stdout}#{stderr}"
      assert_equal "shards check", calls.first
      compiler_call = calls.find { |call| call.start_with?("crystal ") }
      refute_nil compiler_call, "#{label} linker case did not compile"
      if expected_flag
        assert_includes compiler_call, expected_flag
      else
        refute_includes compiler_call, "--link-flags="
      end
    end
  end

  def test_formatting_and_help_targets_do_not_require_shards
    NON_COMPILE_TARGETS.each do |target|
      clear_call_log
      stdout, stderr, status = run_make(target, shards_check_exit: 17)

      assert status.success?, "#{target} required shards: #{stdout}#{stderr}"
      refute calls.any? { |call| call.start_with?("shards ") },
        "#{target} invoked shards"
    end
  end

  private

  def write_executable(name, contents)
    path = File.join(@bin, name)
    File.write(path, contents)
    FileUtils.chmod(0o755, path)
  end

  def clear_call_log
    File.write(@call_log, "")
  end

  def calls
    File.readlines(@call_log, chomp: true)
  end

  def run_make(target, shards_check_exit: 0, make_vars: [])
    env = {
      "PATH" => [@bin, ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR),
      "CALL_LOG" => @call_log,
      "SHARDS_CHECK_EXIT" => shards_check_exit.to_s
    }
    command = ["make", "--no-print-directory", "-C", @workspace, "-f", MAKEFILE] + make_vars
    command << target if target
    Open3.capture3(env, *command)
  end
end
