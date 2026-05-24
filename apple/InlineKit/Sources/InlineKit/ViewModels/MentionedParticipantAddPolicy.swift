import Foundation

public enum MentionedParticipantAddAction: Equatable, Sendable {
  case none
  case autoAdd([Int64])
  case prompt([Int64])
}

public struct MentionedParticipantAddContext: Equatable, Sendable {
  public var chatType: ChatType
  public var isPublic: Bool
  public var isReplyThread: Bool
  public var currentUserId: Int64?
  public var messageCount: Int
  public var participantIds: Set<Int64>
  public var pendingUserIds: Set<Int64>

  public init(
    chatType: ChatType,
    isPublic: Bool,
    isReplyThread: Bool,
    currentUserId: Int64?,
    messageCount: Int,
    participantIds: Set<Int64>,
    pendingUserIds: Set<Int64> = []
  ) {
    self.chatType = chatType
    self.isPublic = isPublic
    self.isReplyThread = isReplyThread
    self.currentUserId = currentUserId
    self.messageCount = messageCount
    self.participantIds = participantIds
    self.pendingUserIds = pendingUserIds
  }
}

public enum MentionedParticipantAddPolicy {
  public static let defaultAutoAddMessageLimit = 10

  public static func action(
    for mentionedUserIds: Set<Int64>,
    context: MentionedParticipantAddContext,
    autoAddMessageLimit: Int = defaultAutoAddMessageLimit
  ) -> MentionedParticipantAddAction {
    guard context.chatType == .thread else { return .none }
    guard !context.isPublic else { return .none }
    guard let currentUserId = context.currentUserId else { return .none }

    let userIds = mentionedUserIds
      .filter { $0 > 0 }
      .filter { $0 != currentUserId }
      .filter { !context.participantIds.contains($0) }
      .filter { !context.pendingUserIds.contains($0) }
      .sorted()

    guard !userIds.isEmpty else { return .none }

    if context.isReplyThread || context.messageCount < autoAddMessageLimit {
      return .autoAdd(userIds)
    }

    return .prompt(userIds)
  }
}
