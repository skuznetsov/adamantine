require "spec"
require "file_utils"

require "../src/editor/key_config"
require "../src/editor/document_orchestrator"
require "../src/editor/document_session"
require "../src/editor/document_types"
require "../src/editor/lsp_client"
require "../src/editor/uri_codec"
require "crystal_tui"

def with_temp_workspace(prefix : String = "editor-ci-smoke-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)
  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

def create_file_of_size(path : Path, bytes : Int64) : Nil
  File.open(path, "w") do |file|
    file.truncate(bytes)
  end
end

def make_smoke_orchestrator : {CrystalEditor::DocumentOrchestrator, CrystalEditor::DocumentSession}
  document_session = CrystalEditor::DocumentSession.new
  editor_tabs = Tui::TabbedPanel.new("tabs")
  status_log = Tui::Log.new("status")

  orchestrator = CrystalEditor::DocumentOrchestrator.new(
    document_session,
    editor_tabs,
    status_log,
    ->(_editor : Tui::TextEditor) { },
    ->(_editor : Tui::TextEditor, _buffer : CrystalEditor::OpenBuffer?) { },
    ->(_editor : Tui::TextEditor, _buffer : CrystalEditor::OpenBuffer) { },
    ->(_path : Path) { "text" },
    ->(path : Path) { CrystalEditor::UriCodec.path_to_uri(path) },
    ->(uri : String) { CrystalEditor::UriCodec.uri_to_path(uri) },
    -> { },
    ->(_buffer : CrystalEditor::OpenBuffer) { },
    ->(_buffer : CrystalEditor::OpenBuffer) { },
    ->(_buffer : CrystalEditor::OpenBuffer) { },
    ->(_uri : String) { },
    -> { nil.as(CrystalEditor::DocumentOrchestrator::CurrentLspContext) }
  )

  {orchestrator, document_session}
end

describe "Editor smoke checks" do
  it "rejects oversized file open in orchestrator" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "too_large.txt")
      create_file_of_size(file, CrystalEditor::DocumentOrchestrator::MAX_FILE_BYTES.to_i64 + 1)

      orchestrator, document_session = make_smoke_orchestrator
      opened = orchestrator.open_file(file)
      raise "oversized file must be rejected" if opened
      raise "no buffer should be created for oversized file" unless document_session.open_buffers.empty?
    end
  end

  it "falls back to defaults for oversized keymap files" do
    with_temp_workspace do |tmp_dir|
      path = Path.new(tmp_dir, "large_keymap.json")
      payload = "{\"keymap\":{\"app.save\":[\"ctrl+s\"]}}"
      padded = payload + (" " * (CrystalEditor::KeyConfig::MAX_KEYMAP_FILE_BYTES + 1 - payload.bytesize))
      File.write(path, padded)

      loaded = CrystalEditor::KeyConfig.load(path.to_s)
      raise "oversized keymap should fallback to defaults" unless loaded == CrystalEditor::KeyConfig.defaults
    end
  end
end
