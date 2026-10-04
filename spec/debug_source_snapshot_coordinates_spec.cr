require "spec"

require "../src/adamantine/debug_source_resolver"
require "../src/adamantine/debug_source_store"

private class DebugSourceSnapshotWithoutWholeText < Adamantine::Debugging::DebugSourceSnapshot
  def text : String
    raise "coordinate lookup must not copy the whole source snapshot"
  end
end

describe Adamantine::Debugging::DebugSourceResolver, "retained source coordinates" do
  it "reads only the requested snapshot line and preserves CRLF and trailing-empty semantics" do
    key = Adamantine::Debugging::DebugSourceKey.local("/tmp/snapshot-coordinates.cr")
    source = DebugSourceSnapshotWithoutWholeText.new(
      key,
      "first\r\n\t😀last\n",
      Adamantine::Debugging::SourceOrigin::LaunchBaseline,
    )
    resolver = Adamantine::Debugging::DebugSourceResolver.new(
      "/tmp",
      [] of Adamantine::Debugging::DebugSourceMap,
      "coordinate-session",
    )

    raise "first line mismatch" unless source.line_text(0) == "first"
    raise "CRLF line mismatch" unless source.line_text(1) == "\t😀last"
    raise "trailing empty line must remain addressable" unless source.line_text(2) == ""
    raise "out-of-range editor line must not be synthesized" unless source.line_text(3).nil?
    raise "negative editor line must not be synthesized" unless source.line_text(-1).nil?

    position = resolver.to_editor_position(source, 2, 4)
    raise "UTF-16 columns must map after a supplementary character" unless position.line == 1 && position.column == 2
    trailing = resolver.to_editor_position(source, 3, 1)
    raise "DAP trailing empty line must map to editor line 2" unless trailing.line == 2 && trailing.column == 0
    begin
      resolver.to_editor_position(source, 4, 1)
      raise "out-of-range DAP source line must be rejected"
    rescue ex : ArgumentError
      raise "out-of-range DAP source line must retain its diagnostic" unless ex.message.try(&.includes?("outside source text"))
    end
  end

  it "scans a late empty line without invoking the whole-source getter" do
    key = Adamantine::Debugging::DebugSourceKey.local("/tmp/large-snapshot-coordinates.cr")
    source_text = "x\n" * 100_000
    source = DebugSourceSnapshotWithoutWholeText.new(
      key,
      source_text,
      Adamantine::Debugging::SourceOrigin::LaunchBaseline,
    )
    resolver = Adamantine::Debugging::DebugSourceResolver.new(
      "/tmp",
      [] of Adamantine::Debugging::DebugSourceMap,
      "large-coordinate-session",
    )

    line = source.line_text(100_000)
    raise "large trailing empty line was lost" unless line == ""
    position = resolver.to_editor_position(source, 100_001, 1)
    raise "late snapshot coordinate mismatch" unless position.line == 100_000 && position.column == 0
  end
end
