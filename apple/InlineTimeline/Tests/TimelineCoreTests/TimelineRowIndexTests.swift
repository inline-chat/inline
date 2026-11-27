import Testing
@testable import TimelineCore

/// An id whose hash only uses part of it, so distinct ids collide.
private struct Colliding: Hashable, Sendable {
  var value: Int
  func hash(into hasher: inout Hasher) { hasher.combine(value % 3) }
}

@Suite("Row index")
struct TimelineRowIndexTests {
  private func expectPositions<ID>(_ index: TimelineRowIndex<ID>, _ rows: [ID], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(index.count == rows.count, sourceLocation: sourceLocation)
    for (position, id) in rows.enumerated() {
      #expect(index[id] == position, sourceLocation: sourceLocation)
    }
  }

  @Test("Positions after a build, appends and prepends, and a rebuild after a removal")
  func updates() {
    var rows = Array(100 ..< 200)
    var index = TimelineRowIndex(rows)
    expectPositions(index, rows)
    rows += Array(200 ..< 205)
    index.update(rows)
    expectPositions(index, rows)
    rows = Array(40 ..< 100) + rows
    index.update(rows)
    expectPositions(index, rows)
    rows = Array(0 ..< 40) + rows
    index.update(rows)
    expectPositions(index, rows)
    rows.remove(at: 70)
    index.update(rows)
    expectPositions(index, rows)
    #expect(index[70] == nil)
    #expect(index[-1] == nil)
    #expect(index[1000] == nil)
    index.update(rows)
    expectPositions(index, rows)
  }

  @Test("Ids sharing a hash are told apart, through appends and prepends")
  func collisions() {
    var rows = (10 ..< 30).map { Colliding(value: $0) }
    var index = TimelineRowIndex(rows)
    expectPositions(index, rows)
    rows += (30 ..< 33).map { Colliding(value: $0) }
    index.update(rows)
    rows = (0 ..< 10).map { Colliding(value: $0) } + rows
    index.update(rows)
    expectPositions(index, rows)
    #expect(index[Colliding(value: 99)] == nil)
  }

  @Test("A list replaced by another (a far jump's window) is rebuilt")
  func replaced() {
    var index = TimelineRowIndex(Array(0 ..< 50))
    let rows = Array(500 ..< 560)
    index.update(rows)
    expectPositions(index, rows)
    #expect(index[10] == nil)
  }
}
