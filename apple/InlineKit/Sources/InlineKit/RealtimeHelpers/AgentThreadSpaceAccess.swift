import Foundation
import GRDB
import InlineProtocol

public enum AgentThreadSpaceAccessError: Error, LocalizedError, Equatable {
  case notAMember
  case publicAccessDenied

  public var errorDescription: String? {
    switch self {
    case .notAMember:
      "This agent isn't a member of this space. Choose Home, or add the agent to the space before sending. Your message is still here."
    case .publicAccessDenied:
      "This agent can't access public threads in this space. Choose a private thread or Home, or update its space access. Your message is still here."
    }
  }
}

public enum OwnedBotSpaceAdmission {
  /// The requested bots a new thread can't include until they join its space.
  /// Only the user's own bots: other people's mentions keep their usual handling.
  public static func botsToAdd(
    requested: Set<Int64>,
    ownedBots: Set<Int64>,
    members: Set<Int64>
  ) -> [Int64] {
    requested.intersection(ownedBots).subtracting(members).sorted()
  }

  /// The user's own mentioned bots that must join a chat's space before they
  /// can be added to it: the server adds only space members to space threads.
  public struct Need: Equatable, Sendable {
    public let spaceId: Int64
    public let spaceName: String
    public let botIds: [Int64]
    /// The chat is a public thread: the bot needs public-thread access, and
    /// joining is all it needs. Otherwise it also gets added to the chat.
    public let grantsPublicAccess: Bool
    /// Whether the current user may add members to the space.
    public let canAddMembers: Bool
  }

  /// Whether `userId` may add members to the space: its owners and admins,
  /// or anyone in a public space (as the server's `addSpaceMember` allows).
  public static func canAddMembers(_ db: Database, spaceId: Int64, userId: Int64) throws -> Bool {
    if try Space.fetchOne(db, id: spaceId)?.isPublic == true { return true }
    let role = try Member
      .filter(Member.Columns.spaceId == spaceId)
      .filter(Member.Columns.userId == userId)
      .fetchOne(db)?
      .role
    return role == .owner || role == .admin
  }

  /// Which of `mentionedUserIds` are the current user's bots outside `chat`'s space.
  public static func need(
    _ db: Database,
    chat: Chat,
    mentionedUserIds: Set<Int64>,
    currentUserId: Int64
  ) throws -> Need? {
    let source = try ChatParticipantsWithMembersViewModel.participantsSourceChat(db, for: chat)
    guard source.type == .thread, let spaceId = source.spaceId else { return nil }
    let owned = try BotOwner.ownedBotIds(db, ownerUserId: currentUserId).intersection(mentionedUserIds)
    guard !owned.isEmpty else { return nil }
    let members = try Set(Int64.fetchAll(
      db,
      sql: "SELECT userId FROM member WHERE spaceId = ?",
      arguments: [spaceId]
    ))
    let botIds = botsToAdd(requested: owned, ownedBots: owned, members: members)
    guard !botIds.isEmpty else { return nil }
    return try Need(
      spaceId: spaceId,
      spaceName: Space.fetchOne(db, id: spaceId)?.name ?? "this space",
      botIds: botIds,
      grantsPublicAccess: chat.isPublic == true && chat.parentChatId == nil,
      canAddMembers: canAddMembers(db, spaceId: spaceId, userId: currentUserId)
    )
  }

  /// Joins the bots to the space, then adds them to `chatId` unless the chat
  /// is public. Returns the bots that made it; throws only if none did.
  @discardableResult
  public static func admit(_ need: Need, chatId: Int64) async throws -> [Int64] {
    var admitted: [Int64] = []
    var lastError: Error?
    for botId in need.botIds {
      do {
        try await Api.realtime.send(.inviteToSpace(
          spaceId: need.spaceId,
          access: .member(canAccessPublicChats: need.grantsPublicAccess),
          userId: botId
        ))
        if !need.grantsPublicAccess {
          try await Api.realtime.send(.addChatParticipant(chatID: chatId, userID: botId))
        }
        admitted.append(botId)
      } catch {
        lastError = error
      }
    }
    if admitted.isEmpty, let lastError { throw lastError }
    return admitted
  }

  /// Confirmation copy shared by the Apple clients.
  public static func confirmationTitle(names: [String], need: Need) -> String {
    names.count == 1
      ? "Add \(names[0]) to \(need.spaceName)?"
      : "Add \(names.count) agents to \(need.spaceName)?"
  }

  public static func confirmationMessage(need: Need) -> String {
    need.grantsPublicAccess
      ? "It joins this space and can read its public threads. Everyone in the space can see it."
      : "It joins this space and this thread, and can read only the threads it's added to. Everyone in the space can see it."
  }

  public static func failureMessage(need: Need) -> String {
    "Couldn't add the agent to \(need.spaceName). Only space admins can add members."
  }
}

enum AgentThreadSpaceAccess {
  static func validate(
    botUserID: Int64,
    spaceID: Int64,
    isPublic: Bool,
    members: [InlineProtocol.Member]
  ) throws {
    guard let member = members.first(where: { $0.userID == botUserID && $0.spaceID == spaceID }) else {
      throw AgentThreadSpaceAccessError.notAMember
    }
    if isPublic, !member.canAccessPublicChats {
      throw AgentThreadSpaceAccessError.publicAccessDenied
    }
  }
}
