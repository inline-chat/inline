import Foundation
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
