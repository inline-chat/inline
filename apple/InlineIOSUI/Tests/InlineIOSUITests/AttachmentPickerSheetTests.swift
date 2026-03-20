import Foundation
import Testing

@testable import InlineIOSUI

@Suite("AttachmentPickerSheet")
struct AttachmentPickerSheetTests {
  private let now = Date(timeIntervalSince1970: 1_000)

  @Test("limited access maps library row to manage limited access")
  func limitedAccessMapsLibraryRowToManageLimitedAccess() {
    #expect(
      resolveAttachmentPickerLibraryActionTarget(showsLimitedAccessNotice: true) == .manageLimitedAccess
    )
  }

  @Test("full access keeps library row mapped to open library")
  func fullAccessKeepsLibraryRowMappedToOpenLibrary() {
    #expect(
      resolveAttachmentPickerLibraryActionTarget(showsLimitedAccessNotice: false) == .openLibrary
    )
  }

  @Test("send selected button title uses video label for video-only selection")
  func sendSelectedButtonTitleUsesVideoLabelForVideoOnlySelection() {
    let selectedItems: [AttachmentPickerModel.RecentItem] = [
      .init(localIdentifier: "video-1", createdAt: now, mediaType: .video),
      .init(localIdentifier: "video-2", createdAt: now, mediaType: .video),
    ]

    #expect(
      attachmentPickerSendSelectedButtonTitle(for: selectedItems) == "Add 2 videos"
    )
  }

  @Test("send selected button title uses neutral copy for mixed photo and video selection")
  func sendSelectedButtonTitleUsesNeutralCopyForMixedSelection() {
    let selectedItems: [AttachmentPickerModel.RecentItem] = [
      .init(localIdentifier: "image-1", createdAt: now, mediaType: .image),
      .init(localIdentifier: "video-1", createdAt: now, mediaType: .video),
    ]

    #expect(
      attachmentPickerSendSelectedButtonTitle(for: selectedItems) == "Add 2 items"
    )
  }
}
