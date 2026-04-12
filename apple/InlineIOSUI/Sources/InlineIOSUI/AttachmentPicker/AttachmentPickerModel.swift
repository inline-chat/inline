import Foundation
import Observation
import Photos

@MainActor
@Observable
public final class AttachmentPickerModel: NSObject, PHPhotoLibraryChangeObserver {
  public static let defaultInitialRecentLimit = 25
  public static let defaultRecentLimit = 75

  public enum RecentMediaType: String, Sendable {
    case image
    case video
  }

  public struct RecentItem: Identifiable, Equatable, Sendable {
    public let localIdentifier: String
    public let createdAt: Date?
    public let mediaType: RecentMediaType
    public let duration: TimeInterval?

    public var id: String { localIdentifier }

    public init(
      localIdentifier: String,
      createdAt: Date?,
      mediaType: RecentMediaType,
      duration: TimeInterval? = nil
    ) {
      self.localIdentifier = localIdentifier
      self.createdAt = createdAt
      self.mediaType = mediaType
      self.duration = duration
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
  @ObservationIgnored private let recentItemsProvider: @Sendable (Int) -> [RecentItem]
  @ObservationIgnored private let initialRecentLimit: Int
  @ObservationIgnored private let recentLimit: Int
  @ObservationIgnored private var backgroundExpansionTask: Task<Void, Never>?
  @ObservationIgnored private var reloadGeneration = 0

  public init(
    recentLimit: Int = 75,
    initialRecentLimit: Int = 25,
    authorizationStatusProvider: @escaping @Sendable () -> PHAuthorizationStatus = {
      PHPhotoLibrary.authorizationStatus(for: .readWrite)
    },
    recentItemsProvider: (@Sendable (Int) -> [RecentItem])? = nil
  ) {
    self.recentLimit = max(1, recentLimit)
    self.initialRecentLimit = min(max(1, initialRecentLimit), self.recentLimit)
    self.authorizationStatusProvider = authorizationStatusProvider
    self.recentItemsProvider = recentItemsProvider ?? {
      Self.fetchRecentItems(limit: $0)
    }
    authorizationStatus = authorizationStatusProvider()
    super.init()
    PHPhotoLibrary.shared().register(self)
  }

  deinit {
    backgroundExpansionTask?.cancel()
    PHPhotoLibrary.shared().unregisterChangeObserver(self)
  }

  nonisolated public func photoLibraryDidChange(_: PHChange) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.reload()
    }
  }

  public func reload() async {
    backgroundExpansionTask?.cancel()
    reloadGeneration += 1
    let generation = reloadGeneration
    isLoading = true

    let status = authorizationStatusProvider()
    authorizationStatus = status

    if isAuthorizedForRecents {
      let fetchRecentItems = recentItemsProvider
      let initialLimit = initialRecentLimit
      let fetchedItems = await Task.detached(priority: .userInitiated) {
        fetchRecentItems(initialLimit)
      }.value
      guard generation == reloadGeneration else { return }

      recentItems = Self.sortRecentItems(fetchedItems)
      let availableIds = Set(recentItems.map(\.localIdentifier))
      selectedRecentItemIds = selectedRecentItemIds.intersection(availableIds)
      scheduleBackgroundExpansion(generation: generation, promotedLocalIdentifiers: [])
    } else {
      recentItems = []
      selectedRecentItemIds = []
    }

    isLoading = false
  }

  public func reload(promotingLocalIdentifiers localIdentifiers: [String]) async {
    backgroundExpansionTask?.cancel()
    reloadGeneration += 1
    let generation = reloadGeneration
    let uniqueIds = Self.uniqueOrderedIdentifiers(from: localIdentifiers)

    isLoading = true

    let status = authorizationStatusProvider()
    authorizationStatus = status

    guard isAuthorizedForRecents else {
      recentItems = []
      selectedRecentItemIds = []
      isLoading = false
      return
    }

    let fetchRecentItems = recentItemsProvider
    let initialLimit = initialRecentLimit
    let initialItems = await Task.detached(priority: .userInitiated) {
      fetchRecentItems(initialLimit)
    }.value
    guard generation == reloadGeneration else { return }

    recentItems = Self.sortRecentItems(initialItems)
    let availableIds = Set(recentItems.map(\.localIdentifier))
    selectedRecentItemIds = selectedRecentItemIds.intersection(availableIds)

    guard uniqueIds.isEmpty == false else {
      scheduleBackgroundExpansion(generation: generation, promotedLocalIdentifiers: [])
      isLoading = false
      return
    }

    let fetchedPromotedItems = await Task.detached(priority: .userInitiated) {
      Self.fetchRecentItems(localIdentifiers: uniqueIds)
    }.value
    guard generation == reloadGeneration else { return }
    guard fetchedPromotedItems.isEmpty == false else {
      scheduleBackgroundExpansion(generation: generation, promotedLocalIdentifiers: [])
      isLoading = false
      return
    }

    let promotedById = Dictionary(uniqueKeysWithValues: fetchedPromotedItems.map { ($0.localIdentifier, $0) })
    let promotedItems = uniqueIds.compactMap { promotedById[$0] }
    guard promotedItems.isEmpty == false else {
      scheduleBackgroundExpansion(generation: generation, promotedLocalIdentifiers: [])
      isLoading = false
      return
    }

    recentItems = mergePromotedItems(promotedItems, into: recentItems, limit: initialRecentLimit)
    let mergedAvailableIds = Set(recentItems.map(\.localIdentifier))
    selectedRecentItemIds = selectedRecentItemIds.intersection(mergedAvailableIds)
    scheduleBackgroundExpansion(
      generation: generation,
      promotedLocalIdentifiers: uniqueIds
    )
    isLoading = false
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
          mediaType: mediaType,
          duration: mediaType == .video ? asset.duration : nil
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
        mediaType: mediaType,
        duration: mediaType == .video ? asset.duration : nil
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

  private func scheduleBackgroundExpansion(
    generation: Int,
    promotedLocalIdentifiers: [String]
  ) {
    guard recentLimit > initialRecentLimit else { return }

    let fetchRecentItems = recentItemsProvider
    let expandedLimit = recentLimit
    backgroundExpansionTask = Task(priority: .utility) { [weak self] in
      let expandedItems = await Task.detached(priority: .utility) {
        fetchRecentItems(expandedLimit)
      }.value

      await MainActor.run {
        guard let self, generation == self.reloadGeneration else { return }

        let sortedItems = Self.sortRecentItems(expandedItems)
        let finalItems: [RecentItem]
        if promotedLocalIdentifiers.isEmpty {
          finalItems = Array(sortedItems.prefix(self.recentLimit))
        } else {
          let promotedById = Dictionary(uniqueKeysWithValues: sortedItems.map { ($0.localIdentifier, $0) })
          let promotedItems = promotedLocalIdentifiers.compactMap { promotedById[$0] }
          finalItems = self.mergePromotedItems(promotedItems, into: sortedItems, limit: self.recentLimit)
        }

        if finalItems != self.recentItems {
          self.recentItems = finalItems
          let availableIds = Set(finalItems.map(\.localIdentifier))
          self.selectedRecentItemIds = self.selectedRecentItemIds.intersection(availableIds)
        }
      }
    }
  }

  private func mergePromotedItems(
    _ promotedItems: [RecentItem],
    into baseItems: [RecentItem],
    limit: Int
  ) -> [RecentItem] {
    let promotedIds = Set(promotedItems.map(\.localIdentifier))
    var mergedItems = promotedItems
    mergedItems.append(contentsOf: baseItems.filter { promotedIds.contains($0.localIdentifier) == false })
    return Array(mergedItems.prefix(limit))
  }
}
