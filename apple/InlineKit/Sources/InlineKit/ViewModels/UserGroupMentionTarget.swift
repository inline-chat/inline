import Foundation

public struct UserGroupMentionTarget: Identifiable, Equatable, Sendable {
  public var groupId: Int64
  public var spaceId: Int64?

  public var id: Int64 { groupId }

  public init(groupId: Int64, spaceId: Int64?) {
    self.groupId = groupId
    self.spaceId = spaceId
  }
}

public struct BotAgentMentionTarget: Identifiable, Hashable, Sendable {
  public let agent: MentionableBotAgent
  public let peer: Peer

  public var id: Int64 { agent.id }

  public init(agent: MentionableBotAgent, peer: Peer) {
    self.agent = agent
    self.peer = peer
  }
}

@MainActor
public enum BotAgentMentionNavigator {
  @discardableResult
  public static func open(agentId: Int64, botUserId: Int64, peer: Peer) async -> Bool {
    let directory = BotAgentDirectory.shared
    let cachedAgent = directory.cached(
      agentId: agentId,
      botUserId: botUserId,
      for: peer
    )
    let agent = if let cachedAgent {
      cachedAgent
    } else {
      try? await directory.agents(for: peer, forceRefresh: true).first {
        $0.id == agentId && $0.botUserId == botUserId
      }
    }
    guard let agent else { return false }
    NotificationCenter.default.post(
      name: .botAgentMentionTapped,
      object: nil,
      userInfo: ["target": BotAgentMentionTarget(agent: agent, peer: peer)]
    )
    return true
  }
}

public extension Notification.Name {
  static let userGroupMentionTapped = Notification.Name("UserGroupMentionTapped")
  static let botAgentMentionTapped = Notification.Name("BotAgentMentionTapped")
}
