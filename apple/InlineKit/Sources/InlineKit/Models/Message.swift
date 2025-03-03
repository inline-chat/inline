import Foundation
import GRDB
import InlineProtocol

public struct ApiMessage: Codable, Hashable, Sendable {
  public var id: Int64
  public var randomId: String?
  public var peerId: Peer
  public var fromId: Int64
  public var chatId: Int64
  public var text: String?
  public var mentioned: Bool?
  public var pinned: Bool?
  public var out: Bool?
  public var editDate: Int?
  public var date: Int
  public var repliedToMessageId: Int64?

  public var photo: [ApiPhoto]?
  public var replyToMsgId: Int64?
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

  // Stable ID for fetched messages (not to be created messages)
  public var stableId: Int64 {
    globalId ?? 0
  }

  public var id: Int64 {
    // this is wrong
    messageId
  }

  public var peerId: Peer {
    if let peerUserId {
      .user(id: peerUserId)
    } else if let peerThreadId {
      .thread(id: peerThreadId)
    } else {
      fatalError("One of peerUserId or peerThreadId must be set")
    }
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

  public var fileId: String?
  public static let file = belongsTo(File.self)
  public var file: QueryInterfaceRequest<File> {
    request(for: Message.file)
  }

  // Add hasMany for all files attached to this message
  public static let files = hasMany(
    File.self,
    using: ForeignKey(["id"], to: ["messageLocalId"])
  )
  public var files: QueryInterfaceRequest<File> {
    request(for: Message.files)
  }

  public static let from = belongsTo(User.self, using: ForeignKey(["fromId"], to: ["id"]))
  public var from: QueryInterfaceRequest<User> {
    request(for: Message.from)
  }

  // needs chat id as well
  public static let repliedToMessage = belongsTo(
    Message.self,
    key: "repliedToMessage",
    using: ForeignKey(["chatId", "repliedToMessageId"], to: ["chatId", "messageId"])
  )
  public var repliedToMessage: QueryInterfaceRequest<Message> {
    request(for: Message.repliedToMessage)
  }

  public static let reactions = hasMany(
    Reaction.self,
    using: ForeignKey(["chatId", "messageId"], to: ["chatId", "messageId"])
  )
  public var reactions: QueryInterfaceRequest<Reaction> {
    request(for: Message.reactions)
  }

  public static let attachments = hasMany(
    Attachment.self,
    using: ForeignKey(["messageId"], to: ["globalId"])
  )

  public var attachments: QueryInterfaceRequest<Attachment> {
    request(for: Message.attachments)
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
    repliedToMessageId: Int64? = nil,
    fileId: String? = nil
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
    self.fileId = fileId

    if peerUserId == nil, peerThreadId == nil {
      fatalError("One of peerUserId or peerThreadId must be set")
    }
  }

  public init(from: ApiMessage) {
    let randomId: Int64? = if let randomId = from.randomId { Int64(randomId) } else { nil }

    self.init(
      messageId: from.id,
      randomId: randomId,
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
      repliedToMessageId: from.replyToMsgId
    )
  }

  public init(from: InlineProtocol.Message) {
    self.init(
      messageId: from.id,
      randomId: nil,
      fromId: from.fromID,
      date: Date(timeIntervalSince1970: TimeInterval(from.date)),
      text: from.hasMessage ? from.message : nil,
      peerUserId: from.peerID.toPeer().asUserId(),
      peerThreadId: from.peerID.toPeer().asThreadId(),
      chatId: from.chatID,
      out: from.out,
      mentioned: from.mentioned,
      pinned: false,
      editDate: from.hasEditDate ? Date(timeIntervalSince1970: TimeInterval(from.editDate)) : nil,
      status: from.out == true ? MessageSendingStatus.sent : nil,
      repliedToMessageId: from.hasReplyToMsgID ? from.replyToMsgID : nil
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

public extension Message {
  mutating func saveMessage(
    _ db: Database,
    onConflict: Database.ConflictResolution = .abort,
    publishChanges: Bool = false
  ) throws {
    var isExisting = false

    // Check if message exists
    if globalId == nil {
      if let existing = try? Message.fetchOne(db, key: ["messageId": messageId, "chatId": chatId]) {
        globalId = existing.globalId
        fileId = existing.fileId ?? fileId
        isExisting = true
      }
    } else {
      isExisting = true
    }

    // Save the message
    try save(db, onConflict: .ignore)

    // Handle unarchiving for incoming messages
    if !isExisting, out != true {
      try unarchiveIncomingMessagesChat(db, peerId: peerId)
    }

    // Publish changes if needed
    if publishChanges {
      let message = self // Create an immutable copy
      let peer = peerId // Capture the peer value
      db.afterNextTransaction { _ in
        Task { @MainActor in
          if isExisting {
            await MessagesPublisher.shared.messageUpdated(message: message, peer: peer, animated: false)
          } else {
            await MessagesPublisher.shared.messageAdded(message: message, peer: peer)
          }
        }
      }
    }
  }

  func unarchiveIncomingMessagesChat(
    _ db: Database,
    peerId: Peer
  ) throws {
    if let dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId)),
       dialog.archived == true
    {
      var updatedDialog = dialog
      updatedDialog.archived = false
      try updatedDialog.save(db, onConflict: .replace)

      // Schedule API update after transaction
      let peer = peerId
      db.afterNextTransaction { _ in
        Task {
          try? await ApiClient.shared.updateDialog(
            peerId: peer,
            pinned: nil,
            draft: nil,
            archived: false
          )
        }
      }
    }
  }
}

public extension ApiMessage {
  func saveFullMessage(
    _ db: Database, publishChanges: Bool = false
  )
    throws -> Message
  {
    let existing = try? Message.fetchOne(db, key: ["messageId": id, "chatId": chatId])
    let isUpdate = existing != nil
    var message = Message(from: self)

    if let existing {
      message.globalId = existing.globalId
      message.status = existing.status
      message.fileId = existing.fileId
      // ... anything else?
    } else {
      // attach main photo
      // TODO: handle multiple files
      let file: File? =
        if let photo = photo?.first
      {
        try? File.save(db, apiPhoto: photo)
      } else {
        nil
      }
      message.fileId = file?.id

      try message.saveMessage(db, publishChanges: false) // publish is below
    }

    if publishChanges {
      // Publish changes when save is successful
      if isUpdate {
        db.afterNextTransaction { _ in
          Task { @MainActor in
            await MessagesPublisher.shared.messageUpdated(message: message, peer: message.peerId, animated: false)
          }
        }
      } else {
        db.afterNextTransaction { _ in
          // This code runs after the transaction successfully commits
          Task { @MainActor in
            await MessagesPublisher.shared.messageAdded(message: message, peer: message.peerId)
          }
        }
      }
    }

    return message
  }
}

public extension Message {
  static func save(
    _ db: Database, protocolMessage: InlineProtocol.Message, publishChanges: Bool = false
  )
    throws -> Message
  {
    let id = protocolMessage.id
    let chatId = protocolMessage.chatID
    let existing = try? Message.fetchOne(db, key: ["messageId": id, "chatId": chatId])
    let isUpdate = existing != nil
    var message = Message(from: protocolMessage)

    if let existing {
      message.globalId = existing.globalId
      message.status = existing.status
      message.fileId = existing.fileId
      // ... anything else?
    } else {
      // attach main photo
      // TODO: handle multiple files
      if protocolMessage.hasMedia {
        var file: File? = nil

        switch protocolMessage.media.media {
          case let .photo(photo):
            file = try? File.save(db, protocolPhoto: photo.photo)
          default:
            break
        }

        message.fileId = file?.id
      }

      try message.saveMessage(db, publishChanges: false) // publish is below
    }

    if publishChanges {
      // Publish changes when save is successful
      if isUpdate {
        db.afterNextTransaction { _ in
          Task { @MainActor in
            await MessagesPublisher.shared.messageUpdated(message: message, peer: message.peerId, animated: false)
          }
        }
      } else {
        db.afterNextTransaction { _ in
          // This code runs after the transaction successfully commits
          Task { @MainActor in
            await MessagesPublisher.shared.messageAdded(message: message, peer: message.peerId)
          }
        }
      }
    }

    return message
  }
}
