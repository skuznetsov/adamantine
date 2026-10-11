require "spec"
require "../src/adamantine/app"

private def debug_projection_node(id : String, parent_id : String?, name : String,
                                  children : Array(String) = [] of String) : Adamantine::Debugging::DebugVariableNode
  Adamantine::Debugging::DebugVariableNode.new(
    id, parent_id, name, "", nil, children.empty? ? 0 : 1, nil, nil,
    parent_id ? 1 : 0, Adamantine::Debugging::DebugVariableLoadState::Loaded, children
  )
end

describe Adamantine::DebugVariableProjection do
  it "projects roots and expanded children by child IDs, not backing insertion order" do
    locals = debug_projection_node("root-locals", nil, "Locals", ["local-child"])
    globals = debug_projection_node("root-globals", nil, "Globals")
    child = debug_projection_node("local-child", "root-locals", "answer")
    snapshot = Adamantine::Debugging::DebugVariableSnapshot.new(
      [locals, globals, child], [locals, globals], 3, 16_i64
    )
    projection = Adamantine::DebugVariableProjection.new

    projection.rebuild(snapshot, Set(String).new)
    projection.rows.map(&.node_id).should eq(["root-locals", "root-globals"] of String?)

    projection.rebuild(snapshot, Set{"root-locals"})
    projection.rows.map(&.node_id).should eq(["root-locals", "local-child", "root-globals"] of String?)
  end

  it "restores a selected root by node ID when asynchronous children shift its row" do
    locals = debug_projection_node("root-locals", nil, "Locals", ["local-child"])
    globals = debug_projection_node("root-globals", nil, "Globals")
    projection = Adamantine::DebugVariableProjection.new
    selection = Adamantine::DebugVariableSelection.new

    before_reply = Adamantine::Debugging::DebugVariableSnapshot.new(
      [locals, globals], [locals, globals], 2, 8_i64
    )
    projection.rebuild(before_reply, Set(String).new)
    selection.select(projection, projection.row_index("root-globals").not_nil!)

    child = debug_projection_node("local-child", "root-locals", "answer")
    after_reply = Adamantine::Debugging::DebugVariableSnapshot.new(
      [locals, globals, child], [locals, globals], 3, 16_i64
    )
    projection.rebuild(after_reply, Set{"root-locals"})

    selection.restore_index(projection).should eq(2)
    projection.row(2).try(&.node_id).should eq("root-globals")
  end

  it "retains hidden descendant expansion IDs while their nodes remain authoritative" do
    locals = debug_projection_node("root-locals", nil, "Locals", ["local-child"])
    globals = debug_projection_node("root-globals", nil, "Globals")
    child = debug_projection_node("local-child", "root-locals", "Nested", ["leaf"])
    leaf = debug_projection_node("leaf", "local-child", "answer")
    snapshot = Adamantine::Debugging::DebugVariableSnapshot.new(
      [locals, globals, child, leaf], [locals, globals], 4, 20_i64
    )
    expanded = Set{"root-locals", "local-child"}
    projection = Adamantine::DebugVariableProjection.new

    projection.rebuild(snapshot, expanded)
    projection.rows.map(&.node_id).should eq(["root-locals", "local-child", "leaf", "root-globals"] of String?)

    # Collapse the root. A later unrelated generation still contains the
    # already-loaded hidden descendant, so its expansion choice must survive.
    projection.rebuild(snapshot, Set(String).new)
    projection.retain_existing_expansions(snapshot, expanded)
    expanded.should eq(Set{"root-locals", "local-child"})
    projection.rebuild(snapshot, expanded)
    projection.rows.map(&.node_id).should eq(["root-locals", "local-child", "leaf", "root-globals"] of String?)
  end
end
