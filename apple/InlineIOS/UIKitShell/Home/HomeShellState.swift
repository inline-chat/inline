import Auth
import Foundation
import InlineCompat
import InlineKit
#if canImport(Observation)
import Observation
#endif

/// Home preferences and per-scene state (active space, All Chats filter), observable from UIKit.
/// Persists to the same keys the SwiftUI home used, so preferences carry over.
@MainActor
final class HomeShellState: CompatObservable {
  nonisolated let observationRegistrar = CompatObservationRegistrar()
  private let defaults = UserDefaults.standard
  private let exclusionsKey: String

  /// Scene scoped (restored with the scene).
  @Tracked var activeSpaceId: Int64?
  @Tracked var allChatsFilter: ChatListFilter

  /// App scoped.
  @Tracked var chatScope: ExperimentalHomeChatScope {
    didSet { defaults.set(chatScope.rawValue, forKey: ExperimentalHomePreferenceKeys.chatScope) }
  }

  @Tracked var sortMode: ExperimentalHomeSortMode {
    didSet { defaults.set(sortMode.rawValue, forKey: ExperimentalHomePreferenceKeys.sortMode) }
  }

  @Tracked var renderMode: ExperimentalHomeChatItemRenderMode {
    didSet { defaults.set(renderMode.rawValue, forKey: ExperimentalHomePreferenceKeys.chatItemRenderMode) }
  }

  @Tracked var unreadBadgeStyle: ExperimentalHomeUnreadBadgeStyle

  @Tracked var exclusions: HomeSpaceExclusions {
    didSet { defaults.set(exclusions.rawValue, forKey: exclusionsKey) }
  }

  @Tracked var isCreatingThread = false

  private static let activeSpaceKey = "ios.home.activeSpaceID.v1"
  private static let filterKey = "ios.home.allChatsFilter.v1"
  private static let legacyActiveSpaceMigrationKey = "ios.home.didMigrateActiveSpaceToScene.v1"

  init(sceneState: [String: String]) {
    let userID = Auth.shared.getCurrentUserId()
    exclusionsKey = ExperimentalHomePreferenceKeys.excludedHomeSpaceIDs(userID: userID)
    chatScope = ExperimentalHomeChatScope(
      rawValue: defaults.string(forKey: ExperimentalHomePreferenceKeys.chatScope) ?? ""
    ) ?? .all
    sortMode = ExperimentalHomeSortMode(
      rawValue: defaults.string(forKey: ExperimentalHomePreferenceKeys.sortMode) ?? ""
    ) ?? .recentActivity
    var mode = ExperimentalHomeChatItemRenderMode(
      rawValue: defaults.string(forKey: ExperimentalHomePreferenceKeys.chatItemRenderMode) ?? ""
    ) ?? .twoLineLastMessage
    if mode == .oneLineLastMessage { mode = .twoLineLastMessage }
    renderMode = mode
    unreadBadgeStyle = ExperimentalHomeUnreadBadgeStyle(
      rawValue: defaults.string(forKey: ExperimentalHomePreferenceKeys.unreadBadgeStyle) ?? ""
    ) ?? .defaultValue
    exclusions = HomeSpaceExclusions(rawValue: defaults.string(forKey: exclusionsKey) ?? "")
    allChatsFilter = ChatListFilter(rawValue: sceneState[Self.filterKey] ?? "") ?? .all

    if let raw = sceneState[Self.activeSpaceKey], let id = Int64(raw) {
      activeSpaceId = id
    } else if !defaults.bool(forKey: Self.legacyActiveSpaceMigrationKey) {
      activeSpaceId = Self.loadLegacyActiveSpaceId()
      defaults.set(true, forKey: Self.legacyActiveSpaceMigrationKey)
    } else {
      activeSpaceId = nil
    }
  }

  private static func loadLegacyActiveSpaceId() -> Int64? {
    let value = UserDefaults.standard.object(forKey: "activeSpaceId")
    return (value as? Int64) ?? (value as? Int).map(Int64.init) ?? (value as? NSNumber)?.int64Value
  }

  var sceneState: [String: String] {
    [
      Self.activeSpaceKey: activeSpaceId.map(String.init) ?? "",
      Self.filterKey: allChatsFilter.rawValue,
    ]
  }

  var listConfiguration: ExperimentalHomeListConfiguration {
    ExperimentalHomeListConfiguration(
      spaceID: activeSpaceId,
      includeSpaceChatsInHome: chatScope == .all,
      homeSpaceExclusions: exclusions,
      inboxSort: sortMode.chatListSort,
      allChatsFilter: allChatsFilter
    )
  }
}

@available(iOS 17.0, macOS 14.0, *)
extension HomeShellState: Observable {}
