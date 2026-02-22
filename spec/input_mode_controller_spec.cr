require "spec"

require "../src/editor/input_mode_controller"

describe CrystalEditor::InputModeController::ModeStack do
  it "moves repeated mode to the top instead of duplicating" do
    stack = CrystalEditor::InputModeController::ModeStack.new
    stack.enter(CrystalEditor::InputModeController::InputMode::Normal)
    stack.enter(CrystalEditor::InputModeController::InputMode::ContextMenu)
    stack.enter(CrystalEditor::InputModeController::InputMode::Normal)

    raise "expected deduplicated top move" unless stack.snapshot == [CrystalEditor::InputModeController::InputMode::ContextMenu, CrystalEditor::InputModeController::InputMode::Normal]
  end

  it "supports restoring historical mode stack state" do
    stack = CrystalEditor::InputModeController::ModeStack.new
    stack.enter(CrystalEditor::InputModeController::InputMode::Settings)
    stack.enter(CrystalEditor::InputModeController::InputMode::ContextMenu)
    checkpoint = stack.snapshot
    stack.enter(CrystalEditor::InputModeController::InputMode::LspPopup)
    stack.restore(checkpoint)

    raise "restored snapshot should match checkpoint" unless stack.snapshot == checkpoint
  end

  it "keeps snapshots isolated from later mutations" do
    stack = CrystalEditor::InputModeController::ModeStack.new
    stack.enter(CrystalEditor::InputModeController::InputMode::Settings)
    snapshot = stack.snapshot
    snapshot << CrystalEditor::InputModeController::InputMode::ContextMenu

    raise "snapshot mutation should not leak into controller stack" unless stack.snapshot == [CrystalEditor::InputModeController::InputMode::Settings]
  end

  it "restores normal stack state from nil" do
    stack = CrystalEditor::InputModeController::ModeStack.new
    stack.enter(CrystalEditor::InputModeController::InputMode::Settings)
    stack.restore(nil)

    raise "nil restore should clear stack" unless stack.snapshot.empty?
    raise "active mode should be normal" unless stack.active == CrystalEditor::InputModeController::InputMode::Normal
  end
end
