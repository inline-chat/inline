import Combine
import Foundation
import GRDB
import Logger

public struct HomeChatListItemSnapshot: Hashable, Identifiable, Sendable {
  public let id: Int64
  public let item: HomeChatItem
  public let peerId: Peer
  public let chatId: Int64?
  public let title: String
  public let parentTitle: String?
  public let preview: String
  public let spaceTitle: String?
  public let unread: Bool
  public let pinned: Bool
  public let archived: Bool
  public let sortDate: Date
  public let searchText: String

  public init(
    item: HomeChatItem,
    titleOverride: String? = nil,
    parentTitle: String? = nil
  ) {
    id = item.id
    self.item = item
    peerId = item.peerId
    chatId = item.dialog.chatId ?? item.chat?.id
    self.parentTitle = parentTitle
    preview = Self.preview(for: item)
    spaceTitle = item.space?.displayName
    unread = (item.dialog.unreadCount ?? 0) > 0 || item.dialog.unreadMark == true
    pinned = item.dialog.pinned == true
    archived = item.dialog.archived == true
    sortDate = item.lastMessage?.message.date ?? item.chat?.date ?? Date.distantPast
    title = Self.title(for: item, titleOverride: titleOverride)
    searchText = Self.normalizedSearchText(
      [
        title,
        parentTitle,
        preview,
        spaceTitle,
        item.user?.user.username,
        item.user?.user.email,
        item.chat?.title,
      ]
      .compactMap { $0 }
      .joined(separator: " ")
    )
  }

  public static func snapshots(from items: [HomeChatItem], db: Database) throws -> [HomeChatListItemSnapshot] {
    let filtered = HomeViewModel.filterEmptyChats(items)
    let titles = try ReplyThreadTitleFallback.titlesByChatId(for: filtered, db: db)
    let parentTitles = try ReplyThreadTitleFallback.parentTitlesByChatId(for: filtered, db: db)
    let sorted = HomeViewModel.sortChats(filtered)

    let snapshots = sorted.map { item in
      HomeChatListItemSnapshot(
        item: item,
        titleOverride: item.chat.flatMap { titles[$0.id] },
        parentTitle: item.chat.flatMap { parentTitles[$0.id] }
      )
    }

    return snapshots.filter { !$0.archived } + snapshots.filter(\.archived)
  }

  public static func normalizedSearchText(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  private static func title(for item: HomeChatItem, titleOverride: String?) -> String {
    if let userInfo = item.displayUserInfo {
      if userInfo.user.isCurrentUser() {
        return "Saved Messages"
      }
      return userInfo.user.needsDisplayNameFetch ? "Loading..." : userInfo.user.displayName
    }

    return titleOverride ?? item.chat?.humanReadableTitle ?? "Chat"
  }

  private static func preview(for item: HomeChatItem) -> String {
    if let draftText = item.dialog.draftMessage?.text {
      let normalized = draftText
        .components(separatedBy: .newlines)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if normalized.isEmpty == false {
        return "Draft: \(normalized)"
      }
    }

    guard let lastMessage = item.lastMessage else { return "" }
    let messageText = lastMessage.documentPreviewText
      ?? lastMessage.message.stringRepresentationPlain

    guard item.chat?.type == .thread else { return messageText }
    guard let sender = lastMessage.senderInfo?.user.shortDisplayName, sender.isEmpty == false else {
      return messageText
    }
    return "\(sender): \(messageText)"
  }
}

public extension AppDatabase {
  func homeChatListItemSnapshotsPublisher() -> AnyPublisher<[HomeChatListItemSnapshot], Never> {
    let log = Log.scoped("HomeChatListItemSnapshot")
    warnIfInMemoryDatabaseForObservation("HomeChatListItemSnapshot.publisher")

    return ValueObservation
      .tracking { db in
        let items = try HomeChatItem.all().fetchAll(db)
        return try HomeChatListItemSnapshot.snapshots(from: items, db: db)
      }
      .publisher(in: reader, scheduling: .immediate)
      .catch { error in
        log.error("Failed to observe forward destinations", error: error)
        return Just<[HomeChatListItemSnapshot]>([])
      }
      .removeDuplicates()
      .eraseToAnyPublisher()
  }
}

private extension EmbeddedMessage {
  var documentPreviewText: String? {
    guard message.documentId != nil else { return nil }
    guard let fileName = document?.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
          fileName.isEmpty == false
    else {
      return nil
    }
    return fileName.replacingOccurrences(of: "\n", with: " ")
  }
}
