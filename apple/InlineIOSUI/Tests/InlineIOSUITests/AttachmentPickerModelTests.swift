import Photos
import Testing

@testable import InlineIOSUI

@Suite("AttachmentPickerModel")
struct AttachmentPickerModelTests {
  @MainActor
  @Test("limited authorization shows the limited access notice")
  func limitedAuthorizationShowsNotice() async {
    let model = AttachmentPickerModel(
      authorizationStatusProvider: { .limited },
      recentItemsProvider: { [] }
    )

    await model.reload()

    #expect(model.authorizationStatus == .limited)
    #expect(model.showsLimitedAccessNotice)
    #expect(model.recentItems.isEmpty)
  }

  @MainActor
  @Test("denied authorization clears recents and hides the limited notice")
  func deniedAuthorizationClearsRecents() async {
    let model = AttachmentPickerModel(
      authorizationStatusProvider: { .denied },
      recentItemsProvider: {
        [
          AttachmentPickerModel.RecentItem(
            localIdentifier: "ignored",
            createdAt: Date(),
            mediaType: .image
          ),
        ]
      }
    )

    await model.reload()

    #expect(model.authorizationStatus == .denied)
    #expect(model.showsLimitedAccessNotice == false)
    #expect(model.recentItems.isEmpty)
  }

  @MainActor
  @Test("reload sorts recent items from newest to oldest")
  func reloadSortsRecentItemsNewestFirst() async {
    let older = Date(timeIntervalSince1970: 10)
    let newer = Date(timeIntervalSince1970: 20)

    let model = AttachmentPickerModel(
      authorizationStatusProvider: { .authorized },
      recentItemsProvider: {
        [
          AttachmentPickerModel.RecentItem(
            localIdentifier: "older",
            createdAt: older,
            mediaType: .image
          ),
          AttachmentPickerModel.RecentItem(
            localIdentifier: "newer",
            createdAt: newer,
            mediaType: .image
          ),
        ]
      }
    )

    await model.reload()

    #expect(model.recentItems.map(\.localIdentifier) == ["newer", "older"])
  }
}
