import Foundation
import GRDB
import InlineProtocol
import Logger

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
  public var isSticker: Bool?
  public var hasLink: Bool?
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
  public var forwardFromPeerUserId: Int64?
  public var forwardFromPeerThreadId: Int64?
  public var forwardFromMessageId: Int64?
  public var forwardFromUserId: Int64?
  public var photoId: Int64?
  public var videoId: Int64?
  public var documentId: Int64?
  public var transactionId: String?
  public var isSticker: Bool?
  public var hasLink: Bool?
  public var entities: MessageEntities?

  private static let log = Log.scoped("Message")
  private static let allowedLinkSchemes: Set<String> = ["http", "https"]
  private static let linkDetector: NSDataDetector? = {
    try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
  }()

  public enum Columns {
    public static let globalId = Column(CodingKeys.globalId)
    public static let messageId = Column(CodingKeys.messageId)
    public static let randomId = Column(CodingKeys.randomId)
    public static let date = Column(CodingKeys.date)
    public static let text = Column(CodingKeys.text)
    public static let peerUserId = Column(CodingKeys.peerUserId)
    public static let peerThreadId = Column(CodingKeys.peerThreadId)
    public static let chatId = Column(CodingKeys.chatId)
    public static let fromId = Column(CodingKeys.fromId)
    public static let mentioned = Column(CodingKeys.mentioned)
    public static let out = Column(CodingKeys.out)
    public static let pinned = Column(CodingKeys.pinned)
    public static let editDate = Column(CodingKeys.editDate)
    public static let status = Column(CodingKeys.status)
    public static let repliedToMessageId = Column(CodingKeys.repliedToMessageId)
    public static let forwardFromPeerUserId = Column(CodingKeys.forwardFromPeerUserId)
    public static let forwardFromPeerThreadId = Column(CodingKeys.forwardFromPeerThreadId)
    public static let forwardFromMessageId = Column(CodingKeys.forwardFromMessageId)
    public static let forwardFromUserId = Column(CodingKeys.forwardFromUserId)
    public static let isSticker = Column(CodingKeys.isSticker)
    public static let photoId = Column(CodingKeys.photoId)
    public static let videoId = Column(CodingKeys.videoId)
    public static let documentId = Column(CodingKeys.documentId)
    public static let hasLink = Column(CodingKeys.hasLink)
    public static let entities = Column(CodingKeys.entities)
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

  public static let forwardFromUser = belongsTo(
    User.self,
    using: ForeignKey(["forwardFromUserId"], to: ["id"])
  )
  public var forwardFromUser: QueryInterfaceRequest<User> {
    request(for: Message.forwardFromUser)
  }

  public static let forwardFromPeerUser = belongsTo(
    User.self,
    using: ForeignKey(["forwardFromPeerUserId"], to: ["id"])
  )
  public var forwardFromPeerUser: QueryInterfaceRequest<User> {
    request(for: Message.forwardFromPeerUser)
  }

  public static let forwardFromPeerThread = belongsTo(
    Chat.self,
    using: ForeignKey(["forwardFromPeerThreadId"], to: ["id"])
  )
  public var forwardFromPeerThread: QueryInterfaceRequest<Chat> {
    request(for: Message.forwardFromPeerThread)
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

  // Relationship to translation
  public static let translations = hasMany(
    Translation.self,
    using: ForeignKey(["chatId", "messageId"], to: ["chatId", "messageId"])
  )

  public var translations: QueryInterfaceRequest<Translation> {
    request(for: Message.translations)
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
    forwardFromPeerUserId: Int64? = nil,
    forwardFromPeerThreadId: Int64? = nil,
    forwardFromMessageId: Int64? = nil,
    forwardFromUserId: Int64? = nil,
    fileId: String? = nil,
    photoId: Int64? = nil,
    videoId: Int64? = nil,
    documentId: Int64? = nil,
    transactionId: String? = nil,
    isSticker: Bool? = nil,
    hasLink: Bool? = nil,
    entities: MessageEntities? = nil
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
    self.forwardFromPeerUserId = forwardFromPeerUserId
    self.forwardFromPeerThreadId = forwardFromPeerThreadId
    self.forwardFromMessageId = forwardFromMessageId
    self.forwardFromUserId = forwardFromUserId
    self.fileId = fileId
    self.photoId = photoId
    self.videoId = videoId
    self.documentId = documentId
    self.transactionId = transactionId
    self.isSticker = isSticker
    self.hasLink = hasLink
    self.entities = entities
    updateHasLinkIfNeeded()

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
      repliedToMessageId: from.replyToMsgId,
      isSticker: from.isSticker,
      hasLink: from.hasLink
    )
  }

  public init(from: InlineProtocol.Message) {
    let forwardHeader = from.hasFwdFrom ? from.fwdFrom : nil
    let forwardPeer = forwardHeader?.hasFromPeerID == true ? forwardHeader?.fromPeerID.toPeer() : nil

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
      forwardFromPeerUserId: forwardPeer?.asUserId(),
      forwardFromPeerThreadId: forwardPeer?.asThreadId(),
      forwardFromMessageId: forwardHeader?.fromMessageID,
      forwardFromUserId: forwardHeader?.fromID,
      fileId: nil,
      photoId: from.media.photo.hasPhoto ? from.media.photo.photo.id : nil,
      videoId: from.media.video.hasVideo ? from.media.video.video.id : nil,
      documentId: from.media.document.hasDocument ? from.media.document.document.id : nil,
      isSticker: from.isSticker,
      hasLink: from.hasHasLink_p ? from.hasLink_p : nil,
      entities: from.hasEntities ? from.entities : nil
    )
  }

  public static let preview = Message(
    messageId: 1,
    fromId: 1,
    date: Date(),
    text: "This is a preview message.",
    peerUserId: 2,
    peerThreadId: nil,
    chatId: 1
  )

  private mutating func updateHasLinkIfNeeded() {
    guard hasLink != true else { return }
    if Message.detectHasLink(text: text, entities: entities) {
      hasLink = true
    }
  }

  private static func detectHasLink(text: String?, entities: MessageEntities?) -> Bool {
    if let entities,
       entities.entities.contains(where: { $0.type == .url || $0.type == .textURL })
    {
      return true
    }

    guard let text, !text.isEmpty else { return false }
    return textContainsLink(text)
  }

  private static func textContainsLink(_ text: String) -> Bool {
    guard let detector = linkDetector else { return false }
    let range = NSRange(text.startIndex..., in: text)
    var hasLink = false

    detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
      guard let url = match?.url,
            let scheme = url.scheme?.lowercased(),
            Self.allowedLinkSchemes.contains(scheme)
      else {
        return
      }
      hasLink = true
      stop.pointee = true
    }

    return hasLink
  }

  var detectedLinkPreview: UrlPreview? {
    guard hasLink == true else { return nil }
    guard let text, !text.isEmpty else { return nil }
    guard let url = Self.detectedLinkURL(text: text, entities: entities) else { return nil }

    return UrlPreview(
      id: Self.fallbackLinkPreviewId(messageId: messageId),
      url: url.absoluteString,
      siteName: url.host,
      title: url.absoluteString,
      description: nil,
      photoId: nil,
      duration: nil
    )
  }

  private static func detectedLinkURL(text: String, entities: MessageEntities?) -> URL? {
    if let entityURL = linkURL(from: text, entities: entities) {
      return entityURL
    }
    return firstLinkURL(in: text)
  }

  private static func linkURL(from text: String, entities: MessageEntities?) -> URL? {
    guard let entities else { return nil }
    let sorted = entities.entities.sorted { $0.offset < $1.offset }

    for entity in sorted {
      switch entity.type {
        case .url:
          let range = NSRange(location: Int(entity.offset), length: Int(entity.length))
          guard range.location >= 0, range.location + range.length <= text.utf16.count else { continue }
          let substring = (text as NSString).substring(with: range)
          if let url = urlFromString(substring) {
            return url
          }

        case .textURL:
          if case let .textURL(textURL) = entity.entity,
             let url = urlFromString(textURL.url)
          {
            return url
          }

        default:
          continue
      }
    }

    return nil
  }

  private static func firstLinkURL(in text: String) -> URL? {
    guard let detector = linkDetector else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    var firstURL: URL? = nil

    detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
      guard let url = match?.url,
            let scheme = url.scheme?.lowercased(),
            Self.allowedLinkSchemes.contains(scheme)
      else {
        return
      }

      firstURL = url
      stop.pointee = true
    }

    return firstURL
  }

  private static func urlFromString(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let url = URL(string: trimmed),
       let scheme = url.scheme?.lowercased(),
       allowedLinkSchemes.contains(scheme)
    {
      return url
    }

    if let url = URL(string: "https://\(trimmed)"),
       let scheme = url.scheme?.lowercased(),
       allowedLinkSchemes.contains(scheme)
    {
      return url
    }

    return nil
  }

  private static func fallbackLinkPreviewId(messageId: Int64) -> Int64 {
    let baseId = messageId == 0 ? 1 : messageId
    return baseId > 0 ? -baseId : baseId
  }
}

// MARK: - UI helpers

public extension Message {
  /// Returns a string representation of the message, including emojis for different media types.
  var stringRepresentationWithEmoji: String {
    if let text, !text.isEmpty {
      text
    } else if isSticker == true {
      "🖼️ Sticker"
    } else if fileId != nil {
      "📄 File"
    } else if let _ = photoId {
      "🖼️ Photo"
    } else if let _ = videoId {
      "🎥 Video"
    } else if let _ = documentId {
      "📄 Document"
    } else {
      "Message"
    }
  }

  /// Returns a string representation of the message without emoji prefixes.
  var stringRepresentationPlain: String {
    if let text, !text.isEmpty {
      text
    } else if isSticker == true {
      "Sticker"
    } else if fileId != nil {
      "File"
    } else if let _ = photoId {
      "Photo"
    } else if let _ = videoId {
      "Video"
    } else if let _ = documentId {
      "Document"
    } else {
      "Message"
    }
  }

  var outgoing: Bool {
    out ?? false
  }
}

public extension InlineProtocol.Message {
  var stringRepresentationWithEmoji: String {
    if hasMessage {
      message
    } else if isSticker == true {
      "🖼️ Sticker"
    } else if case .nudge = media.media {
      "👋 Nudge"
    } else if media.photo.hasPhoto {
      "🖼️ Photo"
    } else if media.video.hasVideo {
      "🎥 Video"
    } else if media.document.hasDocument {
      "📄 Document"
    } else {
      "Message"
    }
  }

  var stringRepresentationPlain: String {
    if hasMessage {
      message
    } else if isSticker == true {
      "Sticker"
    } else if case .nudge = media.media {
      "Nudge"
    } else if media.photo.hasPhoto {
      "Photo"
    } else if media.video.hasVideo {
      "Video"
    } else if media.document.hasDocument {
      "Document"
    } else {
      "Message"
    }
  }
}

// MARK: - DB Helpers

public extension Message {
  // todo create another one for fetching

  @discardableResult
  mutating func saveMessage(
    _ db: Database,
    onConflict: Database.ConflictResolution = .abort,
    publishChanges: Bool = false
  ) throws -> Message {
    var isExisting = false

    // Check if message exists
    if globalId == nil {
      if let existing = try? Message.fetchOne(db, key: ["messageId": messageId, "chatId": chatId]) {
        globalId = existing.globalId

        fileId = fileId ?? existing.fileId
        photoId = photoId ?? existing.photoId
        documentId = documentId ?? existing.documentId
        videoId = videoId ?? existing.videoId
        hasLink = hasLink ?? existing.hasLink
        entities = entities ?? existing.entities
        transactionId = existing.transactionId
        isExisting = true
      }
    } else {
      isExisting = true
    }

    updateHasLinkIfNeeded()

    // Save the message
    let savedMessage = try saveAndFetch(db, onConflict: .ignore)

    // Publish changes if needed
    if publishChanges {
      let messageForPublish = self
      let peer = peerId // Capture the peer value
      let wasExisting = isExisting

      db.afterNextTransaction { _ in
        Task { @MainActor in
          if wasExisting {
            await MessagesPublisher.shared.messageUpdated(message: messageForPublish, peer: peer, animated: false)
          } else {
            await MessagesPublisher.shared.messageAdded(message: messageForPublish, peer: peer)
          }
        }
      }
    }

    return savedMessage
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
      message.transactionId = existing.transactionId
      message.hasLink = existing.hasLink
      message.editDate = editDate.map { Date(timeIntervalSince1970: TimeInterval($0)) }
      // ... anything else?
    } else {
      // attach main photo
      // TODO: handle multiple files
      let file: File? =
        if let photo = photo?.first {
          try? File.save(db, apiPhoto: photo)
        } else {
          nil
        }
      message.fileId = file?.id

      try message.saveMessage(db, publishChanges: false) // publish is below
    }

    if publishChanges {
      let messageForPublish = message
      let peer = messageForPublish.peerId
      // Publish changes when save is successful
      if isUpdate {
        db.afterNextTransaction { _ in
          Task { @MainActor in
            await MessagesPublisher.shared.messageUpdated(message: messageForPublish, peer: peer, animated: false)
          }
        }
      } else {
        db.afterNextTransaction { _ in
          // This code runs after the transaction successfully commits
          Task { @MainActor in
            await MessagesPublisher.shared.messageAdded(message: messageForPublish, peer: peer)
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
      message.transactionId = message.transactionId ?? existing.transactionId
      message.isSticker = message.isSticker ?? existing.isSticker
      message.hasLink = message.hasLink ?? existing.hasLink
      message.editDate = message.editDate ?? existing.editDate
      message.repliedToMessageId = message.repliedToMessageId ?? existing.repliedToMessageId
      message.forwardFromPeerUserId = message.forwardFromPeerUserId ?? existing.forwardFromPeerUserId
      message.forwardFromPeerThreadId = message.forwardFromPeerThreadId ?? existing.forwardFromPeerThreadId
      message.forwardFromMessageId = message.forwardFromMessageId ?? existing.forwardFromMessageId
      message.forwardFromUserId = message.forwardFromUserId ?? existing.forwardFromUserId

      if protocolMessage.hasReactions {
        for reaction in protocolMessage.reactions.reactions {
          Self.log.debug("Saving reaction: \(reaction)")
          try Reaction.save(db, protocolMessage: reaction)
        }
      }

      // Update media selectively if needed
      if protocolMessage.hasMedia {
        try processMediaAttachments(db, protocolMessage: protocolMessage, message: &message)
      }

      // 2. Then save attachments, using the now-persisted message.globalId
      if protocolMessage.hasAttachments {
        for attachment in protocolMessage.attachments.attachments {
          try Attachment.saveWithInnerItems(db, attachment: attachment, messageClientGlobalId: message.globalId!)
        }
      }

      try message.saveMessage(db, publishChanges: false) // publish is below
    } else {
      // Process media attachments if present
      if protocolMessage.hasMedia {
        try processMediaAttachments(db, protocolMessage: protocolMessage, message: &message)
      }

      if protocolMessage.hasReactions {
        for reaction in protocolMessage.reactions.reactions {
          try Reaction.save(db, protocolMessage: reaction)
        }
      }

      let message = try message.saveMessage(db, publishChanges: false) // publish is below

      if protocolMessage.hasAttachments {
        for attachment in protocolMessage.attachments.attachments {
          try Attachment.saveWithInnerItems(db, attachment: attachment, messageClientGlobalId: message.globalId!)
        }
      }
    }

    if publishChanges {
      let messageForPublish = message
      let peer = messageForPublish.peerId
      // Publish changes when save is successful
      if isUpdate {
        db.afterNextTransaction { _ in
          Task { @MainActor in
            await MessagesPublisher.shared.messageUpdated(message: messageForPublish, peer: peer, animated: false)
          }
        }
      } else {
        db.afterNextTransaction { _ in
          // This code runs after the transaction successfully commits
          Task { @MainActor in
            await MessagesPublisher.shared.messageAdded(message: messageForPublish, peer: peer)
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

public extension Message {
  var isEdited: Bool {
    editDate != nil
  }

  var hasPhoto: Bool {
    fileId != nil || photoId != nil
  }

  var hasVideo: Bool {
    videoId != nil
  }

  var hasText: Bool {
    guard let text else { return false }
    return !text.isEmpty
  }

  var hasUnsupportedTypes: Bool {
    false
  }
}

public extension Message {
  /// Deletes the given messages from the database and makes sure the parent chat's
  /// `lastMsgId` stays consistent after the deletion.
  ///
  /// - Parameters:
  ///   - db: The GRDB `Database` instance to perform the deletion on.
  ///   - messageIds: An array of **absolute** message IDs to delete.
  ///   - chatId: The identifier of the chat the messages belong to.
  /// - Throws: Rethrows any database error that occurs.
  static func deleteMessages(
    _ db: Database,
    messageIds: [Int64],
    chatId: Int64,
    deleteMedia: Bool = false
  ) throws {
    // Fetch the chat once so we can update its `lastMsgId` if needed.
    let chat = try Chat.fetchOne(db, id: chatId)

    // Keep track of the current `lastMsgId` so we can update it when we delete it.
    var prevChatLastMsgId = chat?.lastMsgId

    for messageId in messageIds {
      // If the message we are about to delete is the last message of the chat,
      // we need to promote the previous message (if any) to be the new last one.
      if prevChatLastMsgId == messageId {
        let previousMessage = try Message
          .filter(Column("chatId") == chat?.id)
          .order(Column("date").desc)
          .limit(1, offset: 1)
          .fetchOne(db)

        var updatedChat = chat
        updatedChat?.lastMsgId = previousMessage?.messageId
        try updatedChat?.save(db)

        // Preserve the information that we have already handled the current
        // `lastMsgId` so subsequent deletions in the same batch don't repeat
        // the update work unnecessarily.
        prevChatLastMsgId = messageId
      }

      // Remove the message itself.
      try Message
        .filter(Column("messageId") == messageId)
        .filter(Column("chatId") == chatId)
        .deleteAll(db)
    }
  }
}
