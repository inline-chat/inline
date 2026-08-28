@testable import InlineKit
import Testing

@Suite("Home space exclusions")
struct HomeSpaceExclusionsTests {
  @Test("round trips a stable sorted local value")
  func roundTrip() {
    let exclusions = HomeSpaceExclusions(spaceIDs: [42, 7, 19])

    #expect(exclusions.rawValue == "7,19,42")
    #expect(HomeSpaceExclusions(rawValue: exclusions.rawValue) == exclusions)
  }

  @Test("ignores malformed local values")
  func malformedValues() {
    let exclusions = HomeSpaceExclusions(rawValue: "7,nope,,42")

    #expect(exclusions.spaceIDs == [7, 42])
  }

  @Test("keeps Home chats and filters only selected spaces")
  func homeProjection() {
    let exclusions = HomeSpaceExclusions(spaceIDs: [42])

    #expect(exclusions.includesInHome(spaceID: nil))
    #expect(exclusions.includesInHome(spaceID: 7))
    #expect(exclusions.includesInHome(spaceID: 42) == false)
  }

  @Test("toggle adds and removes one space")
  func toggle() {
    let included = HomeSpaceExclusions.empty.toggling(42)
    let restored = included.toggling(42)

    #expect(included.spaceIDs == [42])
    #expect(restored == .empty)
  }
}
