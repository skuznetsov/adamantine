require "spec"
require "file_utils"

require "../src/adamantine/session_store"

private def with_session_workspace(prefix : String = "adamantine-session-store-spec", &)
  tmp_parent = Path.new(File.realpath(Dir.tempdir))
  tmp_dir = tmp_parent / "#{prefix}-#{Random::Secure.hex(8)}"
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def session_position(line : Int32 = 0, column : Int32 = 0) : Adamantine::SessionStore::Position
  Adamantine::SessionStore::Position.new(line, column)
end

private def session_tab(path : Path, line : Int32 = 0, column : Int32 = 0, scroll_line : Int32 = 0, scroll_column : Int32 = 0) : Adamantine::SessionStore::TabState
  Adamantine::SessionStore::TabState.new(
    path,
    session_position(line, column),
    session_position(scroll_line, scroll_column),
  )
end

private def session_snapshot(root : Path, tabs : Array(Adamantine::SessionStore::TabState), active : Int32? = nil) : Adamantine::SessionStore::Snapshot
  Adamantine::SessionStore::Snapshot.new(root, tabs, active)
end

private def with_session_env(name : String, value : String?, &)
  previous = ENV[name]?
  if value
    ENV[name] = value
  else
    ENV.delete(name)
  end
  yield
ensure
  if previous
    ENV[name] = previous
  else
    ENV.delete(name)
  end
end

describe Adamantine::SessionStore do
  it "does not write state while being constructed and round-trips bounded metadata" do
    with_session_workspace do |workspace|
      project = workspace / "project"
      state_root = workspace / "state"
      Dir.mkdir(project)

      store = Adamantine::SessionStore.new(state_root)
      raise "construction must not create state root" if File.exists?(state_root)
      raise "construction must not create state file" if File.exists?(store.state_path(project))

      tabs = [
        session_tab(project / "one.cr", 4, 7, 2, 3),
        session_tab(project / "two.cr", 9, 1, 0, 11),
      ]
      saved = store.save(session_snapshot(project, tabs, 1))
      raise "save should succeed: #{saved.warnings.inspect}" unless saved.saved?
      raise "save should create state root" unless File.directory?(state_root)

      loaded = store.load(project)
      snapshot = loaded.state
      raise "round-trip should produce state" unless snapshot
      state = snapshot.not_nil!
      raise "project root mismatch" unless state.project_root == Path.new(File.realpath(project))
      raise "tab order mismatch" unless state.tabs.map(&.path) == tabs.map(&.path)
      raise "active tab mismatch" unless state.active_tab == 1
      raise "new writes should use version 2" unless JSON.parse(File.read(store.state_path(project)))["version"].as_i == Adamantine::SessionStore::VERSION
      raise "single-group layout should remain flat" unless !state.split_open && state.tab_groups == [0, 0] && state.selected_tabs == [1, nil] && state.active_group == 0
      raise "cursor mismatch" unless state.tabs[0].cursor == session_position(4, 7)
      raise "scroll mismatch" unless state.tabs[1].scroll == session_position(0, 11)
    end
  end

  it "reads bounded version-2 two-group layout metadata in tab order" do
    with_session_workspace do |workspace|
      project = workspace / "project"
      state_root = workspace / "state"
      Dir.mkdir(project)
      paths = [project / "left.cr", project / "right.cr", project / "left2.cr"]
      paths.each { |path| File.write(path, "disk") }
      root_text = File.realpath(project)
      store = Adamantine::SessionStore.new(state_root)
      tabs_json = paths.map do |path|
        %({"path":"#{path}","cursor":{"line":0,"column":0},"scroll":{"line":0,"column":0}})
      end.join(",")
      json = %({"version":2,"project_root":"#{root_text}","active_tab":2,"split_open":true,"tab_groups":[0,1,0],"selected_tabs":[2,1],"active_group":0,"tabs":[#{tabs_json}]})

      raise "private session directory setup should succeed" unless store.save(session_snapshot(project, [] of Adamantine::SessionStore::TabState)).saved?
      File.write(store.state_path(project), json)
      File.chmod(store.state_path(project).to_s, 0o600)
      load_result = store.load(project)
      loaded = load_result.state
      raise "valid version-2 layout should load: #{load_result.warnings.inspect}" unless loaded
      state = loaded.not_nil!
      state.tabs.map(&.path).should eq(paths)
      state.split_open.should be_true
      state.tab_groups.should eq([0, 1, 0])
      state.selected_tabs.should eq([2, 1])
      state.active_group.should eq(0)
      state.active_tab.should eq(2)
    end
  end

  it "maps a valid legacy version-1 file to one group without changing its tab state" do
    with_session_workspace do |workspace|
      project = workspace / "project"
      state_root = workspace / "state"
      path = project / "legacy.cr"
      Dir.mkdir(project)
      File.write(path, "source")
      store = Adamantine::SessionStore.new(state_root)
      raise "private session directory setup should succeed" unless store.save(session_snapshot(project, [] of Adamantine::SessionStore::TabState)).saved?
      root_text = File.realpath(project)
      json = %({"version":1,"project_root":"#{root_text}","active_tab":null,"tabs":[{"path":"#{path}","cursor":{"line":5,"column":8},"scroll":{"line":2,"column":3}}]})
      File.write(store.state_path(project), json)

      state = store.load(project).state
      raise "valid version-1 session should load" unless state
      restored = state.not_nil!
      restored.tabs.map(&.path).should eq([path])
      restored.tabs.first.cursor.should eq(session_position(5, 8))
      restored.tabs.first.scroll.should eq(session_position(2, 3))
      restored.active_tab.should be_nil
      restored.split_open.should be_false
      restored.tab_groups.should eq([0])
      restored.selected_tabs.should eq([nil, nil])
      restored.active_group.should eq(0)
    end
  end

  it "isolates projects by canonical root and supports the opt-out" do
    with_session_workspace do |workspace|
      state_root = workspace / "state"
      alpha = workspace / "alpha"
      beta = workspace / "beta"
      Dir.mkdir(alpha)
      Dir.mkdir(beta)
      store = Adamantine::SessionStore.new(state_root)

      raise "project keys must differ" if store.state_path(alpha) == store.state_path(beta)
      alpha_save = store.save(session_snapshot(alpha, [session_tab(alpha / "a.cr")], 0))
      raise "alpha save should succeed: #{alpha_save.warnings.inspect}" unless alpha_save.saved?
      raise "beta should start empty" if store.load(beta).state

      with_session_env("ADAMANTINE_SESSION", "0") do
        disabled = Adamantine::SessionStore.new(state_root)
        raise "opt-out should disable persistence" if disabled.enabled?
        raise "disabled load should not expose state" if disabled.load(alpha).state
        raise "disabled save should fail" if disabled.save(session_snapshot(alpha, [] of Adamantine::SessionStore::TabState)).saved?
      end
    end
  end

  it "rejects source escapes, malformed metadata, and unsafe state targets without source reads" do
    with_session_workspace do |workspace|
      project = workspace / "project"
      outside = workspace / "outside"
      state_root = workspace / "state"
      Dir.mkdir(project)
      Dir.mkdir(outside)
      outside_file = outside / "secret.txt"
      File.write(outside_file, "must not be read")
      store = Adamantine::SessionStore.new(state_root)

      escaped = session_snapshot(project, [session_tab(outside_file)])
      raise "source escape must be rejected" if store.save(escaped).saved?
      raise "rejected save must not create state" if File.exists?(store.state_path(project))

      Dir.mkdir_p(store.state_path(project).parent)
      File.write(store.state_path(project), "{\"version\":1,\"project_root\":")
      File.chmod(store.state_path(project).to_s, 0o600)
      malformed = store.load(project)
      raise "malformed state must not load" if malformed.state
      raise "malformed state should warn" if malformed.warnings.empty?

      symlink = project / "outside-link.txt"
      File.symlink(outside_file, symlink)
      raise "source symlink escape must be rejected" if store.save(session_snapshot(project, [session_tab(symlink)])).saved?
    end
  end

  it "preserves the previous valid file when a later snapshot exceeds bounds" do
    with_session_workspace do |workspace|
      project = workspace / "project"
      state_root = workspace / "state"
      Dir.mkdir(project)
      store = Adamantine::SessionStore.new(state_root)
      original = session_snapshot(project, [session_tab(project / "stable.cr", 3, 5)], 0)
      initial_save = store.save(original)
      raise "initial save should succeed: #{initial_save.warnings.inspect}" unless initial_save.saved?
      before = File.read(store.state_path(project))

      too_many = Array(Adamantine::SessionStore::TabState).new(Adamantine::SessionStore::MAX_TABS + 1) do
        session_tab(project / "overflow.cr")
      end
      failed = store.save(session_snapshot(project, too_many, 0))
      raise "oversized snapshot must fail" if failed.saved?
      raise "failed save must retain previous bytes" unless File.read(store.state_path(project)) == before
      loaded = store.load(project).state
      raise "previous valid snapshot must remain available" unless loaded && loaded.not_nil!.tabs.first.path == project / "stable.cr"
    end
  end

  it "rejects non-integer, negative, and overflowing positions" do
    with_session_workspace do |workspace|
      project = workspace / "project"
      state_root = workspace / "state"
      Dir.mkdir(project)
      store = Adamantine::SessionStore.new(state_root)
      path = store.state_path(project)
      baseline = store.save(session_snapshot(project, [] of Adamantine::SessionStore::TabState))
      raise "valid baseline state should save" unless baseline.saved?
      raise "valid baseline state should load" unless store.load(project).state

      [
        "{\"version\":1,\"project_root\":\"#{File.realpath(project)}\",\"active_tab\":null,\"tabs\":[{\"path\":\"#{project / "a.cr"}\",\"cursor\":{\"line\":-1,\"column\":0},\"scroll\":{\"line\":0,\"column\":0}}]}",
        "{\"version\":1,\"project_root\":\"#{File.realpath(project)}\",\"active_tab\":null,\"tabs\":[{\"path\":\"#{project / "a.cr"}\",\"cursor\":{\"line\":1.5,\"column\":0},\"scroll\":{\"line\":0,\"column\":0}}]}",
        "{\"version\":1,\"project_root\":\"#{File.realpath(project)}\",\"active_tab\":null,\"tabs\":[{\"path\":\"#{project / "a.cr"}\",\"cursor\":{\"line\":2147483648,\"column\":0},\"scroll\":{\"line\":0,\"column\":0}}]}",
      ].each do |json|
        File.write(path, json)
        File.chmod(path.to_s, 0o600)
        result = store.load(project)
        raise "invalid position should be rejected" if result.state
      end
    end
  end
end
