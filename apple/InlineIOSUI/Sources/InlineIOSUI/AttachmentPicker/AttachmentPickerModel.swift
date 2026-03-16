import Foundation
import Observation
import Photos

@MainActor
@Observable
public final class AttachmentPickerModel {
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

  @ObservationIgnored private let authorizationStatusProvider: @Sendable () -> PHAuthorizationStatus
  @ObservationIgnored private let recentItemsProvider: @Sendable () -> [RecentItem]

  public init(
    recentLimit: Int = 20,
    authorizationStatusProvider: @escaping @Sendable () -> PHAuthorizationStatus = {
      PHPhotoLibrary.authorizationStatus(for: .readWrite)
    },
    recentItemsProvider: (@Sendable () -> [RecentItem])? = nil
  ) {
    self.authorizationStatusProvider = authorizationStatusProvider
    self.recentItemsProvider = recentItemsProvider ?? {
      Self.fetchRecentItems(limit: recentLimit)
    }
    authorizationStatus = authorizationStatusProvider()
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
    } else {
      recentItems = []
    }

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
          mediaType: mediaType
        )
      )
    }

    return items
  }
}
