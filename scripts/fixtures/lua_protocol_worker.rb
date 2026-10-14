#!/usr/bin/env ruby
require "json"

abort unless ARGV == ["--internal-lua-worker"]
start = JSON.parse(STDIN.gets || "")

case start.fetch("script_id")
when "fixture-failed-complete"
  STDOUT.write(JSON.generate(kind: "failed", code: "worker_failed") + "\n")
  STDOUT.write(JSON.generate(kind: "complete") + "\n")
  STDOUT.flush
when "fixture-closed-live"
  STDOUT.write(JSON.generate(kind: "complete") + "\n")
  STDOUT.flush
  STDOUT.close
  STDERR.close
  sleep 60
when "fixture-startup-boundary"
  observations = {
    test_sentinel_absent: !ENV.key?("ADAMANTINE_LUA_TEST_SENTINEL"),
    lua_init_absent: !ENV.key?("LUA_INIT"),
    lua_path_absent: !ENV.key?("LUA_PATH"),
    lua_cpath_absent: !ENV.key?("LUA_CPATH"),
    ld_preload_absent: !ENV.key?("LD_PRELOAD"),
    dyld_insert_libraries_absent: !ENV.key?("DYLD_INSERT_LIBRARIES"),
    ld_library_path_absent: !ENV.key?("LD_LIBRARY_PATH"),
    dyld_library_path_absent: !ENV.key?("DYLD_LIBRARY_PATH"),
    cwd_is_root: Dir.pwd == "/",
  }
  STDOUT.write(JSON.generate(kind: "output", text: JSON.generate(observations) + "\n") + "\n")
  STDOUT.write(JSON.generate(kind: "complete") + "\n")
  STDOUT.flush
when "fixture-partial"
  STDOUT.write('{"kind":"complete"')
  STDOUT.flush
  STDOUT.close
  STDERR.close
when "fixture-stderr-flood"
  STDERR.write("x" * 16_384)
  STDERR.flush
  sleep 60
when "fixture-invalid-failure-message"
  STDOUT.write(JSON.generate(kind: "failed", code: "script_error", message: "bad\u0085diagnostic") + "\n")
  STDOUT.flush
when "fixture-duplicate-complete"
  2.times { STDOUT.write(JSON.generate(kind: "complete") + "\n") }
  STDOUT.flush
when "fixture-complete-output"
  STDOUT.write(JSON.generate(kind: "complete") + "\n")
  STDOUT.write(JSON.generate(kind: "output", text: "late") + "\n")
  STDOUT.flush
when "fixture-complete-tool"
  STDOUT.write(JSON.generate(kind: "complete") + "\n")
  STDOUT.write(JSON.generate(kind: "tool", id: "1", name: "test.echo", arguments: {}) + "\n")
  STDOUT.flush
when "fixture-complete-pending"
  STDOUT.write(JSON.generate(kind: "tool", id: "1", name: "test.echo", arguments: {}) + "\n")
  STDOUT.write(JSON.generate(kind: "complete") + "\n")
  STDOUT.flush
else
  abort "unknown fixture mode"
end
