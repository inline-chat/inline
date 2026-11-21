#if canImport(UIKit)
import ChatListCore
@testable import ChatListUIKit
import QuartzCore
import Testing
import UIKit

@Suite(.serialized) @MainActor
struct ChatListOwnershipTests {
  private typealias Host = ChatListView<Int, String>

  private func window() -> UIWindow {
    let window = if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
      UIWindow(windowScene: scene)
    } else {
      UIWindow(frame: .init(x: 0, y: 0, width: 400, height: 600))
    }
    window.rootViewController = UIViewController()
    window.isHidden = false
    return window
  }

  private func mount(_ host: Host, in window: UIWindow) {
    window.rootViewController!.view.addSubview(host)
    host.frame = .init(x: 0, y: 0, width: 400, height: 300)
    host.setNeedsLayout()
    host.layoutIfNeeded()
  }

  private func apply(_ session: ChatListSession<Int, String>, height: CGFloat, revision: UInt64) throws {
    try session.apply(.init(context: session.layoutContext, items: (0 ..< 20).map {
      .init(id: $0, revision: revision, content: "row \($0)", height: height)
    }), animation: revision == 0 ? .none : .animated, at: CACurrentMediaTime())
  }

  @Test func `replacement revokes mounted UIKit callbacks including queued presentation`() async throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 300))
    let wa = window(), wb = window()
    defer { wa.isHidden = true
      wb.isHidden = true
    }
    var a: Host? = Host(session: session) { _, reused in reused ?? UIView() }
    weak var former = a
    try mount(#require(a), in: wa)
    try apply(session, height: 80, revision: 0)
    try apply(session, height: 100, revision: 1)
    #expect(a?.isAutomaticClockRunning == true)
    var presentations = 0
    session.onPresentation = { _ in presentations += 1 }
    let b = Host(session: session, configuration: .init(
      historyTriggerDistance: 77,
      usesAutomaticDisplayClock: false
    )) { _, reused in
      reused ?? UIView()
    }
    mount(b, in: wb)
    #expect(a?.window === wa && b.window === wb)
    #expect(a?.isAutomaticClockRunning == false)
    let context = session.layoutContext
    let origin = session.timeline.layout.originY
    let intent = session.timeline.intent
    a?.frame.size = .init(width: 650, height: 500)
    a?.setNeedsLayout()
    a?.layoutIfNeeded()
    a?.configuration.historyTriggerDistance = 999
    a?.advance(to: CACurrentMediaTime() + 100)
    if let a {
      a.scrollView.contentOffset.y = 50
      a.scrollViewWillBeginDragging(a.scrollView)
      a.scrollViewDidScroll(a.scrollView)
      a.scrollViewDidEndDragging(a.scrollView, willDecelerate: false)
      a.scrollViewDidEndDecelerating(a.scrollView)
    }
    // Keep A mounted and alive until its queued didPresent has had a chance
    // to run. Weak-self/deallocation must not accidentally make this pass.
    try await Task.sleep(for: .milliseconds(30))
    #expect(a?.window != nil)
    #expect(presentations == 1)
    #expect(session.historyTriggerDistance == 77)
    a?.removeFromSuperview()
    #expect(session.isActive)
    #expect(session.layoutContext == context)
    #expect(session.timeline.layout.originY == origin)
    #expect(session.timeline.intent == intent)
    #expect(!session.isUserScrolling)
    a = nil
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
    defer { wa.isHidden = true
      wb.isHidden = true
    }
    let a = Host(session: session, configuration: .init(usesAutomaticDisplayClock: false)) { _, reused in
      reused ?? UIView()
    }
    mount(a, in: wa)
    a.frame.size = .init(width: 400, height: 300)
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
      reused ?? UIView()
    }
    mount(b, in: wb)
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
      reused ?? UIView()
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
          reused ?? UIView()
        }
      }
      return reused ?? UIView()
    }
    let newest = try #require(c)
    #expect(session.isCurrentHost(newest))
    #expect(!session.isCurrentHost(a) && !session.isCurrentHost(b))
    #expect(session.historyTriggerDistance == 99)
  }

  @Test func `mounted UIKit pause stops real callbacks and resumes frozen spring`() async throws {
    let session = ChatListSession<Int, String>(viewport: .init(width: 400, height: 300))
    let host = Host(session: session) { _, reused in reused ?? UIView() }
    let w = window()
    defer { w.isHidden = true }
    mount(host, in: w)
    var callbacks = 0
    host.automaticFrameObserver = { callbacks += 1 }
    try apply(session, height: 80, revision: 0)
    try apply(session, height: 180, revision: 1)
    #expect(host.isAutomaticClockRunning)
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
