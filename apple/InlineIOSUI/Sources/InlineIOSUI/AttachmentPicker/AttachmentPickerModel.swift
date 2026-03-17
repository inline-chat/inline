import Foundation
import Observation
import Photos

@MainActor
@Observable
public final class AttachmentPickerModel: NSObject, PHPhotoLibraryChangeObserver {
  public enum RecentMediaType: String, Sendable {
    case image
    case video
  }

  public struct RecentItem: Identifiable, Equatable, Sendable {
    public let localIdentifier: String
    public let createdAt: Date?
    public let mediaType: RecentMediaType

    public var id: String { localIdentifier }

    public init(localIdentifier: String, createdAt: Date?, mediaType: RecentMediaType) {
      self.localIdentifier = localIdentifier
      self.createdAt = createdAt
      self.mediaType = mediaType
    }
  }

  public private(set) var authorizationStatus: PHAuthorizationStatus
  public private(set) var recentItems: [RecentItem] = []
  public private(set) var selectedRecentItemIds: Set<String> = []
  public private(set) var isLoading = false

  public var showsLimitedAccessNotice: Bool {
    authorizationStatus == .limited
  }

  public var isAuthorizedForRecents: Bool {
    switch authorizationStatus {
      case .authorized, .limited:
        true
      case .notDetermined, .restricted, .denied:
        false
      @unknown default:
        false
    }
  }

  public var selectedRecentItems: [RecentItem] {
    recentItems.filter { selectedRecentItemIds.contains($0.localIdentifier) }
  }

  @ObservationIgnored private let authorizationStatusProvider: @Sendable () -> PHAuthorizationStatus
  @ObservationIgnored private let recentItemsProvider: @Sendable () -> [RecentItem]
  @ObservationIgnored private let recentLimit: Int

  public init(
    recentLimit: Int = 20,
    authorizationStatusProvider: @escaping @Sendable () -> PHAuthorizationStatus = {
      PHPhotoLibrary.authorizationStatus(for: .readWrite)
    },
    recentItemsProvider: (@Sendable () -> [RecentItem])? = nil
  ) {
    self.recentLimit = recentLimit
    self.authorizationStatusProvider = authorizationStatusProvider
    self.recentItemsProvider = recentItemsProvider ?? {
      Self.fetchRecentItems(limit: recentLimit)
    }
    authorizationStatus = authorizationStatusProvider()
    super.init()
    PHPhotoLibrary.shared().register(self)
  }

  deinit {
    PHPhotoLibrary.shared().unregisterChangeObserver(self)
  }

  nonisolated public func photoLibraryDidChange(_: PHChange) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.reload()
    }
  }

  public func reload() async {
    isLoading = true

    let status = authorizationStatusProvider()
    authorizationStatus = status

    if isAuthorizedForRecents {
      let fetchRecentItems = recentItemsProvider
      let fetchedItems = await Task.detached(priority: .userInitiated) {
        fetchRecentItems()
      }.value
      recentItems = Self.sortRecentItems(fetchedItems)
      let availableIds = Set(recentItems.map(\.localIdentifier))
      selectedRecentItemIds = selectedRecentItemIds.intersection(availableIds)
    } else {
      recentItems = []
      selectedRecentItemIds = []
    }

    isLoading = false
  }

  public func reload(promotingLocalIdentifiers localIdentifiers: [String]) async {
    let uniqueIds = Self.uniqueOrderedIdentifiers(from: localIdentifiers)
    await reload()

    guard uniqueIds.isEmpty == false else { return }

    let fetchedPromotedItems = await Task.detached(priority: .userInitiated) {
      Self.fetchRecentItems(localIdentifiers: uniqueIds)
    }.value
    guard fetchedPromotedItems.isEmpty == false else { return }

    let promotedById = Dictionary(uniqueKeysWithValues: fetchedPromotedItems.map { ($0.localIdentifier, $0) })
    let promotedItems = uniqueIds.compactMap { promotedById[$0] }
    guard promotedItems.isEmpty == false else { return }

    let promotedIds = Set(promotedItems.map(\.localIdentifier))
    var mergedItems = promotedItems
    mergedItems.append(contentsOf: recentItems.filter { promotedIds.contains($0.localIdentifier) == false })
    if mergedItems.count > recentLimit {
      mergedItems = Array(mergedItems.prefix(recentLimit))
    }

    recentItems = mergedItems
    let availableIds = Set(recentItems.map(\.localIdentifier))
    selectedRecentItemIds = selectedRecentItemIds.intersection(availableIds)
  }

  nonisolated static func sortRecentItems(_ items: [RecentItem]) -> [RecentItem] {
    items.sorted { lhs, rhs in
      switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?):
          if left != right {
            return left > right
          }
        case (_?, nil):
          return true
        case (nil, _?):
          return false
        case (nil, nil):
          break
      }

      return lhs.localIdentifier > rhs.localIdentifier
    }
  }

  nonisolated static func recentMediaType(for assetMediaType: PHAssetMediaType) -> RecentMediaType? {
    switch assetMediaType {
      case .image:
        return .image
      case .video:
        return .video
      case .audio:
        return nil
      case .unknown:
        return nil
      @unknown default:
        return nil
    }
  }

  private nonisolated static func fetchRecentItems(limit: Int) -> [RecentItem] {
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: #keyPath(PHAsset.creationDate), ascending: false)]
    options.fetchLimit = limit
    options.predicate = NSPredicate(
      format: "mediaType == %d OR mediaType == %d",
      PHAssetMediaType.image.rawValue,
      PHAssetMediaType.video.rawValue
    )

    let assets = PHAsset.fetchAssets(with: options)
    var items: [RecentItem] = []
    items.reserveCapacity(min(limit, assets.count))

    assets.enumerateObjects { asset, _, stop in
      guard items.count < limit else {
        stop.pointee = true
        return
      }

      guard let mediaType = recentMediaType(for: asset.mediaType) else {
        return
      }

      items.append(
        RecentItem(
          localIdentifier: asset.localIdentifier,
          createdAt: asset.creationDate,
          mediaType: mediaType
        )
      )
    }

    return items
  }

  private nonisolated static func fetchRecentItems(localIdentifiers: [String]) -> [RecentItem] {
    let uniqueIds = uniqueOrderedIdentifiers(from: localIdentifiers)
    guard uniqueIds.isEmpty == false else { return [] }

    let assets = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIds, options: nil)
    var itemsById: [String: RecentItem] = [:]
    itemsById.reserveCapacity(uniqueIds.count)

    assets.enumerateObjects { asset, _, _ in
      guard let mediaType = recentMediaType(for: asset.mediaType) else {
        return
      }

      itemsById[asset.localIdentifier] = RecentItem(
        localIdentifier: asset.localIdentifier,
        createdAt: asset.creationDate,
        mediaType: mediaType
      )
    }

    return uniqueIds.compactMap { itemsById[$0] }
  }

  private nonisolated static func uniqueOrderedIdentifiers(from localIdentifiers: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    ordered.reserveCapacity(localIdentifiers.count)

    for identifier in localIdentifiers where identifier.isEmpty == false {
      if seen.insert(identifier).inserted {
        ordered.append(identifier)
      }
    }

    return ordered
  }

  public func toggleRecentSelection(localIdentifier: String) {
    if selectedRecentItemIds.contains(localIdentifier) {
      selectedRecentItemIds.remove(localIdentifier)
    } else {
      selectedRecentItemIds.insert(localIdentifier)
    }
  }

  public func clearRecentSelection() {
    selectedRecentItemIds.removeAll()
  }
}
