require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

private class AsyncNavigationRegressionApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def set_lsp_client_public(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def show_definition_public : Nil
    goto_definition
  end

  def invalidate_lsp_actions_public : Nil
    invalidate_lsp_actions
  end

  def current_buffer_path_public : String?
    current_buffer.try(&.path.to_s)
  end

  def current_editor_public : Tui::TextEditor?
    current_editor
  end

  def open_buffer_count_public : Int32
    @document_session.open_buffers.size
  end

  def navigation_history_size_public : Int32
    @document_session.navigation_history.size
  end

  def wait_for_lsp_action_public(timeout_span : Time::Span = 2.seconds) : Nil
    deadline = Time.instant + timeout_span
    while @lsp_action_running
      raise "timed out waiting for asynchronous LSP action" if Time.instant >= deadline
      sleep 1.millisecond
    end
  end

  def shutdown_lsp_public : Nil
    shutdown_lsp
  end
end

private class AsyncNavigationDefinitionClient < Adamantine::Lsp::Client
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

private def with_async_navigation_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-lsp-async-navigation-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

private def wait_for_async_navigation_signal(channel : Channel(Nil), label : String, timeout_span : Time::Span = 1.second) : Nil
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

private def release_async_navigation_worker(channel : Channel(Nil)) : Nil
  select
  when channel.send(nil)
  else
  end
end

private def write_large_async_navigation_target(path : Path) : Nil
  line = "x" * 2_000_000
  File.open(path.to_s, "w") do |file|
    file << line
    file << "\n"
  end
end

describe "asynchronous LSP navigation" do
  it "drops a stale definition while snapshotting a large unopened target" do
    app : AsyncNavigationRegressionApp? = nil
    client : AsyncNavigationDefinitionClient? = nil
    with_async_navigation_workspace do |tmp|
      source = tmp / "source.cr"
      target = tmp / "large_target.cr"
      File.write(source.to_s, "puts :source\n")
      write_large_async_navigation_target(target)

      test_app = AsyncNavigationRegressionApp.new(project_root: tmp, lsp_command: "")
      app = test_app
      test_client = AsyncNavigationDefinitionClient.new(tmp, target)
      client = test_client
      test_app.set_lsp_client_public(test_client)
      raise "source file should open" unless test_app.open_file_public(source)

      initial_editor = test_app.current_editor_public
      raise "source editor should be active" unless initial_editor
      test_app.show_definition_public
      wait_for_async_navigation_signal(test_client.entered, "definition request")

      # Let the worker enter FileRevision.read before invalidating. The target
      # is deliberately much larger than one read chunk, so it yields repeatedly.
      release_async_navigation_worker(test_client.release)
      invalidation_done = Channel(Nil).new(1)
      spawn do
        3.times { Fiber.yield }
        app.not_nil!.invalidate_lsp_actions_public
        invalidation_done.send(nil)
      end

      test_app.wait_for_lsp_action_public
      wait_for_async_navigation_signal(invalidation_done, "navigation invalidation")
      raise "stale navigation must not add a target buffer" unless test_app.open_buffer_count_public == 1
      raise "stale navigation must not change the active tab" unless test_app.current_buffer_path_public == source.to_s
      raise "stale navigation must not add history" unless test_app.navigation_history_size_public == 0
      active_editor = test_app.current_editor_public
      raise "stale navigation must not move focus" unless active_editor && active_editor.same?(initial_editor.not_nil!)
    ensure
      if action_client = client
        release_async_navigation_worker(action_client.release)
      end
      app.try &.wait_for_lsp_action_public
      app.try &.shutdown_lsp_public
      client.try &.stop
    end
  end
end
