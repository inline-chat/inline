import Foundation
@testable import ChatListCore
import Testing

@MainActor
struct ChatListNativeViewportTests {
  private typealias Session = ChatListSession<Int, String>
  private typealias Snapshot = ChatListSnapshot<Int, String>
  private let viewport = TimelineViewport(width: 500, height: 600, topInset: 40, bottomInset: 220)

  private func snapshot(revision: UInt64 = 0, changedHeight: CGFloat = 50, append: Bool = false) -> Snapshot {
    .init(context: .init(width: 500), items: (0 ..< (append ? 81 : 80)).map { id in
      .init(id: id, revision: revision, content: "cell \(id):\(revision)", height: id == 20 ? changedHeight : 50)
    }, history: .init(hasOlder: true, hasNewer: true, isAtLiveEnd: false))
  }

  private func reader() throws -> Session {
    let session = Session(viewport: viewport, now: { 0 })
    try session.apply(snapshot(), intent: .reading(.init(id: 40, localY: 20, viewportY: 60)),
                      animation: .none, at: 0)
    return session
  }

  private func glyphY(in session: Session) throws -> CGFloat {
    try #require(session.timeline.layout.placement(for: 42)?.frame.minY) + 10 - session.timeline.layout.originY
  }

  @Test func `native keyboard drag and reversal move content once and passive settlement resumes anchoring`() throws {
    let session = try reader()
    defer { session.dispose() }
    let originalOrigin = session.timeline.layout.originY
    let originalGlyph = try glyphY(in: session)
    session.beginUserScroll(at: originalOrigin)
    session.userScrolled(to: originalOrigin - 20)
    var dragged = viewport
    dragged.bottomInset -= 20
    session.updateViewport(dragged, animation: .none, at: 0.1, viewportAdjustment: .nativeInput)
    #expect(session.timeline.layout.viewport == dragged)
    #expect(abs(session.timeline.layout.originY - (originalOrigin - 20)) < 0.001)
    #expect(try abs(glyphY(in: session) - originalGlyph - 20) < 0.001)

    session.userScrolled(to: originalOrigin - 8)
    dragged.bottomInset += 12
    session.updateViewport(dragged, animation: .none, at: 0.2, viewportAdjustment: .nativeInput)
    #expect(session.timeline.layout.viewport == dragged)
    #expect(abs(session.timeline.layout.originY - (originalOrigin - 8)) < 0.001)
    #expect(try abs(glyphY(in: session) - originalGlyph - 8) < 0.001)
    session.endUserScroll(at: originalOrigin - 8, time: 0.2)
    session.advance(to: 1)
    #expect(!session.isUserScrolling)
    #expect(abs(session.timeline.layout.originY - (originalOrigin - 8)) < 0.001)

    // Once UIKit finishes interactive ownership, its passive settle transition
    // again asks the list to anchor against the moving usable bottom.
    session.updateViewport(viewport, animation: .animated, at: 1)
    for frame in 0 ... 240 {
      session.advance(to: 1 + Double(frame) / 120)
      let insetDelta = session.timeline.layout.viewport.bottomInset - dragged.bottomInset
      #expect(abs(session.timeline.layout.originY - (originalOrigin - 8 + insetDelta)) < 0.001)
      #expect(try abs(glyphY(in: session) - (originalGlyph + 8 - insetDelta)) < 0.001)
    }
    #expect(session.timeline.layout.viewport == viewport)
    #expect(!session.timeline.isAnimating)
  }

  @Test func `passive default still anchors inset changes during an active native drag`() throws {
    let session = try reader()
    defer { session.dispose() }
    let originalOrigin = session.timeline.layout.originY
    let originalGlyph = try glyphY(in: session)
    session.beginUserScroll(at: originalOrigin)
    session.userScrolled(to: originalOrigin - 20)
    var target = viewport
    target.bottomInset -= 20
    session.updateViewport(target, animation: .none, at: 0.1)
    #expect(abs(session.timeline.layout.originY - (originalOrigin - 40)) < 0.001)
    #expect(try abs(glyphY(in: session) - originalGlyph - 40) < 0.001)
    #expect(session.isUserScrolling)
  }

  @Test(arguments: [false, true])
  func `native ownership interrupts a passive inset spring before the later transaction samples time`(
    atomicPublication: Bool
  ) throws {
    let session = try reader()
    defer { session.dispose() }
    var passiveTarget = viewport
    passiveTarget.bottomInset = 360
    session.updateViewport(passiveTarget, animation: .animated, at: 0)
    session.advance(to: 0.05)
    let presented = session.timeline.layout.viewport
    #expect(presented.bottomInset > viewport.bottomInset && presented.bottomInset < passiveTarget.bottomInset)
    let beforeInputOrigin = session.timeline.layout.originY
    let beforeInputGlyph = try glyphY(in: session)
    let reachedOrigin = beforeInputOrigin - 20
    session.beginUserScroll(at: beforeInputOrigin)
    session.userScrolled(to: reachedOrigin)
    var nativeTarget = presented
    nativeTarget.bottomInset -= 20

    // The callback timestamp is newer than the last displayed passive frame.
    // Sampling that obsolete spring before capturing the reached native origin
    // would add its unpresented displacement to the user's movement.
    if atomicPublication {
      try session.apply(snapshot(revision: 1), animation: .none, at: 0.12, viewport: nativeTarget,
                        viewportAdjustment: .nativeInput)
    } else {
      session.updateViewport(nativeTarget, animation: .none, at: 0.12, viewportAdjustment: .nativeInput)
    }
    #expect(session.timeline.layout.viewport == nativeTarget)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    #expect(try abs(glyphY(in: session) - beforeInputGlyph - 20) < 0.001)
    #expect(!session.timeline.isAnimating)
    #expect(session.generation == (atomicPublication ? 2 : 1))
    session.advance(to: 1)
    #expect(session.timeline.layout.viewport == nativeTarget)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    session.endUserScroll(at: reachedOrigin, time: 1)
    session.advance(to: 2)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    #expect(!session.isUserScrolling)
  }

  @Test(arguments: [false, true])
  func `native bounce handoff freezes the last presented inset before its legal boundary can advance`(
    atomicPublication: Bool
  ) throws {
    let session = try reader()
    defer { session.dispose() }
    var passiveTarget = viewport
    passiveTarget.bottomInset = 360
    session.updateViewport(passiveTarget, animation: .animated, at: 0)
    session.advance(to: 0.05)
    let presented = session.timeline.layout.viewport
    #expect(presented.bottomInset > viewport.bottomInset && presented.bottomInset < passiveTarget.bottomInset)
    let reachedOrigin = session.timeline.layout.maximumOrigin + 25
    session.beginUserScroll(at: reachedOrigin)
    session.userScrolled(to: reachedOrigin)
    var nativeTarget = presented
    nativeTarget.bottomInset -= 20
    if atomicPublication {
      let result = try session.apply(snapshot(revision: 1), animation: .none, at: 0.12,
                                     viewport: nativeTarget, viewportAdjustment: .nativeInput)
      #expect(result == .deferred)
    } else {
      session.updateViewport(nativeTarget, animation: .none, at: 0.12, viewportAdjustment: .nativeInput)
    }
    #expect(session.timeline.layout.viewport == nativeTarget)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    #expect(abs(session.timeline.layout.originY - session.timeline.layout.maximumOrigin - 45) < 0.001)
    #expect(session.generation == 1)
    #expect(!session.timeline.isAnimating)
    session.advance(to: 1)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    #expect(session.timeline.layout.viewport == nativeTarget)
    let legalOrigin = session.timeline.layout.maximumOrigin
    session.endUserScroll(at: legalOrigin, time: 1)
    #expect(!session.isUserScrolling)
    #expect(abs(session.timeline.layout.originY - legalOrigin) < 0.001)
    #expect(session.generation == (atomicPublication ? 2 : 1))
  }

  @Test func `native ownership installs an unchanged viewport target when its presentation is still moving`() throws {
    let session = try reader()
    defer { session.dispose() }
    var target = viewport
    target.bottomInset = 360
    session.updateViewport(target, animation: .animated, at: 0)
    session.advance(to: 0.05)
    #expect(session.timeline.targetViewport == target)
    #expect(session.timeline.layout.viewport != target)
    let reachedOrigin = session.timeline.layout.originY - 20
    session.beginUserScroll(at: session.timeline.layout.originY)
    session.userScrolled(to: reachedOrigin)
    let reachedGlyph = try glyphY(in: session)
    session.updateViewport(target, animation: .none, at: 0.12, viewportAdjustment: .nativeInput)
    #expect(session.timeline.layout.viewport == target)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    #expect(try abs(glyphY(in: session) - reachedGlyph) < 0.001)
    #expect(!session.timeline.isAnimating)
    session.advance(to: 1)
    #expect(session.timeline.layout.viewport == target)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    #expect(!session.timeline.isAnimating)
  }

  @Test(arguments: [false, true])
  func `atomic native viewport adjustment retains independent row compensation`(animated: Bool) throws {
    let session = try reader()
    defer { session.dispose() }
    let originalOrigin = session.timeline.layout.originY
    let originalGlyph = try glyphY(in: session)
    let reachedOrigin = originalOrigin - 20
    session.beginUserScroll(at: originalOrigin)
    session.userScrolled(to: reachedOrigin)
    var target = viewport
    target.bottomInset -= 20
    try session.apply(snapshot(revision: 1, changedHeight: 200, append: true),
                      animation: animated ? .animated : .none, at: 0.1, viewport: target,
                      viewportAdjustment: .nativeInput)
    #expect(session.timeline.layout.viewport == target)
    for frame in 0 ... 240 {
      session.advance(to: 0.1 + Double(frame) / 120)
      let editedHeight = try #require(session.timeline.layout.placement(for: 20)?.frame.height)
      #expect(abs(session.timeline.layout.originY - (reachedOrigin + editedHeight - 50)) < 0.001)
      #expect(try abs(glyphY(in: session) - originalGlyph - 20) < 0.001)
      #expect(session.timeline.layout.viewport == target)
    }
    #expect(session.snapshot?.items.last?.id == 80)
    #expect(session.timeline.layout.placement(for: 20)?.frame.height == 200)
    #expect(session.timeline.intent != .latest)
  }

  @Test(arguments: [false, true])
  func `native viewport changes preserve actual reached bounce origin rather than repeating edge compensation`(
    bouncingAtBottom: Bool
  ) throws {
    let session = try reader()
    defer { session.dispose() }
    let reachedOrigin = bouncingAtBottom ? session.timeline.layout.maximumOrigin + 25 : -25
    session.beginUserScroll(at: reachedOrigin)
    session.userScrolled(to: reachedOrigin)
    var target = viewport
    target.bottomInset -= 20
    session.updateViewport(target, animation: .none, at: 0.1, viewportAdjustment: .nativeInput)
    #expect(session.timeline.layout.viewport == target)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    if bouncingAtBottom {
      #expect(abs(session.timeline.layout.originY - session.timeline.layout.maximumOrigin - 45) < 0.001)
    }
    let result = try session.apply(snapshot(revision: 1), animation: .none, at: 0.1)
    #expect(result == .deferred)
    session.advance(to: 1)
    #expect(session.generation == 1)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    let legalOrigin = bouncingAtBottom ? session.timeline.layout.maximumOrigin : 0
    session.endUserScroll(at: legalOrigin, time: 1)
    #expect(session.generation == 2)
    #expect(!session.isUserScrolling)
    #expect(abs(session.timeline.layout.originY - legalOrigin) < 0.001)
  }

  @Test func `native viewport shrink reclassifies the retained origin when it crosses the legal boundary`() throws {
    let session = try reader()
    defer { session.dispose() }
    let reachedOrigin = session.timeline.layout.maximumOrigin - 10
    session.beginUserScroll(at: reachedOrigin)
    session.userScrolled(to: reachedOrigin)
    var target = viewport
    target.bottomInset -= 20
    session.updateViewport(target, animation: .none, at: 0.1, viewportAdjustment: .nativeInput)
    #expect(abs(session.timeline.layout.originY - reachedOrigin) < 0.001)
    #expect(abs(session.timeline.layout.originY - session.timeline.layout.maximumOrigin - 10) < 0.001)
    let result = try session.apply(snapshot(revision: 1), animation: .none, at: 0.1)
    #expect(result == .deferred)
    #expect(session.generation == 1)
    session.endUserScroll(at: reachedOrigin, time: 0.2)
    #expect(session.isUserScrolling)
    #expect(session.generation == 1)
    let legalOrigin = session.timeline.layout.maximumOrigin
    session.endUserScroll(at: legalOrigin, time: 0.3)
    #expect(session.generation == 2)
    #expect(!session.isUserScrolling)
    #expect(abs(session.timeline.layout.originY - legalOrigin) < 0.001)
  }
}
