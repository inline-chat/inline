#if os(iOS)
import Foundation
import Testing

@testable import InlineIOSUI

@Suite("AttachmentPickerTileFormatting")
struct AttachmentPickerTileFormattingTests {
  @Test("video duration renders minute and second labels")
  func videoDurationRendersMinutesAndSeconds() {
    #expect(AttachmentPickerVideoDurationFormatter.string(for: 61) == "1:01")
  }

  @Test("video duration renders hour labels when needed")
  func videoDurationRendersHoursWhenNeeded() {
    #expect(AttachmentPickerVideoDurationFormatter.string(for: 3_661) == "1:01:01")
  }

  @Test("video duration hides zero or invalid durations")
  func videoDurationHidesInvalidDurations() {
    #expect(AttachmentPickerVideoDurationFormatter.string(for: 0) == nil)
    #expect(AttachmentPickerVideoDurationFormatter.string(for: -.infinity) == nil)
  }
}
#endif
