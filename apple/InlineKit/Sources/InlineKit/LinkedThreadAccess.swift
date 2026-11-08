import Foundation
import GRDB
import InlineProtocol

/// People a message is going to who can't open a private thread it links to.
public struct LinkedThreadAccessGap: Sendable, Identifiable {
  public let chat: Chat
  public let users: [UserInfo]

  public var id: Int64 { chat.id }

  public var chatTitle: String {
    let title = chat.humanReadableTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? "this thread" : title
  }
}

/// Finds thread links in an outgoing message whose recipients lack access, so
/// the sender can add them right after sending. Everything is read from the
/// local database; when the data needed to be sure isn't cached, it stays quiet.
public enum LinkedThreadAccess {
  /// Beyond this many people the right move is a different share, not a prompt.
  public static let maxMissingUsers = 5
  static let maxLinkedChats = 3

  public static func linkedChatIds(text: String?, entities: MessageEntities?) -> [Int64] {
    var ids: [Int64] = []
    func append(_ id: Int64?) {
      guard let id, id > 0, !ids.contains(id) else { return }
      ids.append(id)
    }

    for entity in entities?.entities ?? [] {
      switch entity.type {
        case .thread:
          append(entity.thread.chatID)
        case .textURL:
          append(chatId(fromLink: entity.textURL.url))
        default:
          break
      }
    }

    if let text, mayContainChatLink(text) {
      for link in detectedLinks(in: text) {
        append(chatId(fromLink: link))
      }
    }

    return Array(ids.prefix(maxLinkedChats))
  }

  /// Runs after a send. Rosters that were never fully loaded are refreshed
  /// first, so a thread nobody opened recently still gets an accurate answer.
  public static func findGaps(
    text: String?,
    entities: MessageEntities?,
    destination: Peer,
    currentUserId: Int64?,
    database: AppDatabase,
    refreshRoster: @Sendable (Int64) async -> Void
  ) async -> [LinkedThreadAccessGap] {
    let linkedIds = linkedChatIds(text: text, entities: entities)
    guard let currentUserId, !linkedIds.isEmpty else { return [] }

    do {
      var destinationThreadIds: [Int64] = []
      if case let .thread(id) = destination { destinationThreadIds.append(id) }
      let rosterChatIds = linkedIds + destinationThreadIds
      let incomplete = try await database.reader.read { db in
        try Chat
          .filter(ids: rosterChatIds)
          .filter(Chat.Columns.participantRosterComplete == false)
          .filter(Chat.Columns.type == ChatType.thread.rawValue)
          .fetchAll(db)
          .map(\.id)
      }
      for chatId in incomplete {
        await refreshRoster(chatId)
      }
      return try await database.reader.read { db in
        try gaps(db, linkedChatIds: linkedIds, destination: destination, currentUserId: currentUserId)
      }
    } catch {
      return []
    }
  }

  public static func gaps(
    _ db: Database,
    linkedChatIds: [Int64],
    destination: Peer,
    currentUserId: Int64
  ) throws -> [LinkedThreadAccessGap] {
    guard !linkedChatIds.isEmpty,
          let recipients = try recipientIds(db, destination: destination, currentUserId: currentUserId),
          !recipients.isEmpty
    else { return [] }

    var gaps: [LinkedThreadAccessGap] = []
    for chatId in linkedChatIds {
      guard let chat = try Chat.fetchOne(db, id: chatId),
            ChatParticipantPolicy.canAdd(chat: chat),
            destination != .thread(id: chat.id)
      else { continue }

      let access = try ChatParticipantsWithMembersViewModel.effectiveParticipantAccess(db, for: chat)
      // Without our own grant cached, the participant list isn't loaded and
      // everyone would look missing.
      guard access.userIds.contains(currentUserId) else { continue }

      var missing = recipients.subtracting(access.userIds)
      if let spaceId = chat.spaceId {
        // Only space members can be added to a space thread.
        let memberIds = try Member
          .filter(Member.Columns.spaceId == spaceId)
          .filter(Array(missing).contains(Member.Columns.userId))
          .fetchAll(db)
          .map(\.userId)
        missing.formIntersection(memberIds)
      }

      guard !missing.isEmpty, missing.count <= maxMissingUsers else { continue }

      let users = try User
        .filter(ids: Array(missing))
        .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
        .asRequest(of: UserInfo.self)
        .fetchAll(db)
        .sorted { $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending }
      guard !users.isEmpty else { continue }

      gaps.append(LinkedThreadAccessGap(chat: chat, users: users))
    }
    return gaps
  }

  /// Who will read the message: the DM peer, or a private thread's members.
  /// Nil when the audience is open-ended or not loaded.
  private static func recipientIds(
    _ db: Database,
    destination: Peer,
    currentUserId: Int64
  ) throws -> Set<Int64>? {
    switch destination {
      case let .user(id):
        return id == currentUserId ? [] : [id]
      case let .thread(id):
        guard let chat = try Chat.fetchOne(db, id: id) else { return nil }
        let access = try ChatParticipantsWithMembersViewModel.effectiveParticipantAccess(db, for: chat)
        let isPublicRoot = access.sourceChat.type == .thread && access.sourceChat.isPublic == true
        guard !isPublicRoot, access.userIds.contains(currentUserId) else { return nil }
        return access.userIds.subtracting([currentUserId])
    }
  }

  static func chatId(fromLink link: String) -> Int64? {
    var link = link.trimmingCharacters(in: .whitespacesAndNewlines)
    if !link.contains("://") { link = "https://" + link }
    guard var components = URLComponents(string: link) else { return nil }
    if components.host?.lowercased() == "inline.chat" || components.host?.lowercased() == "www.inline.chat" {
      components.scheme = "https"
      components.host = "inline.chat"
    }
    guard let url = components.url else { return nil }

    switch InlineDeepLink(universalLink: url) ?? InlineDeepLink(url: url) {
      case let .chat(id):
        return id
      case let .message(chatId, _):
        return chatId
      default:
        return nil
    }
  }

  private static func mayContainChatLink(_ text: String) -> Bool {
    text.range(of: "inline.chat/c/", options: .caseInsensitive) != nil ||
      text.range(of: "://chat", options: .caseInsensitive) != nil ||
      text.range(of: "://message", options: .caseInsensitive) != nil
  }

  private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

  private static func detectedLinks(in text: String) -> [String] {
    guard let linkDetector else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return linkDetector.matches(in: text, range: range).compactMap { match in
      if let url = match.url { return url.absoluteString }
      return Range(match.range, in: text).map { String(text[$0]) }
    }
  }
}
