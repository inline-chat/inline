import Testing

@testable import InlineIOSUI

@Suite("AttachmentPickerSheet")
struct AttachmentPickerSheetTests {
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
}
