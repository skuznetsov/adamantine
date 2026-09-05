require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"
require "../src/adamantine/lsp_client"

private class AsyncLifecycleProbeApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def set_lsp_client_public(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def show_hover_hint_public : Nil
    show_hover_hint
  end

  def hyperclick_smart_public : Nil
    hyperclick_smart
  end

  def invalidate_lsp_actions_public : Nil
    invalidate_lsp_actions
  end

  def close_active_tab_public : Bool
    close_active_tab
  end

  def insert_text_public(text : String) : Nil
    editor = current_editor
    raise "no active editor" unless editor
    editor.insert_text(text)
  end

  def current_buffer_path_public : String?
    current_buffer.try(&.path.to_s)
  end

  def lsp_popup_open_public : Bool
    @lsp_popup.open
  end

  def lsp_popup_lines_public : Array(String)
    @lsp_popup.lines
  end

  def wait_for_lsp_action_public(timeout_span : Time::Span = 1.second) : Nil
    deadline = Time.instant + timeout_span
    while @lsp_action_running
      raise "timed out waiting for asynchronous LSP action" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end
end

private class AsyncLifecycleDelayedClient < Adamantine::Lsp::Client
  getter hover_entered = Channel(Nil).new(1)
  getter definition_entered = Channel(Nil).new(1)
  getter release_hover = Channel(Nil).new(1)
  getter release_definition = Channel(Nil).new(1)
  getter hover_calls : Int32 = 0
  getter definition_calls : Int32 = 0
  getter references_calls : Int32 = 0

  def initialize(root : Path)
    super("", root)
    self.connected = true
  end

  def hover(_uri : String, _line : Int32, _character : Int32) : Adamantine::Lsp::Hover?
    call_index = @hover_calls
    @hover_calls += 1
    if call_index == 0
      @hover_entered.send(nil)
      @release_hover.receive
      Adamantine::Lsp::Hover.new("stale-hover")
    else
      Adamantine::Lsp::Hover.new("queued-hover")
    end
  end

  def goto_definition(uri : String, line : Int32, character : Int32) : Array(Adamantine::Lsp::Location)
    @definition_calls += 1
    @definition_entered.send(nil)
    @release_definition.receive
    [Adamantine::Lsp::Location.new(uri, line, character)]
  end

  def references(_uri : String, _line : Int32, _character : Int32, _include_declaration : Bool = true) : Array(Adamantine::Lsp::Location)
    @references_calls += 1
    [] of Adamantine::Lsp::Location
  end
end

private def with_async_lifecycle_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-lsp-async-lifecycle-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def wait_for_async_lifecycle_signal(channel : Channel(Nil), label : String, timeout_span : Time::Span = 1.second) : Nil
  deadline = Time.instant + timeout_span
  loop do
    select
    when channel.receive
      return
    when timeout(5.milliseconds)
      raise "timed out waiting for #{label}" if Time.instant >= deadline
    end
  end
end

private def release_async_lifecycle_worker(channel : Channel(Nil)) : Nil
  select
  when channel.send(nil)
  else
  end
end

describe "asynchronous LSP lifecycle invalidation" do
  it "drops a delayed hover after switching from tab A to B and back to A" do
    app : AsyncLifecycleProbeApp? = nil
    client : AsyncLifecycleDelayedClient? = nil
    with_async_lifecycle_workspace do |tmp|
      source_a = tmp / "a.cr"
      source_b = tmp / "b.cr"
      File.write(source_a.to_s, "puts :a\n")
      File.write(source_b.to_s, "puts :b\n")

      app = AsyncLifecycleProbeApp.new(project_root: tmp, lsp_command: "")
      client = AsyncLifecycleDelayedClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      raise "tab A should open" unless app.open_file_public(source_a)

      app.show_hover_hint_public
      wait_for_async_lifecycle_signal(client.not_nil!.hover_entered, "tab A hover")

      raise "tab B should open" unless app.open_file_public(source_b)
      raise "tab A should be reopened" unless app.open_file_public(source_a)

      release_async_lifecycle_worker(client.not_nil!.release_hover)
      app.wait_for_lsp_action_public
      raise "active tab should be A after switching back" unless app.current_buffer_path_public == source_a.to_s
      raise "tab-switch stale hover must not open a popup" if app.lsp_popup_open_public
      raise "stale hover must not be displayed" if app.lsp_popup_lines_public.includes?("stale-hover")
    ensure
      if action_client = client
        release_async_lifecycle_worker(action_client.release_hover)
        release_async_lifecycle_worker(action_client.release_definition)
      end
      app.try &.wait_for_lsp_action_public(1.second)
      client.try &.stop
    end
  end

  it "drops a delayed hover after closing and reopening the same path" do
    app : AsyncLifecycleProbeApp? = nil
    client : AsyncLifecycleDelayedClient? = nil
    with_async_lifecycle_workspace do |tmp|
      source = tmp / "reopen.cr"
      File.write(source.to_s, "puts :reopen\n")

      app = AsyncLifecycleProbeApp.new(project_root: tmp, lsp_command: "")
      client = AsyncLifecycleDelayedClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      raise "source should open" unless app.open_file_public(source)

      app.show_hover_hint_public
      wait_for_async_lifecycle_signal(client.not_nil!.hover_entered, "initial hover")

      raise "active tab should close" unless app.close_active_tab_public
      raise "closed path should not remain active" unless app.current_buffer_path_public.nil?
      raise "source should reopen" unless app.open_file_public(source)

      release_async_lifecycle_worker(client.not_nil!.release_hover)
      app.wait_for_lsp_action_public
      raise "reopened source should be active" unless app.current_buffer_path_public == source.to_s
      raise "close/reopen stale hover must not open a popup" if app.lsp_popup_open_public
      raise "stale hover must not be displayed after reopen" if app.lsp_popup_lines_public.includes?("stale-hover")
    ensure
      if action_client = client
        release_async_lifecycle_worker(action_client.release_hover)
        release_async_lifecycle_worker(action_client.release_definition)
      end
      app.try &.wait_for_lsp_action_public(1.second)
      client.try &.stop
    end
  end

  it "does not send hyperclick references after invalidating a held definition" do
    app : AsyncLifecycleProbeApp? = nil
    client : AsyncLifecycleDelayedClient? = nil
    with_async_lifecycle_workspace do |tmp|
      source = tmp / "hyperclick.cr"
      File.write(source.to_s, "puts :hyperclick\n")

      app = AsyncLifecycleProbeApp.new(project_root: tmp, lsp_command: "")
      client = AsyncLifecycleDelayedClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      raise "source should open" unless app.open_file_public(source)

      app.hyperclick_smart_public
      wait_for_async_lifecycle_signal(client.not_nil!.definition_entered, "held hyperclick definition")

      app.invalidate_lsp_actions_public
      release_async_lifecycle_worker(client.not_nil!.release_definition)
      app.wait_for_lsp_action_public
      raise "definition should be requested exactly once" unless client.not_nil!.definition_calls == 1
      raise "invalidated hyperclick must not request references" unless client.not_nil!.references_calls == 0
      raise "invalidated hyperclick must not open a popup" if app.lsp_popup_open_public
    ensure
      if action_client = client
        release_async_lifecycle_worker(action_client.release_hover)
        release_async_lifecycle_worker(action_client.release_definition)
      end
      app.try &.wait_for_lsp_action_public(1.second)
      client.try &.stop
    end
  end

  it "does not send a queued request after a programmatic edit" do
    app : AsyncLifecycleProbeApp? = nil
    client : AsyncLifecycleDelayedClient? = nil
    with_async_lifecycle_workspace do |tmp|
      source = tmp / "queued.cr"
      File.write(source.to_s, "puts :queued\n")

      app = AsyncLifecycleProbeApp.new(project_root: tmp, lsp_command: "")
      client = AsyncLifecycleDelayedClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      raise "source should open" unless app.open_file_public(source)

      app.show_hover_hint_public
      wait_for_async_lifecycle_signal(client.not_nil!.hover_entered, "running hover")
      app.show_hover_hint_public
      app.insert_text_public("x")

      release_async_lifecycle_worker(client.not_nil!.release_hover)
      app.wait_for_lsp_action_public
      raise "the queued request must be discarded before client dispatch" unless client.not_nil!.hover_calls == 1
      raise "stale queued hover must not open a popup" if app.lsp_popup_open_public
      raise "stale queued hover must not be displayed" if app.lsp_popup_lines_public.includes?("queued-hover")
    ensure
      if action_client = client
        release_async_lifecycle_worker(action_client.release_hover)
        release_async_lifecycle_worker(action_client.release_definition)
      end
      app.try &.wait_for_lsp_action_public(1.second)
      client.try &.stop
    end
  end
end
