require "spec"
require "file_utils"

require "../src/adamantine/key_config"
require "../src/adamantine/document_orchestrator"
require "../src/adamantine/document_session"
require "../src/adamantine/document_types"
require "../src/adamantine/lsp_client"
require "../src/adamantine/uri_codec"
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

def make_smoke_orchestrator : {Adamantine::DocumentOrchestrator, Adamantine::DocumentSession}
  document_session = Adamantine::DocumentSession.new
  editor_tabs = Tui::TabbedPanel.new("tabs")
  status_log = Tui::Log.new("status")

  orchestrator = Adamantine::DocumentOrchestrator.new(
    document_session,
    editor_tabs,
    status_log,
    ->(_editor : Tui::TextEditor) { },
    ->(_editor : Tui::TextEditor, _buffer : Adamantine::OpenBuffer?) { },
    ->(_editor : Tui::TextEditor, _buffer : Adamantine::OpenBuffer) { },
    ->(_path : Path) { "text" },
    ->(path : Path) { Adamantine::UriCodec.path_to_uri(path) },
    ->(uri : String) { Adamantine::UriCodec.uri_to_path(uri) },
    -> { },
    ->(_buffer : Adamantine::OpenBuffer) { },
    ->(_buffer : Adamantine::OpenBuffer, _change : Tui::TextEditor::TextChange) { },
    ->(_buffer : Adamantine::OpenBuffer) { },
    ->(_uri : String) { },
    -> { nil.as(Adamantine::DocumentOrchestrator::CurrentLspContext) }
  )

  {orchestrator, document_session}
end

describe "Editor smoke checks" do
  it "rejects oversized file open in orchestrator" do
    with_temp_workspace do |tmp_dir|
      file = Path.new(tmp_dir, "too_large.txt")
      create_file_of_size(file, Adamantine::DocumentOrchestrator::MAX_FILE_BYTES.to_i64 + 1)

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
      padded = payload + (" " * (Adamantine::KeyConfig::MAX_KEYMAP_FILE_BYTES + 1 - payload.bytesize))
      File.write(path, padded)

      loaded = Adamantine::KeyConfig.load(path.to_s)
      raise "oversized keymap should fallback to defaults" unless loaded == Adamantine::KeyConfig.defaults
    end
  end
end
