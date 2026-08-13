require "spec"
require "crystal_tui"

require "../src/editor/lsp_client"
require "../src/editor/hyperclick"

describe CrystalEditor::Hyperclick do
  it "prefers references when definition list is empty" do
    locations = [] of CrystalEditor::Lsp::Location
    raise "empty should prefer references" unless CrystalEditor::Hyperclick.prefer_references?("file:///a.cr", 3, locations)
  end

  it "prefers references when a definition is on the same line" do
    locations = [
      CrystalEditor::Lsp::Location.new("file:///a.cr", 10, 2),
      CrystalEditor::Lsp::Location.new("file:///b.cr", 1, 0),
    ]
    raise "same-line def should prefer references" unless CrystalEditor::Hyperclick.prefer_references?("file:///a.cr", 10, locations)
  end

  it "jumps when definition is elsewhere" do
    locations = [CrystalEditor::Lsp::Location.new("file:///b.cr", 4, 0)]
    raise "remote def should jump" if CrystalEditor::Hyperclick.prefer_references?("file:///a.cr", 10, locations)
  end
end
