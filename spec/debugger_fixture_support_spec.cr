require "spec"
require "file_utils"
require "random/secure"
require "./support/debugger_fixture_support"
require "../src/adamantine/debug_profile_store"

private def debugger_fixture_support_root : Path
  root = Path.new(Dir.tempdir, "adamantine-debugger-support-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root.to_s)
  Path.new(File.realpath(root.to_s))
end

private def write_executable_fixture(path : Path) : Nil
  Dir.mkdir_p(path.parent.to_s)
  File.write(path.to_s, "#!/bin/sh\nexit 0\n")
  File.chmod(path.to_s, 0o755)
end

private def fixture_profile(root : Path, executable : String) : Adamantine::Debugging::LaunchProfile
  Adamantine::Debugging::LaunchProfile.new(
    id: "fixture-profile",
    name: "Fixture",
    adapter_argv: [executable, "fixture.rb"],
    program: executable,
    cwd: root.to_s
  )
end

describe DebuggerFixtureSupport do
  it "resolves an executable from a caller-selected non-default PATH entry" do
    root = debugger_fixture_support_root
    executable = root / "custom-runtime" / "bin" / "ruby"
    write_executable_fixture(executable)

    resolved = DebuggerFixtureSupport.resolve_executable("ruby", executable.parent.to_s) ||
               raise "fixture runtime should be found on the supplied PATH"
    resolved.should eq(File.realpath(executable.to_s))
    resolved.should_not eq("/usr/bin/ruby")
  ensure
    FileUtils.rm_rf(root.to_s) if root
  end

  it "canonicalizes a PATH symlink while the launch validator still rejects the alias" do
    root = debugger_fixture_support_root
    target = root / "runtime" / "ruby"
    alias_path = root / "bin" / "ruby"
    write_executable_fixture(target)
    Dir.mkdir_p(alias_path.parent.to_s)
    File.symlink(target.to_s, alias_path.to_s)

    selected = Process.find_executable("ruby", alias_path.parent.to_s) ||
               raise "symlink runtime should be found on the supplied PATH"
    selected.should eq(alias_path.to_s)

    resolved = DebuggerFixtureSupport.resolve_executable("ruby", alias_path.parent.to_s) ||
               raise "symlink runtime should resolve to its executable target"
    resolved.should eq(File.realpath(target.to_s))
    resolved.should_not eq(alias_path.to_s)
    fixture_profile(root, resolved).review_errors(root).should be_empty

    alias_errors = fixture_profile(root, selected).review_errors(root)
    alias_errors.should contain("adapter executable is missing or not a regular file: #{selected}")
  ensure
    FileUtils.rm_rf(root.to_s) if root
  end
end
