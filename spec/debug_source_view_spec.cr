require "spec"
require "file_utils"
require "random/secure"

require "../src/adamantine/app"

private class DebugReadOnlySourceRenderApp < Adamantine::App
  def render_source_text_public(text : String, width : Int32, height : Int32) : Array(String)
    @debug_readonly_source = Adamantine::DebugReadOnlySource.new("adapter source", nil, "Unverified", false, text)
    @debug_modal_kind = Adamantine::DebugUiController::DebugModalKind::Source
    self.rect = Tui::Rect.new(0, 0, width, height)
    buffer = Tui::Buffer.new(width, height)
    clip = Tui::Rect.new(0, 0, width, height)
    style = Tui::Style.new
    render_debug_readonly_source(buffer, clip, 0, 0, width, height, style, style)
    @debug_source_cached_lines.map(&.dup)
  end

  def close_debug_source_test_public : Nil
    close_debug_ui
  end
end

private def with_debug_source_view_workspace(&)
  root = Path.new(Dir.tempdir, "adamantine-debug-source-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

describe Adamantine::DebugReadOnlySource do
  it "returns a bounded UTF-8-safe prefix before display formatting" do
    text = "🧪界" * 400_000
    source = Adamantine::DebugReadOnlySource.new("adapter source", nil, "Unverified", false, text)

    row = source.line(0, 22)
    row.valid_encoding?.should be_true
    row.bytesize.should be <= 22
    row.should end_with("…")
    row.should start_with("🧪界")
    source.line(0, 0).should eq("")
    source.line(0, 2).bytesize.should be <= 2
  end

  it "projects only the requested line from sparse checkpoints" do
    source = Adamantine::DebugReadOnlySource.new("source", nil, "Match", false,
      "alpha\nbeta-界界\ngamma")

    source.line_count.should eq(3)
    source.line(0).should eq("alpha")
    source.line(1, 8).should eq("beta-…")
    source.line(2).should eq("gamma")
  end

  it "renders a very long non-ASCII line from a viewport-sized cached prefix" do
    with_debug_source_view_workspace do |root|
      app = DebugReadOnlySourceRenderApp.new(
        project_root: root,
        lsp_command: "",
        recovery_root: root / "recovery",
        session_enabled: false
      )
      rows = app.render_source_text_public("界🧪" * 300_000, 40, 8)
      rows.size.should eq(1)
      rows.first.bytesize.should be <= 36
      rows.first.should start_with("1: ")
      rows.first.should end_with("…")
    ensure
      app.try(&.close_debug_source_test_public)
    end
  end
end
