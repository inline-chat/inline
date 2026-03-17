import Testing

@testable import InlineIOSUI

@Suite("AttachmentPickerSheet")
struct AttachmentPickerSheetTests {
  @Test("limited access keeps library row mapped to open library")
  func limitedAccessKeepsLibraryRowMappedToOpenLibrary() {
    #expect(
      resolveAttachmentPickerLibraryActionTarget(showsLimitedAccessNotice: true) == .openLibrary
    )
  }

  @Test("full access keeps library row mapped to open library")
  func fullAccessKeepsLibraryRowMappedToOpenLibrary() {
    #expect(
      resolveAttachmentPickerLibraryActionTarget(showsLimitedAccessNotice: false) == .openLibrary
    )
  }
}
