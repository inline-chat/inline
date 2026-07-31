import Foundation
import InlineKit
import Testing

@Suite("Optimistic message timestamps")
struct OptimisticMessageTimestampTests {
  @Test("floors fractional seconds to match server message dates")
  func floorsFractionalSeconds() {
    let date = Date(timeIntervalSince1970: 1_234.999)

    #expect(optimisticMessageTimestamp(for: date) == 1_234)
  }
}
