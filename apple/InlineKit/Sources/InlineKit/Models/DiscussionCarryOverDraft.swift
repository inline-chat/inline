import Foundation
import GRDB
import InlineProtocol

/// Immutable public context and submission identities for the existing draft owner.
/// Provider sessions and task lifecycle continue to belong to the destination chat.
public struct DiscussionCarryOverDraft: Codable, Hashable, Sendable, DatabaseValueConvertible {
  public enum Destination: String, Codable, Sendable {
    case independent
    case anchored
  }

  public let authorUserId: Int64
  public let messages: [FullMessage]
  public let destination: Destination
  public let reservedChatId: Int64
  public let topic: String?
  public let botUserId: Int64?
  public let instruction: String
  public let instructionEntities: MessageEntities?
  public let activationRandomId: Int64
  public let forwardingRandomIds: [Int64]
  public var seedComplete: Bool

  public init(
    authorUserId: Int64,
    messages: [FullMessage],
    destination: Destination,
    reservedChatId: Int64,
    topic: String?,
    botUserId: Int64?,
    instruction: String,
    instructionEntities: MessageEntities?,
    activationRandomId: Int64 = Int64.random(in: 1 ... Int64.max),
    forwardingRandomIds: [Int64]? = nil,
    seedComplete: Bool = false
  ) {
    self.authorUserId = authorUserId
    self.messages = messages
    self.destination = destination
    self.reservedChatId = reservedChatId
    self.topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.botUserId = botUserId
    self.instruction = instruction
    self.instructionEntities = instructionEntities
    self.activationRandomId = activationRandomId
    self.forwardingRandomIds = forwardingRandomIds ?? messages.map { _ in Int64.random(in: 1 ... Int64.max) }
    self.seedComplete = seedComplete
  }

  public var sourcePeer: Peer? { messages.first?.peerId }
  public func hasSameSubmission(as other: Self) -> Bool {
    var lhs = self, rhs = other
    lhs.seedComplete = false
    rhs.seedComplete = false
    return lhs == rhs
  }
  public var sourceChatId: Int64? { messages.first?.chatId }
  public var anchorMessageId: Int64? { messages.first?.message.messageId }
  public var placeholderTitle: String {
    var currentStarter = instruction
    if let entity = instructionEntities?.entities.first, entity.offset == 0, entity.type == .mention, entity.length > 0,
       Int(entity.length) <= currentStarter.utf16.count {
      currentStarter = (currentStarter as NSString).substring(from: Int(entity.length))
    }
    let starter = currentStarter.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? messages.first?.message.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Discussion"
    return String(starter.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
  }

  public var hasValidIdentity: Bool {
    guard authorUserId > 0, reservedChatId > 0, activationRandomId > 0,
          !messages.isEmpty, messages.count == forwardingRandomIds.count,
          Set(forwardingRandomIds).count == forwardingRandomIds.count,
          forwardingRandomIds.allSatisfy({ $0 > 0 && $0 != activationRandomId }),
          let source = messages.first else { return false }
    if let botUserId {
      guard botUserId > 0, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            instructionEntities?.entities.contains(where: {
              $0.type == .mention && $0.mention.userID == botUserId && $0.offset >= 0 && $0.length > 0
                && Int($0.offset) + Int($0.length) <= instruction.utf16.count
            }) == true else { return false }
    }
    let messageIds = messages.map(\.message.messageId)
    return messageIds == messageIds.sorted() && Set(messageIds).count == messages.count
      && messages.allSatisfy {
        $0.chatId == source.chatId && $0.peerId == source.peerId && $0.message.messageId > 0
          && !$0.message.isServiceMessage && $0.message.sourceSnapshot?.isEmpty == false
          && ($0.message.status == nil || $0.message.status == .sent)
      }
  }

  public var databaseValue: DatabaseValue {
    (try? JSONEncoder().encode(self).databaseValue) ?? .null
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
    guard let data = Data.fromDatabaseValue(dbValue) else { return nil }
    return try? JSONDecoder().decode(Self.self, from: data)
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
