require "spec"

require "../src/adamantine/input_mode_controller"

describe Adamantine::InputModeController::ModeStack do
  it "moves repeated mode to the top instead of duplicating" do
    stack = Adamantine::InputModeController::ModeStack.new
    stack.enter(Adamantine::InputModeController::InputMode::Normal)
    stack.enter(Adamantine::InputModeController::InputMode::ContextMenu)
    stack.enter(Adamantine::InputModeController::InputMode::Normal)

    raise "expected deduplicated top move" unless stack.snapshot == [Adamantine::InputModeController::InputMode::ContextMenu, Adamantine::InputModeController::InputMode::Normal]
  end

  it "supports restoring historical mode stack state" do
    stack = Adamantine::InputModeController::ModeStack.new
    stack.enter(Adamantine::InputModeController::InputMode::Settings)
    stack.enter(Adamantine::InputModeController::InputMode::ContextMenu)
    checkpoint = stack.snapshot
    stack.enter(Adamantine::InputModeController::InputMode::LspPopup)
    stack.restore(checkpoint)

    raise "restored snapshot should match checkpoint" unless stack.snapshot == checkpoint
  end

  it "keeps snapshots isolated from later mutations" do
    stack = Adamantine::InputModeController::ModeStack.new
    stack.enter(Adamantine::InputModeController::InputMode::Settings)
    snapshot = stack.snapshot
    snapshot << Adamantine::InputModeController::InputMode::ContextMenu

    raise "snapshot mutation should not leak into controller stack" unless stack.snapshot == [Adamantine::InputModeController::InputMode::Settings]
  end

  it "restores normal stack state from nil" do
    stack = Adamantine::InputModeController::ModeStack.new
    stack.enter(Adamantine::InputModeController::InputMode::Settings)
    stack.restore(nil)

    raise "nil restore should clear stack" unless stack.snapshot.empty?
    raise "active mode should be normal" unless stack.active == Adamantine::InputModeController::InputMode::Normal
  end
end
