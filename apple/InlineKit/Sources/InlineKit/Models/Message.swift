import Foundation
import GRDB

public struct ApiMessage: Codable, Hashable, Sendable {
  public var id: Int64
  public var peerId: Peer
  public var fromId: Int64
  public var chatId: Int64
  // Raw message text
  public var text: String?
  public var mentioned: Bool?
  public var pinned: Bool?
  public var out: Bool?
  public var editDate: Int?
  public var date: Int
  public var repliedToMessageId: Int64?
}

public enum MessageSendingStatus: Int64, Codable, DatabaseValueConvertible, Sendable {
  case sending
  case sent
  case failed
}

public struct Message: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  // Locally autoincremented id
  public var globalId: Int64?

  public var id: Int64 {
    self.messageId
  }

  // Only set for outgoing messages
  public var randomId: Int64?

  // From API, unique per chat
  public var messageId: Int64

  public var date: Date

  // Raw message text
  public var text: String?

  // One of these must be set
  public var peerUserId: Int64?
  public var peerThreadId: Int64?
  public var chatId: Int64

  // Sent from user
  public var fromId: Int64

  // Are we mentioned in this message?
  public var mentioned: Bool?

  // Is this message outgoing?
  public var out: Bool?

  // is this message pinned?
  public var pinned: Bool?

  // If message was edited
  public var editDate: Date?

  public var status: MessageSendingStatus?

  public var repliedToMessageId: Int64?

  public static let chat = belongsTo(Chat.self)
  public var chat: QueryInterfaceRequest<Chat> {
    request(for: Message.chat)
  }

  public static let from = belongsTo(User.self, using: ForeignKey(["fromId"], to: ["id"]))
  public var from: QueryInterfaceRequest<User> {
    request(for: Message.from)
  }

  public static let repliedToMessage = belongsTo(
    Message.self, using: ForeignKey(["repliedToMessageId"], to: ["messageId"])
  )
  public var repliedToMessage: QueryInterfaceRequest<Message> {
    request(for: Message.repliedToMessage)
  }

  public init(
    messageId: Int64,
    randomId: Int64? = nil,
    fromId: Int64,
    date: Date,
    text: String?,
    peerUserId: Int64?,
    peerThreadId: Int64?,
    chatId: Int64,
    out: Bool? = nil,
    mentioned: Bool? = nil,
    pinned: Bool? = nil,
    editDate: Date? = nil,
    status: MessageSendingStatus? = nil,
    repliedToMessageId: Int64? = nil
  ) {
    self.messageId = messageId
    self.randomId = randomId
    self.date = date
    self.text = text
    self.fromId = fromId
    self.peerUserId = peerUserId
    self.peerThreadId = peerThreadId
    self.editDate = editDate
    self.chatId = chatId
    self.out = out
    self.mentioned = mentioned
    self.pinned = pinned
    self.status = status
    self.repliedToMessageId = repliedToMessageId
    if peerUserId == nil && peerThreadId == nil {
      fatalError("One of peerUserId or peerThreadId must be set")
    }
  }

  public init(from: ApiMessage) {
    self.init(
      messageId: from.id,
      fromId: from.fromId,
      date: Date(timeIntervalSince1970: TimeInterval(from.date)),
      text: from.text,
      peerUserId: from.peerId.isPrivate ? from.peerId.id : nil,
      peerThreadId: from.peerId.isThread ? from.peerId.id : nil,
      chatId: from.chatId,
      out: from.out,
      mentioned: from.mentioned,
      pinned: from.pinned,
      editDate: from.editDate.map { Date(timeIntervalSince1970: TimeInterval($0)) },
      status: from.out == true ? MessageSendingStatus.sent : nil,
      repliedToMessageId: from.repliedToMessageId
    )
  }

  public static let preview = Message(
    messageId: 1,
    fromId: 1,
    date: Date(),
    text: "Hello, world!",
    peerUserId: 2,
    peerThreadId: nil,
    chatId: 1
  )
}

// MARK: Helpers

extension Message {
  public mutating func saveMessage(_ db: Database, onConflict: Database.ConflictResolution = .abort)
    throws
  {
    if self.globalId == nil {
      // Alternative:
      //          if let existing = try Message
      //            .filter(Column("messageId") == apiMessage.id)
      //            .filter(Column("chatId") == apiMessage.chatId)
      //            .fetchOne(db)
      //          {
      //            print("found existing message \(existing)")
      //            message.globalId = existing.globalId
      //          }

      if let existing =
        try? Message
        .fetchOne(db, key: ["messageId": self.messageId, "chatId": self.chatId])
      {
        self.globalId = existing.globalId
      }
    }

    try self.save(db, onConflict: .replace)
  }
}
