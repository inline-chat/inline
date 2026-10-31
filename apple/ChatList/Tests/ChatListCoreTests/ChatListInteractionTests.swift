import Testing
@testable import ChatListCore

@MainActor
struct ChatListInteractionTests {
  @Test func `exact width replacement does not snap an unchanged keyboard inset target`() throws {
    let session = ChatListSession<Int, Int>(viewport: .init(width: 500, height: 500), now: { 0 })
    let items = (0 ..< 40).map { ChatListItem(id: $0, revision: 0, content: $0, height: 80) }
    try session.apply(.init(context: session.layoutContext, items: items),
                      intent: .reading(.init(id: 20)), animation: .none, at: 0)
    session.updateViewport(.init(width: 500, height: 500, bottomInset: 200), animation: .animated, at: 0)
    session.advance(to: 0.05)
    let inset = session.timeline.layout.viewport.bottomInset
    let origin = session.timeline.layout.originY
    #expect(inset > 0 && inset < 200)
    session.updateViewport(.init(width: 320, height: 500, bottomInset: 200), animation: .none, at: 0.05)
    try session.apply(.init(context: session.layoutContext, items: items), animation: .none, at: 0.05)
    #expect(session.timeline.layout.viewport.width == 320)
    #expect(session.timeline.layout.viewport.bottomInset == inset)
    #expect(abs(session.timeline.layout.originY - origin) < 0.001)
    session.advance(to: 0.1)
    #expect(session.timeline.layout.viewport.bottomInset > inset)
    #expect(session.timeline.layout.viewport.bottomInset < 200)
  }

  @Test func `nonfinite external input cannot poison a valid presentation`() throws {
    let session = ChatListSession<Int, Int>(viewport: .init(width: 500, height: 500))
    let snapshot = ChatListSnapshot(context: session.layoutContext,
      items: (0 ..< 40).map { ChatListItem(id: $0, revision: 0, content: $0, height: 80) })
    try session.apply(snapshot, animation: .none, at: 0)
    let origin = session.timeline.layout.originY
    let context = session.layoutContext
    #expect(throws: ChatListError.invalidGeometry) {
      try session.apply(snapshot, intent: .reading(.init(id: 20, localY: .nan)), at: 0)
    }
    session.navigate(to: .reading(.init(id: 20, viewportY: .infinity)), at: 0)
    session.userScrolled(to: .nan)
    session.updateViewport(.init(width: 300, height: 500), displayScale: .nan, at: 0)
    #expect(session.timeline.layout.originY == origin)
    #expect(session.layoutContext == context)
    #expect(session.generation == 1)
  }

  @Test func `navigation waits for native input to settle`() throws {
    let session = ChatListSession<Int, Int>(viewport: .init(width: 500, height: 500), now: { 0 })
    let snapshot = ChatListSnapshot(context: session.layoutContext,
      items: (0 ..< 40).map { ChatListItem(id: $0, revision: 0, content: $0, height: 80) })
    try session.apply(snapshot, animation: .none, at: 0)
    session.beginUserScroll(at: 800)
    session.userScrolled(to: 820)
    session.navigate(to: .latest, animation: .none, at: 0)
    #expect(session.timeline.layout.originY == 820)
    #expect(session.isUserScrolling)
    session.endUserScroll(at: 820, time: 0)
    #expect(session.timeline.intent == .latest)
    #expect(session.timeline.layout.originY == session.timeline.layout.maximumOrigin)
  }

  @Test func `inactive native callbacks do not move frozen presentation`() throws {
    let session = ChatListSession<Int, Int>(viewport: .init(width: 500, height: 500))
    let snapshot = ChatListSnapshot(context: session.layoutContext,
      items: (0 ..< 40).map { ChatListItem(id: $0, revision: 0, content: $0, height: 80) })
    try session.apply(snapshot, animation: .none, at: 0)
    session.setActive(false, at: 0)
    let origin = session.timeline.layout.originY
    session.beginUserScroll(at: 20)
    session.userScrolled(to: 40)
    session.endUserScroll(at: 40)
    #expect(session.timeline.layout.originY == origin)
    #expect(session.timeline.intent == .latest)
    #expect(!session.isUserScrolling)
  }

  @Test func `presentation callback replacement cannot demand history from old snapshot`() throws {
    let session = ChatListSession<Int, Int>(viewport: .init(width: 500, height: 500))
    let items = [ChatListItem(id: 0, revision: 0, content: 0, height: 100)]
    let old = ChatListSnapshot(context: session.layoutContext, items: items, history: .init(hasOlder: true))
    let replacement = ChatListSnapshot(context: session.layoutContext, items: items)
    try session.apply(old, animation: .none, at: 0)
    var demands = 0
    session.onHistoryDemand = { _ in demands += 1 }
    session.onPresentation = { _ in
      session.onPresentation = nil
      try? session.apply(replacement, animation: .none, at: 0)
    }
    session.didPresent()
    #expect(demands == 0)
    session.didPresent()
    #expect(demands == 0)
  }

  @Test func `large animated removal preserves old neighbor order without repeated insertion`() {
    var timeline = MessageTimeline<Int>(viewport: .init(width: 500, height: 500))
    timeline.apply(rows: (0 ..< 2_000).map { .init(id: $0, height: 10) },
                   viewport: .init(width: 500, height: 500), animated: false, at: 0)
    timeline.apply(rows: [.init(id: 1_000, height: 10), .init(id: 10, height: 10)],
                   viewport: .init(width: 500, height: 500), animated: true, at: 0)
    let expected = Array(11 ..< 1_000) + [1_000] + Array(0 ..< 10) + [10] + Array(1_001 ..< 2_000)
    #expect(timeline.layout.rows.map(\.row.id) == expected)
    #expect(timeline.layout.rows.filter(\.isExiting).count == 1_998)
    timeline.advance(to: 5)
    #expect(timeline.layout.rows.map(\.row.id) == [1_000, 10])
  }
}
