require "spec"
require "../src/adamantine/debug_variable_tree"

private def bounded_scope(name : String, reference : Int32, count : Int32? = nil) : Adamantine::Debugging::DebugScopeInput
  Adamantine::Debugging::DebugScopeInput.new(name: name, variables_reference: reference, named_variables: count)
end

private def bounded_variable(name : String, value : String, reference : Int32 = 0,
                             type : String? = "Int32", count : Int32? = nil) : Adamantine::Debugging::DebugVariableInput
  Adamantine::Debugging::DebugVariableInput.new(
    name: name,
    value: value,
    type: type,
    variables_reference: reference,
    named_variables: count
  )
end

describe Adamantine::Debugging::DebugVariableTree do
  it "loads children only by an explicit bounded page and makes later pages explicit" do
    tree = Adamantine::Debugging::DebugVariableTree.new(page_size: 3, max_nodes: 32)
    root = tree.replace_scopes([bounded_scope("Locals", 700, 7)]).roots.first
    raise "scope roots must remain unloaded until explicitly expanded" unless root.load_state == Adamantine::Debugging::DebugVariableLoadState::Unloaded

    first = tree.begin_children(root.id).not_nil!
    raise "a page must be bounded" unless first.count == 3
    entries = (0...3).map { |index| bounded_variable("item#{index}", index.to_s, 0) }
    raise "current page should apply" unless tree.complete(first, entries, total_count: 7)
    first_page = tree.snapshot
    children = first_page.nodes.select { |node| node.parent_id == root.id }
    raise "only the requested page should be retained" unless children.size == 3
    raise "unfinished page must be marked partial" unless first_page.node(root.id).not_nil!.load_state == Adamantine::Debugging::DebugVariableLoadState::Partial

    second = tree.load_more(root.id).not_nil!
    raise "next page must begin after retained children" unless second.start == 3 && second.count == 3
    raise "next page should apply" unless tree.complete(second, (3...6).map { |index| bounded_variable("item#{index}", index.to_s) }, total_count: 7)
    third = tree.load_more(root.id).not_nil!
    raise "final page is bounded to remaining entries" unless third.start == 6 && third.count == 1
    raise "final page should apply" unless tree.complete(third, [bounded_variable("item6", "6")], total_count: 7)
    raise "known count should complete the node" unless tree.snapshot.node(root.id).not_nil!.load_state == Adamantine::Debugging::DebugVariableLoadState::Loaded
  end

  it "retains no more than the node and display-byte budgets for hostile pages" do
    tree = Adamantine::Debugging::DebugVariableTree.new(
      page_size: 100,
      max_nodes: 8,
      max_display_bytes: 128,
      max_value_bytes: 64
    )
    root = tree.replace_scopes([bounded_scope("Locals", 800, 100)]).roots.first
    request = tree.begin_children(root.id).not_nil!
    hostile = (0...100).map { |index| bounded_variable("v#{index}", "x" * 4096) }
    raise "oversubscribed response should be recorded as a bounded partial page" unless tree.complete(request, hostile, total_count: 100)

    snapshot = tree.snapshot
    raise "retained nodes exceeded their cap" if snapshot.retained_node_count > 8
    raise "display data exceeded its logical byte cap" if snapshot.retained_display_bytes > 128
    raise "the hostile page must expose partialness" unless snapshot.partial?
    raise "a retained variable value must itself stay small" if snapshot.nodes.any? { |node| node.value.bytesize > 64 }
  end

  it "rejects stale pages and prevents child references from cycling to an ancestor" do
    tree = Adamantine::Debugging::DebugVariableTree.new(page_size: 10, max_depth: 4)
    root = tree.replace_scopes([bounded_scope("Locals", 900, 1)]).roots.first
    request = tree.begin_children(root.id).not_nil!
    child_input = bounded_variable("self", "Record", 900, "Record", 1)
    raise "cycle page should be accepted as bounded structural data" unless tree.complete(request, [child_input], total_count: 1)
    child = tree.snapshot.nodes.find { |node| node.parent_id == root.id }.not_nil!
    raise "ancestor reference cycle must not offer further expansion" if child.expandable?
    raise "cycle must be explicit" unless child.load_state == Adamantine::Debugging::DebugVariableLoadState::Cycle

    stale = tree.begin_children(child.id)
    raise "cycle node cannot be expanded" unless stale.nil?
    pending_tree = Adamantine::Debugging::DebugVariableTree.new
    pending_root = pending_tree.replace_scopes([bounded_scope("Locals", 901)]).roots.first
    pending = pending_tree.begin_children(pending_root.id).not_nil!
    pending_tree.retire("new stop")
    raise "a response from a retired variable generation must be rejected" if pending_tree.complete(pending, [bounded_variable("old", "1")])
    raise "retired references must be cleared" unless pending_tree.snapshot.nodes.empty?
  end

  it "does not claim completeness when the adapter omits a total child count" do
    tree = Adamantine::Debugging::DebugVariableTree.new(page_size: 2)
    root = tree.replace_scopes([bounded_scope("Locals", 902)]).roots.first
    request = tree.begin_children(root.id).not_nil!
    tree.complete(request, [bounded_variable("a", "1"), bounded_variable("b", "2")])
    view = tree.snapshot.node(root.id).not_nil!
    raise "missing total counts must remain explicitly partial" unless view.load_state == Adamantine::Debugging::DebugVariableLoadState::Partial
    raise "partial reason must name the missing count" unless view.reason.try(&.includes?("count"))
    continuation = tree.load_more(root.id)
    raise "an exact-sized unknown-total page must retain an explicit continuation" unless continuation
    raise "the unknown-total continuation must begin after the full page" unless continuation.not_nil!.start == 2
  end

  it "budgets both named and indexed children when planning a page" do
    tree = Adamantine::Debugging::DebugVariableTree.new(page_size: 10)
    scope = Adamantine::Debugging::DebugScopeInput.new(
      name: "Locals",
      variables_reference: 903,
      named_variables: 1,
      indexed_variables: 2
    )
    root = tree.replace_scopes([scope]).roots.first
    page = tree.begin_children(root.id).not_nil!
    raise "named and indexed child counts must be combined" unless page.count == 3
  end

  it "surfaces scope-list truncation without disabling retained scopes" do
    tree = Adamantine::Debugging::DebugVariableTree.new(max_nodes: 1)
    snapshot = tree.replace_scopes([
      bounded_scope("Locals", 907, 1),
      bounded_scope("Arguments", 908, 1),
    ])

    raise "retained scope should remain available" unless snapshot.roots.size == 1
    raise "omitted scopes must make snapshot partial" unless snapshot.partial?
    raise "scope-list clipping must be explicit" unless snapshot.truncated?
    raise "truncation reason must identify the clipped scope list" unless snapshot.truncation_reason.try(&.includes?("scope list"))
    raise "a retained root must remain explicitly expandable" unless snapshot.roots.first.expandable?
  end

  it "keeps invalid UTF-8 fallback text within the configured value-byte cap" do
    tree = Adamantine::Debugging::DebugVariableTree.new(max_value_bytes: 1)
    root = tree.replace_scopes([bounded_scope("Locals", 904, 1)]).roots.first
    page = tree.begin_children(root.id).not_nil!
    invalid = String.new(Bytes[0xff])
    tree.complete(page, [bounded_variable("bad", invalid)], total_count: 1)
    value = tree.snapshot.nodes.find { |node| node.parent_id == root.id }.not_nil!.value
    raise "invalid UTF-8 fallback exceeded max_value_bytes" if value.bytesize > 1
  end

  it "tracks dropped source characters independently from sanitized display byte length" do
    clipped_tree = Adamantine::Debugging::DebugVariableTree.new(max_value_bytes: 3)
    clipped_root = clipped_tree.replace_scopes([bounded_scope("L", 910, 1)]).roots.first
    clipped_page = clipped_tree.begin_children(clipped_root.id).not_nil!
    clipped_tree.complete(clipped_page, [bounded_variable("v", "\eA", type: nil)], total_count: 1)
    clipped_node = clipped_tree.snapshot.nodes.find { |node| node.parent_id == clipped_root.id }.not_nil!
    raise "terminal-control replacement and clipping output must remain unchanged" unless clipped_node.value == "␛"
    raise "a source character dropped after an expanding replacement must be reported" unless clipped_node.reason.try(&.includes?("clipped"))

    complete_tree = Adamantine::Debugging::DebugVariableTree.new(max_value_bytes: 3)
    complete_root = complete_tree.replace_scopes([bounded_scope("L", 911, 1)]).roots.first
    complete_page = complete_tree.begin_children(complete_root.id).not_nil!
    complete_tree.complete(complete_page, [bounded_variable("v", "\e", type: nil)], total_count: 1)
    complete_node = complete_tree.snapshot.nodes.find { |node| node.parent_id == complete_root.id }.not_nil!
    raise "a fully consumed terminal replacement must remain unchanged" unless complete_node.value == "␛"
    raise "fully consumed expanding replacement must not be marked clipped" if complete_node.reason.try(&.includes?("clipped"))
  end

  it "does not retry the same empty unknown-count page forever" do
    tree = Adamantine::Debugging::DebugVariableTree.new(page_size: 2)
    root = tree.replace_scopes([bounded_scope("Locals", 905)]).roots.first
    page = tree.begin_children(root.id).not_nil!
    tree.complete(page, [] of Adamantine::Debugging::DebugVariableInput)
    view = tree.snapshot.node(root.id).not_nil!
    raise "empty no-progress page must have an explicit terminal state" unless view.load_state.in?(
                                                                                 Adamantine::Debugging::DebugVariableLoadState::Failed,
                                                                                 Adamantine::Debugging::DebugVariableLoadState::Limit
                                                                               )
    raise "empty no-progress page must explain the unavailable continuation" unless view.reason.try(&.includes?("progress"))
    raise "empty page must not repeat start=0" unless tree.load_more(root.id).nil?
  end

  it "preserves the display Limit state when an entry cannot be retained" do
    tree = Adamantine::Debugging::DebugVariableTree.new(
      page_size: 4,
      max_display_bytes: 64,
      max_value_bytes: 64
    )
    root = tree.replace_scopes([bounded_scope("Locals", 906, 4)]).roots.first
    page = tree.begin_children(root.id).not_nil!
    oversized = bounded_variable("child", "x" * 64)
    tree.complete(page, [oversized], total_count: 4)
    view = tree.snapshot.node(root.id).not_nil!
    raise "failure to retain must remain a terminal Limit" unless view.load_state == Adamantine::Debugging::DebugVariableLoadState::Limit
    raise "Limit reason must identify display-byte exhaustion" unless view.reason.try(&.includes?("display byte"))
    raise "terminal Limit must not offer another page" unless tree.load_more(root.id).nil?
  end
end
