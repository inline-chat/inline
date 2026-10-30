import CoreGraphics
import Foundation
@testable import ChatListCore
import Testing

/// Mechanisms matched to Telegram iOS's ListView: curves, keyboard timing,
/// scroll positions and far jumps, row transitions, visibility, scroll events,
/// sticky header idling, reordering, and staged preparation.
@MainActor
struct ChatListTelegramParityTests {
  private typealias Session = ChatListSession<Int, String>
  private typealias Snapshot = ChatListSnapshot<Int, String>
  private let viewport = TimelineViewport(width: 600, height: 500, topInset: 40, bottomInset: 60)

  private func snapshot(_ ids: [Int], height: CGFloat = 40, decorations: [ChatListDecoration<Int>] = []) -> Snapshot {
    .init(
      context: .init(width: 600),
      items: ids.map { .init(id: $0, revision: 0, content: "\($0)", height: height) },
      decorations: decorations
    )
  }

  private func viewportY(_ session: Session, _ id: Int) -> CGFloat? {
    session.timeline.layout.viewportFrame(for: id)?.minY
  }

  // MARK: Motion

  @Test func `system spring matches the iOS 26 keyboard curve`() {
    var spring = TimelineSpring(0)
    spring.set(1, motion: .system)
    spring.advance(0.3832)
    let omega = sqrt(555.027)
    let expected = 1 - (1 + omega * 0.3832) * exp(-omega * 0.3832)
    #expect(abs(spring.value - expected) < 0.002)
    #expect(spring.value > 0.99)
  }

  @Test func `spring stepping is independent of frame cadence`() {
    var single = TimelineSpring(0)
    single.set(100, motion: .spring(stiffness: 300, damping: 12))
    single.advance(0.25)
    var stepped = TimelineSpring(0)
    stepped.set(100, motion: .spring(stiffness: 300, damping: 12))
    for _ in 0 ..< 30 { stepped.advance(0.25 / 30) }
    #expect(abs(single.value - stepped.value) < 0.01)
  }

  @Test func `underdamped springs overshoot and overdamped springs do not`() {
    var bouncy = TimelineSpring(0)
    bouncy.set(1, motion: .spring(stiffness: 400, damping: 8))
    var peak: CGFloat = 0
    for _ in 0 ..< 120 {
      bouncy.advance(1.0 / 120)
      peak = max(peak, bouncy.value)
    }
    #expect(peak > 1.05)
    var heavy = TimelineSpring(0)
    heavy.set(1, motion: .spring(stiffness: 1000, damping: 500, mass: 3))
    for _ in 0 ..< 240 {
      heavy.advance(1.0 / 120)
      #expect(heavy.value <= 1.0001)
    }
  }

  @Test func `timed motion follows its curve and lands exactly`() {
    var linear = TimelineSpring(0)
    linear.set(10, motion: .timed(duration: 0.4, curve: .linear))
    linear.advance(0.1)
    #expect(abs(linear.value - 2.5) < 0.001)
    linear.advance(1)
    #expect(linear.value == 10)
    #expect(linear.isSettled)
    #expect(abs(ChatListTimingCurve.easeInOut.solve(0.5) - 0.5) < 0.001)
    #expect(ChatListTimingCurve.easeIn.solve(0.25) < 0.25)
    #expect(ChatListTimingCurve.easeOut.solve(0.25) > 0.25)
    #expect(abs(ChatListTimingCurve.bezier(0.23, 1, 0.32, 1).solve(1) - 1) < 0.0001)
  }

  // MARK: Keyboard timing

  @Test func `a keyboard change starts at its own time, not the next frame`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    try session.apply(snapshot(Array(0 ..< 40)), animation: .none, at: 0)
    session.advance(to: 1.0)
    var keyboard = viewport
    keyboard.bottomInset = 360
    session.updateViewport(keyboard, displayScale: 1, animation: .motion(.system), at: 0.95)
    var spring = TimelineSpring(60)
    spring.set(360, motion: .system)
    spring.advance(0.05)
    #expect(abs(session.timeline.layout.viewport.bottomInset - spring.value) < 0.01)
    #expect(session.timeline.layout.viewport.bottomInset > 60)
  }

  @Test func `the latest message rides on the keyboard edge every frame`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    try session.apply(snapshot(Array(0 ..< 40)), animation: .none, at: 0)
    var keyboard = viewport
    keyboard.bottomInset = 360
    session.updateViewport(keyboard, displayScale: 1, animation: .motion(.system), at: 0)
    for frame in 1 ... 30 {
      session.advance(to: Double(frame) / 120)
      let layout = session.timeline.layout
      let bottom = layout.viewport.height - layout.viewport.bottomInset
      #expect(abs((layout.viewportFrame(for: 39)?.maxY ?? 0) - bottom) < 0.01)
    }
  }

  // MARK: Scroll positions and far jumps

  @Test func `scroll positions place the row like Telegram`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    try session.apply(snapshot(Array(0 ..< 60)), animation: .none, at: 0)
    session.scroll(to: .init(id: 20, position: .top(10)), animation: .none, at: 1)
    #expect(abs((viewportY(session, 20) ?? 0) - 50) < 0.01)
    session.scroll(to: .init(id: 20, position: .bottom(0)), animation: .none, at: 2)
    #expect(abs((session.timeline.layout.viewportFrame(for: 20)?.maxY ?? 0) - 440) < 0.01)
    session.scroll(to: .init(id: 20, position: .center), animation: .none, at: 3)
    #expect(abs((session.timeline.layout.viewportFrame(for: 20)?.midY ?? 0) - 240) < 0.01)
    let before = session.timeline.layout.originY
    session.scroll(to: .init(id: 21, position: .visible), animation: .none, at: 4)
    #expect(session.timeline.layout.originY == before)
    session.scroll(to: .init(id: 2, position: .visible), animation: .none, at: 5)
    #expect(abs((viewportY(session, 2) ?? 0) - 40) < 0.01)
  }

  @Test func `a far jump slides the old screen out with the new one touching it`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    var events: [ChatListScrollEvent] = []
    session.onScrollEvent = { events.append($0) }
    try session.apply(snapshot(Array(0 ..< 400)), animation: .none, at: 0)
    let oldY = try #require(viewportY(session, 395))
    session.scroll(to: .init(id: 0, position: .top(0)), animation: .animated, at: 1)
    let layout = session.timeline.layout
    // The old row has not moved, and the new screen ends where the old one starts.
    #expect(abs(try #require(viewportY(session, 395)) - oldY) < 0.01)
    #expect(layout.departingIDs.contains(395))
    #expect(session.timeline.isNavigating)
    let oldTop = layout.departingIDs.compactMap { layout.viewportFrame(for: $0)?.minY }.min() ?? 0
    let targetRows = layout.rows.filter { !$0.isSuppressed && !layout.departingIDs.contains($0.row.id) && $0.row.id <= 13 }
    let newBottom = (targetRows.map(\.frame.maxY).max() ?? 0) - layout.originY
    #expect(abs(newBottom - oldTop) < 0.01)
    // Rows past the target screen would overlap the old ones and stay hidden.
    #expect(layout.placement(for: 200)?.isSuppressed == true)
    session.advance(to: 1.1)
    let moved = try #require(viewportY(session, 395))
    #expect(moved > oldY)
    session.advance(to: 4)
    #expect(session.timeline.layout.departingIDs.isEmpty)
    #expect(viewportY(session, 0) == 40)
    #expect(session.timeline.layout.placement(for: 200)?.isSuppressed == false)
    #expect(events.contains(.navigationFinished))
    #expect(!session.timeline.isAnimating)
  }

  @Test func `a nearby jump just scrolls, and a user drag cancels a far jump`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    try session.apply(snapshot(Array(0 ..< 400)), animation: .none, at: 0)
    session.scroll(to: .init(id: 390, position: .top(0)), animation: .animated, at: 1)
    #expect(session.timeline.layout.departingIDs.isEmpty)
    session.advance(to: 4)
    session.scroll(to: .init(id: 0, position: .top(0)), animation: .animated, at: 5)
    #expect(!session.timeline.layout.departingIDs.isEmpty)
    let origin = session.timeline.layout.originY
    session.beginUserScroll(at: origin)
    #expect(session.timeline.layout.departingIDs.isEmpty)
    #expect(!session.timeline.isNavigating)
    #expect(session.timeline.layout.placement(for: 200)?.isSuppressed == false)
  }

  @Test func `a window replacement slides in from the requested direction`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    try session.apply(snapshot(Array(1_000 ..< 1_100)), animation: .none, at: 0)
    try session.apply(
      snapshot(Array(0 ..< 100)), animation: .animated, at: 1,
      scrollTo: .init(id: 50, position: .center, direction: .up)
    )
    // The removed rows stay on screen until the new window has slid in.
    let layout = session.timeline.layout
    #expect(layout.departingIDs.contains(1_099))
    #expect(layout.placement(for: 1_099)?.isExiting == true)
    #expect(layout.placement(for: 1_099)?.frame.height == 40)
    #expect(session.item(for: 1_099) != nil)
    #expect((layout.viewportFrame(for: 50)?.midY ?? 0) < 240)
    session.advance(to: 10)
    #expect(session.timeline.layout.placement(for: 1_099) == nil)
    #expect(abs((session.timeline.layout.viewportFrame(for: 50)?.midY ?? 0) - 240) < 0.01)
  }

  // MARK: Row transitions

  @Test func `insertion styles choose height and opacity like Telegram`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    try session.apply(snapshot(Array(0 ..< 5)), animation: .none, at: 0)
    try session.apply(
      snapshot(Array(0 ..< 8)), animation: .animated, at: 1,
      transitions: .init(insertions: [5: .fade, 6: .reveal, 7: .grow])
    )
    let layout = session.timeline.layout
    #expect(layout.placement(for: 5)?.frame.height == 40)
    #expect(layout.placement(for: 5)?.opacity == 0)
    #expect(layout.placement(for: 6)?.frame.height == 0)
    #expect(layout.placement(for: 6)?.opacity == 1)
    #expect(layout.placement(for: 7)?.frame.height == 0)
    #expect(layout.placement(for: 7)?.opacity == 0)
    #expect(layout.placement(for: 7)?.phase == .entering(progress: 0, insertion: .grow))
    session.advance(to: 2)
    #expect(session.timeline.layout.placement(for: 7)?.phase == .present)
  }

  @Test func `removal styles and the removal hook`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    var removed: [ChatListRemovalEvent<Int>] = []
    session.onWillRemove = { removed.append($0) }
    try session.apply(snapshot(Array(0 ..< 6)), animation: .none, at: 0)
    let frame = session.timeline.layout.viewportFrame(for: 4)
    try session.apply(
      snapshot([0, 1, 2]), animation: .animated, at: 1,
      transitions: .init(removals: [3: .none, 4: .collapseOpaque])
    )
    let layout = session.timeline.layout
    #expect(layout.placement(for: 3) == nil)
    #expect(layout.placement(for: 4)?.opacity == 1)
    #expect(layout.placement(for: 5)?.isExiting == true)
    if case .exiting(_, .collapseOpaque) = layout.placement(for: 4)?.phase {} else { Issue.record("phase") }
    #expect(Set(removed.map(\.id)) == [3, 4, 5])
    #expect(removed.first { $0.id == 4 }?.frame == frame)
    session.advance(to: 3)
    #expect(session.timeline.layout.placement(for: 4) == nil)
  }

  @Test func `reordered snapshots can slide rows from their old positions`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    try session.apply(snapshot(Array(0 ..< 6)), animation: .none, at: 0)
    let old = viewportY(session, 1)
    try session.apply(snapshot([0, 2, 3, 1, 4, 5]), animation: .animated, at: 1,
                      transitions: .init(animatesMoves: true))
    #expect(viewportY(session, 1) == old)
    session.advance(to: 3)
    #expect(viewportY(session, 1) != old)
  }

  // MARK: Visibility and events

  @Test func `visibility reports the usable viewport only`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    var ranges: [ChatListVisibleRange<Int>] = []
    session.onVisibleRangeChanged = { ranges.append($0) }
    try session.apply(snapshot(Array(0 ..< 60)), animation: .none, at: 0)
    session.scroll(to: .init(id: 20, position: .top(-20)), animation: .none, at: 1)
    let range = session.timeline.layout.visibleRange
    #expect(range.first == 20)
    #expect(range.fullyVisible.first == 21)
    #expect(range.ids.count == 11)
    #expect(session.timeline.layout.visibility(for: 20).fraction == 0.5)
    #expect(session.timeline.layout.visibility(for: 10) == .hidden)
    #expect(ranges.last == range)
  }

  @Test func `scroll lifecycle, direction and content offsets`() throws {
    let session = Session(viewport: viewport, now: { 0 })
    var events: [ChatListScrollEvent] = []
    var offsets: [ChatListContentOffset] = []
    session.onScrollEvent = { events.append($0) }
    session.onContentOffsetChanged = { offsets.append($0) }
    try session.apply(snapshot(Array(0 ..< 60)), animation: .none, at: 0)
    #expect(offsets.last?.fromBottom == 0)
    let origin = session.timeline.layout.originY
    session.beginUserScroll(at: origin)
    session.userScrolled(to: origin - 100)
    session.userScrolled(to: origin - 50)
    session.endUserScroll(at: origin - 50)
    #expect(events == [.userScrollBegan, .directionChanged(.up), .directionChanged(.down), .userScrollEnded])
    #expect(offsets.last?.fromBottom == 50)
    #expect(offsets.last?.delta == -50)
  }

  @Test func `stuck headers fade when idle and return on scroll`() throws {
    var clock = 0.0
    let session = Session(viewport: viewport, now: { clock })
    let header = ChatListDecoration<Int>(
      id: "day", firstRow: 0, lastRow: 59, edge: .top, x: 0,
      size: .init(width: 100, height: 24), hidesWhenIdle: true
    )
    try session.apply(snapshot(Array(0 ..< 60), decorations: [header]), animation: .none, at: 0)
    #expect(session.decorationPlacements.first?.isStuck == true)
    #expect(session.needsDisplayFrames == false)
    let origin = session.timeline.layout.originY
    session.beginUserScroll(at: origin)
    session.userScrolled(to: origin - 10)
    session.endUserScroll(at: origin - 10)
    #expect(session.needsDisplayFrames)
    clock = 0.2
    session.advance(to: clock)
    #expect(session.decorationPlacements.first?.opacity == 1)
    clock = 0.4
    session.advance(to: clock)
    clock = 0.6
    session.advance(to: clock)
    let fading = try #require(session.decorationPlacements.first?.opacity)
    #expect(fading > 0 && fading < 1)
    clock = 0.8
    session.advance(to: clock)
    #expect(session.decorationPlacements.first?.opacity == 0)
    session.beginUserScroll(at: origin - 10)
    clock = 0.9
    session.advance(to: clock)
    clock = 1.2
    session.advance(to: clock)
    #expect(session.decorationPlacements.first?.opacity == 1)
  }

  // MARK: Reordering

  @Test func `a lifted row follows the touch, hops at most every 0.2 s, and commits`() throws {
    let session = Session(viewport: .init(width: 600, height: 500), now: { 0 })
    session.canReorder = { _ in true }
    var hops = 0
    var committed: ChatListReorder<Int>?
    session.onReorderHop = { _ in hops += 1 }
    session.onReorder = { committed = $0 }
    try session.apply(snapshot(Array(0 ..< 10)), animation: .none, at: 0)
    let start = (viewportY(session, 2) ?? 0) + 20
    #expect(session.beginReorder(id: 2, touchY: start, at: 1))
    // The center crosses the next row's far edge, its nearest edge.
    session.updateReorder(touchY: start + 55, at: 1.02)
    #expect(hops == 0)
    session.updateReorder(touchY: start + 65, at: 1.05)
    #expect(abs((viewportY(session, 2) ?? 0) + 20 - (start + 65)) < 0.01)
    #expect(hops == 1)
    session.updateReorder(touchY: start + 105, at: 1.1)
    #expect(hops == 1)
    session.updateReorder(touchY: start + 105, at: 1.3)
    #expect(hops == 2)
    let result = session.endReorder(at: 1.4)
    #expect(result == .init(id: 2, fromIndex: 2, toIndex: 4, before: 4, after: 5))
    #expect(committed == result)
    session.advance(to: 3)
    try session.apply(snapshot([0, 1, 3, 4, 2, 5, 6, 7, 8, 9]), animation: .animated, at: 3)
    let settled = session.timeline.layout.rows.map(\.frame)
    session.advance(to: 4)
    #expect(session.timeline.layout.rows.map(\.frame) == settled)
  }

  @Test func `reordering stays inside the movable run and can be cancelled`() throws {
    let session = Session(viewport: .init(width: 600, height: 500), now: { 0 })
    session.canReorder = { $0 >= 2 && $0 <= 4 }
    try session.apply(snapshot(Array(0 ..< 10)), animation: .none, at: 0)
    #expect(!session.beginReorder(id: 6, touchY: 300, at: 1))
    let start = (viewportY(session, 3) ?? 0) + 20
    #expect(session.beginReorder(id: 3, touchY: start, at: 1))
    session.updateReorder(touchY: start + 200, at: 2)
    #expect(session.timeline.layout.index(for: 3) == 4)
    session.cancelReorder(at: 3)
    session.advance(to: 5)
    #expect(session.timeline.layout.rows.map(\.row.id) == Array(0 ..< 10))
  }

  @Test func `content applied during a reorder waits for the drop`() throws {
    let session = Session(viewport: .init(width: 600, height: 500), now: { 0 })
    session.canReorder = { _ in true }
    try session.apply(snapshot(Array(0 ..< 10)), animation: .none, at: 0)
    #expect(session.beginReorder(id: 3, touchY: 200, at: 1))
    #expect(try session.apply(snapshot(Array(0 ..< 11)), animation: .none, at: 1.1) == .deferred)
    session.endReorder(at: 1.2)
    #expect(session.snapshot?.items.count == 11)
  }

  @Test func `holding a lifted row near an edge autoscrolls`() throws {
    let session = Session(viewport: .init(width: 600, height: 500), now: { 0 })
    session.canReorder = { _ in true }
    try session.apply(snapshot(Array(0 ..< 100)), animation: .none, at: 0)
    session.scroll(to: .init(id: 50, position: .center), animation: .none, at: 0)
    let origin = session.timeline.layout.originY
    let start = (viewportY(session, 50) ?? 0) + 20
    #expect(session.beginReorder(id: 50, touchY: start, at: 1))
    session.updateReorder(touchY: 495, at: 1)
    #expect(session.needsDisplayFrames)
    session.advance(to: 2)
    #expect(abs(session.timeline.layout.originY - (origin + 360)) < 1)
    // Half again as fast after 2 s at the edge, with the touch held still.
    session.advance(to: 3)
    session.advance(to: 4)
    #expect(abs(session.timeline.layout.originY - (origin + 360 * 2 + 540)) < 1)
  }

  // MARK: Staged preparation

  @Test func `staged preparation publishes the newest rows first and the rest later`() async throws {
    let session = Session(viewport: .init(width: 600, height: 500), now: { 0 })
    var demands: [ChatListEdge] = []
    var prepared: [[Int]] = []
    var counts: [Int] = []
    session.onHistoryDemand = { demands.append($0) }
    session.onPresentationChanged = { counts.append(session.snapshot?.items.count ?? 0) }
    session.updateViewport(.init(width: 600, height: 500), at: 0)
    session.requestStagedPreparation(
      identities: Array(0 ..< 300), initialCount: 40, chunkCount: 100,
      history: .init(hasOlder: true)
    ) { ids, context in
      prepared.append(ids)
      return ids.map { .init(id: $0, revision: 0, content: "\($0)", height: 40) }
    }
    for _ in 0 ..< 200 {
      await Task.yield()
      if session.snapshot?.items.count == 300 { break }
    }
    #expect(prepared.first == Array(260 ..< 300))
    #expect(prepared.flatMap { $0 }.count == 300)
    #expect(counts.contains(40))
    #expect(session.snapshot?.items.count == 300)
    #expect(session.timeline.intent == .latest)
    #expect(demands.isEmpty)
  }
}
