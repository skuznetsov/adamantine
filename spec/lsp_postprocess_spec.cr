require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"
require "../src/adamantine/lsp_line_source"

private class NoWholeLinesEditor < Adamantine::EditingTextEditor
  def lines : Array(String)
    raise "post-processing must not materialize editor lines"
  end
end

private class LspPostProcessProbeApp < Adamantine::App
  def open_file_public(path : Path) : Bool
    open_file(path)
  end

  def close_active_tab_public : Bool
    close_active_tab
  end

  def current_buffer_public : Adamantine::OpenBuffer?
    current_buffer
  end

  def set_lsp_client_public(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def clear_lsp_client_public : Nil
    @lsp = nil
  end

  def schedule_semantic_public(buffer : Adamantine::OpenBuffer, delay : Time::Span) : Nil
    schedule_semantic_tokens(buffer, delay)
  end
end

private class DelayedSemanticClient < Adamantine::Lsp::Client
  getter entered = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)
  getter finished = Channel(Nil).new(1)

  def initialize(root : Path)
    super("", root)
    self.connected = true
  end

  def semantic_tokens_supported? : Bool
    true
  end

  def semantic_tokens_full(_uri : String) : Array(Int32)?
    @entered.send(nil)
    @release.receive
    @finished.send(nil)
    [0, 0, 3, 15, 0]
  end
end

private def wait_postprocess_signal(channel : Channel(Nil), label : String) : Nil
  deadline = Time.instant + 1.second
  loop do
    select
    when channel.receive
      return
    when timeout(5.milliseconds)
      raise "timed out waiting for #{label}" if Time.instant >= deadline
    end
  end
end

private def with_postprocess_workspace(&)
  tmp_dir = Path.new(Dir.tempdir, "editor-lsp-postprocess-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe "lazy LSP post-processing sources" do
  it "builds semantic overlays without the editor lines getter" do
    editor = NoWholeLinesEditor.new("lazy-semantic")
    editor.text = "def foo\n  # note\nend"
    source = editor.lsp_line_source

    overlay = Adamantine::SemanticOverlay.build(
      [0, 0, 3, 15, 0],
      source,
      Adamantine::SemanticOverlay::STANDARD_LEGEND
    )
    overlay.apply_hash_comments(source)

    raise "keyword token should be present" unless overlay.name_at(0, 0) == "keyword"
    raise "hash comment should be present" unless overlay.name_at(1, 2) == "comment"
  end

  it "keeps a persistent source snapshot after the editor changes" do
    editor = NoWholeLinesEditor.new("snapshot-source")
    editor.text = "else\n  puts 1\nend"
    source = editor.lsp_line_source
    editor.text = "new text"

    ranges = Adamantine::Folding.merge_crystal_branches(source, [] of Tui::TextEditor::FoldRange)
    raise "snapshot should retain the old branch" unless ranges.any? { |range| range.start_line == 0 }
  end

  it "rejects a response after the buffer version changes" do
    app : LspPostProcessProbeApp? = nil
    client : DelayedSemanticClient? = nil
    with_postprocess_workspace do |tmp|
      path = tmp / "version.cr"
      File.write(path.to_s, "def versioned\nend\n")
      app = LspPostProcessProbeApp.new(project_root: tmp, lsp_command: "")
      raise "source should open" unless app.open_file_public(path)
      client = DelayedSemanticClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      buffer = app.current_buffer_public.not_nil!
      app.schedule_semantic_public(buffer, Time::Span.zero)
      wait_postprocess_signal(client.not_nil!.entered, "semantic request")

      buffer.version += 1
      client.not_nil!.release.send(nil)
      wait_postprocess_signal(client.not_nil!.finished, "semantic response")
      raise "version-stale response must not publish" if buffer.semantic_overlay.any_tokens?
    ensure
      client.try &.stop
      app.try &.clear_lsp_client_public
    end
  end

  it "rejects a response after closing and reopening the same path" do
    app : LspPostProcessProbeApp? = nil
    client : DelayedSemanticClient? = nil
    with_postprocess_workspace do |tmp|
      path = tmp / "reopen.cr"
      File.write(path.to_s, "def reopened\nend\n")
      app = LspPostProcessProbeApp.new(project_root: tmp, lsp_command: "")
      raise "source should open" unless app.open_file_public(path)
      client = DelayedSemanticClient.new(tmp)
      app.set_lsp_client_public(client.not_nil!)
      old_buffer = app.current_buffer_public.not_nil!
      app.schedule_semantic_public(old_buffer, Time::Span.zero)
      wait_postprocess_signal(client.not_nil!.entered, "semantic request")

      raise "path should close" unless app.close_active_tab_public
      raise "path should reopen" unless app.open_file_public(path)
      new_buffer = app.current_buffer_public.not_nil!
      raise "close/reopen must create a new OpenBuffer" if new_buffer.same?(old_buffer)

      client.not_nil!.release.send(nil)
      wait_postprocess_signal(client.not_nil!.finished, "semantic response")
      app.clear_lsp_client_public
      raise "close/reopen stale response must not publish" if new_buffer.semantic_overlay.any_tokens?
    ensure
      client.try &.stop
      app.try &.clear_lsp_client_public
    end
  end
end
