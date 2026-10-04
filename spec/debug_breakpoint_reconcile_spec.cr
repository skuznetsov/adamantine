require "spec"

require "../src/adamantine/debug_breakpoint_store"
require "../src/adamantine/debug_source_store"

describe Adamantine::Debugging::DebugBreakpointStore do
  it "rejects foreign source references while allowing references from its own session" do
    store = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    foreign = Adamantine::Debugging::DebugSourceKey.session("session-b", 7)
    rejected = false
    begin
      store.toggle(foreign, 3)
    rescue ArgumentError
      rejected = true
    end
    raise "foreign source reference must be rejected before becoming desired state" unless rejected && store.breakpoints(foreign).empty?
    raise "foreign source reference must not produce an adapter batch" unless store.begin_batch(foreign).nil?

    owned = Adamantine::Debugging::DebugSourceKey.session("session-a", 7)
    store.toggle(owned, 4)
    batch = store.begin_batch(owned).not_nil!
    raise "store-owned source reference must remain batchable" unless batch.source_key == owned && batch.session_id == "session-a"
  end

  it "serializes one full set per source and coalesces mutations behind the in-flight generation" do
    source = Adamantine::Debugging::DebugSourceKey.local("/tmp/main.cr")
    store = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    first = store.toggle(source, 4)
    batch = store.begin_batch(source).not_nil!
    raise "requested editor line must be zero-based" unless batch.breakpoints.first.requested_line == 4
    changed = store.toggle(source, 8)
    raise "a second full set must wait behind the current one" unless store.begin_batch(source).nil?
    store.complete(batch, [Adamantine::Debugging::DebugBreakpointResolution.new(first.id, "adapter-1", 5)])
    next_batch = store.begin_batch(source).not_nil!
    raise "newest desired generation must be sent next" unless next_batch.breakpoints.map(&.requested_line) == [4, 8]
    raise "edited breakpoint was not coalesced" unless next_batch.generation > batch.generation && changed.requested_line == 8
  end

  it "rejects foreign, stale, and old-session replies/events and exposes moved or rejected states" do
    source = Adamantine::Debugging::DebugSourceKey.local("/tmp/main.cr")
    left = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    right = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    bp = left.toggle(source, 2)
    batch = left.begin_batch(source).not_nil!
    raise "same brand/generation from another store must not consume a batch" unless !right.complete(batch, [] of Adamantine::Debugging::DebugBreakpointResolution).accepted?
    left.complete(batch, [Adamantine::Debugging::DebugBreakpointResolution.new(bp.id, "adapter-2", 9, reason: "adapter moved it")])
    view = left.breakpoints(source).first
    raise "moved breakpoint state missing" unless view.status == Adamantine::Debugging::BreakpointStatus::Moved && view.resolved_line == 9
    raise "requested line must be preserved" unless view.requested_line == 2 && view.reason.not_nil!.includes?("moved")
    live_event = left.reconcile_event("session-a", source, batch.generation, "adapter-2", 10)
    raise "positive current-generation event should reconcile" unless live_event.accepted? && left.breakpoints(source).first.resolved_line == 10
    raise "unknown adapter event must be ignored" unless !left.reconcile_event("session-a", source, batch.generation, "foreign-id", 20).accepted?

    left.new_session("session-b")
    raise "old-session adapter ID must not cross sessions" unless !left.reconcile_event("session-a", source, batch.generation, "adapter-2", 30).accepted?
    fresh = left.begin_batch(source).not_nil!
    left.complete(fresh, [] of Adamantine::Debugging::DebugBreakpointResolution, success: false, reason: "not verified")
    raise "failed response should be visible as rejected" unless left.breakpoints(source).first.status == Adamantine::Debugging::BreakpointStatus::Rejected
  end

  it "blocks implicit rebinding after edits and sends an empty full set to remove all enabled breakpoints" do
    source = Adamantine::Debugging::DebugSourceKey.local("/tmp/main.cr")
    store = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    breakpoint = store.toggle(source, 5)
    original = store.begin_batch(source).not_nil!
    store.complete(original, [Adamantine::Debugging::DebugBreakpointResolution.new(breakpoint.id, "adapter-5", 5)])

    raise "edit barrier should be recorded" unless store.mark_source_edited(source, "buffer changed")
    raise "edited source must not auto-resubmit shifted lines" unless store.begin_batch(source).nil?
    raise "old verified binding must be marked outdated" unless store.breakpoints(source).first.status == Adamantine::Debugging::BreakpointStatus::Outdated
    store.rebind_source(source)
    rebound = store.begin_batch(source).not_nil!
    raise "rebind must be explicit and preserve requested line" unless rebound.breakpoints.first.requested_line == 5
    store.complete(rebound, [Adamantine::Debugging::DebugBreakpointResolution.new(breakpoint.id, "adapter-6", 6)])
    store.remove(source, breakpoint.id)
    removal = store.begin_batch(source).not_nil!
    raise "an empty enabled set must still be sent" unless removal.breakpoints.empty?
    store.complete(removal, [] of Adamantine::Debugging::DebugBreakpointResolution)
    raise "removed ID must not be accepted as a live event" unless !store.reconcile_event("session-a", source, removal.generation, "adapter-6", 5).accepted?
  end

  it "preserves outdated reasons across toggle, enable, and removal after an edit" do
    source = Adamantine::Debugging::DebugSourceKey.local("/tmp/edited-state.cr")
    store = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    original = store.toggle(source, 5)
    initial = store.begin_batch(source).not_nil!
    store.complete(initial, [Adamantine::Debugging::DebugBreakpointResolution.new(original.id, "adapter-old", 5)])
    store.mark_source_edited(source, "buffer changed")

    added = store.toggle(source, 8)
    views = store.breakpoints(source)
    raise "enabled entries must remain outdated after a toggle" unless views.all? { |entry| entry.status == Adamantine::Debugging::BreakpointStatus::Outdated && entry.reason == "buffer changed" }
    raise "edited source must not become batchable after a toggle" unless store.begin_batch(source).nil?

    raise "disable should be accepted" unless store.set_enabled(source, original.id, false)
    disabled = store.breakpoints(source).find { |entry| entry.id == original.id }.not_nil!
    still_outdated = store.breakpoints(source).find { |entry| entry.id == added.id }.not_nil!
    raise "disabled entry should stay disabled without an outdated reason" unless disabled.status == Adamantine::Debugging::BreakpointStatus::Disabled && disabled.reason.nil?
    raise "remaining enabled entry lost its outdated status" unless still_outdated.status == Adamantine::Debugging::BreakpointStatus::Outdated && still_outdated.reason == "buffer changed"

    raise "re-enable should be accepted" unless store.set_enabled(source, original.id, true)
    reenabled = store.breakpoints(source).find { |entry| entry.id == original.id }.not_nil!
    raise "re-enabled entry must remain outdated with its edit reason" unless reenabled.status == Adamantine::Debugging::BreakpointStatus::Outdated && reenabled.reason == "buffer changed"

    raise "removal should be accepted" unless store.remove(source, added.id)
    remaining = store.breakpoints(source).find { |entry| entry.id == original.id }.not_nil!
    raise "removal must not erase the remaining outdated state" unless remaining.status == Adamantine::Debugging::BreakpointStatus::Outdated && remaining.reason == "buffer changed"
    raise "edited source must remain unbatchable after all mutations" unless store.begin_batch(source).nil?
  end

  it "distinguishes disabled breakpoints and rejects stale completion after a generation change" do
    source = Adamantine::Debugging::DebugSourceKey.local("/tmp/main.cr")
    store = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    bp = store.toggle(source, 7)
    batch = store.begin_batch(source).not_nil!
    store.set_enabled(source, bp.id, false)
    stale = store.complete(batch, [Adamantine::Debugging::DebugBreakpointResolution.new(bp.id, "old-id", 7)])
    raise "stale generation must not certify current desired state" unless !stale.applied?
    next_batch = store.begin_batch(source).not_nil!
    raise "disabled breakpoints must not be sent" unless next_batch.breakpoints.empty?
    store.complete(next_batch, [] of Adamantine::Debugging::DebugBreakpointResolution)
    raise "disabled state should remain visible" unless store.breakpoints(source).first.status == Adamantine::Debugging::BreakpointStatus::Disabled
    raise "disabled state must not retain a stale rejection reason" unless store.breakpoints(source).first.reason.nil?
  end

  it "sends an empty replacement after an in-flight nonempty batch becomes empty" do
    source = Adamantine::Debugging::DebugSourceKey.local("/tmp/main.cr")
    store = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    bp = store.toggle(source, 12)
    initial = store.begin_batch(source).not_nil!
    store.complete(initial, [Adamantine::Debugging::DebugBreakpointResolution.new(bp.id, "adapter-12", 12)])

    store.rebind_source(source)
    in_flight = store.begin_batch(source).not_nil!
    raise "control batch should contain current desired breakpoint" unless in_flight.breakpoints.map(&.id) == [bp.id]
    store.remove(source, bp.id)
    stale = store.complete(in_flight, [Adamantine::Debugging::DebugBreakpointResolution.new(bp.id, "old-adapter-12", 12)])
    raise "old response must not apply after desired set becomes empty" if stale.applied?

    removal = store.begin_batch(source).not_nil!
    raise "coalesced latest generation must be an empty full set" unless removal.breakpoints.empty? && removal.generation > in_flight.generation
    completion = store.complete(removal, [] of Adamantine::Debugging::DebugBreakpointResolution)
    raise "empty removal response should apply" unless completion.applied?
    raise "retired adapter ID must not regain current event authority" unless !store.reconcile_event("session-a", source, removal.generation, "old-adapter-12", 12).accepted?
  end

  it "drops adapter-reference keys when a new session starts" do
    old_source = Adamantine::Debugging::DebugSourceKey.session("session-a", 9)
    store = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    breakpoint = store.toggle(old_source, 3)
    batch = store.begin_batch(old_source).not_nil!
    store.complete(batch, [Adamantine::Debugging::DebugBreakpointResolution.new(breakpoint.id, "remote-1", 3)])
    store.new_session("session-b")
    raise "session-reference breakpoint must not survive session reset" unless store.breakpoints(old_source).empty? && store.begin_batch(old_source).nil?
  end

  it "does not certify a reply that completes after a source-edit barrier" do
    source = Adamantine::Debugging::DebugSourceKey.local("/tmp/edited.cr")
    store = Adamantine::Debugging::DebugBreakpointStore.new("session-a")
    first = store.toggle(source, 2)
    initial = store.begin_batch(source).not_nil!
    store.complete(initial, [Adamantine::Debugging::DebugBreakpointResolution.new(first.id, "old-id", 2)])
    second = store.toggle(source, 6)
    pending = store.begin_batch(source).not_nil!
    store.mark_source_edited(source, "buffer changed during request")
    stale = store.complete(pending, [
      Adamantine::Debugging::DebugBreakpointResolution.new(first.id, "old-id", 2),
      Adamantine::Debugging::DebugBreakpointResolution.new(second.id, "new-id", 6),
    ])
    raise "edit-crossing response must not apply" unless !stale.applied?
    raise "edit barrier must continue suppressing submission" unless store.begin_batch(source).nil?
    store.rebind_source(source)
    fresh = store.begin_batch(source).not_nil!
    raise "only explicit rebind should submit newest desired set" unless fresh.breakpoints.size == 2 && fresh.generation > pending.generation
  end
end
