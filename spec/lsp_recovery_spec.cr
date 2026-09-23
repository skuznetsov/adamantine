require "spec"
require "file_utils"
require "set"

require "../src/adamantine/app"

private class CoordinatorSpecClient < Adamantine::Lsp::Client
  getter events = [] of Tuple(String, String, Int32, String)
  getter opened = Set(String).new
  getter open_started = Channel(Nil).new(1)
  getter release_open = Channel(Nil).new(1)
  getter start_entered = Channel(Nil).new(1)
  getter release_start = Channel(Nil).new(1)
  getter stop_entered = Channel(Nil).new(1)
  getter release_stop = Channel(Nil).new(1)
  property hold_open = false
  property hold_start = false
  property hold_stop = false
  property fail_start = false
  getter starts = 0

  def initialize(root : Path)
    super("coordinator-spec", root)
  end

  def start : Bool
    @starts += 1
    if @hold_start
      @hold_start = false
      @start_entered.send(nil)
      @release_start.receive
    end
    return false if @fail_start
    self.connected = true
    true
  end

  def stop : Nil
    self.connected = false
    if @hold_stop
      @hold_stop = false
      @stop_entered.send(nil)
      @release_stop.receive
    end
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
  getter failed_wakeup_entered = Channel(Nil).new(1)
  getter release_failed_wakeup = Channel(Nil).new(1)
  property hold_failed_wakeup = false

  def failure_reason : String?
    state = lsp_recovery_state
    state.mutex.synchronize { state.failure_reason }
  end

  def status_messages : Array(String)
    @status_log.entries.map(&.message)
  end

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

  def wakeup : Nil
    if @hold_failed_wakeup && lsp_health_label == "failed"
      @hold_failed_wakeup = false
      @failed_wakeup_entered.send(nil)
      @release_failed_wakeup.receive
    end
    super
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
      app.failure_reason.should_not be_nil

      recovered = CoordinatorSpecClient.new(root)
      app.clients << recovered
      app.restart_lsp
      await_coordinator("manual recovery") { app.lsp_health_label == "connected" }
      app.failure_reason.should be_nil

      original.on_transport_failure.not_nil!.call("stale original failure")
      app.lsp_health_label.should eq("connected")
      app.failure_reason.should be_nil
    end
  end

  it "does not publish a stale terminal failure while a newer manual restart is starting" do
    with_coordinator_spec do |root, app|
      original = CoordinatorSpecClient.new(root)
      app.connect_public(original)

      failing_clients = Array.new(4) { CoordinatorSpecClient.new(root) }
      failing_clients.each { |client| client.fail_start = true }
      failing = failing_clients.last
      failing.hold_stop = true
      app.clients.concat(failing_clients)
      app.restart_lsp
      select
      when failing.stop_entered.receive
      when timeout(5.seconds)
        raise "failed attempt teardown did not pause before terminal publication"
      end

      newer = CoordinatorSpecClient.new(root)
      newer.hold_start = true
      app.clients << newer
      app.restart_lsp
      failing.release_stop.send(nil)
      select
      when newer.start_entered.receive
      when timeout(3.seconds)
        raise "newer manual restart did not begin"
      end

      # A stale attempt's cleanup must not overwrite the new manual attempt's
      # retry counter after the epoch changes.
      app.lsp_health_label.should eq("retrying 1/3")
      app.failure_reason.should be_nil
      app.status_messages.any? { |message| message.includes?("LSP recovery failed after") }.should be_false

      newer.release_start.send(nil)
      await_coordinator("newer manual recovery") { app.lsp_health_label == "connected" }
      app.failure_reason.should be_nil
      app.status_messages.any? { |message| message.includes?("LSP recovery failed after") }.should be_false
    ensure
      failing.try do |client|
        select
        when client.release_stop.send(nil)
        else
        end
      end
      newer.try do |client|
        select
        when client.release_start.send(nil)
        else
        end
      end
    end
  end

  it "rechecks the epoch after terminal-state wakeup before publishing a failure log" do
    with_coordinator_spec do |root, app|
      original = CoordinatorSpecClient.new(root)
      app.connect_public(original)

      failing_clients = Array.new(4) do
        client = CoordinatorSpecClient.new(root)
        client.fail_start = true
        client
      end
      app.clients.concat(failing_clients)
      app.hold_failed_wakeup = true
      app.restart_lsp

      select
      when app.failed_wakeup_entered.receive
      when timeout(5.seconds)
        raise "terminal failed-state wakeup did not pause"
      end
      app.lsp_health_label.should eq("failed")

      newer = CoordinatorSpecClient.new(root)
      newer.hold_start = true
      app.clients << newer
      app.restart_lsp
      app.lsp_health_label.should eq("retrying 1/3")
      app.release_failed_wakeup.send(nil)

      select
      when newer.start_entered.receive
      when timeout(3.seconds)
        raise "newer manual attempt did not start after stale wakeup resumed"
      end
      app.status_messages.any? { |message| message.includes?("LSP recovery failed after") }.should be_false

      newer.release_start.send(nil)
      await_coordinator("newer manual recovery after failed-state wakeup") { app.lsp_health_label == "connected" }
      app.failure_reason.should be_nil
      app.status_messages.any? { |message| message.includes?("LSP recovery failed after") }.should be_false
    ensure
      select
      when app.release_failed_wakeup.send(nil)
      else
      end
      newer.try do |client|
        select
        when client.release_start.send(nil)
        else
        end
      end
    end
  end
end
