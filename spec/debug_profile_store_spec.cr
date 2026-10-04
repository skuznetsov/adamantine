require "spec"
require "file_utils"
require "json"

require "../src/adamantine/debug_profile_store"

private def with_debug_profile_workspace(&)
  parent = Path.new(Dir.tempdir)
  root = parent / "debug-profile-#{Random::Secure.hex(8)}"
  Dir.mkdir_p(root)
  root = Path.new(File.realpath(root.to_s))
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

describe Adamantine::Debugging::DebugProfileStore do
  it "has no constructor side effects and round-trips only the bounded allowlist" do
    with_debug_profile_workspace do |root|
      project = root / "project"
      state = root / "private-state"
      Dir.mkdir(project)
      adapter = root / "adapter"
      program = root / "program"
      File.write(adapter, "adapter")
      File.chmod(adapter.to_s, 0o700)
      File.write(program, "target")
      File.chmod(program.to_s, 0o700)
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "local",
        name: "Local debug",
        adapter_argv: [adapter.to_s, "--stdio"],
        program: program.to_s,
        cwd: project.to_s,
        target_argv: ["--mode", "test"],
        source_maps: [Adamantine::Debugging::DebugSourceMap.new("/build/src", project.to_s)],
      )
      store = Adamantine::Debugging::DebugProfileStore.new(state)
      raise "constructing a store must not create state" if File.exists?(state)
      raise "valid profile should need no review: #{profile.review_errors(project).inspect}" unless profile.review_errors(project).empty?

      saved = store.save(project, [profile], "local")
      raise "save failed: #{saved.warnings.inspect}" unless saved.saved?
      path = store.state_path(project)
      raise "profile file mode must be private" unless (File.info(path).permissions.to_i & 0o077) == 0
      loaded = store.load(project)
      raise "profile did not load: #{loaded.warnings.inspect}" unless loaded.valid?
      raise "last profile mismatch" unless loaded.last_profile_id == "local"
      restored = loaded.profiles.first
      raise "argv mismatch" unless restored.adapter_argv == [adapter.to_s, "--stdio"]
      raise "target args mismatch" unless restored.target_argv == ["--mode", "test"]
      raise "source maps mismatch" unless restored.source_maps.first.local_prefix == project.to_s
      raise "unexpected persisted fields" unless JSON.parse(File.read(path))["profiles"].as_a.first.as_h.keys.sort == ["adapter_argv", "cwd", "id", "name", "program", "source_maps", "target_argv"].sort

      argv = restored.adapter_argv
      argv << "mutated"
      raise "array getter leaked mutable state" if restored.adapter_argv.includes?("mutated")

      nested = JSON.parse(File.read(path)).as_h
      nested_profile = nested["profiles"].as_a.first.as_h
      nested_profile["environment"] = JSON::Any.new("must not persist")
      File.write(path, nested.to_json)
      File.chmod(path.to_s, 0o600)
      raise "unknown nested field must invalidate the profile" if store.load(project).valid?
    end
  end

  it "fails closed on unknown schema fields and oversized or symlinked state" do
    with_debug_profile_workspace do |root|
      project = root / "project"
      state = root / "private-state"
      Dir.mkdir(project)
      store = Adamantine::Debugging::DebugProfileStore.new(state)
      save = store.save(project, [] of Adamantine::Debugging::LaunchProfile, nil)
      raise "empty save should create a valid private state: #{save.warnings.inspect}" unless save.saved?
      path = store.state_path(project)
      raw = JSON.parse(File.read(path)).as_h
      raw["extension"] = JSON::Any.new("must not be retained")
      File.write(path, raw.to_json)
      File.chmod(path.to_s, 0o600)
      raise "unknown top-level key must invalidate the state" if store.load(project).valid?

      File.write(path, "x" * (Adamantine::Debugging::DebugProfileStore::MAX_STATE_BYTES + 1))
      File.chmod(path.to_s, 0o600)
      raise "oversized state must not load" if store.load(project).valid?

      File.delete(path)
      outside = root / "outside.json"
      File.write(outside, "{}")
      File.symlink(outside.to_s, path.to_s)
      raise "symlink state must not load" if store.load(project).valid?
      rejected = store.save(project, [] of Adamantine::Debugging::LaunchProfile, nil)
      raise "save must reject a symlinked state target" if rejected.saved?
      raise "symlink target must not be overwritten" unless File.read(outside) == "{}"
    end
  end

  it "preserves existing state when a replacement cannot be written safely" do
    with_debug_profile_workspace do |root|
      project = root / "project"
      state = root / "private-state"
      Dir.mkdir(project)
      store = Adamantine::Debugging::DebugProfileStore.new(state)
      initial = store.save(project, [] of Adamantine::Debugging::LaunchProfile, nil)
      raise "initial state should save" unless initial.saved?
      path = store.state_path(project)
      previous = File.read(path)
      File.chmod(path.to_s, 0o644)

      replacement = Adamantine::Debugging::LaunchProfile.new(
        id: "replacement", name: "Replacement", adapter_argv: ["/missing/adapter"],
        program: "/missing/program", cwd: project.to_s,
      )
      failed = store.save(project, [replacement], "replacement")
      raise "permissive existing target must reject save" if failed.saved?
      raise "failed save must not replace existing contents" unless File.read(path) == previous
    end
  end

  it "keeps missing or noncanonical launch paths visible as review errors" do
    with_debug_profile_workspace do |root|
      project = root / "project"
      Dir.mkdir(project)
      profile = Adamantine::Debugging::LaunchProfile.new(
        id: "missing", name: "Missing", adapter_argv: ["adapter"],
        program: (project / "gone").to_s, cwd: (project / "missing-dir").to_s,
      )
      errors = profile.review_errors(project)
      raise "missing paths must be visible" unless errors.size >= 3
      raise "review should identify the adapter executable" unless errors.any?(&.includes?("adapter"))
    end
  end
end
