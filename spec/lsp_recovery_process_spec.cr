require "spec"
require "file_utils"
require "../src/adamantine/app"

private class RecoveryProcessProbeApp < Adamantine::App
  def open_probe(path : Path) : Adamantine::OpenBuffer
    raise "file did not open" unless open_file(path)
    current_buffer.not_nil!
  end

  def restart_probe : Nil
    restart_lsp
  end

  def close_probe : Bool
    close_active_tab
  end

  def switch_root_probe(root : Path) : Nil
    @project_root = root
    lsp_project_root_changed
  end
end

private def recovery_events(path : Path) : Array(JSON::Any)
  return [] of JSON::Any unless File.exists?(path)
  File.read(path).lines.compact_map do |line|
    JSON.parse(line) rescue nil # The peer may currently be appending a row.
  end
end

private def await_recovery_probe(label : String, timeout : Time::Span = 8.seconds, &block : -> Bool) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "timed out waiting for #{label}" if Time.instant >= deadline
    sleep 5.milliseconds
  end
end

private def with_recovery_process_app(&)
  root = Path.new(Dir.tempdir, "adamantine-recovery-process-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  File.write(root / "config.json", "{}")
  events = root / "events.jsonl"
  control = root / "crash"
  ruby = Process.find_executable("ruby") || raise "Ruby is required for the stdio test peer"
  fixture = Path.new(__DIR__, "fixtures", "recovery_probe_server.rb").expand
  app = RecoveryProcessProbeApp.new(
    project_root: root, lsp_command: ruby,
    lsp_args: [fixture.to_s, events.to_s, control.to_s],
    keymap_path: (root / "config.json").to_s,
    clipboard_backend: Adamantine::Clipboard::UnsupportedBackend.new,
    recovery_root: root / "recovery", session_enabled: false,
  )
  yield root, app, events, control
ensure
  app.try(&.quit(force: true))
  FileUtils.rm_rf(root) if root
end

private def recovery_process_ids(events : Path) : Array(Int64)
  recovery_events(events).select { |event| event["message"]["method"]? == "initialize" }
    .map(&.["pid"].as_i64).uniq
end

describe "real process LSP recovery" do
  it "resyncs edits and changed buffer membership after a delayed initialize" do
    with_recovery_process_app do |root, app, events, control|
      a_path = root / "a.cr"
      b_path = root / "b.cr"
      c_path = root / "c.cr"
      [a_path, b_path, c_path].each { |path| File.write(path, "puts 1\n") }
      a = app.open_probe(a_path)
      b = app.open_probe(b_path)
      File.write(control, "hold-initialize")
      app.restart_probe
      await_recovery_probe("held initialization") { recovery_process_ids(events).size == 2 }
      replacement_pid = recovery_process_ids(events).last
      a.editor.insert_text("# during initialize\n")
      app.close_probe.should be_true
      c = app.open_probe(c_path)
      c.editor.insert_text("# new buffer\n")
      replacement_events = recovery_events(events).select { |event| event["pid"].as_i64 == replacement_pid }
      replacement_events.map(&.["message"]["method"].as_s).should eq(["initialize"])
      File.write(control, "")
      await_recovery_probe("current membership opens") do
        recovery_events(events).count { |event|
          event["pid"].as_i64 == replacement_pid && event["message"]["method"]? == "textDocument/didOpen"
        } == 2
      end
      app.quit(force: true)
      messages = recovery_events(events).select { |event| event["pid"].as_i64 == replacement_pid }
        .map(&.["message"])
      messages.map(&.["method"].as_s).first(2).should eq(["initialize", "initialized"])
      documents = messages.select { |message| message["method"]? == "textDocument/didOpen" }
        .map(&.["params"]["textDocument"])
      documents.any? { |document| document["uri"].as_s == b.uri }.should be_false
      [a, c].each do |buffer|
        document = documents.find { |item| item["uri"].as_s == buffer.uri }.not_nil!
        document["text"].as_s.should eq(buffer.editor.text)
        document["version"].as_i.should eq(buffer.version)
        buffer.editor.modified?.should be_true
      end
    end
  end

  it "reaps a crashed peer, resyncs two unsaved buffers, then permits manual restart" do
    with_recovery_process_app do |root, app, events, control|
      first = root / "a.cr"
      second = root / "b.cr"
      File.write(first, "puts 1\n")
      File.write(second, "puts 2\n")
      a = app.open_probe(first)
      b = app.open_probe(second)
      a.editor.insert_text("# unsaved A\n")
      b.editor.insert_text("# unsaved B\n")
      versions = {a.version, b.version}
      texts = {a.editor.text, b.editor.text}
      old_pid = recovery_process_ids(events).first
      File.write(control, old_pid.to_s)
      await_recovery_probe("new peer and both didOpen messages") do
        ids = recovery_process_ids(events)
        ids.size == 2 && recovery_events(events).count { |event|
          event["pid"].as_i64 == ids.last && event["message"]["method"]? == "textDocument/didOpen"
        } == 2
      end
      Process.exists?(old_pid).should be_false
      new_pid = recovery_process_ids(events).last
      opens = recovery_events(events).select { |event|
        event["pid"].as_i64 == new_pid && event["message"]["method"]? == "textDocument/didOpen"
      }.map(&.["message"]["params"]["textDocument"])
      [a, b].each_with_index do |buffer, index|
        opened = opens.find { |document| document["uri"].as_s == buffer.uri }.not_nil!
        opened["version"].as_i.should eq(versions[index])
        opened["text"].as_s.should eq(texts[index])
        app.open_probe(buffer.path).same?(buffer).should be_true
        buffer.editor.modified?.should be_true
      end
      app.restart_probe
      await_recovery_probe("manual replacement") { recovery_process_ids(events).size == 3 }
      Process.exists?(new_pid).should be_false
      a.editor.text.should eq(texts[0])
      b.editor.undo.should be_true
      b.editor.text.should eq("puts 2\n")
      File.read(first).should eq("puts 1\n")
      File.read(second).should eq("puts 2\n")
      app.quit(force: true)
      recovery_process_ids(events).each { |pid| Process.exists?(pid).should be_false }
    end
  end

  it "does not replenish automatic retries when every initialized peer crashes on open" do
    with_recovery_process_app do |root, app, events, control|
      File.write(control, "crash-on-open")
      source = root / "loop.cr"
      File.write(source, "end")
      app.open_probe(source)
      await_recovery_probe("terminal failed state") { app.lsp_health_label.includes?("failed") }
      recovery_process_ids(events).size.should eq(4) # Initial peer plus three retries.
      sleep 1100.milliseconds
      recovery_process_ids(events).size.should eq(4)
      app.quit(force: true)
      recovery_process_ids(events).each { |pid| Process.exists?(pid).should be_false }
    end
  end

  it "reconnects with the new root and cancels an automatic restart on quit" do
    with_recovery_process_app do |root, app, events, control|
      source = root / "retained.cr"
      File.write(source, "puts 3\n")
      buffer = app.open_probe(source)
      buffer.editor.insert_text("# retained\n")
      original_text = buffer.editor.text
      old_pid = recovery_process_ids(events).first
      next_root = root / "next root"
      Dir.mkdir(next_root)
      app.switch_root_probe(next_root)
      await_recovery_probe("new-root initialization and document open") do
        ids = recovery_process_ids(events)
        ids.size == 2 && recovery_events(events).any? { |event|
          event["pid"].as_i64 == ids.last && event["message"]["method"]? == "textDocument/didOpen"
        }
      end
      Process.exists?(old_pid).should be_false
      initialization = recovery_events(events).select { |event|
        event["message"]["method"]? == "initialize"
      }.last
      initialization["message"]["params"]["rootUri"].as_s.should eq(Adamantine::UriCodec.path_to_uri(next_root))
      buffer.editor.text.should eq(original_text)
      File.write(control, recovery_process_ids(events).last.to_s)
      await_recovery_probe("retry backoff") { app.lsp_health_label.includes?("retrying") }
      app.quit(force: true)
      ids_at_quit = recovery_process_ids(events)
      sleep 1100.milliseconds
      recovery_process_ids(events).should eq(ids_at_quit)
      ids_at_quit.each { |pid| Process.exists?(pid).should be_false }
    end
  end
end
