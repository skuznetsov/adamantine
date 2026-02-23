require "spec"
require "file_utils"
require "crystal_tui"

require "../src/editor/app"

class LspControllerTestApp < CrystalEditor::App
  def diagnostic_in_range_public?(diagnostic : CrystalEditor::Lsp::Diagnostic, line : Int32, col : Int32) : Bool
    diagnostic_in_range?(diagnostic, line, col)
  end

  def severity_rank_public(severity : Int32?) : Int32
    severity_rank(severity)
  end

  def lsp_diagnostic_style_public(diagnostics : Array(CrystalEditor::Lsp::Diagnostic), line : Int32, col : Int32, base_style : Tui::Style) : Tui::Style
    lsp_diagnostic_style(diagnostics, line, col, base_style)
  end

  def lsp_connected? : Bool
    !@lsp.nil?
  end
end

def with_temp_workspace(prefix : String = "editor-lsp-ctrl-spec", &)
  tmp_dir = Path.new(Dir.tempdir, "#{prefix}-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(tmp_dir)

  yield tmp_dir
ensure
  FileUtils.rm_rf(tmp_dir) if tmp_dir
end

describe CrystalEditor::App do
  describe "LspController" do
    describe "diagnostic_in_range?" do
      it "returns true when cursor is within single-line diagnostic" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = CrystalEditor::Lsp::Diagnostic.new(5, 10, "error", end_line: 5, end_character: 20)
          raise "col 10 should be in range" unless app.diagnostic_in_range_public?(diag, 5, 10)
          raise "col 15 should be in range" unless app.diagnostic_in_range_public?(diag, 5, 15)
          raise "col 19 should be in range" unless app.diagnostic_in_range_public?(diag, 5, 19)
        end
      end

      it "returns false when cursor is outside single-line diagnostic" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = CrystalEditor::Lsp::Diagnostic.new(5, 10, "error", end_line: 5, end_character: 20)
          raise "col 9 should be out of range" if app.diagnostic_in_range_public?(diag, 5, 9)
          raise "col 20 should be out of range (exclusive)" if app.diagnostic_in_range_public?(diag, 5, 20)
          raise "line 4 should be out of range" if app.diagnostic_in_range_public?(diag, 4, 15)
          raise "line 6 should be out of range" if app.diagnostic_in_range_public?(diag, 6, 15)
        end
      end

      it "handles multi-line diagnostic on start line" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = CrystalEditor::Lsp::Diagnostic.new(3, 5, "warning", end_line: 7, end_character: 10)
          raise "at start character should be in range" unless app.diagnostic_in_range_public?(diag, 3, 5)
          raise "after start character should be in range" unless app.diagnostic_in_range_public?(diag, 3, 20)
          raise "before start character should be out of range" if app.diagnostic_in_range_public?(diag, 3, 4)
        end
      end

      it "handles multi-line diagnostic on end line" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = CrystalEditor::Lsp::Diagnostic.new(3, 5, "warning", end_line: 7, end_character: 10)
          raise "col 0 on end line should be in range" unless app.diagnostic_in_range_public?(diag, 7, 0)
          raise "col 9 on end line should be in range" unless app.diagnostic_in_range_public?(diag, 7, 9)
          raise "col 10 on end line should be out of range" if app.diagnostic_in_range_public?(diag, 7, 10)
        end
      end

      it "handles multi-line diagnostic on middle line" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          diag = CrystalEditor::Lsp::Diagnostic.new(3, 5, "info", end_line: 7, end_character: 10)
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
          CrystalEditor::Theme.reset
          CrystalEditor::Theme.load("vscode-dark")
          base = Tui::Style.new(fg: Tui::Color.white)
          diag = CrystalEditor::Lsp::Diagnostic.new(5, 10, "error", end_line: 5, end_character: 20, severity: 1)
          result = app.lsp_diagnostic_style_public([diag], 0, 0, base)
          raise "should return base style" unless result == base
        end
      end

      it "selects highest severity diagnostic when multiple overlap" do
        with_temp_workspace do |tmp|
          app = LspControllerTestApp.new(project_root: tmp, lsp_command: "")
          CrystalEditor::Theme.reset
          CrystalEditor::Theme.load("vscode-dark")
          base = Tui::Style.new
          warning = CrystalEditor::Lsp::Diagnostic.new(5, 0, "warn", end_line: 5, end_character: 30, severity: 2)
          error = CrystalEditor::Lsp::Diagnostic.new(5, 5, "err", end_line: 5, end_character: 25, severity: 1)
          result = app.lsp_diagnostic_style_public([warning, error], 5, 10, base)
          error_fg = CrystalEditor::Theme.color("lsp.error_fg")
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
  end
end
