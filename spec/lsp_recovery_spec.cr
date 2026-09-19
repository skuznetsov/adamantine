require "spec"
require "file_utils"
require "set"

require "../src/adamantine/app"

private class CoordinatorSpecClient < Adamantine::Lsp::Client
  getter events = [] of Tuple(String, String, Int32, String)
  getter opened = Set(String).new
  getter open_started = Channel(Nil).new(1)
  getter release_open = Channel(Nil).new(1)
  property hold_open = false
  property fail_start = false
  getter starts = 0

  def initialize(root : Path)
    super("coordinator-spec", root)
  end

  def start : Bool
    @starts += 1
    return false if @fail_start
    self.connected = true
    true
  end

  def stop : Nil
    self.connected = false
  end

  def open_text_document(uri : String, language_id : String, version : Int32, text : String) : Nil
    raise "duplicate didOpen: #{uri}" if @opened.includes?(uri)
    @opened.add(uri)
    @events << {"open", uri, version, text}
    if @hold_open
      @hold_open = false
      @open_started.send(nil)
      @release_open.receive
    end
  end

  def close_text_document(uri : String) : Nil
    raise "didClose without didOpen: #{uri}" unless @opened.delete(uri)
    @events << {"close", uri, 0, ""}
  end

  def text_change(uri : String, version : Int32, text : String) : Nil
    raise "didChange before didOpen: #{uri}" unless @opened.includes?(uri)
    @events << {"change", uri, version, text}
  end
end

private class CoordinatorSpecApp < Adamantine::App
  getter clients = [] of CoordinatorSpecClient

  protected def new_lsp_client(command : String, root : Path, args : Array(String)) : Adamantine::Lsp::Client
    @clients.shift? || raise "coordinator test factory is empty"
  end

  def connect_public(client : CoordinatorSpecClient) : Nil
    @clients << client
    connect_lsp_if_requested("coordinator-spec", [] of String)
  end

  def open_public(path : Path) : Adamantine::OpenBuffer
    raise "open failed" unless open_file(path)
    current_buffer.not_nil!
  end

  def close_public : Bool
    close_active_tab
  end
end

private def with_coordinator_spec(&)
  root = Path.new(Dir.tempdir, "adamantine-lsp-recovery-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  File.write(root / "config.json", "{}")
  app = CoordinatorSpecApp.new(
    project_root: root,
    lsp_command: "",
    keymap_path: (root / "config.json").to_s,
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    recovery_root: root / "recovery",
    session_enabled: false,
  )
  yield root, app
ensure
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

private def await_coordinator(label : String, timeout : Time::Span = 3.seconds, &block : -> Bool) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "timed out waiting for #{label}" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

describe "LSP recovery coordinator" do
  it "keeps manual restart disabled without a configured server" do
    with_coordinator_spec do |_root, app|
      app.lsp_health_label.should eq("disabled")
      app.restart_lsp
      app.lsp_health_label.should eq("disabled")
    end
  end

  it "preserves current edits and close-before-reopen ordering during resync" do
    with_coordinator_spec do |root, app|
      source = root / "source.cr"
      File.write(source, "puts 1\n")
      original = CoordinatorSpecClient.new(root)
      app.connect_public(original)
      previous = app.open_public(source)

      replacement = CoordinatorSpecClient.new(root)
      replacement.hold_open = true
      app.clients << replacement
      app.restart_lsp
      select
      when replacement.open_started.receive
      when timeout(3.seconds)
        raise "replacement did not begin didOpen"
      end

      previous.editor.insert_text("# changed while opening\n")
      # Recovery must not bypass the ordinary dirty-buffer close guard.
      app.close_public.should be_false
      # Dismiss the file-scoped question before editing/closing again.
      app.on_capture(Tui::KeyEvent.new(Tui::Key::Escape)).should be_true
      previous.editor.undo.should be_true
      app.close_public.should be_true
      current = app.open_public(source)
      current.editor.insert_text("# reopened\n")
      replacement.release_open.send(nil)
      await_coordinator("replacement readiness") { app.lsp_health_label == "connected" }

      document_events = replacement.events.select { |event| event[1] == current.uri }
      document_events.map(&.[0]).should eq(["open", "close", "open"])
      document_events.last[2].should eq(current.version)
      document_events.last[3].should eq(current.editor.text)
    ensure
      replacement.try do |client|
        select
        when client.release_open.send(nil)
        else
        end
      end
    end
  end

  it "uses exactly three automatic retries after an immediate manual attempt" do
    with_coordinator_spec do |root, app|
      source = root / "source.cr"
      File.write(source, "puts 1\n")
      original = CoordinatorSpecClient.new(root)
      app.connect_public(original)
      app.open_public(source)

      failed = Array.new(4) do
        client = CoordinatorSpecClient.new(root)
        client.fail_start = true
        client
      end
      failed.each { |client| app.clients << client }
      app.restart_lsp
      await_coordinator("terminal recovery state") { app.lsp_health_label == "failed" }
      failed.map(&.starts).should eq([1, 1, 1, 1])
    end
  end
end
