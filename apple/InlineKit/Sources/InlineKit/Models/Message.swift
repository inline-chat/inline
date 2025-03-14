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

  /// @Deprecated
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
  public var fromId: Int64
  public var mentioned: Bool?
  public var out: Bool?
  public var pinned: Bool?
  public var editDate: Date?
  public var fileId: String?
  public var status: MessageSendingStatus?
  public var repliedToMessageId: Int64?
  public var photoId: Int64?
  public var videoId: Int64?
  public var documentId: Int64?

  enum Columns {
    static let messageId = Column(CodingKeys.messageId)
    static let photoId = Column(CodingKeys.photoId)
    static let videoId = Column(CodingKeys.videoId)
    static let documentId = Column(CodingKeys.documentId)
  }

  public static let chat = belongsTo(Chat.self)
  public var chat: QueryInterfaceRequest<Chat> {
    request(for: Message.chat)
  }

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

  // Relationship to photo using photoId (server ID)
  static let photo = belongsTo(Photo.self, using: ForeignKey(["photoId"], to: ["photoId"]))

  var photo: QueryInterfaceRequest<Photo> {
    request(for: Message.photo)
  }

  // Relationship to video using videoId (server ID)
  static let video = belongsTo(Video.self, using: ForeignKey(["videoId"], to: ["videoId"]))

  var video: QueryInterfaceRequest<Video> {
    request(for: Message.video)
  }

  // Relationship to document using documentId (server ID)
  static let document = belongsTo(Document.self, using: ForeignKey(["documentId"], to: ["documentId"]))

  var document: QueryInterfaceRequest<Document> {
    request(for: Message.document)
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
    fileId: String? = nil,
    photoId: Int64? = nil,
    videoId: Int64? = nil,
    documentId: Int64? = nil
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
    self.photoId = photoId
    self.videoId = videoId
    self.documentId = documentId

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
      repliedToMessageId: from.hasReplyToMsgID ? from.replyToMsgID : nil,
      fileId: nil,
      photoId: from.media.photo.hasPhoto ? from.media.photo.photo.id : nil,
      videoId: from.media.video.hasVideo ? from.media.video.video.id : nil,
      documentId: from.media.document.hasDocument ? from.media.document.document.id : nil
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
      // TODO: move this out of here
      try unarchiveIncomingMessagesChat(db, peerId: peerId)
    }

    // Publish changes if needed
    if publishChanges {
      let message = self // Create an immutable copy
      let peer = peerId // Capture the peer value

      db.afterNextTransaction { _ in
        Task { @MainActor in
          // HACKY WAY
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
      message.text = existing.text
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
  ) throws -> Message {
    let id = protocolMessage.id
    let chatId = protocolMessage.chatID
    let existing = try? Message.fetchOne(db, key: ["messageId": id, "chatId": chatId])
    let isUpdate = existing != nil
    var message = Message(from: protocolMessage)

    if let existing {
      message.globalId = existing.globalId
      message.status = existing.status
      message.fileId = existing.fileId
      message.date = existing.date // keep optimistic date for now until we fix message reordering
      message.photoId = message.photoId ?? existing.photoId
      message.videoId = message.videoId ?? existing.videoId
      message.documentId = message.documentId ?? existing.documentId

      // Update media selectively if needed
      if protocolMessage.hasMedia {
        try processMediaAttachments(db, protocolMessage: protocolMessage, message: &message)
      }

      try message.saveMessage(db, publishChanges: false) // publish is below
    } else {
      // Process media attachments if present
      if protocolMessage.hasMedia {
        try processMediaAttachments(db, protocolMessage: protocolMessage, message: &message)
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

  private static func processMediaAttachments(
    _ db: Database,
    protocolMessage: InlineProtocol.Message,
    message: inout Message
  ) throws {
    switch protocolMessage.media.media {
      case let .photo(photoMessage):
        try processPhotoAttachment(db, photoMessage: photoMessage.photo, message: &message)

      case let .video(videoMessage):
        try processVideoAttachment(db, videoMessage: videoMessage.video, message: &message)

      case let .document(documentMessage):
        try processDocumentAttachment(db, documentMessage: documentMessage.document, message: &message)

      default:
        break
    }
  }

  private static func processPhotoAttachment(
    _ db: Database,
    photoMessage: InlineProtocol.Photo,
    message: inout Message
  ) throws {
    // Use the new update method that preserves local paths
    let photo = try Photo.updateFromProtocol(db, protoPhoto: photoMessage)

    // Update message with photo reference
    message.photoId = photo.photoId
  }

  private static func processVideoAttachment(
    _ db: Database,
    videoMessage: InlineProtocol.Video,
    message: inout Message
  ) throws {
    // Process thumbnail photo if present
    var thumbnailPhotoId: Int64?
    if videoMessage.hasPhoto {
      let photo = try Photo.updateFromProtocol(db, protoPhoto: videoMessage.photo)
      thumbnailPhotoId = photo.id
    }

    // Use the new update method that preserves local path
    let video = try Video.updateFromProtocol(db, protoVideo: videoMessage, thumbnailPhotoId: thumbnailPhotoId)

    // Update message with video reference
    message.videoId = video.videoId
  }

  private static func processDocumentAttachment(
    _ db: Database,
    documentMessage: InlineProtocol.Document,
    message: inout Message
  ) throws {
    // Use the new update method that preserves local path
    let document = try Document.updateFromProtocol(db, protoDocument: documentMessage)

    // Update message with document reference
    message.documentId = document.documentId
  }
}
