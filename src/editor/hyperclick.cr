module CrystalEditor
  module Hyperclick
    # Prefer find-references when definition is missing or already under the cursor.
    def self.prefer_references?(uri : String, line : Int32, locations : Array(Lsp::Location)) : Bool
      return true if locations.empty?
      locations.any? { |location| location.uri == uri && location.line == line }
    end
  end
end
