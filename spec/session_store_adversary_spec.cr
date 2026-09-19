require "spec"
require "file_utils"
require "../src/adamantine/session_store"

private class FailingSessionStore < Adamantine::SessionStore
  property fail_rename : Bool = false

  protected def before_state_rename(_path : Path) : Nil
    raise "injected pre-rename failure" if @fail_rename
  end
end

private def with_session_store_adversary(&)
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-session-store-adversary-#{Random::Secure.hex(8)}")
  project = root / "project"
  Dir.mkdir_p(project)
  store = Adamantine::SessionStore.new(root / "state", enabled: true)
  position = Adamantine::SessionStore::Position.new(0, 0)
  tab = Adamantine::SessionStore::TabState.new(project / "file.cr", position, position)
  snapshot = Adamantine::SessionStore::Snapshot.new(project, [tab], 0)
  yield root, project, store, snapshot
ensure
  FileUtils.rm_rf(root) if root
end

describe "Session store adversaries" do
  it "uses XDG and explicit app-state roots without duplicate directory names" do
    with_session_store_adversary do |root, project, _store, snapshot|
      previous_override = ENV["ADAMANTINE_STATE_HOME"]?
      previous_xdg = ENV["XDG_STATE_HOME"]?
      begin
        ENV.delete("ADAMANTINE_STATE_HOME")
        ENV["XDG_STATE_HOME"] = (root / "xdg").to_s
        xdg = Adamantine::SessionStore.new(enabled: true)
        xdg.state_root.should eq root / "xdg/adamantine"
        xdg.state_path(project).parent.should eq root / "xdg/adamantine/sessions"
        File.exists?(root / "xdg").should be_false
        ENV["ADAMANTINE_STATE_HOME"] = (root / "override").to_s
        custom = Adamantine::SessionStore.new(enabled: true)
        custom.state_path(project).parent.should eq root / "override/sessions"
        ENV["ADAMANTINE_STATE_HOME"] = "relative-state-is-invalid"
        invalid = Adamantine::SessionStore.new(enabled: true)
        invalid.enabled?.should be_false
        invalid.save(snapshot).saved?.should be_false
      ensure
        if previous_override
          ENV["ADAMANTINE_STATE_HOME"] = previous_override
        else
          ENV.delete("ADAMANTINE_STATE_HOME")
        end
        if previous_xdg
          ENV["XDG_STATE_HOME"] = previous_xdg
        else
          ENV.delete("XDG_STATE_HOME")
        end
      end
    end
  end

  it "does not change permissions on an existing non-private state directory" do
    with_session_store_adversary do |root, project, store, snapshot|
      Dir.mkdir(root / "state", 0o755)
      File.chmod(root / "state", 0o755)
      store.save(snapshot).saved?.should be_false
      (File.info(root / "state").permissions.value.to_i & 0o777).should eq 0o755
      Dir.children(root / "state").should be_empty
    end
  end

  it "preserves prior bytes and cleans temporary files when a write fails before rename" do
    with_session_store_adversary do |root, project, _store, snapshot|
      store = FailingSessionStore.new(root / "state", enabled: true)
      store.save(snapshot).saved?.should be_true
      path = store.state_path(project)
      previous = File.read(path)
      store.fail_rename = true
      empty = Adamantine::SessionStore::Snapshot.new(project, [] of Adamantine::SessionStore::TabState)
      store.save(empty).saved?.should be_false
      File.read(path).should eq previous
      Dir.children(path.parent).should eq [path.basename]
      store.load(project).state.not_nil!.tabs.size.should eq 1
    end
  end

  it "refuses state reached through a symlinked sessions directory" do
    with_session_store_adversary do |root, project, store, snapshot|
      store.save(snapshot).saved?.should be_true
      path = store.state_path(project)
      relocated = root / "relocated-sessions"
      File.rename(path.parent, relocated)
      File.symlink(relocated, path.parent)
      fresh = Adamantine::SessionStore.new(root / "state", enabled: true)
      fresh.load(project).state.should be_nil
      fresh.save(snapshot).saved?.should be_false
    end
  end

  it "creates private metadata and never stores source text" do
    with_session_store_adversary do |root, project, store, snapshot|
      File.write(project / "file.cr", "UNSAVED_OR_SOURCE_TEXT_MUST_NOT_ENTER_METADATA")
      store.save(snapshot).saved?.should be_true
      path = store.state_path(project)
      (File.info(path).permissions.value.to_i & 0o777).should eq 0o600
      (File.info(path.parent).permissions.value.to_i & 0o777).should eq 0o700
      File.read(path).includes?("UNSAVED_OR_SOURCE_TEXT").should be_false
    end
  end

  it "rejects a copied state belonging to another root and unsupported versions" do
    with_session_store_adversary do |root, project, store, snapshot|
      store.save(snapshot).saved?.should be_true
      path = store.state_path(project)
      original = File.read(path)
      changed = JSON.parse(original).as_h
      changed["project_root"] = JSON::Any.new((root / "other").to_s)
      File.write(path, changed.to_json)
      store.load(project).state.should be_nil
      changed = JSON.parse(original).as_h
      changed["version"] = JSON::Any.new(999_i64)
      File.write(path, changed.to_json)
      result = store.load(project)
      result.state.should be_nil
      result.warnings.should_not be_empty
    end
  end

  it "does not follow a symlink replacing the state file" do
    with_session_store_adversary do |root, project, store, snapshot|
      store.save(snapshot).saved?.should be_true
      path = store.state_path(project)
      target = root / "do-not-touch"
      File.write(target, "protected")
      File.delete(path)
      File.symlink(target, path)
      store.load(project).state.should be_nil
      store.save(snapshot).saved?.should be_false
      File.read(target).should eq "protected"
    end
  end

  it "does not create state through a symlinked state root" do
    with_session_store_adversary do |root, project, store, snapshot|
      target = root / "elsewhere"
      Dir.mkdir(target)
      File.symlink(target, root / "state")
      store.save(snapshot).saved?.should be_false
      Dir.children(target).should be_empty
    end
  end

  it "rejects oversized metadata before JSON parsing" do
    with_session_store_adversary do |root, project, store, snapshot|
      store.save(snapshot).saved?.should be_true
      path = store.state_path(project)
      File.write(path, " " * (1024 * 1024 + 1))
      result = store.load(project)
      result.state.should be_nil
      result.warnings.should_not be_empty
    end
  end

  it "rejects persisted source paths escaping through an intermediate symlink" do
    with_session_store_adversary do |root, project, store, snapshot|
      outside = root / "outside"
      Dir.mkdir(outside)
      File.write(outside / "secret.cr", "private")
      File.symlink(outside, project / "link")
      store.save(snapshot).saved?.should be_true
      path = store.state_path(project)
      parsed = JSON.parse(File.read(path))
      parsed["tabs"][0].as_h["path"] = JSON::Any.new((project / "link/secret.cr").to_s)
      File.write(path, parsed.to_json)
      store.load(project).state.should be_nil
      File.read(outside / "secret.cr").should eq "private"
    end
  end
end
