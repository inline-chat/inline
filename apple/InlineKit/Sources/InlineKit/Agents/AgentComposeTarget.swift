import Foundation

/// Why a draft would reach an Agent. This is a rough client-side version of
/// the bridge's intake rules, used only to decide whether Compose shows Agent
/// controls. The bridge stays authoritative about who takes a turn.
public enum AgentComposeTargetReason: Equatable, Sendable {
  case leadingMention
  case reply
  case agentThread
  case directMessage
}

public struct AgentComposeTarget: Equatable, Sendable {
  public let botUserID: Int64
  public let reason: AgentComposeTargetReason

  public init(botUserID: Int64, reason: AgentComposeTargetReason) {
    self.botUserID = botUserID
    self.reason = reason
  }
}

public enum AgentComposeTargetResolver {
  /// The leading run of mentions names who a message is for. When it names
  /// only other people or bots, the message reaches no Agent, even in that
  /// Agent's own thread or DM, so Compose shows no Agent controls.
  public static func resolve(
    leadingMentionUserIDs: [Int64],
    replyToUserID: Int64?,
    agentThreadBotUserID: Int64?,
    directMessageBotUserID: Int64?,
    isBot: (Int64) -> Bool
  ) -> AgentComposeTarget? {
    if !leadingMentionUserIDs.isEmpty {
      guard let botUserID = leadingMentionUserIDs.first(where: isBot) else { return nil }
      return AgentComposeTarget(botUserID: botUserID, reason: .leadingMention)
    }
    if let replyToUserID, isBot(replyToUserID) {
      return AgentComposeTarget(botUserID: replyToUserID, reason: .reply)
    }
    if let agentThreadBotUserID {
      return AgentComposeTarget(botUserID: agentThreadBotUserID, reason: .agentThread)
    }
    if let directMessageBotUserID {
      return AgentComposeTarget(botUserID: directMessageBotUserID, reason: .directMessage)
    }
    return nil
  }

  /// User IDs of the mention run at the start of `text`, in order. Mentions
  /// may be separated by whitespace; the first other character ends the run.
  public static func leadingMentionUserIDs(
    in text: NSAttributedString,
    key: NSAttributedString.Key = .mentionUserId
  ) -> [Int64] {
    let string = text.string as NSString
    var location = 0
    var userIDs: [Int64] = []
    while location < string.length {
      let character = string.character(at: location)
      if let scalar = Unicode.Scalar(character), CharacterSet.whitespacesAndNewlines.contains(scalar) {
        location += 1
        continue
      }
      var range = NSRange(location: NSNotFound, length: 0)
      let value = text.attribute(
        key,
        at: location,
        longestEffectiveRange: &range,
        in: NSRange(location: 0, length: string.length)
      )
      guard let userID = Self.userID(from: value), range.location != NSNotFound, range.length > 0 else {
        break
      }
      if userIDs.last != userID { userIDs.append(userID) }
      location = range.location + range.length
    }
    return userIDs
  }

  private static func userID(from value: Any?) -> Int64? {
    switch value {
    case let value as Int64: value
    case let value as Int: Int64(value)
    case let value as NSNumber: value.int64Value
    case let value as String: Int64(value)
    default: nil
    }
  }
}
