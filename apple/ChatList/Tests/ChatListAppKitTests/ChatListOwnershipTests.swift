#if canImport(AppKit)
import AppKit
@testable import ChatListAppKit
import ChatListCore
import QuartzCore
import Testing

@Suite(.serialized) @MainActor
struct ChatListOwnershipTests {
  private typealias Host = ChatListView<Int, String>

  private func window() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    return window
  }

  private func apply(_ session: ChatListSession<Int, String>, height: CGFloat, revision: UInt64) throws {
    try session.apply(.init(context: session.layoutContext, items: (0 ..< 20).map {
      .init(id: $0, revision: revision, content: "row \($0)", height: height)
    }), animation: revision == 0 ? .none : .animated, at: CACurrentMediaTime())
  }

  @Test func `replaced mounted host cannot resize scroll pause or publish for its successor`() async throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 300))
    let wa = window(), wb = window()
    defer { wa.close()
      wb.close()
    }
    var a: Host? = Host(session: session) { _, reused in reused ?? NSView() }
    weak var former = a
    wa.contentView = a
    a?.frame.size = .init(width: 400, height: 300)
    a?.layoutSubtreeIfNeeded()
    try apply(session, height: 80, revision: 0)
    try apply(session, height: 100, revision: 1)
    #expect(a?.isAutomaticClockRunning == true)
    // A still has its native window and a queued didPresent when B takes over.
    var presentations = 0
    session.onPresentation = { _ in presentations += 1 }
    let b = Host(session: session, configuration: .init(
      historyTriggerDistance: 77,
      usesAutomaticDisplayClock: false
    )) { _, reused in
      reused ?? NSView()
    }
    wb.contentView = b
    b.frame.size = .init(width: 400, height: 300)
    b.layoutSubtreeIfNeeded()
    #expect(a?.window === wa && b.window === wb)
    #expect(a?.isAutomaticClockRunning == false)
    let context = session.layoutContext
    let origin = session.timeline.layout.originY
    let intent = session.timeline.intent
    a?.frame.size = .init(width: 650, height: 500)
    a?.layoutSubtreeIfNeeded()
    a?.configuration.historyTriggerDistance = 999
    a?.advance(to: CACurrentMediaTime() + 100)
    if let scroll = a?.scrollView {
      NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
      scroll.contentView.scroll(to: .init(x: 0, y: 50))
      NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
      NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }
    // Keep A mounted and alive until its queued didPresent has had a chance
    // to run. Weak-self/deallocation must not accidentally make this pass.
    try await Task.sleep(for: .milliseconds(30))
    #expect(a?.window != nil)
    #expect(presentations == 1)
    #expect(session.historyTriggerDistance == 77)
    // Unmount while B is active: the original bug deactivated B here.
    wa.contentView = nil
    #expect(session.isActive)
    #expect(session.layoutContext == context)
    #expect(session.timeline.layout.originY == origin)
    #expect(session.timeline.intent == intent)
    #expect(!session.isUserScrolling)
    a = nil
    // AppKit may autorelease the removed content view until the run loop drains.
    for _ in 0 ..< 20 where former != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(former == nil)
    await Task.yield()
    #expect(session.isCurrentHost(b))
    #expect(session.isActive)
    #expect(session.historyTriggerDistance == 77)
    try apply(session, height: 110, revision: 2)
    #expect(b.materializedCells.count > 0)
    b.configuration.usesAutomaticDisplayClock = true
    #expect(b.isAutomaticClockRunning)
  }

  @Test(arguments: [false, true])
  func `replacement settles the revoked native phase and admits deferred content`(bouncing: Bool) throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 300))
    let wa = window(), wb = window()
    defer { wa.close()
      wb.close()
    }
    let a = Host(session: session, configuration: .init(usesAutomaticDisplayClock: false)) { _, reused in
      reused ?? NSView()
    }
    wa.contentView = a
    a.frame.size = .init(width: 400, height: 300)
    a.layoutSubtreeIfNeeded()
    try apply(session, height: 80, revision: 0)
    // The session receives the same reached native origin as a platform drag;
    // OS rubber-band synthesis is outside this ownership regression.
    let origin: CGFloat = bouncing ? -23 : 50
    session.beginUserScroll(at: origin)
    session.userScrolled(to: origin)
    try apply(session, height: 100, revision: 1)
    #expect(session.isUserScrolling)
    #expect(session.generation == (bouncing ? 1 : 2))
    let b = Host(session: session, configuration: .init(usesAutomaticDisplayClock: false)) { _, reused in
      reused ?? NSView()
    }
    wb.contentView = b
    b.frame.size = .init(width: 400, height: 300)
    b.layoutSubtreeIfNeeded()
    #expect(a.window != nil && b.window != nil)
    #expect(!session.isUserScrolling)
    #expect(session.generation == 2)
    #expect(session.snapshot?.items.first?.revision == 1)
    #expect(session.timeline.layout.originY >= 0)
    try apply(session, height: 110, revision: 2)
    #expect(session.generation == 3)
    #expect(session.snapshot?.items.first?.revision == 2)
  }

  @Test func `reentrant attachment cannot overwrite the newest host configuration`() throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 300))
    let a = Host(session: session, configuration: .init(usesAutomaticDisplayClock: false)) { _, reused in
      reused ?? NSView()
    }
    try apply(session, height: 80, revision: 0)
    session.beginUserScroll(at: -20)
    try apply(session, height: 100, revision: 1)
    var c: Host?
    let b = Host(session: session, configuration: .init(
      historyTriggerDistance: 77,
      usesAutomaticDisplayClock: false
    )) { _, reused in
      if c == nil {
        c = Host(session: session, configuration: .init(
          historyTriggerDistance: 99,
          usesAutomaticDisplayClock: false
        )) { _, reused in
          reused ?? NSView()
        }
      }
      return reused ?? NSView()
    }
    let newest = try #require(c)
    #expect(session.isCurrentHost(newest))
    #expect(!session.isCurrentHost(a) && !session.isCurrentHost(b))
    #expect(session.historyTriggerDistance == 99)
  }

  @Test func `mounted pause invalidates automatic link and resume preserves presentation`() async throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 300))
    let host = Host(session: session) { _, reused in reused ?? NSView() }
    let w = window()
    defer { w.close() }
    w.contentView = host
    host.frame.size = .init(width: 400, height: 300)
    host.layoutSubtreeIfNeeded()
    if let screen = NSScreen.screens.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
      w.setFrameOrigin(.init(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
    }
    w.orderFront(nil)
    var callbacks = 0
    host.automaticFrameObserver = { callbacks += 1 }
    try apply(session, height: 80, revision: 0)
    try apply(session, height: 180, revision: 1)
    #expect(host.isAutomaticClockRunning)
    // Exercise the real CADisplayLink, not a fake advance/presentation count.
    for _ in 0 ..< 20 where callbacks == 0 {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(callbacks > 0)
    session.setActive(false, at: CACurrentMediaTime())
    #expect(host.window != nil)
    #expect(session.timeline.isAnimating)
    #expect(!host.isAutomaticClockRunning)
    let pausedCallbacks = callbacks
    let frame = session.timeline.layout.placement(for: 19)?.frame
    let origin = session.timeline.layout.originY
    try await Task.sleep(for: .milliseconds(160))
    #expect(callbacks == pausedCallbacks)
    #expect(session.timeline.layout.placement(for: 19)?.frame == frame)
    #expect(session.timeline.layout.originY == origin)
    session.setActive(true, at: CACurrentMediaTime())
    #expect(host.isAutomaticClockRunning)
    #expect(session.timeline.layout.placement(for: 19)?.frame == frame)
    #expect(session.timeline.layout.originY == origin)
    for _ in 0 ..< 20 where callbacks == pausedCallbacks {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(callbacks > pausedCallbacks)
    #expect(session.timeline.layout.placement(for: 19)?.frame != frame)
  }
}
#endif
