import Testing

@testable import InlineIOSUI

@Suite("Message layout stability")
struct MessageLayoutStabilityTests {
  @Test("large URL previews use a fixed maximum bubble width")
  func largeURLPreviewsUseFixedMaximumBubbleWidth() {
    #expect(MessageBubbleWidthPolicy.mode(hasLargeURLPreview: true) == .fixedMaximum)
    #expect(MessageBubbleWidthPolicy.maximumWidthFraction == 0.9)
  }

  @Test("ordinary messages retain content-sized bubbles")
  func ordinaryMessagesRetainContentSizedBubbles() {
    #expect(MessageBubbleWidthPolicy.mode(hasLargeURLPreview: false) == .contentSizedUpToMaximum)
  }

  @Test("stable repeated measurements pass through unchanged")
  func stableRepeatedMeasurementsPassThrough() {
    var stabilizer = SelfSizingHeightStabilizer()

    let first = stabilizer.resolve(width: 402, measuredHeight: 442.333)
    let second = stabilizer.resolve(width: 402, measuredHeight: 442.333)

    #expect(first.height == 442.333)
    #expect(first.instability == nil)
    #expect(!first.isLocked)
    #expect(second.height == 442.333)
    #expect(second.instability == nil)
    #expect(!second.isLocked)
  }

  @Test("Ellie URL preview oscillation locks to the larger height")
  func ellieURLPreviewOscillationLocksToLargerHeight() {
    var stabilizer = SelfSizingHeightStabilizer()

    _ = stabilizer.resolve(width: 402, measuredHeight: 413.333)
    let unstable = stabilizer.resolve(width: 402, measuredHeight: 442.333)
    let repeatedSmallerMeasurement = stabilizer.resolve(width: 402, measuredHeight: 413.333)

    #expect(unstable.height == 442.333)
    #expect(unstable.instability?.previousHeight == 413.333)
    #expect(unstable.instability?.measuredHeight == 442.333)
    #expect(unstable.instability?.stabilizedHeight == 442.333)
    #expect(unstable.isLocked)
    #expect(repeatedSmallerMeasurement.height == 442.333)
    #expect(repeatedSmallerMeasurement.instability == nil)
    #expect(repeatedSmallerMeasurement.isLocked)
  }

  @Test("Geo URL preview oscillation locks to the larger earlier height")
  func geoURLPreviewOscillationLocksToLargerEarlierHeight() {
    var stabilizer = SelfSizingHeightStabilizer()

    _ = stabilizer.resolve(width: 428, measuredHeight: 335)
    let unstable = stabilizer.resolve(width: 428, measuredHeight: 308.667)
    let repeatedSmallerMeasurement = stabilizer.resolve(width: 428, measuredHeight: 308.667)

    #expect(unstable.height == 335)
    #expect(unstable.instability?.stabilizedHeight == 335)
    #expect(repeatedSmallerMeasurement.height == 335)
  }

  @Test("a new collection width starts a new measurement generation")
  func widthChangeStartsNewGeneration() {
    var stabilizer = SelfSizingHeightStabilizer()

    _ = stabilizer.resolve(width: 402, measuredHeight: 413.333)
    _ = stabilizer.resolve(width: 402, measuredHeight: 442.333)
    let rotated = stabilizer.resolve(width: 390, measuredHeight: 420)

    #expect(rotated.height == 420)
    #expect(rotated.instability == nil)
    #expect(!rotated.isLocked)
  }

  @Test("content reconfiguration clears a locked height")
  func resetClearsLockedHeight() {
    var stabilizer = SelfSizingHeightStabilizer()

    _ = stabilizer.resolve(width: 390, measuredHeight: 413.667)
    _ = stabilizer.resolve(width: 390, measuredHeight: 442.667)
    stabilizer.reset()
    let reconfigured = stabilizer.resolve(width: 390, measuredHeight: 500)

    #expect(reconfigured.height == 500)
    #expect(reconfigured.instability == nil)
    #expect(!reconfigured.isLocked)
  }
}
