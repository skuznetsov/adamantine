require "spec"
require "file_utils"
require "../src/adamantine/app"

private class SessionAdversaryApp < Adamantine::App
  property stale_size_public : Bool = false

  private def session_source_size(path : Path) : Int64?
    @stale_size_public ? 0_i64 : super
  end

  def activate_public : Nil
    start_session_lifecycle
  end

  def save_public : Nil
    save_session_state
  end

  def activate_with_budget_public(bytes : Int64) : Nil
    @session_lifecycle_active = true
    @session_controller.activate
    restore_session_state(@project_root, max_bytes: bytes)
  end

  def root_public(path : Path) : Nil
    change_project_root(path.to_s)
  end

  def open_public(path : Path) : Adamantine::EditingTextEditor
    raise "fixture open failed" unless open_file(path)
    current_editor.as(Adamantine::EditingTextEditor)
  end

  def paths_public : Array(String)
    @editor_tabs.tabs.map(&.id)
  end

  def active_public : String?
    @editor_tabs.active_tab_id
  end

  def editor_public : Adamantine::EditingTextEditor
    current_editor.as(Adamantine::EditingTextEditor)
  end
end

private def with_session_adversary(&)
  root = Path.new(File.realpath(Dir.tempdir), "adamantine-session-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root / "a")
  Dir.mkdir_p(root / "b")
  File.write(root / "config.json", "{}")
  apps = [] of SessionAdversaryApp
  factory = ->(project : Path, enabled : Bool) do
    app = SessionAdversaryApp.new(project, lsp_command: "", keymap_path: (root / "config.json").to_s,
      recovery_root: root / "recovery", clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
      session_root: root / "state", session_enabled: enabled)
    apps << app
    app
  end
  yield root, factory
ensure
  apps.try(&.each { |app| app.quit(force: true) })
  FileUtils.rm_rf(root) if root
end

describe "Session restoration adversaries" do
  it "applies a cumulative source budget across individually acceptable files" do
    with_session_adversary do |root, factory|
      paths = [root / "a/one.cr", root / "a/two.cr", root / "a/three.cr"]
      paths.each { |path| File.write(path, "1234") }
      first = factory.call(root / "a", true)
      first.activate_public
      paths.each { |path| first.open_public(path) }
      first.save_public
      second = factory.call(root / "a", true)
      second.stale_size_public = true
      second.activate_with_budget_public(8_i64)
      second.paths_public.should eq paths.first(2).map(&.to_s)
      paths.each { |path| File.read(path).should eq "1234" }
    end
  end

  it "does not admit bytes beyond an exhausted budget when metadata is stale" do
    with_session_adversary do |root, factory|
      path = root / "a/one.cr"
      File.write(path, "x")
      first = factory.call(root / "a", true)
      first.activate_public
      first.open_public(path)
      first.save_public
      second = factory.call(root / "a", true)
      second.stale_size_public = true
      second.activate_with_budget_public(0_i64)
      second.paths_public.should be_empty
      File.read(path).should eq "x"
    end
  end

  it "does not create state on construction or a headless quit" do
    with_session_adversary do |root, factory|
      app = factory.call(root / "a", true)
      File.write(root / "a/one.cr", "one")
      app.open_public(root / "a/one.cr")
      app.quit(force: true)
      File.exists?(root / "state").should be_false
    end
  end

  it "restores current disk text and clamps a stale codepoint cursor without writing sources" do
    with_session_adversary do |root, factory|
      path = root / "a/one.cr"
      File.write(path, "old text\nsecond line")
      first = factory.call(root / "a", true)
      first.activate_public
      first.open_public(path).set_cursor(1, 9)
      first.save_public
      File.write(path, "🙂x")
      second = factory.call(root / "a", true)
      second.activate_public
      second.paths_public.should eq [path.to_s]
      second.editor_public.text.should eq "🙂x"
      second.editor_public.cursor_line.should eq 0
      second.editor_public.cursor_col.should eq 2
      second.editor_public.modified?.should be_false
      second.editor_public.can_undo?.should be_false
      File.read(path).should eq "🙂x"
    end
  end

  it "does not replace a dirty existing alias with a duplicate canonical buffer" do
    with_session_adversary do |root, factory|
      path = root / "a/one.cr"
      link = root / "a/alias.cr"
      File.write(path, "source")
      File.symlink(path, link)
      first = factory.call(root / "a", true)
      first.activate_public
      first.open_public(path).set_cursor(0, 6)
      first.save_public
      second = factory.call(root / "a", true)
      editor = second.open_public(link)
      editor.insert_text("dirty")
      editor.set_cursor(0, 2)
      second.activate_public
      second.paths_public.size.should eq 1
      second.editor_public.same?(editor).should be_true
      editor.text.should eq "dirtysource"
      editor.cursor_col.should eq 2
      editor.undo.should be_true
      editor.text.should eq "source"
      File.read(path).should eq "source"
    end
  end

  it "does not mistake a bounded alias scan for proof that no dirty buffer exists" do
    with_session_adversary do |root, factory|
      path = root / "a/target.cr"
      link = root / "a/alias.cr"
      File.write(path, "source")
      File.symlink(path, link)
      first = factory.call(root / "a", true)
      first.activate_public
      first.open_public(path)
      first.save_public
      second = factory.call(root / "a", true)
      128.times do |index|
        filler = root / "a/filler-#{index}.cr"
        File.write(filler, "x")
        second.open_public(filler)
      end
      dirty = second.open_public(link)
      dirty.insert_text("dirty")
      second.activate_public
      second.paths_public.size.should eq 129
      second.editor_public.same?(dirty).should be_true
      dirty.text.should eq "dirtysource"
      File.read(path).should eq "source"
    end
  end

  it "retains dirty tabs across project switches but persists only the owner project's tabs" do
    with_session_adversary do |root, factory|
      a = root / "a/a.cr"
      b = root / "b/b.cr"
      File.write(a, "a")
      File.write(b, "b")
      first = factory.call(root / "a", true)
      first.activate_public
      dirty = first.open_public(a)
      dirty.insert_text("dirty")
      first.root_public(root / "b")
      first.paths_public.should eq [a.to_s]
      first.open_public(b)
      first.save_public
      b_app = factory.call(root / "b", true)
      b_app.activate_public
      b_app.paths_public.should eq [b.to_s]
      first.root_public(root / "a")
      first.paths_public.size.should eq 2
      dirty.text.should eq "dirtya"
      dirty.undo.should be_true
      dirty.text.should eq "a"
      a_app = factory.call(root / "a", true)
      a_app.activate_public
      a_app.paths_public.should eq [a.to_s]
      File.read(a).should eq "a"
      File.read(b).should eq "b"
    end
  end

  it "does not publish a new snapshot when normal quit is refused" do
    with_session_adversary do |root, factory|
      a = root / "a/a.cr"
      b = root / "a/b.cr"
      File.write(a, "a")
      File.write(b, "b")
      first = factory.call(root / "a", true)
      first.activate_public
      first.open_public(a)
      first.save_public
      first.open_public(b).insert_text("dirty")
      first.quit
      second = factory.call(root / "a", true)
      second.activate_public
      second.paths_public.should eq [a.to_s]
      File.read(b).should eq "b"
    end
  end

  it "keeps disabled sessions inert even after lifecycle activation" do
    with_session_adversary do |root, factory|
      File.write(root / "a/a.cr", "a")
      app = factory.call(root / "a", false)
      app.activate_public
      app.open_public(root / "a/a.cr")
      app.save_public
      app.root_public(root / "b")
      app.quit(force: true)
      File.exists?(root / "state").should be_false
    end
  end

  it "skips missing and newly binary files while restoring the remaining active tab" do
    with_session_adversary do |root, factory|
      missing = root / "a/missing.cr"
      binary = root / "a/binary.cr"
      valid = root / "a/valid.cr"
      [missing, binary, valid].each { |path| File.write(path, "ok") }
      first = factory.call(root / "a", true)
      first.activate_public
      [missing, binary, valid].each { |path| first.open_public(path) }
      first.save_public
      File.delete(missing)
      File.write(binary, "\u0000binary")
      second = factory.call(root / "a", true)
      second.activate_public
      second.paths_public.should eq [valid.to_s]
      second.active_public.should eq valid.to_s
      File.read(binary).should eq "\u0000binary"
    end
  end
end
