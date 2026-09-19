require "spec"
require "file_utils"
require "../src/adamantine/app"

private class RecoveryWireOracle < Adamantine::Lsp::Client
  getter events = [] of Tuple(String, String, Int32, String)
  getter opened = Set(String).new
  getter open_entered = Channel(Nil).new(1)
  getter release_open = Channel(Nil).new(1)
  property hold_open = false
  property diagnostics_on_open = false
  getter semantic_calls = 0
  getter fold_calls = 0
  property fail_start = false
  getter starts = 0
  property hold_stop = false
  getter stop_entered = Channel(Nil).new(1)
  getter release_stop = Channel(Nil).new(1)
  @stop_guard = Mutex.new

  def initialize(root : Path)
    super("oracle", root)
  end

  def start : Bool
    @starts += 1
    return false if @fail_start
    self.connected = true
    true
  end

  def stop : Nil
    @stop_guard.synchronize do
      self.connected = false
      if @hold_stop
        @hold_stop = false
        @stop_entered.send(nil)
        @release_stop.receive
      end
    end
  end

  def open_text_document(uri : String, language_id : String, version : Int32, text : String) : Nil
    raise "duplicate didOpen without didClose: #{uri}" if @opened.includes?(uri)
    @opened.add(uri)
    @events << {"open", uri, version, text}
    if @diagnostics_on_open
      on_versioned_diagnostics.try(&.call(uri, version, [Adamantine::Lsp::Diagnostic.new(0, 0, "fresh")], false))
    end
    if @hold_open
      @hold_open = false
      @open_entered.send(nil)
      @release_open.receive
    end
  end

  def close_text_document(uri : String) : Nil
    raise "didClose without didOpen" unless @opened.delete(uri)
    @events << {"close", uri, 0, ""}
  end

  def text_change(uri : String, version : Int32, text : String) : Nil
    raise "didChange without didOpen" unless @opened.includes?(uri)
    @events << {"change", uri, version, text}
  end

  def semantic_tokens_supported? : Bool
    true
  end

  def folding_ranges_supported? : Bool
    true
  end

  def semantic_tokens_full(uri : String) : Array(Int32)?
    raise "semantic request before didOpen" unless @opened.includes?(uri)
    @semantic_calls += 1
    [] of Int32
  end

  def folding_ranges(uri : String) : Array(Tui::TextEditor::FoldRange)?
    raise "fold request before didOpen" unless @opened.includes?(uri)
    @fold_calls += 1
    [] of Tui::TextEditor::FoldRange
  end
end

private class RecoveryAdversaryApp < Adamantine::App
  getter clients = [] of RecoveryWireOracle
  property fail_factory = false

  protected def new_lsp_client(command : String, root : Path, args : Array(String)) : Adamantine::Lsp::Client
    if @fail_factory
      @fail_factory = false
      raise "factory fault"
    end
    @clients.shift
  end

  def connect_probe(client : RecoveryWireOracle) : Nil
    @clients << client
    connect_lsp_if_requested("oracle", [] of String)
  end

  def open_probe(path : Path) : Adamantine::OpenBuffer
    raise "open failed" unless open_file(path)
    current_buffer.not_nil!
  end

  def close_probe : Bool
    close_active_tab
  end

  def header_probe : String
    @header.subtitle
  end
end

private def with_recovery_adversary(&)
  root = Path.new(Dir.tempdir, "adamantine-recovery-adversary-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  File.write(root / "config.json", "{}")
  File.write(root / "source.cr", "puts 1\n")
  app = RecoveryAdversaryApp.new(
    project_root: root, lsp_command: "", keymap_path: (root / "config.json").to_s,
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    recovery_root: root / "recovery", session_enabled: false,
  )
  original = RecoveryWireOracle.new(root)
  app.connect_probe(original)
  replacement = RecoveryWireOracle.new(root)
  app.clients << replacement
  yield app, original, replacement, root
ensure
  original.try do |client|
    select
    when client.release_stop.send(nil)
    else
    end
  end
  # Release a suspended oracle before application teardown, including failures.
  replacement.try do |client|
    select
    when client.release_open.send(nil)
    else
    end
  end
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

private def await_recovery_adversary(&block : -> Bool)
  deadline = Time.instant + 4.seconds
  until yield
    raise "recovery oracle timed out" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

describe "parent LSP recovery wire-order adversary" do
  it "waits for in-progress teardown before completing quit" do
    with_recovery_adversary do |app, original, replacement, root|
      original.hold_stop = true
      app.restart_lsp
      select
      when original.stop_entered.receive
      when timeout(2.seconds)
        raise "old client teardown did not start"
      end
      quit_done = Channel(Nil).new(1)
      spawn { app.quit(force: true); quit_done.send(nil) }
      select
      when quit_done.receive
        raise "quit returned before process teardown"
      when timeout(30.milliseconds)
      end
      original.release_stop.send(nil)
      select
      when quit_done.receive
      when timeout(2.seconds)
        raise "quit did not complete after teardown"
      end
      replacement.starts.should eq(0)
    end
  end

  it "allows an immediate manual attempt plus exactly three automatic retries" do
    with_recovery_adversary do |app, original, replacement, root|
      failed = [replacement] + Array.new(3) { RecoveryWireOracle.new(root) }
      failed.each { |client| client.fail_start = true }
      app.clients.concat(failed.skip(1))
      app.restart_lsp
      await_recovery_adversary { app.lsp_health_label == "failed" }
      failed.map(&.starts).should eq([1, 1, 1, 1])
      app.clients.should be_empty
    end
  end

  it "accepts a new explicit restart after a coordinator exception" do
    with_recovery_adversary do |app, original, replacement, root|
      app.fail_factory = true
      app.restart_lsp
      await_recovery_adversary { app.lsp_health_label == "failed" }
      app.restart_lsp
      await_recovery_adversary { app.lsp_health_label == "connected" }
      replacement.starts.should eq(1)
    end
  end

  it "closes the old identity before reopening the same URI during a yielded didOpen" do
    with_recovery_adversary do |app, original, replacement, root|
      previous = app.open_probe(root / "source.cr")
      replacement.hold_open = true
      app.restart_lsp
      select
      when replacement.open_entered.receive
      when timeout(2.seconds)
        raise "replacement didOpen did not start"
      end
      app.close_probe.should be_true
      current = app.open_probe(root / "source.cr")
      current.same?(previous).should be_false
      current.editor.insert_text("# reopened\n")
      replacement.release_open.send(nil)
      await_recovery_adversary { app.lsp_health_label == "connected" }
      document_events = replacement.events.select { |event| event[1] == current.uri }
      document_events.map(&.[0]).should eq(["open", "close", "open"])
      document_events.last[2].should eq(current.version)
      document_events.last[3].should eq(current.editor.text)
    end
  end

  it "rejects old diagnostics immediately and restores semantic requests and visible health" do
    with_recovery_adversary do |app, original, replacement, root|
      buffer = app.open_probe(root / "source.cr")
      replacement.diagnostics_on_open = true
      app.restart_lsp
      app.header_probe.should contain("[LSP retrying")
      original.on_diagnostics.not_nil!.call(buffer.uri, [Adamantine::Lsp::Diagnostic.new(0, 0, "stale")])
      buffer.diagnostics.should be_empty
      await_recovery_adversary { app.lsp_health_label == "connected" }
      await_recovery_adversary { replacement.semantic_calls > 0 && replacement.fold_calls > 0 }
      buffer.diagnostics.map(&.message).should eq(["fresh"])
      app.header_probe.should contain("[LSP connected]")
    end
  end
end
