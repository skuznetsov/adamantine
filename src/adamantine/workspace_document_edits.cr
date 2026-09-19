require "json"
require "set"

require "./safe_document_edits"

module Adamantine
  # Extract the plain TextEdit payload from the small WorkspaceEdit subset that
  # Adamantine can safely preview and apply.  This is deliberately a protocol
  # boundary, not a TextEdit validator: SafeDocumentEdits owns ranges,
  # replacement bounds, UTF-16 resolution, and mutation atomicity.
  module WorkspaceDocumentEdits
    MAX_EDITS = SafeDocumentEdits::MAX_EDITS

    private def self.reject!(message : String) : NoReturn
      raise ArgumentError.new("invalid workspace edit: #{message}")
    end

    private def self.object!(value : JSON::Any?, label : String) : Hash(String, JSON::Any)
      reject!("missing #{label}") unless value
      value.not_nil!.as_h? || reject!("#{label} must be an object")
    end

    private def self.array!(value : JSON::Any?, label : String) : Array(JSON::Any)
      reject!("missing #{label}") unless value
      value.not_nil!.as_a? || reject!("#{label} must be an array")
    end

    private def self.string!(value : JSON::Any?, label : String) : String
      reject!("missing #{label}") unless value
      result = value.not_nil!.as_s?
      reject!("#{label} must be a string") unless result
      text = result.not_nil!
      reject!("#{label} must be valid UTF-8") unless text.valid_encoding?
      text
    end

    private def self.reject_unknown!(object : Hash(String, JSON::Any), allowed : Array(String), label : String) : Nil
      object.each_key do |key|
        reject!("unsupported #{label} field") unless allowed.includes?(key)
      end
    end

    private def self.append_edits!(destination : Array(JSON::Any), raw_edits : Array(JSON::Any), label : String) : Nil
      if destination.size.to_i64 + raw_edits.size.to_i64 > MAX_EDITS
        reject!("#{label} exceeds #{MAX_EDITS} edits")
      end

      raw_edits.each do |edit|
        # AnnotatedTextEdit is a valid LSP type, but annotation application is
        # intentionally outside this slice.  Keep all other TextEdit shape
        # and coordinate checks in SafeDocumentEdits.
        if edit_hash = edit.as_h?
          reject!("unsupported annotated edit") if edit_hash.has_key?("annotationId")
        end
        destination << edit
      end
    end

    private def self.version_matches!(text_document : Hash(String, JSON::Any), expected : Int32) : Nil
      reject!("textDocument.version is missing") unless text_document.has_key?("version")
      raw_version = text_document["version"]
      return if raw_version.raw.nil?

      actual = raw_version.as_i64?
      reject!("textDocument.version must be an integer or null") unless actual
      reject!("textDocument.version does not match the captured version") unless actual == expected.to_i64
    end

    private def self.extract_changes(raw_changes : JSON::Any, uri : String) : Array(JSON::Any)
      changes = object!(raw_changes, "changes")
      result = [] of JSON::Any
      changes.each do |target_uri, raw_edits|
        # Reject a wider operation even when the server supplied no edits for
        # the foreign file.  A same-file subset must never be silently applied.
        reject!("foreign document URI") unless target_uri == uri
        append_edits!(result, array!(raw_edits, "changes entry"), "changes")
      end
      result
    end

    private def self.extract_document_changes(raw_document_changes : JSON::Any, uri : String, version : Int32) : Array(JSON::Any)
      entries = array!(raw_document_changes, "documentChanges")
      result = [] of JSON::Any
      seen = Set(String).new

      entries.each_with_index do |raw_entry, index|
        entry = object!(raw_entry, "documentChanges[#{index}]")
        reject_unknown!(entry, ["textDocument", "edits"], "documentChanges entry")

        text_document = object!(entry["textDocument"]?, "documentChanges[#{index}].textDocument")
        reject_unknown!(text_document, ["uri", "version"], "textDocument")
        target_uri = string!(text_document["uri"]?, "documentChanges[#{index}].textDocument.uri")
        reject!("duplicate document entry") if seen.includes?(target_uri)
        seen.add(target_uri)
        reject!("foreign document URI") unless target_uri == uri

        version_matches!(text_document, version)
        raw_edits = entry["edits"]?
        append_edits!(result, array!(raw_edits, "documentChanges[#{index}].edits"), "documentChanges")
      end

      result
    end

    # Return a detached array of plain TextEdit JSON values for the captured
    # current document.  Null and an empty object intentionally mean no work.
    # Any non-empty unsupported or mixed envelope fails closed.
    def self.extract(raw : JSON::Any?, uri : String, version : Int32) : Array(JSON::Any)
      return [] of JSON::Any unless raw
      return [] of JSON::Any if raw.raw.nil?

      envelope = object!(raw, "workspace edit")
      return [] of JSON::Any if envelope.empty?

      reject_unknown!(envelope, ["changes", "documentChanges"], "workspace edit")
      has_changes = envelope.has_key?("changes")
      has_document_changes = envelope.has_key?("documentChanges")
      reject!("changes and documentChanges cannot both be present") if has_changes && has_document_changes

      if has_changes
        extract_changes(envelope["changes"], uri)
      elsif has_document_changes
        extract_document_changes(envelope["documentChanges"], uri, version)
      else
        [] of JSON::Any
      end
    end
  end
end
