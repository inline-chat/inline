import Foundation
@testable import ChatListCore
import Testing

@MainActor
struct TimelineBottomAnchorTests {
  private let viewport = TimelineViewport(width: 600, height: 617, topInset: 63, bottomInset: 71)

  private struct BottomPoint {
    let id: Int
    let localY: CGFloat
    let distance: CGFloat
  }

  private func rows(_ ids: Range<Int> = 0 ..< 100) -> [TimelineRow<Int>] {
    ids.map { .init(id: $0, height: 41) }
  }

  private func reader(viewport: TimelineViewport? = nil) -> MessageTimeline<Int> {
    let viewport = viewport ?? self.viewport
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(), viewport: viewport,
                   intent: .reading(.init(id: 40, localY: 12, viewportY: 19)), animated: false, at: 0)
    return timeline
  }

  /// This oracle uses public row geometry only, independently of anchor(at:).
  /// The point actually touching the usable bottom must follow the composer.
  private func bottomPoint(in layout: TimelineLayout<Int>) throws -> BottomPoint {
    let bottom = layout.readingRect.maxY
    let row = try #require(layout.rows.last {
      !$0.isExiting && $0.row.canAnchor && $0.frame.minY < bottom
        && $0.frame.maxY > layout.readingRect.minY
    })
    let point = min(bottom, row.frame.maxY)
    return .init(id: row.row.id, localY: point - row.frame.minY, distance: bottom - point)
  }

  private func expectBottomPoint(_ point: BottomPoint, in layout: TimelineLayout<Int>) throws {
    let row = try #require(layout.placement(for: point.id))
    let documentY = row.frame.minY + min(point.localY, row.frame.height)
    let desiredOrigin = documentY + point.distance - layout.viewport.height + layout.viewport.bottomInset
    let legalOrigin = min(layout.maximumOrigin, max(0, desiredOrigin))
    #expect(abs(layout.originY - legalOrigin) < 0.001)
    if desiredOrigin >= 0, desiredOrigin <= layout.maximumOrigin {
      #expect(abs(layout.readingRect.maxY - documentY - point.distance) < 0.001)
    }
    #expect(layout.originY >= 0 && layout.originY <= layout.maximumOrigin)
    #expect(layout.originY.isFinite)
  }

  @Test(arguments: [CGFloat(12), CGFloat(270)])
  func `bottom inset growth and shrink preserve bottommost visible point at every frame`(bottomInset: CGFloat) throws {
    var timeline = reader()
    let point = try bottomPoint(in: timeline.layout)
    var target = viewport
    target.bottomInset = bottomInset
    timeline.resize(viewport: target, animated: true, at: 0)
    for frame in 0 ... 240 {
      timeline.advance(to: Double(frame) / 120)
      try expectBottomPoint(point, in: timeline.layout)
      #expect(timeline.intent != .latest)
    }
    guard case let .reading(anchor) = timeline.intent else {
      Issue.record("Inset change lost the middle-history reading intent")
      return
    }
    #expect(anchor.edge == .bottom)
    #expect(anchor.id == point.id)
    #expect(!timeline.isAnimating)
  }

  @Test func `interactive bottom inset changes preserve the same bottom point without animation`() throws {
    var timeline = reader()
    let point = try bottomPoint(in: timeline.layout)
    for (index, bottomInset) in [CGFloat(140), 270, 190, 80, 0, 225, 71].enumerated() {
      var target = viewport
      target.bottomInset = bottomInset
      timeline.resize(viewport: target, animated: false, at: Double(index + 1) / 60)
      try expectBottomPoint(point, in: timeline.layout)
      #expect(!timeline.isAnimating)
    }
  }

  @Test func `animated bottom inset reversals retarget from presentation without moving the bottom point`() throws {
    var timeline = reader()
    let point = try bottomPoint(in: timeline.layout)
    let targets: [Int: CGFloat] = [0: 280, 8: 20, 16: 190, 26: 45]
    for frame in 0 ... 270 {
      let time = Double(frame) / 120
      timeline.advance(to: time)
      if let bottomInset = targets[frame] {
        let origin = timeline.layout.originY
        let presentedViewport = timeline.layout.viewport
        var target = viewport
        target.bottomInset = bottomInset
        timeline.resize(viewport: target, animated: true, at: time)
        #expect(abs(timeline.layout.originY - origin) < 0.001)
        #expect(timeline.layout.viewport == presentedViewport)
      }
      try expectBottomPoint(point, in: timeline.layout)
    }
    #expect(!timeline.isAnimating)
    #expect(timeline.layout.viewport.bottomInset == 45)
  }

  @Test func `native input during a bottom inset spring retains the reached bottom point after gesture end`() throws {
    var timeline = reader()
    var target = viewport
    target.bottomInset = 250
    timeline.resize(viewport: target, animated: true, at: 0)
    timeline.advance(to: 0.05)
    let reachedOrigin = timeline.layout.originY + 12
    timeline.beginUserScroll(at: timeline.layout.originY)
    timeline.userScrolled(to: reachedOrigin)
    let reachedPoint = try bottomPoint(in: timeline.layout)
    timeline.endUserScroll(at: reachedOrigin, canFollowLatest: false)
    #expect(abs(timeline.layout.originY - reachedOrigin) < 0.001)
    guard case let .reading(anchor) = timeline.intent else {
      Issue.record("Native gesture lost the reading intent")
      return
    }
    #expect(anchor.edge == .bottom)
    for frame in 0 ... 240 {
      timeline.advance(to: 0.05 + Double(frame) / 120)
      try expectBottomPoint(reachedPoint, in: timeline.layout)
    }
    #expect(!timeline.isAnimating)
    #expect(timeline.intent != .latest)
  }

  @Test func `top inset update during keyboard motion keeps ownership at the usable bottom`() throws {
    var timeline = reader()
    var keyboard = viewport
    keyboard.bottomInset = 250
    timeline.resize(viewport: keyboard, animated: true, at: 0)
    timeline.advance(to: 0.05)
    let point = try bottomPoint(in: timeline.layout)
    let origin = timeline.layout.originY
    let presented = timeline.layout.viewport
    #expect(presented.bottomInset != keyboard.bottomInset)
    var toolbar = keyboard
    toolbar.topInset = 135
    timeline.resize(viewport: toolbar, animated: true, at: 0.05)
    #expect(abs(timeline.layout.originY - origin) < 0.001)
    #expect(timeline.layout.viewport == presented)
    guard case let .reading(anchor) = timeline.intent else {
      Issue.record("Toolbar update lost the keyboard reading anchor")
      return
    }
    #expect(anchor.edge == .bottom)
    for frame in 0 ... 240 {
      timeline.advance(to: 0.05 + Double(frame) / 120)
      try expectBottomPoint(point, in: timeline.layout)
    }
    #expect(!timeline.isAnimating)
    #expect(timeline.layout.viewport == toolbar)
  }

  @Test(arguments: [false, true])
  func `atomic data and height changes preserve the actual bottom visible row while inset changes`(animated: Bool) throws {
    var timeline = reader()
    let point = try bottomPoint(in: timeline.layout)
    let topRow = try #require(timeline.layout.anchor()?.id)
    #expect(point.id - 2 > topRow)
    var changed = rows(-10 ..< 120)
    let editedIndex = try #require(changed.firstIndex { $0.id == point.id - 2 })
    changed[editedIndex].height = 341
    var target = viewport
    target.bottomInset = 240
    timeline.apply(rows: changed, viewport: target, animated: animated, at: 0)
    for frame in 0 ... 240 {
      timeline.advance(to: Double(frame) / 120)
      try expectBottomPoint(point, in: timeline.layout)
    }
    #expect(!timeline.isAnimating)
    #expect(timeline.intent != .latest)
  }

  @Test func `simultaneous top and bottom insets use bottom anchoring in middle history`() throws {
    var timeline = reader()
    let point = try bottomPoint(in: timeline.layout)
    var target = viewport
    target.topInset = 135
    target.bottomInset = 225
    timeline.resize(viewport: target, animated: true, at: 0)
    for frame in 0 ... 240 {
      timeline.advance(to: Double(frame) / 120)
      try expectBottomPoint(point, in: timeline.layout)
    }
    #expect(timeline.layout.viewport == target)
  }

  @Test func `bottom anchoring obeys legal clamp and retargets the actually presented bottom after clamping`() throws {
    var initial = viewport
    initial.bottomInset = 250
    var timeline = reader(viewport: initial)
    timeline.navigate(to: .reading(.init(id: 1, localY: 6)), animated: false, at: 0)
    let oldPoint = try bottomPoint(in: timeline.layout)
    var open = initial
    open.bottomInset = 0
    timeline.resize(viewport: open, animated: true, at: 0)
    for frame in 0 ... 240 {
      timeline.advance(to: Double(frame) / 120)
      try expectBottomPoint(oldPoint, in: timeline.layout)
    }
    #expect(timeline.layout.originY == 0)
    let reachedPoint = try bottomPoint(in: timeline.layout)
    #expect(reachedPoint.id != oldPoint.id)
    var closed = initial
    closed.bottomInset = 210
    timeline.resize(viewport: closed, animated: true, at: 2)
    for frame in 0 ... 240 {
      timeline.advance(to: 2 + Double(frame) / 120)
      try expectBottomPoint(reachedPoint, in: timeline.layout)
    }
  }

  @Test func `explicit top navigation overrides implicit bottom inset policy`() throws {
    var timeline = reader()
    var target = viewport
    target.bottomInset = 240
    let requested = TimelineAnchor(id: 15, localY: 9, viewportY: 23)
    timeline.apply(rows: rows(), viewport: target, intent: .reading(requested), animated: true, at: 0)
    for frame in 0 ... 240 {
      timeline.advance(to: Double(frame) / 120)
      let row = try #require(timeline.layout.placement(for: 15))
      #expect(abs(row.frame.minY + 9 - timeline.layout.readingRect.minY - 23) < 0.001)
    }
    #expect(timeline.intent == .reading(requested))
  }

  @Test func `public session viewport and atomic publication both preserve bottom visible content`() throws {
    let session = ChatListSession<Int, String>(viewport: viewport, now: { 0 })
    defer { session.dispose() }
    func snapshot(_ rows: [TimelineRow<Int>]) -> ChatListSnapshot<Int, String> {
      .init(context: .init(width: viewport.width), items: rows.map {
        .init(id: $0.id, revision: 0, content: "cell \($0.id)", height: $0.height)
      }, history: .init(hasOlder: true, hasNewer: true, isAtLiveEnd: false))
    }
    try session.apply(snapshot(rows()), intent: .reading(.init(id: 40, localY: 12, viewportY: 19)),
                      animation: .none, at: 0)
    let point = try bottomPoint(in: session.timeline.layout)
    var first = viewport
    first.bottomInset = 200
    session.updateViewport(first, animation: .animated, at: 0)
    for frame in 0 ... 12 {
      session.advance(to: Double(frame) / 120)
      try expectBottomPoint(point, in: session.timeline.layout)
    }
    var changed = rows(-10 ..< 120)
    let editedIndex = try #require(changed.firstIndex { $0.id == point.id - 2 })
    changed[editedIndex].height = 300
    var second = viewport
    second.topInset = 100
    second.bottomInset = 110
    try session.apply(snapshot(changed), animation: .animated, at: 0.1, viewport: second)
    for frame in 0 ... 240 {
      session.advance(to: 0.1 + Double(frame) / 120)
      try expectBottomPoint(point, in: session.timeline.layout)
    }
    #expect(session.timeline.intent != .latest)
  }
}
