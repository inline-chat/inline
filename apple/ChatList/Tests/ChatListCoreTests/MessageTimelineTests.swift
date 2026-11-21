import Foundation
@testable import ChatListCore
import Testing

struct MessageTimelineTests {
  private let viewport = TimelineViewport(width: 600, height: 600, topInset: 64, bottomInset: 72)

  private func rows(_ range: Range<Int>, height: CGFloat = 40) -> [TimelineRow<Int>] {
    range.map { .init(id: $0, height: height) }
  }

  @Test func `renderer anchor refinement preserves springs and survives release at settle`() throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var initial = rows(0 ..< 40)
    initial[15] = .init(id: 15, height: 900, elements: ["paragraph": CGRect(x: 0, y: 100, width: 500, height: 700)])
    timeline.apply(
      rows: initial,
      viewport: viewport,
      intent: .reading(.init(id: 15, localY: 300)),
      animated: false,
      at: 0
    )
    var target = initial
    target[15] = .init(id: 15, height: 1_200, elements: ["paragraph": CGRect(x: 0, y: 400, width: 500, height: 700)])
    timeline.apply(rows: target, viewport: viewport, animated: true, at: 0)
    var reference = timeline
    for frame in 0 ... 240 {
      let time = Double(frame) / 120
      timeline.advance(to: time)
      reference.advance(to: time)
      let row = try #require(timeline.layout.placement(for: 15))
      let localY = try #require(row.row.elements["paragraph"]?.minY) + 200
      let refinement1 = timeline.refineReadingAnchor(.init(id: 15, localY: localY))
      #expect(refinement1)
      #expect(abs(row.frame.minY + localY - timeline.layout.readingRect.minY) < 0.001)
      #expect(timeline.layout.rows.map(\.frame) == reference.layout.rows.map(\.frame))
      #expect(timeline.layout.rows.map(\.row.elements) == reference.layout.rows.map(\.row.elements))
      #expect(timeline.isAnimating == reference.isAnimating)
    }
    let origin = timeline.layout.originY
    timeline.advance(to: 3)
    #expect(!timeline.isAnimating)
    #expect(timeline.layout.originY == origin)
    #expect(timeline.intent == .reading(.init(id: 15, localY: 600)))
  }

  @Test func `renderer anchor refinement respects latest navigation overscroll and invalid coordinates`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 50), viewport: viewport, animated: false, at: 0)
    let anchor = TimelineAnchor(id: 15, localY: 10)
    let refinement2 = !timeline.refineReadingAnchor(anchor)
    #expect(refinement2)
    timeline.navigate(to: .reading(anchor), animated: true, at: 0)
    let refinement3 = !timeline.refineReadingAnchor(anchor)
    #expect(refinement3)
    timeline.beginUserScroll(at: -20)
    let refinement4 = !timeline.refineReadingAnchor(anchor)
    #expect(refinement4)
    timeline.endUserScroll(at: 500, canFollowLatest: false)
    let before = timeline.layout.originY
    let refinement5 = !timeline.refineReadingAnchor(.init(id: 999))
    #expect(refinement5)
    let refinement6 = !timeline.refineReadingAnchor(.init(id: 15, localY: .nan))
    #expect(refinement6)
    let refinement7 = !timeline.refineReadingAnchor(.init(id: 15, viewportY: .infinity))
    #expect(refinement7)
    #expect(timeline.layout.originY == before)
  }

  @Test func `short conversation aligns above composer`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 2), viewport: viewport, animated: false, at: 0)
    #expect(timeline.layout.rows.first?.frame.minY == 448)
    #expect(timeline.layout.rows.last?.frame.maxY == 528)
    #expect(timeline.layout.originY == 0)
    #expect(timeline.layout.contentHeight == 600)
  }

  @Test(arguments: [
    false,
    true
  ]) func `simultaneous prepend append and height edit preserve reader`(animated: Bool) throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(10 ..< 60), viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 25, localY: 13)), animated: false, at: 0)
    var next = rows(0 ..< 80)
    next[4].height = 900
    next[50].height = 250
    timeline.apply(rows: next, viewport: viewport, animated: animated, at: 0)
    for frame in 0 ... 180 {
      timeline.advance(to: Double(frame) / 120)
      let anchor = try #require(timeline.layout.placement(for: 25)?.frame.minY) + 13
      #expect(abs(anchor - timeline.layout.readingRect.minY) < 0.001)
      checkExtent(timeline.layout)
    }
    #expect(!timeline.isAnimating)
  }

  @Test(arguments: [60, 120]) func `unread slot and message internals share clock`(hz: Int) throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var initial = rows(0 ..< 50)
    initial[20] = .init(id: 20, height: 80, elements: ["footer": CGRect(x: 0, y: 60, width: 50, height: 20)])
    timeline.apply(rows: initial, viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 21, viewportY: 90)), animated: false, at: 0)
    var target = initial
    target[20] = .init(id: 20, height: 300, elements: ["footer": CGRect(x: 0, y: 280, width: 50, height: 20)])
    target.insert(.init(id: -1, height: 32), at: 10)
    timeline.apply(rows: target, viewport: viewport, animated: true, at: 0)
    for frame in 0 ... hz {
      timeline.advance(to: Double(frame) / Double(hz))
      let row = try #require(timeline.layout.placement(for: 20))
      #expect(try abs(#require(row.row.elements["footer"]?.maxY) - row.frame.height) < 0.001)
      #expect(
        try abs(#require(timeline.layout.placement(for: 21)?.frame.minY) - timeline.layout.readingRect.minY - 90) <
          0.001
      )
    }
  }

  @Test func `latest tracks current extent during inset and streaming changes`() throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 30), viewport: viewport, animated: false, at: 0)
    var grown = viewport
    grown.bottomInset = 230
    timeline.apply(rows: rows(0 ..< 33), viewport: grown, animated: true, at: 0)
    for frame in 0 ... 120 {
      timeline.advance(to: Double(frame) / 120)
      #expect(try abs(#require(timeline.layout.rows.last?.frame.maxY) - timeline.layout.readingRect.maxY) < 0.001)
    }
  }

  @Test func `retarget starts at presentation without velocity reset`() throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 30), viewport: viewport, animated: false, at: 0)
    timeline.apply(rows: rows(0 ..< 30, height: 80), viewport: viewport, animated: true, at: 0)
    timeline.advance(to: 0.06)
    let before = try #require(timeline.layout.placement(for: 15)?.frame)
    timeline.apply(rows: rows(0 ..< 30, height: 120), viewport: viewport, animated: true, at: 0.06)
    #expect(timeline.layout.placement(for: 15)?.frame == before)
    timeline.advance(to: 0.061)
    #expect(try #require(timeline.layout.placement(for: 15)?.frame.height) > before.height)
  }

  @Test func `deleted anchor preserves surviving neighbor screen coordinate`() throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 50), viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 20, localY: 18)), animated: false, at: 0)
    let expected = try #require(timeline.layout.placement(for: 21)?.frame.minY) - timeline.layout.readingRect.minY
    timeline.apply(rows: rows(0 ..< 50).filter { $0.id != 20 }, viewport: viewport, animated: true, at: 0)
    for frame in 0 ... 120 {
      timeline.advance(to: Double(frame) / 120)
      #expect(try abs(#require(timeline.layout.placement(for: 21)?.frame.minY) - timeline.layout.readingRect
          .minY - expected) < 0.001)
    }
    #expect(timeline.layout.placement(for: 20) == nil)
  }

  @Test func `width and occlusion change retain bottom visible coordinate`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 50), viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 20, localY: 7)), animated: false, at: 0)
    let bottom = timeline.layout.anchor(edge: .bottom)!
    var narrow = viewport
    narrow.width = 240
    narrow.topInset = 110
    narrow.bottomInset = 220
    narrow.height = 500
    timeline.apply(rows: rows(0 ..< 50, height: 100), viewport: narrow, animated: false, at: 1)
    #expect(abs(timeline.layout.readingRect.maxY - timeline.layout.placement(for: bottom.id)!.frame.minY
      - bottom.localY - bottom.viewportY) < 0.001)
    #expect(timeline.layout.rows.allSatisfy { $0.frame.width == 240 })
    checkExtent(timeline.layout)
  }

  @Test func `wheel revokes latest before synchronous append`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 50), viewport: viewport, animated: false, at: 0)
    let origin = timeline.layout.originY
    timeline.beginUserScroll(at: origin)
    timeline.apply(rows: rows(0 ..< 51), viewport: viewport, animated: false, at: 0)
    #expect(timeline.layout.originY == origin)
    timeline.userScrolled(to: origin - 50)
    #expect(timeline.layout.originY == origin - 50)
    timeline.endUserScroll(at: origin - 50, canFollowLatest: true)
    #expect(timeline.intent != .latest)
  }

  @Test func `uncached newer history cannot certify latest`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 50), viewport: viewport, animated: false, at: 0)
    timeline.beginUserScroll(at: timeline.layout.maximumOrigin)
    timeline.endUserScroll(at: timeline.layout.maximumOrigin, canFollowLatest: false)
    #expect(timeline.intent != .latest)
  }

  @Test func `user interrupts navigation at actual position`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 80), viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 3)), animated: true, at: 0)
    timeline.advance(to: 0.1)
    let origin = timeline.layout.originY
    timeline.beginUserScroll(at: origin)
    timeline.userScrolled(to: origin + 11)
    timeline.advance(to: 4)
    #expect(abs(timeline.layout.originY - origin - 11) < 0.001)
  }

  @Test func `delayed display callback settles without overshoot`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 50), viewport: viewport, animated: false, at: 0)
    timeline.apply(rows: rows(0 ..< 55, height: 80), viewport: viewport, animated: true, at: 0)
    timeline.advance(to: 8)
    #expect(!timeline.isAnimating)
    #expect(timeline.layout.rows.count == 55)
    #expect(timeline.layout.rows.allSatisfy { $0.frame.height == 80 })
    checkExtent(timeline.layout)
  }

  @Test func `range lookup matches independent linear oracle`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    let input = (0 ..< 400).map { TimelineRow(id: $0, height: CGFloat(($0 * 97) % 300 + 1)) }
    timeline.apply(rows: input, viewport: viewport, animated: false, at: 0)
    for index in 0 ..< 1_000 {
      let rect = CGRect(x: 0, y: CGFloat((index * 193) % 60_000), width: 600, height: CGFloat(index % 800 + 1))
      let expected = timeline.layout.rows.filter { $0.frame.maxY > rect.minY && $0.frame.minY < rect.maxY }
        .map(\.row.id)
      let actual = timeline.layout.rows[timeline.layout.visibleRows(in: rect)].map(\.row.id)
      #expect(actual == expected)
    }
  }

  @Test func `removing everything produces finite empty viewport`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 50), viewport: viewport, animated: false, at: 0)
    timeline.apply(rows: [], viewport: viewport, animated: true, at: 0)
    timeline.advance(to: 1)
    #expect(timeline.layout.rows.isEmpty)
    #expect(timeline.layout.contentHeight == viewport.height)
    #expect(timeline.layout.originY == 0)
  }

  @Test func `moving unread divider cannot become the reading anchor`() throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var initial = rows(0 ..< 60)
    initial.insert(.init(id: -1, height: 32, canAnchor: false), at: 20)
    timeline.apply(rows: initial, viewport: viewport, animated: false, at: 0)
    let dividerTop = try #require(timeline.layout.placement(for: -1)?.frame.minY)
    timeline.beginUserScroll(at: dividerTop - viewport.topInset + 5)
    let expected = try #require(timeline.layout.placement(for: 20)?.frame.minY) - timeline.layout.readingRect.minY
    var changed = rows(0 ..< 60)
    changed.insert(.init(id: -1, height: 32, canAnchor: false), at: 50)
    timeline.apply(rows: changed, viewport: viewport, animated: true, at: 0)
    for frame in 0 ... 120 {
      timeline.advance(to: Double(frame) / 120)
      #expect(try abs(#require(timeline.layout.placement(for: 20)?.frame.minY) - timeline.layout.readingRect
          .minY - expected) < 0.001)
    }
  }

  @Test func `explicit window destination cancels old navigation spring`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 100), viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 5)), animated: true, at: 0)
    timeline.advance(to: 0.03)
    timeline.apply(
      rows: rows(200 ..< 300),
      viewport: viewport,
      intent: .reading(.init(id: 220)),
      animated: false,
      at: 0.03
    )
    #expect(!timeline.isAnimating)
    #expect(timeline.layout.readingRect.minY == timeline.layout.placement(for: 220)!.frame.minY)
  }

  private func checkExtent(_ layout: TimelineLayout<Int>, sourceLocation: SourceLocation = #_sourceLocation) {
    for (previous, next) in zip(layout.rows, layout.rows.dropFirst()) {
      #expect(abs(previous.frame.maxY - next.frame.minY) < 0.001, sourceLocation: sourceLocation)
    }
    #expect(layout.originY >= 0 && layout.originY <= layout.maximumOrigin, sourceLocation: sourceLocation)
    #expect(layout.contentHeight >= layout.viewport.height, sourceLocation: sourceLocation)
    if let last = layout.rows.last {
      #expect(
        abs(last.frame.maxY + layout.viewport.bottomInset - layout.contentHeight) < 0.001,
        sourceLocation: sourceLocation
      )
    }
  }

  @Test func `rebasing clock after native overscroll does not finish paused animation`() {
    let viewport = TimelineViewport(width: 600, height: 600)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: [.init(id: 1, height: 1_000)], viewport: viewport, animated: false, at: 0)
    timeline.apply(rows: [.init(id: 1, height: 1_500)], viewport: viewport, animated: true, at: 0)
    timeline.advance(to: 0.05)
    let before = timeline.layout.contentHeight
    timeline.synchronizeClock(at: 10)
    timeline.advance(to: 10 + 1.0 / 120)
    #expect(timeline.layout.contentHeight > before)
    #expect(timeline.layout.contentHeight < 1_500)
    timeline.advance(to: 11)
    #expect(timeline.layout.contentHeight == 1_500)
  }

  @Test(arguments: [
    false,
    true
  ]) func `shrinking anchored row keeps reader at surviving content`(animated: Bool) throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var content = rows(0 ..< 40, height: 100)
    content[15].height = 1_000
    timeline.apply(rows: content, viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 15, localY: 700)), animated: false, at: 0)
    content[15].height = 100
    timeline.apply(rows: content, viewport: viewport, animated: animated, at: 0)
    for frame in 0 ... 180 {
      timeline.advance(to: Double(frame) / 120)
      let row = try #require(timeline.layout.placement(for: 15))
      #expect(abs(timeline.layout.readingRect.minY - row.frame.minY - min(700, row.frame.height)) < 0.001)
      #expect(timeline.layout.readingRect.minY <= row.frame.maxY + 0.001)
    }
    #expect(timeline.intent == .reading(.init(id: 15, localY: 100)))
    content[15].height = 1_000
    timeline.apply(rows: content, viewport: viewport, animated: false, at: 2)
    #expect(timeline.intent == .reading(.init(id: 15, localY: 100)))
    #expect(try abs(timeline.layout.readingRect.minY - #require(timeline.layout.placement(for: 15)).frame.minY - 100) <
      0.001)
  }

  @Test func `interrupted collapse retains the presented coordinate through growth and another collapse`() throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var content = rows(0 ..< 40, height: 100)
    content[15].height = 1_000
    timeline.apply(rows: content, viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 15, localY: 700)), animated: false, at: 0)
    content[15].height = 100
    timeline.apply(rows: content, viewport: viewport, animated: true, at: 0)
    let time = 0.1
    let step = 0.00001
    timeline.advance(to: time - step)
    let previousOrigin = timeline.layout.originY
    timeline.advance(to: time)
    let currentOrigin = timeline.layout.originY
    let incomingVelocity = (currentOrigin - previousOrigin) / step
    let resolved = try #require(timeline.layout.placement(for: 15)).frame.height
    #expect(resolved < 700)
    content[15].height = 1_200
    timeline.apply(rows: content, viewport: viewport, animated: true, at: time)
    #expect(timeline.layout.originY == currentOrigin)
    #expect(timeline.intent == .reading(.init(id: 15, localY: resolved)))
    timeline.advance(to: time + step)
    let outgoingVelocity = (timeline.layout.originY - currentOrigin) / step
    #expect(abs(outgoingVelocity - incomingVelocity) < abs(incomingVelocity) * 0.01)
    timeline.advance(to: 2)
    #expect(try abs(timeline.layout.readingRect.minY - #require(timeline.layout.placement(for: 15)).frame
        .minY - resolved) < 0.001)
    content[15].height = 60
    timeline.apply(rows: content, viewport: viewport, animated: true, at: 2)
    timeline.advance(to: 4)
    #expect(timeline.intent == .reading(.init(id: 15, localY: 60)))
  }

  @Test func `shrinking anchor preserves negative gap offset`() throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var content = rows(0 ..< 40, height: 100)
    timeline.apply(rows: content, viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 15, localY: -28)), animated: false, at: 0)
    content[15].height = 20
    timeline.apply(rows: content, viewport: viewport, animated: true, at: 0)
    timeline.advance(to: 2)
    #expect(timeline.intent == .reading(.init(id: 15, localY: -28)))
    #expect(try abs(timeline.layout.readingRect.minY - #require(timeline.layout.placement(for: 15)).frame.minY + 28) <
      0.001)
  }

  @Test func `explicit coordinate survives zero height insertion and growing retarget`() throws {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var content = rows(0 ..< 40, height: 100)
    timeline.apply(rows: content, viewport: viewport, animated: false, at: 0)
    content.insert(.init(id: 100, height: 1_000), at: 15)
    let destination = TimelineIntent<Int>.reading(.init(id: 100, localY: 700))
    timeline.apply(rows: content, viewport: viewport, intent: destination, animated: true, at: 0)
    #expect(timeline.layout.placement(for: 100)?.frame.height == 0)
    #expect(timeline.intent == destination)
    timeline.advance(to: 0.05)
    #expect(try #require(timeline.layout.placement(for: 100)).frame.height < 700)
    content[15].height = 1_200
    timeline.apply(rows: content, viewport: viewport, animated: true, at: 0.05)
    #expect(timeline.intent == destination)
    timeline.advance(to: 2)
    #expect(timeline.intent == destination)
    #expect(try abs(timeline.layout.readingRect.minY - #require(timeline.layout.placement(for: 100)).frame.minY - 700) <
      0.001)
  }

  @Test(arguments: [0, 30]) func `navigation retarget preserves presentation velocity`(destination: Int) {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.apply(rows: rows(0 ..< 50, height: 100), viewport: viewport, animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 2)), animated: false, at: 0)
    timeline.navigate(to: .reading(.init(id: 6)), animated: true, at: 0)
    let time = 0.08
    let step = 0.00001
    timeline.advance(to: time - step)
    let previousOrigin = timeline.layout.originY
    timeline.advance(to: time)
    let currentOrigin = timeline.layout.originY
    let incomingVelocity = (currentOrigin - previousOrigin) / step
    #expect(incomingVelocity > 0)
    timeline.navigate(to: .reading(.init(id: destination)), animated: true, at: time)
    #expect(timeline.layout.originY == currentOrigin)
    timeline.advance(to: time + step)
    let outgoingVelocity = (timeline.layout.originY - currentOrigin) / step
    #expect(abs(outgoingVelocity - incomingVelocity) < abs(incomingVelocity) * 0.01)
    timeline.advance(to: 2)
    #expect(!timeline.isAnimating)
    #expect(timeline.layout.readingRect.minY == timeline.layout.placement(for: destination)!.frame.minY)
  }

  @Test func `avatar handoff retarget keeps position velocity and clock ownership`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    #expect(!timeline.isAnimating)
    let previousAvatarY: CGFloat = 180
    let newOwnerTargetY: CGFloat = 100
    timeline.retargetOverlayOffset(
      for: 42, from: CGPoint(x: 0, y: previousAvatarY - newOwnerTargetY), animated: true
    )
    #expect(newOwnerTargetY + timeline.overlayOffset(for: 42).y == previousAvatarY)
    #expect(timeline.isAnimating) // No row motion is needed to keep the display clock alive.
    timeline.advance(to: 0)

    let time = 0.08
    let step = 0.00001
    timeline.advance(to: time - step)
    let previous = timeline.overlayOffset(for: 42).y
    timeline.advance(to: time)
    let current = timeline.overlayOffset(for: 42).y
    let incomingVelocity = (current - previous) / step
    #expect(incomingVelocity < 0)

    timeline.retargetOverlayOffset(for: 42, from: CGPoint(x: 0, y: current + 20), animated: true)
    #expect(timeline.overlayOffset(for: 42).y == current + 20)
    timeline.advance(to: time + step)
    let outgoingVelocity = (timeline.overlayOffset(for: 42).y - current - 20) / step
    #expect(abs(outgoingVelocity - incomingVelocity) < abs(incomingVelocity) * 0.02)

    timeline.advance(to: 2)
    #expect(timeline.overlayOffset(for: 42) == .zero)
    #expect(!timeline.isAnimating)
  }

  @Test func `avatar handoff pauses during native rubber band clock rebase`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.retargetOverlayOffset(for: 42, from: CGPoint(x: 0, y: 90), animated: true)
    timeline.advance(to: 0)
    timeline.advance(to: 0.04)
    let beforePause = timeline.overlayOffset(for: 42).y
    timeline.synchronizeClock(at: 10)
    timeline.advance(to: 10 + 1.0 / 120)
    let resumed = timeline.overlayOffset(for: 42).y
    #expect(resumed < beforePause)
    #expect(resumed > 0)
    timeline.retainOverlayOffsets(for: [])
    #expect(timeline.overlayOffset(for: 42) == .zero)
    #expect(!timeline.isAnimating)
  }

  @Test func `an older boundary timestamp cannot rewind the presentation clock`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.retargetOverlayOffset(for: 42, from: CGPoint(x: 0, y: 90), animated: true)
    timeline.advance(to: 0)
    timeline.advance(to: 0.08)
    var control = timeline
    timeline.advance(to: 0.04)
    timeline.apply(rows: rows(0 ..< 1), viewport: viewport, animated: true, at: 0.04)
    control.apply(rows: rows(0 ..< 1), viewport: viewport, animated: true, at: 0.08)
    timeline.synchronizeClock(at: 0.03)
    timeline.advance(to: 0.1)
    control.advance(to: 0.1)
    #expect(timeline.overlayOffset(for: 42) == control.overlayOffset(for: 42))
  }

  @Test func `redundant avatar fades on the same clock and can retire at idle`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.retargetOverlayOpacity(for: 7, from: 1, to: 0)
    #expect(timeline.overlayOpacity(for: 7) == 1)
    #expect(timeline.isAnimating)
    timeline.advance(to: 0)
    timeline.advance(to: 0.08)
    let midFade = timeline.overlayOpacity(for: 7)
    #expect(midFade > 0 && midFade < 1)
    timeline.retargetOverlayOpacity(for: 7, from: midFade, to: 0)
    #expect(timeline.overlayOpacity(for: 7) == midFade)
    timeline.advance(to: 2)
    #expect(timeline.overlayOpacity(for: 7) == 0)
    #expect(timeline.isOverlayOpacitySettled(for: 7))
    #expect(!timeline.isAnimating)
    timeline.removeOverlayMotion(for: 7)
    #expect(timeline.overlayOpacity(for: 7) == 1)
  }

  @Test func `new split avatar appears without A second animation clock`() {
    var timeline = MessageTimeline<Int>(viewport: viewport)
    timeline.retargetOverlayOpacity(for: 8, from: 0, to: 1)
    #expect(timeline.overlayOpacity(for: 8) == 0)
    #expect(timeline.isAnimating)
    timeline.advance(to: 0)
    timeline.advance(to: 2)
    #expect(timeline.overlayOpacity(for: 8) == 1)
    #expect(!timeline.isAnimating)
  }
}
