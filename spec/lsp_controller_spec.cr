require "spec"
require "file_utils"
require "crystal_tui"

require "../src/adamantine/app"

class LspControllerTestApp < Adamantine::App
  def diagnostic_in_range_public?(diagnostic : Adamantine::Lsp::Diagnostic, line : Int32, col : Int32) : Bool
    diagnostic_in_range?(diagnostic, line, col)
  end

  def severity_rank_public(severity : Int32?) : Int32
    severity_rank(severity)
  end

  def lsp_diagnostic_style_public(diagnostics : Array(Adamantine::Lsp::Diagnostic), line : Int32, col : Int32, base_style : Tui::Style) : Tui::Style
    lsp_diagnostic_style(diagnostics, line, col, base_style)
  end

  def lsp_connected? : Bool
    !@lsp.nil?
  end

  def set_lsp_client(client : Adamantine::Lsp::Client) : Nil
    @lsp = client
  end

  def show_lsp_status_public : Nil
    show_lsp_status
  end

  def sync_lsp_change_public(buffer : Adamantine::OpenBuffer, change : Tui::TextEditor::TextChange) : Nil
    sync_lsp_change(buffer, change)
  end

  def lsp_warnings : Array(String)
    @status_log.entries.select { |entry| entry.level == Tui::Log::Level::Warning }.map(&.message)
  end
end

private class LspSyncCaptureClient < Adamantine::Lsp::Client
  getter full_changes = [] of Tuple(String, Int32, String)
  getter ranged_changes = [] of Tuple(String, Int32, Adamantine::Lsp::Range, String)

  def initialize(@incremental : Bool)
    super("", Path.new(Dir.current), [] of String)
  end

  def connected? : Bool
    true
  end

  def incremental_text_sync? : Bool
    @incremental
  end

  def text_change(uri : String, version : Int32, text : String) : Nil
    @full_changes << {uri, version, text}
  end

  def text_change(uri : String, version : Int32, range : Adamantine::Lsp::Range, text : String) : Nil
    @ranged_changes << {uri, version, range, text}
  end
end

private class TextMaterializationSpy < Tui::TextEditor
  getter text_reads : Int32 = 0

  def text : String
    @text_reads += 1
    super
  end
end

def with_temp_workspace(prefix : String = "editor-lsp-ctrl-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe Adamantine::App do
  describe "LspController" do
    describe "diagnostic_in_range?" do
      it "returns true when cursor is within single-line diagnostic" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = Adamantine::Lsp::Diagnostic.new(5, 10, "error", end_line: 5, end_character: 20)
          raise "col 10 should be in range" unless app.diagnostic_in_range_public?(diag, 5, 10)
          raise "col 15 should be in range" unless app.diagnostic_in_range_public?(diag, 5, 15)
          raise "col 19 should be in range" unless app.diagnostic_in_range_public?(diag, 5, 19)
        end
      end

      it "returns false when cursor is outside single-line diagnostic" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = Adamantine::Lsp::Diagnostic.new(5, 10, "error", end_line: 5, end_character: 20)
          raise "col 9 should be out of range" if app.diagnostic_in_range_public?(diag, 5, 9)
          raise "col 20 should be out of range (exclusive)" if app.diagnostic_in_range_public?(diag, 5, 20)
          raise "line 4 should be out of range" if app.diagnostic_in_range_public?(diag, 4, 15)
          raise "line 6 should be out of range" if app.diagnostic_in_range_public?(diag, 6, 15)
        end
      end

      it "handles multi-line diagnostic on start line" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = Adamantine::Lsp::Diagnostic.new(3, 5, "warning", end_line: 7, end_character: 10)
          raise "at start character should be in range" unless app.diagnostic_in_range_public?(diag, 3, 5)
          raise "after start character should be in range" unless app.diagnostic_in_range_public?(diag, 3, 20)
          raise "before start character should be out of range" if app.diagnostic_in_range_public?(diag, 3, 4)
        end
      end

      it "handles multi-line diagnostic on end line" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = Adamantine::Lsp::Diagnostic.new(3, 5, "warning", end_line: 7, end_character: 10)
          raise "col 0 on end line should be in range" unless app.diagnostic_in_range_public?(diag, 7, 0)
          raise "col 9 on end line should be in range" unless app.diagnostic_in_range_public?(diag, 7, 9)
          raise "col 10 on end line should be out of range" if app.diagnostic_in_range_public?(diag, 7, 10)
        end
      end

      it "handles multi-line diagnostic on middle line" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = Adamantine::Lsp::Diagnostic.new(3, 5, "info", end_line: 7, end_character: 10)
          raise "any column on middle line should be in range" unless app.diagnostic_in_range_public?(diag, 5, 0)
          raise "any column on middle line should be in range" unless app.diagnostic_in_range_public?(diag, 5, 100)
        end
      end
    end

    describe "severity_rank" do
      it "ranks severity 1 (error) as highest priority" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          raise "error should be rank 0" unless app.severity_rank_public(1) == 0
        end
      end

      it "ranks severity 2 (warning) as second priority" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          raise "warning should be rank 1" unless app.severity_rank_public(2) == 1
        end
      end

      it "ranks severity 3 (info) as third priority" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          raise "info should be rank 2" unless app.severity_rank_public(3) == 2
        end
      end

      it "ranks severity 4 (hint) as fourth priority" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          raise "hint should be rank 3" unless app.severity_rank_public(4) == 3
        end
      end

      it "ranks nil severity as lowest priority" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          raise "nil should be rank 4" unless app.severity_rank_public(nil) == 4
        end
      end

      it "maintains ordering: error < warning < info < hint < nil" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          ranks = [1, 2, 3, 4, nil].map { |s| app.severity_rank_public(s) }
          raise "should be strictly increasing" unless ranks == ranks.sort
          raise "should have no duplicates" unless ranks.size == ranks.uniq.size
        end
      end
    end

    describe "lsp_diagnostic_style" do
      it "returns base style when no diagnostics match cursor position" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          Adamantine::Theme.reset
          Adamantine::Theme.load("vscode-dark")
          base = Tui::Style.new(fg: Tui::Color.white)
          diag = Adamantine::Lsp::Diagnostic.new(5, 10, "error", end_line: 5, end_character: 20, severity: 1)
          result = app.lsp_diagnostic_style_public([diag], 0, 0, base)
          raise "should return base style" unless result == base
        end
      end

      it "selects highest severity diagnostic when multiple overlap" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          Adamantine::Theme.reset
          Adamantine::Theme.load("vscode-dark")
          base = Tui::Style.new
          warning = Adamantine::Lsp::Diagnostic.new(5, 0, "warn", end_line: 5, end_character: 30, severity: 2)
          error = Adamantine::Lsp::Diagnostic.new(5, 5, "err", end_line: 5, end_character: 25, severity: 1)
          result = app.lsp_diagnostic_style_public([warning, error], 5, 10, base)
          error_fg = Adamantine::Theme.color("lsp.error_fg")
          raise "should use error style fg" unless result.fg == error_fg
        end
      end
    end

    describe "connect_lsp_if_requested" do
      it "does not connect with empty command and no default LSP" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          raise "should not be connected with empty command" if app.lsp_connected?
        end
      end
    end

    describe "show_lsp_status" do
      it "reports a disconnected client as disconnected" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          client = Adamantine::Lsp::Client.new("", tmp)
          app.set_lsp_client(client)

          app.show_lsp_status_public
          raise "disconnected client must not be reported as connected" unless app.lsp_warnings.any? { |entry| entry.includes?("not connected") }
        end
      end
    end

    describe "sync_lsp_change" do
      it "does not materialize the document while the client is disconnected" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          app.set_lsp_client(Adamantine::Lsp::Client.new("", tmp))
          editor = TextMaterializationSpy.new("disconnected-spy")
          editor.text = "complete document"
          buffer = Adamantine::OpenBuffer.new(tmp / "sample.cr", editor, "crystal", "file:///sample.cr")

          app.sync_lsp_change_public(buffer, Tui::TextEditor::TextChange.full)

          raise "disconnected sync must not materialize editor text" unless editor.text_reads == 0
        end
      end

      it "sends a ranged change without materializing the document" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          client = LspSyncCaptureClient.new(true)
          app.set_lsp_client(client)
          editor = TextMaterializationSpy.new("incremental-spy")
          editor.text = "a🙂b"
          buffer = Adamantine::OpenBuffer.new(tmp / "sample.cr", editor, "crystal", "file:///sample.cr")
          buffer.version = 7
          change = Tui::TextEditor::TextChange.new(
            Tui::TextEditor::TextPosition.new(0, 2, 3),
            Tui::TextEditor::TextPosition.new(0, 2, 3),
            "🚀"
          )

          app.sync_lsp_change_public(buffer, change)

          raise "incremental sync must not materialize editor text" unless editor.text_reads == 0
          raise "full change should not be sent" unless client.full_changes.empty?
          raise "one ranged change expected" unless client.ranged_changes.size == 1
          uri, version, range, text = client.ranged_changes.first
          raise "wrong ranged metadata" unless uri == buffer.uri && version == 7 && text == "🚀"
          raise "wrong ranged coordinates" unless range == Adamantine::Lsp::Range.new(0, 3, 0, 3)
        end
      end

      it "materializes a full fallback when incremental sync is unavailable" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          client = LspSyncCaptureClient.new(false)
          app.set_lsp_client(client)
          editor = TextMaterializationSpy.new("full-spy")
          editor.text = "complete document"
          buffer = Adamantine::OpenBuffer.new(tmp / "sample.cr", editor, "crystal", "file:///sample.cr")
          change = Tui::TextEditor::TextChange.new(
            Tui::TextEditor::TextPosition.new(0, 0, 0),
            Tui::TextEditor::TextPosition.new(0, 0, 0),
            "x"
          )

          app.sync_lsp_change_public(buffer, change)

          raise "fallback should materialize once" unless editor.text_reads == 1
          raise "ranged change should not be sent" unless client.ranged_changes.empty?
          raise "wrong full fallback" unless client.full_changes == [{buffer.uri, buffer.version, "complete document"}]
        end
      end

      it "materializes a full fallback for a coarse editor change" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          client = LspSyncCaptureClient.new(true)
          app.set_lsp_client(client)
          editor = TextMaterializationSpy.new("coarse-spy")
          editor.text = "replacement result"
          buffer = Adamantine::OpenBuffer.new(tmp / "sample.cr", editor, "crystal", "file:///sample.cr")

          app.sync_lsp_change_public(buffer, Tui::TextEditor::TextChange.full)

          raise "coarse fallback should materialize once" unless editor.text_reads == 1
          raise "ranged change should not be sent" unless client.ranged_changes.empty?
          raise "wrong coarse fallback" unless client.full_changes == [{buffer.uri, buffer.version, "replacement result"}]
        end
      end
    end
  end
end
