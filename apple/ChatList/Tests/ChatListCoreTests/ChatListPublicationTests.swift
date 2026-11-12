import ChatListCore
import Testing

@MainActor
struct ChatListPublicationTests {
  @Test(arguments: [false, true])
  func `callback width change cannot publish stale cells`(fromHost: Bool) throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 600))
    let original = ChatListSnapshot(context: session.layoutContext, items: [
      ChatListItem(id: 1, revision: 0, content: "original", height: 800),
    ])
    try session.apply(original, animation: .none, at: 0)
    let owner = Owner()
    var publications = 0
    session.onPresentationChanged = {
      publications += 1
      #expect(session.snapshot?.context.width == session.timeline.layout.viewport.width)
      #expect(session.item(for: 1)?.content == "original")
    }
    let resize: (TimelineIntent<Int>?) -> Void = { _ in
      session.updateViewport(.init(width: 600, height: 600), at: 1)
    }
    session.attachHost(owner: owner, willApply: fromHost ? resize : { _ in }, presentationChanged: {})
    if !fromHost {
      session.onWillApply = resize
    }
    let replacement = ChatListSnapshot(context: session.layoutContext, items: [
      ChatListItem(id: 2, revision: 1, content: "must not publish", height: 900),
    ])
    #expect(throws: ChatListError.staleContext) {
      try session.apply(replacement, animation: .none, at: 1)
    }
    #expect(session.generation == 1)
    #expect(session.snapshot?.items.first?.id == 1)
    #expect(session.item(for: 2) == nil)
    #expect(session.timeline.layout.viewport.width == 400)
    #expect(session.layoutContext.width == 600)
    // Width-only preparation retains the installed canvas and need not emit.
    #expect(publications <= 1)
    session.onWillApply = nil
    session.detachHost(owner: owner)
    let fresh = ChatListSnapshot(context: session.layoutContext, items: original.items)
    session.onPresentationChanged = nil
    try session.apply(fresh, animation: .none, at: 2)
    #expect(session.snapshot?.context.width == 600)
    #expect(session.timeline.layout.viewport.width == 600)
  }

  @Test func `host replacement in capture rejects outer publication`() throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 600))
    let a = Owner(), b = Owner()
    session.attachHost(owner: a, willApply: { _ in
      session.attachHost(owner: b, willApply: { _ in }, presentationChanged: {})
    }, presentationChanged: {})
    #expect(throws: ChatListError.reentrantTransaction) {
      try session.apply(.init(context: session.layoutContext, items: [
        .init(id: 1, revision: 0, content: "unpublished", height: 100),
      ]), animation: .none, at: 0)
    }
    #expect(session.snapshot == nil)
    #expect(session.generation == 0)
    #expect(session.isCurrentHost(b))
  }

  @Test func `explicit detach settles bounce before a successor starts input`() throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 600), now: { 1 })
    let a = Owner(), b = Owner()
    var wasRevoked = false
    session.attachHost(owner: a, willApply: { _ in }, presentationChanged: {
      if !session.isCurrentHost(a) {
        wasRevoked = true
        session.attachHost(owner: b, willApply: { _ in }, presentationChanged: {})
        session.beginUserScroll(at: 40)
      }
    })
    func snapshot(_ revision: UInt64) -> ChatListSnapshot<Int, String> {
      .init(context: session.layoutContext, items: [
        .init(id: 1, revision: revision, content: "row", height: 900),
      ])
    }
    try session.apply(snapshot(0), animation: .none, at: 0)
    session.beginUserScroll(at: -20)
    session.userScrolled(to: -20)
    #expect(try session.apply(snapshot(1), animation: .none, at: 1) == .deferred)
    session.detachHost(owner: b) // Mismatched detach must not settle A.
    #expect(session.isUserScrolling)
    #expect(session.generation == 1)
    session.detachHost(owner: a)
    #expect(wasRevoked)
    #expect(session.generation == 2)
    #expect(session.snapshot?.items.first?.revision == 1)
    #expect(session.isCurrentHost(b))
    #expect(session.isUserScrolling) // B's new gesture survives the notification.
    #expect(session.timeline.layout.originY == 40)
    session.endUserScroll(at: 40, time: 1)
    #expect(try session.apply(snapshot(2), animation: .none, at: 1) == .applied(generation: 3))
  }

  @Test func `capture replacement drains accepted navigation after rejected publication`() throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 600), now: { 1 })
    let a = Owner(), b = Owner()
    let snapshot = ChatListSnapshot(context: session.layoutContext, items: [
      ChatListItem(id: 1, revision: 0, content: "row", height: 900),
    ])
    try session.apply(snapshot, animation: .none, at: 0)
    session.attachHost(owner: a, willApply: { _ in
      session.attachHost(owner: b, willApply: { _ in }, presentationChanged: {})
    }, presentationChanged: {})
    session.beginUserScroll(at: 40)
    session.navigate(to: .latest, animation: .none, at: 1)
    #expect(throws: ChatListError.reentrantTransaction) {
      try session.apply(snapshot, animation: .none, at: 1)
    }
    #expect(session.isCurrentHost(b))
    #expect(!session.isUserScrolling)
    #expect(session.generation == 1)
    #expect(session.timeline.intent == .latest)
    #expect(session.timeline.layout.originY == session.timeline.layout.maximumOrigin)
  }

  private final class Owner {}
}
