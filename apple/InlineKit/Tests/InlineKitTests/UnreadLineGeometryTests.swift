import CoreGraphics
import Foundation
@testable import InlineKit
import Testing

/// Property checks for the unread line's scroll math, over an exhaustive grid and seeded random
/// geometry. Each property is one sentence of the contract in `UnreadLineGeometry`.
@Suite("Unread line geometry")
struct UnreadLineGeometryTests {
  private static let tolerance = UnreadLineGeometry.tolerance

  /// Exhaustive grid: line, document, viewport and both insets.
  private static func grid() -> [UnreadLineGeometry] {
    var out: [UnreadLineGeometry] = []
    for document in stride(from: CGFloat(0), through: 1_800, by: 60) {
      for line in stride(from: CGFloat(0), through: document, by: 30) {
        for viewport in [CGFloat(240), 600, 1_100] {
          for top: CGFloat in [0, 52, 96] {
            for bottom in [CGFloat(0), 64, 180] {
              out.append(.init(
                lineTop: line, documentHeight: document, viewportHeight: viewport,
                topInset: top, bottomInset: bottom
              ))
            }
          }
        }
      }
    }
    return out
  }

  private static func random(_ rng: inout SplitMix64) -> UnreadLineGeometry {
    let document = rng.cgFloat(0 ... 20_000)
    return .init(
      lineTop: rng.cgFloat(0 ... document),
      documentHeight: document,
      viewportHeight: rng.cgFloat(120 ... 1_600),
      topInset: rng.cgFloat(0 ... 160),
      bottomInset: rng.cgFloat(0 ... 400)
    )
  }

  private static var cases: [UnreadLineGeometry] {
    var rng = SplitMix64(seed: 0x5EED_0F_0E)
    return grid() + (0 ..< 50_000).map { _ in random(&rng) }
  }

  /// Visible distance of the line below the top inset at a given origin.
  private static func lineOffset(_ g: UnreadLineGeometry, origin: CGFloat) -> CGFloat {
    g.lineTop - origin - g.topInset
  }

  @Test func gridIsLarge() {
    #expect(Self.grid().count > 25_000)
  }

  @Test func originsStayInTheScrollRange() {
    for g in Self.cases {
      let range = g.scrollRange
      if let landing = g.landingOrigin {
        #expect(range.contains(landing), "\(g)")
      }
      for hold in [CGFloat(0), 12, -30, 400] {
        #expect(range.contains(g.heldOrigin(hold: hold)), "\(g) hold \(hold)")
      }
    }
  }

  /// A landing puts the line exactly at the top inset unless the document starts below it.
  @Test func landingPutsTheLineAtTheTopInset() {
    for g in Self.cases {
      guard let landing = g.landingOrigin else { continue }
      if g.lineTop - g.topInset >= g.scrollRange.lowerBound {
        #expect(abs(Self.lineOffset(g, origin: landing)) < 0.001, "\(g)")
      } else {
        #expect(Self.lineOffset(g, origin: landing) > 0, "\(g)")
      }
    }
  }

  /// No landing exactly when everything from the line down fits on screen, and then the bottom
  /// still shows the line below the top inset, never under the toolbar.
  @Test func noLandingOnlyWhenTheRestFitsAndTheLineStaysVisible() {
    for g in Self.cases {
      let restFits = (g.documentHeight - g.lineTop) + g.bottomInset + g.topInset
        <= g.viewportHeight + Self.tolerance
      #expect((g.landingOrigin == nil) == restFits, "\(g)")
      if g.landingOrigin == nil {
        #expect(Self.lineOffset(g, origin: g.scrollRange.upperBound) >= -Self.tolerance, "\(g)")
      }
    }
  }

  /// Re-deriving a held origin from the geometry it produced never moves it: no oscillation.
  @Test func heldOriginIsAFixedPoint() {
    for g in Self.cases {
      let first = g.heldOrigin(hold: 0)
      #expect(g.heldOrigin(hold: 0) == first)
      if let landing = g.landingOrigin {
        #expect(abs(g.heldOrigin(hold: 0) - landing) < 0.001, "landing and hold disagree \(g)")
      }
    }
  }

  /// Rows added or growing above the line move the origin by exactly their height, so the line
  /// does not move on screen (older history, a photo above loading).
  @Test func growthAboveTheLineDoesNotMoveIt() {
    var rng = SplitMix64(seed: 1)
    for g in Self.cases {
      let d = rng.cgFloat(1 ... 3_000)
      var grown = g
      grown.lineTop += d
      grown.documentHeight += d
      // The rows from the line down are unchanged, so a chat that lands on the line still does,
      // with the line exactly where it was.
      #expect((g.landingOrigin == nil) == (grown.landingOrigin == nil), "\(g) +\(d)")
      if g.landingOrigin != nil {
        let before = g.heldOrigin(hold: 0)
        let after = grown.heldOrigin(hold: 0)
        #expect(abs(Self.lineOffset(grown, origin: after) - Self.lineOffset(g, origin: before)) < 0.001, "\(g)")
      }
    }
  }

  /// Rows added or growing below the line never move a held origin (newer page, edits below).
  @Test func growthBelowTheLineDoesNotMoveIt() {
    var rng = SplitMix64(seed: 2)
    for g in Self.cases {
      var grown = g
      grown.documentHeight += rng.cgFloat(1 ... 3_000)
      let before = g.heldOrigin(hold: 0)
      if before == g.lineTop - g.topInset {
        #expect(grown.heldOrigin(hold: 0) == before, "\(g)")
      } else {
        // Clamped at the bottom: more content lets it move toward the hold, never away.
        #expect(Self.lineOffset(grown, origin: grown.heldOrigin(hold: 0)).magnitude
          <= Self.lineOffset(g, origin: before).magnitude + 0.001, "\(g)")
      }
    }
  }

  /// A top inset change (pinned header) keeps the line at the new inset edge.
  @Test func topInsetChangesKeepTheLineAtTheEdge() {
    var rng = SplitMix64(seed: 3)
    for g in Self.cases {
      var changed = g
      changed.topInset = rng.cgFloat(0 ... 160)
      let origin = changed.heldOrigin(hold: 0)
      if origin == changed.lineTop - changed.topInset {
        #expect(abs(Self.lineOffset(changed, origin: origin)) < 0.001, "\(changed)")
      }
    }
  }

  /// A bottom inset change (compose growing) never moves a line that is not clamped.
  @Test func bottomInsetChangesDoNotMoveAHeldLine() {
    var rng = SplitMix64(seed: 4)
    for g in Self.cases {
      var changed = g
      changed.bottomInset = rng.cgFloat(0 ... 400)
      let before = g.heldOrigin(hold: 0)
      let after = changed.heldOrigin(hold: 0)
      if before == g.lineTop - g.topInset, after == changed.lineTop - changed.topInset {
        #expect(before == after, "\(g)")
      }
    }
  }

  /// No amplification: the origin never moves more than the geometry did. Every correction is
  /// at most the change that caused it, so the hold cannot produce a jump of its own.
  @Test func originIsOneLipschitzInTheGeometry() {
    var rng = SplitMix64(seed: 5)
    for g in Self.cases {
      var h = g
      h.lineTop = max(0, h.lineTop + rng.cgFloat(-200 ... 200))
      h.documentHeight = max(h.lineTop, h.documentHeight + rng.cgFloat(-200 ... 200))
      h.viewportHeight = max(1, h.viewportHeight + rng.cgFloat(-200 ... 200))
      h.topInset = max(0, h.topInset + rng.cgFloat(-50 ... 50))
      h.bottomInset = max(0, h.bottomInset + rng.cgFloat(-50 ... 50))
      let bound = abs(h.lineTop - g.lineTop) + abs(h.documentHeight - g.documentHeight)
        + abs(h.viewportHeight - g.viewportHeight) + abs(h.topInset - g.topInset)
        + abs(h.bottomInset - g.bottomInset)
      #expect(abs(h.heldOrigin(hold: 0) - g.heldOrigin(hold: 0)) <= bound + 0.001, "\(g) -> \(h)")
    }
  }
}

/// Small deterministic generator, so a failing case can be replayed from its seed.
struct SplitMix64 {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

  mutating func cgFloat(_ range: ClosedRange<CGFloat>) -> CGFloat {
    range.lowerBound + CGFloat(unit()) * (range.upperBound - range.lowerBound)
  }

  mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
  }

  mutating func chance(_ p: Double) -> Bool { unit() < p }
}
