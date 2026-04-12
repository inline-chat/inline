import Foundation
import Photos
import Testing

@testable import InlineIOSUI

@Suite("AttachmentPickerModel")
struct AttachmentPickerModelTests {
  private final class RecentItemsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AttachmentPickerModel.RecentItem]

    init(_ items: [AttachmentPickerModel.RecentItem]) {
      self.items = items
    }

    func get() -> [AttachmentPickerModel.RecentItem] {
      lock.lock()
      defer { lock.unlock() }
      return items
    }

    func set(_ items: [AttachmentPickerModel.RecentItem]) {
      lock.lock()
      self.items = items
      lock.unlock()
    }
  }

  @MainActor
  @Test("limited authorization shows the limited access notice")
  func limitedAuthorizationShowsNotice() async {
    let model = AttachmentPickerModel(
      authorizationStatusProvider: { .limited },
      recentItemsProvider: { _ in [] }
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
      recentItemsProvider: { _ in
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
      recentItemsProvider: { _ in
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

  @Test("media type mapper includes videos")
  func mediaTypeMapperIncludesVideos() {
    #expect(AttachmentPickerModel.recentMediaType(for: .image) == .image)
    #expect(AttachmentPickerModel.recentMediaType(for: .video) == .video)
    #expect(AttachmentPickerModel.recentMediaType(for: .audio) == nil)
  }

  @MainActor
  @Test("selected recent items keep picker order")
  func selectedRecentItemsKeepPickerOrder() async {
    let oldest = Date(timeIntervalSince1970: 1)
    let middle = Date(timeIntervalSince1970: 2)
    let newest = Date(timeIntervalSince1970: 3)

    let model = AttachmentPickerModel(
      authorizationStatusProvider: { .authorized },
      recentItemsProvider: { _ in
        [
          .init(localIdentifier: "oldest", createdAt: oldest, mediaType: .image),
          .init(localIdentifier: "middle", createdAt: middle, mediaType: .video, duration: 91),
          .init(localIdentifier: "newest", createdAt: newest, mediaType: .image),
        ]
      }
    )

    await model.reload()
    model.toggleRecentSelection(localIdentifier: "middle")
    model.toggleRecentSelection(localIdentifier: "newest")

    #expect(model.selectedRecentItems.map(\.localIdentifier) == ["newest", "middle"])
  }

  @MainActor
  @Test("reload prunes selected items that are no longer available")
  func reloadPrunesMissingSelections() async {
    let now = Date()
    let store = RecentItemsStore([
      .init(localIdentifier: "one", createdAt: now, mediaType: .image),
      .init(localIdentifier: "two", createdAt: now.addingTimeInterval(-1), mediaType: .image),
    ])

    let model = AttachmentPickerModel(
      authorizationStatusProvider: { .authorized },
      recentItemsProvider: { _ in store.get() }
    )

    await model.reload()
    model.toggleRecentSelection(localIdentifier: "one")
    model.toggleRecentSelection(localIdentifier: "two")
    #expect(model.selectedRecentItems.count == 2)

    store.set([
      .init(localIdentifier: "two", createdAt: now.addingTimeInterval(-1), mediaType: .image),
    ])
    await model.reload()

    #expect(model.selectedRecentItems.map(\.localIdentifier) == ["two"])
  }

  @MainActor
  @Test("reload expands recent items in the background after the initial batch")
  func reloadExpandsRecentItemsInBackground() async {
    let items = (0..<AttachmentPickerModel.defaultRecentLimit).map { index in
      AttachmentPickerModel.RecentItem(
        localIdentifier: "item-\(index)",
        createdAt: Date(timeIntervalSince1970: TimeInterval(AttachmentPickerModel.defaultRecentLimit - index)),
        mediaType: index.isMultiple(of: 3) ? .video : .image,
        duration: index.isMultiple(of: 3) ? TimeInterval(index + 30) : nil
      )
    }

    let model = AttachmentPickerModel(
      recentLimit: AttachmentPickerModel.defaultRecentLimit,
      initialRecentLimit: AttachmentPickerModel.defaultInitialRecentLimit,
      authorizationStatusProvider: { .authorized },
      recentItemsProvider: { limit in
        Array(items.prefix(limit))
      }
    )

    await model.reload()

    #expect(model.recentItems.count == AttachmentPickerModel.defaultInitialRecentLimit)

    for _ in 0..<30 where model.recentItems.count < AttachmentPickerModel.defaultRecentLimit {
      await Task.yield()
    }

    #expect(model.recentItems.count == AttachmentPickerModel.defaultRecentLimit)
  }

}
