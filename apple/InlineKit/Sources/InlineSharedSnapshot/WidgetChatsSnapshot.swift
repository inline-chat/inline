import Foundation

/// The top of the chat list, as the home and lock screen widgets show it.
public struct WidgetChatsSnapshot: SharedSnapshotPayload, Equatable {
  public static let kind = "widget-chats"
  public static let schemaVersion = 1
  /// WidgetKit kind of the chats widget, for timeline reloads from the app.
  public static let widgetKind = "chat.inline.widget.chats"
  /// Enough rows for the large widget.
  public static let maximumChatCount = 6

  public var chats: [WidgetChat]
  /// Unarchived chats with unread messages, across the whole list.
  public var unreadChatCount: Int

  public init(chats: [WidgetChat], unreadChatCount: Int) {
    self.chats = chats
    self.unreadChatCount = unreadChatCount
  }
}

public struct WidgetChat: Codable, Hashable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable {
    case user
    case thread
  }

  public var id: Int64
  public var kind: Kind
  public var title: String
  /// Last message or draft, single line.
  public var preview: String
  public var date: Date?
  public var unreadCount: Int
  public var isUnread: Bool
  public var isPinned: Bool
  public var emoji: String?
  public var initials: String
  /// Avatar exported by the app, relative to the app group container.
  public var avatarPath: String?
  /// Opens the chat in the app that wrote the snapshot (its own URL scheme).
  public var deepLink: String?

  public init(
    id: Int64,
    kind: Kind,
    title: String,
    preview: String,
    date: Date?,
    unreadCount: Int,
    isUnread: Bool,
    isPinned: Bool,
    emoji: String?,
    initials: String,
    avatarPath: String?,
    deepLink: String?
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.preview = preview
    self.date = date
    self.unreadCount = unreadCount
    self.isUnread = isUnread
    self.isPinned = isPinned
    self.emoji = emoji
    self.initials = initials
    self.avatarPath = avatarPath
    self.deepLink = deepLink
  }

  public var avatarURL: URL? {
    SharedSnapshotStore.appGroupFileURL(relativePath: avatarPath)
  }

  public var deepLinkURL: URL? {
    deepLink.flatMap(URL.init(string:))
  }

  public static func initials(for title: String) -> String {
    let words = title
      .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
      .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
    let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
    return letters.isEmpty ? "#" : letters.joined()
  }
}
