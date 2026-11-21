import CoreGraphics
import Foundation
import Testing
@testable import ChatListCore

struct ChatListInvariantTests {
  struct Random {
    var state: UInt64
    mutating func next(_ limit: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 32) % UInt64(limit))
    }
  }

  @Test func `seeded transactions preserve reader at every unclamped sample`() throws {
    for seed in 1 ... 64 {
      var random = Random(state: UInt64(seed))
      var viewport = TimelineViewport(width: 600, height: 600, topInset: 40, bottomInset: 60)
      var rows = (0 ..< 40).map { TimelineRow(id: $0, height: CGFloat(80 + random.next(200))) }
      rows[20].height = 4_000
      var timeline = MessageTimeline<Int>(viewport: viewport)
      var anchor = TimelineAnchor(id: 20, localY: 1_600, viewportY: 120)
      timeline.apply(rows: rows, viewport: viewport, intent: .reading(anchor), animated: false, at: 0)
      var time = 0.0
      for event in 0 ..< 32 {
        if event % 8 == 5 {
          // Give alternate top-only updates a definitely settled bottom;
          // the others deliberately arrive during its visible spring motion.
          time += 3
          timeline.advance(to: time)
        }
        // Keep a tall surviving witness, while changing both sides, width,
        // occlusion, and geometry in the same publication.
        let index = random.next(rows.count)
        if rows[index].id != 20 { rows[index].height = CGFloat(10 + random.next(900)) }
        if event % 4 == 0 { rows.insert(.init(id: -event - 1, height: CGFloat(random.next(400))), at: 0) }
        if event % 5 == 0 { rows.append(.init(id: 100 + event, height: CGFloat(random.next(500)))) }
        if event % 7 == 0, rows[2].id != 20 { rows.remove(at: 2) }
        let oldTarget = viewport
        let nextTop = CGFloat(random.next(150))
        var nextBottom = CGFloat(random.next(200))
        if event % 8 == 0, nextBottom == oldTarget.bottomInset {
          nextBottom = oldTarget.bottomInset == 199 ? 198 : oldTarget.bottomInset + 1
        }
        // Exercise both edges, top only, geometry only, and bottom only.
        // Geometry-only publications must retain the preceding edge witness.
        viewport.topInset = event % 4 == 2 || event % 4 == 3 ? oldTarget.topInset : nextTop
        viewport.bottomInset = event % 4 == 1 || event % 4 == 2 ? oldTarget.bottomInset : nextBottom
        viewport.width = CGFloat(300 + random.next(600))
        let bottomChanged = viewport.bottomInset != oldTarget.bottomInset
        let topChanged = viewport.topInset != oldTarget.topInset
        let bottomInMotion = timeline.layout.viewport.bottomInset != oldTarget.bottomInset
        if bottomChanged || (topChanged && bottomInMotion) {
          // Independently sample the actual bottom-visible point before this
          // transaction changes rows or geometry; do not use layout.anchor().
          let before = timeline.layout
          let bottom = before.originY + before.viewport.height - before.viewport.bottomInset
          let row = try #require(before.rows.last {
            !$0.isExiting && $0.row.canAnchor && $0.frame.height > 0
              && $0.frame.minY < bottom && $0.frame.maxY > before.readingRect.minY
          })
          let localY = min(row.frame.height, max(0, bottom - row.frame.minY))
          anchor = .init(id: row.row.id, localY: localY,
                         viewportY: bottom - row.frame.minY - localY, edge: .bottom)
        } else if topChanged {
          let before = timeline.layout
          let row = try #require(before.rows.first {
            !$0.isExiting && $0.row.canAnchor && $0.frame.height > 0
              && $0.frame.maxY > before.readingRect.minY && $0.frame.minY < before.readingRect.maxY
          })
          anchor = .init(id: row.row.id, localY: before.readingRect.minY - row.frame.minY)
        }
        timeline.apply(rows: rows, viewport: viewport, animated: true, at: time)
        for frame in 0 ..< 17 {
          time += frame % 3 == 0 ? 1.0 / 60 : 1.0 / 120
          timeline.advance(to: time)
          let layout = timeline.layout
          let witness = try #require(layout.placement(for: anchor.id))
          let documentY = witness.frame.minY + min(anchor.localY, witness.frame.height)
          let viewportY = anchor.edge == .top
            ? layout.viewport.topInset + anchor.viewportY
            : layout.viewport.height - layout.viewport.bottomInset - anchor.viewportY
          let desired = documentY - viewportY
          #expect(abs(layout.originY - min(layout.maximumOrigin, max(0, desired))) < 0.001)
          // An independent adjacency and extent oracle detects correct origins
          // paired with incorrectly installed row geometry.
          for pair in zip(layout.rows, layout.rows.dropFirst()) {
            #expect(abs(pair.0.frame.maxY - pair.1.frame.minY) < 0.001)
          }
          let last = try #require(layout.rows.last)
          #expect(abs(layout.contentHeight - max(layout.viewport.height, last.frame.maxY + layout.viewport.bottomInset)) < 0.001)
        }
      }
      timeline.advance(to: time + 3)
      var y = viewport.topInset
      for row in rows {
        let actual = try #require(timeline.layout.placement(for: row.id))
        #expect(abs(actual.frame.minY - y) < 0.001)
        #expect(abs(actual.frame.height - row.height) < 0.001)
        y += row.height
      }
    }
  }

  @Test func `sticky decorations use presented group bounds and inset sample`() throws {
    let viewport = TimelineViewport(width: 500, height: 500, topInset: 50, bottomInset: 80)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var rows = (0 ..< 40).map { TimelineRow(id: $0, height: 80) }
    timeline.apply(rows: rows, viewport: viewport, intent: .reading(.init(id: 15)), animated: false, at: 0)
    let badge = ChatListDecoration(id: "date", firstRow: 10, lastRow: 20, edge: .top,
                                   x: 200, size: CGSize(width: 80, height: 24), inset: 4)
    let avatar = ChatListDecoration(id: "avatar", firstRow: 10, lastRow: 20, edge: .bottom,
                                    x: 10, size: CGSize(width: 30, height: 30), inset: 3)
    rows[12].height = 500
    timeline.apply(rows: rows, viewport: .init(width: 500, height: 500, topInset: 100, bottomInset: 120),
                   animated: true, at: 0)
    for frame in 0 ... 120 {
      timeline.advance(to: Double(frame) / 120)
      let layout = timeline.layout
      let top = try #require(badge.placement(in: layout))
      let bottom = try #require(avatar.placement(in: layout))
      #expect(abs(top.frame.minY - layout.viewport.topInset - 4) < 0.001)
      #expect(abs(bottom.frame.maxY - (layout.viewport.height - layout.viewport.bottomInset - 3)) < 0.001)
    }
  }

  @Test func `negative control total extent compensation moves reader on append`() throws {
    let viewport = TimelineViewport(width: 500, height: 500)
    var timeline = MessageTimeline<Int>(viewport: viewport)
    var rows = (0 ..< 40).map { TimelineRow(id: $0, height: 80) }
    timeline.apply(rows: rows, viewport: viewport, intent: .reading(.init(id: 15)), animated: false, at: 0)
    let old = timeline.layout
    rows.append(.init(id: 41, height: 900))
    timeline.apply(rows: rows, viewport: viewport, animated: false, at: 0)
    let naiveOrigin = old.originY + timeline.layout.contentHeight - old.contentHeight
    #expect(abs(naiveOrigin - timeline.layout.originY) == 900)
    #expect(timeline.layout.originY == old.originY)
  }
}
