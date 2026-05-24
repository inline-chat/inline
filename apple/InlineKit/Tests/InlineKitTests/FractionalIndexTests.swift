import Testing

@testable import InlineKit

@Suite("FractionalIndex")
struct FractionalIndexTests {
  @Test("generates sorted append keys")
  func appendsSortedKeys() {
    let keys = FractionalIndex.sequence(count: 10)
    #expect(keys == keys.sorted())
  }

  @Test("generates keys between neighbors")
  func betweenNeighbors() {
    let left = FractionalIndex.after(nil)
    let right = FractionalIndex.after(left)
    let middle = FractionalIndex.between(left, right)

    #expect(left < middle)
    #expect(middle < right)
  }

  @Test("generates prepend keys")
  func prependKeys() {
    let first = FractionalIndex.after(nil)
    let before = FractionalIndex.before(first)

    #expect(before < first)
  }
}

