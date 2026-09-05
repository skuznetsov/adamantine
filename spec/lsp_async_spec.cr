require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private class AsyncLspTestApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def set_lsp_client_public(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def show_hover_hint_public : Nil
    show_hover_hint
  end

  def show_references_hint_public : Nil
    show_references_hint
  end

  def show_definition_public : Nil
    goto_definition
  end

  def close_lsp_popup_public : Nil
    close_lsp_popup
  end

  def set_cursor_public(line : Int32, column : Int32) : Nil
    editor = current_editor
    raise "no active editor" unless editor
    editor.set_cursor(line, column)
  end

  def insert_text_public(text : String) : Nil
    editor = current_editor
    raise "no active editor" unless editor
    editor.insert_text(text)
  end

  def move_cursor_with_key_public(key : Tui::Key) : Bool
    handle_event(Tui::KeyEvent.new(key))
  end

  def lsp_popup_open_public : Bool
    @lsp_popup.open
  end

  def lsp_popup_lines_public : Array(String)
    @lsp_popup.lines
  end

  def lsp_popup_title_public : String
    @lsp_popup.title
  end

  def current_buffer_path_public : String?
    current_buffer.try(&.path.to_s)
  end

  def navigation_history_size_public : Int32
    @document_session.navigation_history.size
  end

  def wait_for_lsp_action_public(timeout_span : Time::Span = 1.second) : Nil
    deadline = Time.instant + timeout_span
    while @lsp_action_running
      raise "timed out waiting for asynchronous LSP action" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  def shutdown_lsp_public : Nil
    shutdown_lsp
  end

  def hyperclick_smart_public : Nil
    hyperclick_smart
  end

  def mark_clean_public : Nil
    mark_clean!
  end

  def fill_event_channel_public : Nil
    64.times do
      select
      when @input.events.send(Tui::WakeupEvent.new)
      else
        break
      end
    end
  end

  def lsp_warnings_public : Array(String)
    @status_log.entries.select { |entry| entry.level == Tui::Log::Level::Warning }.map(&.message)
  end
end

private class SlowHoverClient < Adamantine::Lsp::Client
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  def initialize(root : Path)
    super("", root)
    self.connected = true
  end

  def hover(uri : String, line : Int32, character : Int32) : Adamantine::Lsp::Hover?
    @entered.send(nil)
    @release.receive
    Adamantine::Lsp::Hover.new("slow hover")
  end
end

private class SequencedHoverClient < Adamantine::Lsp::Client
  getter calls = Channel(Int32).new(4)
  getter release_first = Channel(Nil).new(1)

  @call_count = 0

  def initialize(root : Path)
    super("", root)
    self.connected = true
  end

  def hover(uri : String, line : Int32, character : Int32) : Adamantine::Lsp::Hover?
    call_index = @call_count
    @call_count += 1
    @calls.send(call_index)
    if call_index == 0
      @release_first.receive
      Adamantine::Lsp::Hover.new("stale hover")
    else
      Adamantine::Lsp::Hover.new("latest hover")
    end
  end
end

private class ErrorThenHoverClient < Adamantine::Lsp::Client
  getter calls = 0

  def initialize(root : Path)
    super("", root)
    self.connected = true
  end

  def hover(uri : String, line : Int32, character : Int32) : Adamantine::Lsp::Hover?
    @calls += 1
    raise "controlled hover failure" if @calls == 1
    Adamantine::Lsp::Hover.new("recovered hover")
  end
end

private class SlowDefinitionClient < Adamantine::Lsp::Client
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  def initialize(root : Path, @target : Path)
    super("", root)
    self.connected = true
  end

  def goto_definition(uri : String, line : Int32, character : Int32) : Array(Adamantine::Lsp::Location)
    @entered.send(nil)
    @release.receive
    [Adamantine::Lsp::Location.new(Adamantine::UriCodec.path_to_uri(@target), 0, 0)]
  end
end

private class FullQueueHyperclickClient < Adamantine::Lsp::Client
  getter definition_entered = Channel(Nil).new(1)
  getter release_definition = Channel(Nil).new(1)
  getter definition_calls : Int32 = 0
  getter references_calls : Int32 = 0

  def initialize(root : Path)
    super("", root)
    self.connected = true
  end

  def goto_definition(uri : String, line : Int32, character : Int32) : Array(Adamantine::Lsp::Location)
    @definition_calls += 1
    @definition_entered.send(nil)
    @release_definition.receive
    [Adamantine::Lsp::Location.new(uri, line, character)]
  end

  def references(uri : String, line : Int32, character : Int32, _include_declaration : Bool = true) : Array(Adamantine::Lsp::Location)
    @references_calls += 1
    [Adamantine::Lsp::Location.new(uri, line, character)]
  end
end

def with_async_lsp_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-lsp-async-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe "interactive LSP actions" do
  it "returns control while a hover request is slow" do
    client : SlowHoverClient? = nil
    with_async_lsp_workspace do |tmp|
      path = tmp / "sample.cr"
      File.write(path.to_s, "puts 1\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "sample file should open" unless app.open_file_public(path)
      client = SlowHoverClient.new(tmp)
      app.set_lsp_client_public(client)

      returned = Channel(Nil).new(1)
      spawn do
        app.show_hover_hint_public
        returned.send(nil)
      end

      select
      when returned.receive
      when timeout(100.milliseconds)
        raise "slow hover must return control to the caller"
      end

      select
      when client.not_nil!.entered.receive
      when timeout(1.second)
        raise "slow hover request should run in the background"
      end
    ensure
      if action_client = client
        select
        when action_client.release.send(nil)
        else
        end
      end
    end
  end

  it "keeps one running action and replaces an older queued action" do
    client : SequencedHoverClient? = nil
    with_async_lsp_workspace do |tmp|
      path = tmp / "sample.cr"
      File.write(path.to_s, "puts 1\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "sample file should open" unless app.open_file_public(path)
      client = SequencedHoverClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)

      app.show_hover_hint_public
      select
      when call = client.not_nil!.calls.receive
        raise "first hover should be the running action" unless call == 0
      when timeout(1.second)
        raise "first hover should start"
      end

      app.show_hover_hint_public
      app.show_references_hint_public
      app.show_hover_hint_public

      select
      when client.not_nil!.release_first.send(nil)
      else
      end
      app.wait_for_lsp_action_public

      raise "latest queued hover should publish" unless app.lsp_popup_open_public
      raise "latest queued hover should win" unless app.lsp_popup_lines_public.includes?("latest hover")
      raise "stale hover must not publish" if app.lsp_popup_lines_public.includes?("stale hover")
      calls = [] of Int32
      loop do
        select
        when call = client.not_nil!.calls.receive
          calls << call
        else
          break
        end
      end
      raise "only one queued action should run" unless calls == [1]
    ensure
      if action_client = client
        select
        when action_client.release_first.send(nil)
        else
        end
      end
    end
  end

  it "drops a response after a cursor move away and back" do
    client : SlowHoverClient? = nil
    with_async_lsp_workspace do |tmp|
      path = tmp / "sample.cr"
      File.write(path.to_s, "puts 1\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "sample file should open" unless app.open_file_public(path)
      client = SlowHoverClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      app.show_hover_hint_public
      select
      when client.not_nil!.entered.receive
      when timeout(1.second)
        raise "hover should start"
      end

      app.move_cursor_with_key_public(Tui::Key::Right)
      app.move_cursor_with_key_public(Tui::Key::Left)
      select
      when client.not_nil!.release.send(nil)
      else
      end
      app.wait_for_lsp_action_public
      raise "moving away and back must invalidate hover" if app.lsp_popup_open_public
    ensure
      if action_client = client
        select
        when action_client.release.send(nil)
        else
        end
      end
    end
  end

  it "drops a response after the buffer is edited" do
    client : SlowHoverClient? = nil
    with_async_lsp_workspace do |tmp|
      path = tmp / "sample.cr"
      File.write(path.to_s, "puts 1\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "sample file should open" unless app.open_file_public(path)
      client = SlowHoverClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      app.show_hover_hint_public
      select
      when client.not_nil!.entered.receive
      when timeout(1.second)
        raise "hover should start"
      end

      app.insert_text_public("x")
      select
      when client.not_nil!.release.send(nil)
      else
      end
      app.wait_for_lsp_action_public
      raise "editing must invalidate hover" if app.lsp_popup_open_public
    ensure
      if action_client = client
        select
        when action_client.release.send(nil)
        else
        end
      end
    end
  end

  it "does not change navigation history for a stale definition" do
    client : SlowDefinitionClient? = nil
    with_async_lsp_workspace do |tmp|
      source = tmp / "source.cr"
      target = tmp / "target.cr"
      File.write(source.to_s, "puts 1\n")
      File.write(target.to_s, "puts 2\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "source file should open" unless app.open_file_public(source)
      client = SlowDefinitionClient.new(tmp, target)
      app.set_lsp_client_public(client.not_nil!)
      app.show_definition_public
      select
      when client.not_nil!.entered.receive
      when timeout(1.second)
        raise "definition should start"
      end

      app.move_cursor_with_key_public(Tui::Key::Right)
      select
      when client.not_nil!.release.send(nil)
      else
      end
      app.wait_for_lsp_action_public
      raise "stale definition must not navigate" unless app.current_buffer_path_public == source.to_s
      raise "stale definition must not add navigation history" unless app.navigation_history_size_public == 0
    ensure
      if action_client = client
        select
        when action_client.release.send(nil)
        else
        end
      end
    end
  end

  it "does not reopen a dismissed popup from a pending response" do
    client : SlowHoverClient? = nil
    with_async_lsp_workspace do |tmp|
      path = tmp / "sample.cr"
      File.write(path.to_s, "puts 1\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "sample file should open" unless app.open_file_public(path)
      client = SlowHoverClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      app.show_hover_hint_public
      select
      when client.not_nil!.entered.receive
      when timeout(1.second)
        raise "hover should start"
      end

      app.close_lsp_popup_public
      select
      when client.not_nil!.release.send(nil)
      else
      end
      app.wait_for_lsp_action_public
      raise "dismissed popup must stay closed" if app.lsp_popup_open_public
    ensure
      if action_client = client
        select
        when action_client.release.send(nil)
        else
        end
      end
    end
  end

  it "rejects a response from a replaced client" do
    client : SlowHoverClient? = nil
    with_async_lsp_workspace do |tmp|
      path = tmp / "sample.cr"
      File.write(path.to_s, "puts 1\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "sample file should open" unless app.open_file_public(path)
      client = SlowHoverClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      app.show_hover_hint_public
      select
      when client.not_nil!.entered.receive
      when timeout(1.second)
        raise "hover should start"
      end

      replacement = ErrorThenHoverClient.new(tmp)
      app.set_lsp_client_public(replacement)
      select
      when client.not_nil!.release.send(nil)
      else
      end
      app.wait_for_lsp_action_public
      raise "old client response must not publish" if app.lsp_popup_open_public
    ensure
      if action_client = client
        select
        when action_client.release.send(nil)
        else
        end
      end
    end
  end

  it "invalidates pending work before shutdown" do
    client : SlowHoverClient? = nil
    with_async_lsp_workspace do |tmp|
      path = tmp / "sample.cr"
      File.write(path.to_s, "puts 1\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "sample file should open" unless app.open_file_public(path)
      client = SlowHoverClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      app.show_hover_hint_public
      select
      when client.not_nil!.entered.receive
      when timeout(1.second)
        raise "hover should start"
      end

      app.shutdown_lsp_public
      select
      when client.not_nil!.release.send(nil)
      else
      end
      app.wait_for_lsp_action_public
      raise "shutdown must leave popup closed" if app.lsp_popup_open_public
    ensure
      if action_client = client
        select
        when action_client.release.send(nil)
        else
        end
      end
    end
  end

  it "cleans up after an action error so the next request can publish" do
    with_async_lsp_workspace do |tmp|
      path = tmp / "sample.cr"
      File.write(path.to_s, "puts 1\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "sample file should open" unless app.open_file_public(path)
      client = ErrorThenHoverClient.new(tmp)
      app.set_lsp_client_public(client)

      app.show_hover_hint_public
      app.wait_for_lsp_action_public
      raise "failed hover should be contained" unless app.lsp_warnings_public.any? { |line| line.includes?("controlled hover failure") }

      app.show_hover_hint_public
      app.wait_for_lsp_action_public
      raise "next hover should run after failure" unless app.lsp_popup_open_public
      raise "recovered hover should publish" unless app.lsp_popup_lines_public.includes?("recovered hover")
    end
  end

  it "does not block hyperclick follow-up or popup publication on a full event queue" do
    client : FullQueueHyperclickClient? = nil
    with_async_lsp_workspace do |tmp|
      path = tmp / "sample.cr"
      File.write(path.to_s, "puts 1\n")
      app = AsyncLspTestApp.new(project_root: tmp, lsp_command: "")
      raise "sample file should open" unless app.open_file_public(path)
      client = FullQueueHyperclickClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)

      app.hyperclick_smart_public
      select
      when client.not_nil!.definition_entered.receive
      when timeout(1.second)
        raise "hyperclick definition should start"
      end

      # Force publication to exercise wakeup while the bounded event channel
      # is full. The action itself must still reach references and open its
      # read-only popup.
      app.mark_clean_public
      app.fill_event_channel_public
      select
      when client.not_nil!.release_definition.send(nil)
      else
      end
      app.wait_for_lsp_action_public

      raise "hyperclick definition should be requested once" unless client.not_nil!.definition_calls == 1
      raise "hyperclick should request references once" unless client.not_nil!.references_calls == 1
      raise "references popup should publish after a full event queue" unless app.lsp_popup_open_public
      raise "references popup title should be preserved" unless app.lsp_popup_title_public == "References"
    ensure
      if action_client = client
        select
        when action_client.release_definition.send(nil)
        else
        end
      end
    end
  end
end
