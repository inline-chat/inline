import Auth
import Foundation
import GRDB

/// Builds `FullMessage` values with one cached, batched statement per relation.
///
/// `FullMessage.queryRequest` is an association graph of ~18 joins and ~19 `including(all:)`
/// prefetches. GRDB compiles it on every fetch (association requests are not statement-cached) and each
/// prefetch re-runs the base join, so a single message costs 4.5–7 ms and a page of 50 about 10 ms, most
/// of it in `sqlite3_prepare`. This loader takes the base `Message` rows and attaches the same relations
/// with fixed SQL: the statements stay compiled per connection and each relation is one indexed lookup
/// for the whole batch. It returns the same `FullMessage` values, children in the same order.
public enum MessageBundleLoader {
  // MARK: Entry points

  /// Same result as `FullMessage.queryRequest(currentUserId:)` filtered to these rows, in their order.
  public static func load(
    _ db: Database,
    messages: [Message],
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) throws -> [FullMessage] {
    guard !messages.isEmpty else { return [] }
    var loader = Batch(db: db, currentUserId: currentUserId)
    return try loader.load(messages)
  }

  public static func fetchOne(
    _ db: Database,
    chatId: Int64,
    messageId: Int64,
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) throws -> FullMessage? {
    guard let message = try Message.fetchOne(
      db.cachedStatement(sql: "SELECT * FROM message WHERE messageId = ? AND chatId = ?"),
      arguments: [messageId, chatId]
    ) else { return nil }
    return try load(db, messages: [message], currentUserId: currentUserId).first
  }

  public static func fetchOne(
    _ db: Database,
    globalId: Int64,
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) throws -> FullMessage? {
    guard let message = try Message.fetchOne(
      db.cachedStatement(sql: "SELECT * FROM message WHERE globalId = ?"),
      arguments: [globalId]
    ) else { return nil }
    return try load(db, messages: [message], currentUserId: currentUserId).first
  }

  /// Newest-first page of a chat, the shape chat open and history paging read.
  public static func fetchLatest(
    _ db: Database,
    chatId: Int64,
    limit: Int,
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) throws -> [FullMessage] {
    let messages = try Message.fetchAll(
      db.cachedStatement(sql: "SELECT * FROM message WHERE chatId = ? ORDER BY messageId DESC LIMIT ?"),
      arguments: [chatId, limit]
    )
    return try load(db, messages: messages, currentUserId: currentUserId)
  }

  // MARK: Batch

  /// One load. Keys are collected from the base rows, then each relation is fetched once with an
  /// `IN (SELECT value FROM json_each(?))` list, so the SQL text (and the cached statement) never
  /// depends on the batch size.
  private struct Batch {
    let db: Database
    let currentUserId: Int64?
    private var userInfos: [Int64: UserInfo] = [:]
    private var photoInfosByPhotoId: [Int64: PhotoInfo] = [:]
    private var photoInfosById: [Int64: PhotoInfo] = [:]

    init(db: Database, currentUserId: Int64?) {
      self.db = db
      self.currentUserId = currentUserId
    }

    mutating func load(_ messages: [Message]) throws -> [FullMessage] {
      let byChat = Dictionary(grouping: messages, by: \.chatId)

      // Replied-to messages are embedded with their own sender, translations and media.
      var repliedByKey: [MessageKey: Message] = [:]
      for (chatId, chatMessages) in byChat {
        let ids = Set(chatMessages.compactMap(\.repliedToMessageId))
        guard !ids.isEmpty else { continue }
        for replied in try Message.fetchAll(
          db.cachedStatement(sql: """
          SELECT * FROM message WHERE chatId = ? AND messageId IN (SELECT value FROM json_each(?))
          """),
          arguments: [chatId, json(ids)]
        ) {
          repliedByKey[MessageKey(chatId: replied.chatId, messageId: replied.messageId)] = replied
        }
      }
      let replied = Array(repliedByKey.values)

      // Per-message children for both the messages and the embedded replies.
      let reactions = try fetchGrouped(
        Reaction.self, byChat: byChat,
        sql: "SELECT * FROM reaction WHERE chatId = ? AND messageId IN (SELECT value FROM json_each(?)) ORDER BY messageId, userId, emoji"
      ) { MessageKey(chatId: $0.chatId, messageId: $0.messageId) }
      let translationSource = Dictionary(grouping: messages + replied, by: \.chatId)
      let translations = try fetchGrouped(
        Translation.self, byChat: translationSource,
        sql: "SELECT * FROM translation WHERE chatId = ? AND messageId IN (SELECT value FROM json_each(?)) ORDER BY messageId, language"
      ) { MessageKey(chatId: $0.chatId, messageId: $0.messageId) }

      var acknowledgements: [MessageKey: [Acknowledgement]] = [:]
      var currentUserAcknowledgements: [Int64: Acknowledgement] = [:]
      var replyThreads: [MessageKey: Chat] = [:]
      for (chatId, chatMessages) in byChat {
        let messageIds = json(Set(chatMessages.map(\.messageId)))
        for ack in try Acknowledgement.fetchAll(
          db.cachedStatement(sql: """
          SELECT * FROM acknowledgement WHERE chatId = ? AND maxId IN (SELECT value FROM json_each(?)) ORDER BY userId
          """),
          arguments: [chatId, messageIds]
        ) {
          acknowledgements[MessageKey(chatId: ack.chatId, messageId: ack.maxId), default: []].append(ack)
        }
        if let ack = try Acknowledgement.fetchOne(
          db.cachedStatement(sql: "SELECT * FROM acknowledgement WHERE chatId = ? AND userId = ?"),
          arguments: [chatId, currentUserId ?? 0]
        ) {
          currentUserAcknowledgements[chatId] = ack
        }
        for thread in try Chat.fetchAll(
          db.cachedStatement(sql: """
          SELECT * FROM chat WHERE parentChatId = ? AND parentMessageId IN (SELECT value FROM json_each(?))
          ORDER BY id
          """),
          arguments: [chatId, messageIds]
        ) {
          if let parentMessageId = thread.parentMessageId {
            replyThreads[MessageKey(chatId: chatId, messageId: parentMessageId)] = replyThreads[
              MessageKey(chatId: chatId, messageId: parentMessageId)
            ] ?? thread
          }
        }
      }

      // Attachments hang off the message's globalId.
      let globalIds = Set(messages.compactMap(\.globalId))
      var attachmentsByGlobalId: [Int64: [Attachment]] = [:]
      if !globalIds.isEmpty {
        for attachment in try Attachment.fetchAll(
          db.cachedStatement(sql: """
          SELECT * FROM attachment WHERE messageId IN (SELECT value FROM json_each(?)) ORDER BY messageId, id
          """),
          arguments: [json(globalIds)]
        ) {
          if let messageId = attachment.messageId {
            attachmentsByGlobalId[messageId, default: []].append(attachment)
          }
        }
      }
      let allAttachments = attachmentsByGlobalId.values.flatMap { $0 }
      let externalTasks = try fetchByKey(
        ExternalTask.self,
        keys: Set(allAttachments.compactMap(\.externalTaskId)),
        sql: "SELECT * FROM externalTask WHERE id IN (SELECT value FROM json_each(?))"
      ) { $0.id }
      let urlPreviews = try fetchByKey(
        UrlPreview.self,
        keys: Set(allAttachments.compactMap(\.urlPreviewId)),
        sql: "SELECT * FROM urlPreview WHERE id IN (SELECT value FROM json_each(?))"
      ) { $0.id }

      // Belongs-to rows.
      let threadChats = try fetchByKey(
        Chat.self,
        keys: Set(messages.compactMap(\.forwardFromPeerThreadId)),
        sql: "SELECT * FROM chat WHERE id IN (SELECT value FROM json_each(?))"
      ) { $0.id }
      let fileIds = Set(messages.compactMap(\.fileId))
      var files: [String: File] = [:]
      if !fileIds.isEmpty {
        for file in try File.fetchAll(
          db.cachedStatement(sql: "SELECT * FROM file WHERE id IN (SELECT value FROM json_each(?))"),
          arguments: [json(fileIds)]
        ) {
          files[file.id] = file
        }
      }
      let mediaSources = messages + replied
      let videos = try fetchByKey(
        Video.self,
        keys: Set(mediaSources.compactMap(\.videoId)),
        sql: "SELECT * FROM video WHERE videoId IN (SELECT value FROM json_each(?))"
      ) { $0.videoId }
      let documents = try fetchByKey(
        Document.self,
        keys: Set(mediaSources.compactMap(\.documentId)),
        sql: "SELECT * FROM document WHERE documentId IN (SELECT value FROM json_each(?))"
      ) { $0.documentId }

      // Photos by server photoId (messages, url previews) and by local id (thumbnails).
      try loadPhotos(
        photoIds: Set(mediaSources.compactMap(\.photoId))
          .union(urlPreviews.values.compactMap(\.photoId))
          .union(urlPreviews.values.compactMap(\.authorPhotoId)),
        localIds: Set(videos.values.compactMap(\.thumbnailPhotoId))
          .union(documents.values.compactMap(\.thumbnailPhotoId))
      )

      // Users referenced anywhere in the graph, with their profile photos.
      var userIds = Set<Int64>()
      for message in mediaSources {
        userIds.insert(message.fromId)
        if let id = message.forwardFromUserId { userIds.insert(id) }
        if let id = message.forwardFromPeerUserId { userIds.insert(id) }
      }
      for list in reactions.values { userIds.formUnion(list.map(\.userId)) }
      for list in acknowledgements.values { userIds.formUnion(list.map(\.userId)) }
      userIds.formUnion(externalTasks.values.compactMap(\.assignedUserId))
      try loadUsers(userIds)

      func videoInfo(_ id: Int64?) -> VideoInfo? {
        guard let id, let video = videos[id] else { return nil }
        return VideoInfo(video: video, photoInfo: video.thumbnailPhotoId.flatMap { photoInfosById[$0] })
      }

      func documentInfo(_ id: Int64?) -> DocumentInfo? {
        guard let id, let document = documents[id] else { return nil }
        return DocumentInfo(document: document, photoInfo: document.thumbnailPhotoId.flatMap { photoInfosById[$0] })
      }

      return messages.map { message in
        let key = MessageKey(chatId: message.chatId, messageId: message.messageId)
        let embedded: EmbeddedMessage? = message.repliedToMessageId.flatMap { repliedId in
          repliedByKey[MessageKey(chatId: message.chatId, messageId: repliedId)].map { replied in
            EmbeddedMessage(
              message: replied,
              senderInfo: userInfos[replied.fromId],
              translations: translations[MessageKey(chatId: replied.chatId, messageId: replied.messageId)] ?? [],
              photoInfo: replied.photoId.flatMap { photoInfosByPhotoId[$0] },
              videoInfo: videoInfo(replied.videoId),
              document: replied.documentId.flatMap { documents[$0] }
            )
          }
        }
        let attachments: [FullAttachment] = (message.globalId.flatMap { attachmentsByGlobalId[$0] } ?? []).map { attachment in
          let task = attachment.externalTaskId.flatMap { externalTasks[$0] }
          let preview = attachment.urlPreviewId.flatMap { urlPreviews[$0] }
          return FullAttachment(
            attachment: attachment,
            externalTask: task,
            urlPreview: preview,
            photoInfo: preview?.photoId.flatMap { photoInfosByPhotoId[$0] },
            authorPhotoInfo: preview?.authorPhotoId.flatMap { photoInfosByPhotoId[$0] },
            userInfo: task?.assignedUserId.flatMap { userInfos[$0] }
          )
        }
        var full = FullMessage(
          senderInfo: userInfos[message.fromId],
          forwardFromUserInfo: message.forwardFromUserId.flatMap { userInfos[$0] },
          forwardFromPeerUserInfo: message.forwardFromPeerUserId.flatMap { userInfos[$0] },
          forwardFromChatInfo: message.forwardFromPeerThreadId.flatMap { threadChats[$0] },
          message: message,
          replyThread: replyThreads[key],
          reactions: (reactions[key] ?? []).map { FullReaction(reaction: $0, userInfo: userInfos[$0.userId]) },
          repliedToMessage: embedded,
          attachments: attachments,
          translations: translations[key] ?? []
        )
        full.acknowledgements = (acknowledgements[key] ?? []).map {
          FullAcknowledgement(acknowledgement: $0, userInfo: userInfos[$0.userId])
        }
        full.currentUserAcknowledgement = currentUserAcknowledgements[message.chatId]
        full.file = message.fileId.flatMap { files[$0] }
        full.photoInfo = message.photoId.flatMap { photoInfosByPhotoId[$0] }
        full.videoInfo = videoInfo(message.videoId)
        full.documentInfo = documentInfo(message.documentId)
        return full
      }
    }

    private mutating func loadUsers(_ ids: Set<Int64>) throws {
      let missing = ids.filter { userInfos[$0] == nil }
      guard !missing.isEmpty else { return }
      let list = json(missing)
      var photos: [Int64: [File]] = [:]
      for file in try File.fetchAll(
        db.cachedStatement(sql: """
        SELECT * FROM file WHERE profileForUserId IN (SELECT value FROM json_each(?)) ORDER BY profileForUserId, rowid
        """),
        arguments: [list]
      ) {
        if let userId = file.profileForUserId {
          photos[userId, default: []].append(file)
        }
      }
      for user in try User.fetchAll(
        db.cachedStatement(sql: "SELECT * FROM user WHERE id IN (SELECT value FROM json_each(?))"),
        arguments: [list]
      ) {
        userInfos[user.id] = UserInfo(user: user, profilePhotos: photos[user.id] ?? [])
      }
    }

    private mutating func loadPhotos(photoIds: Set<Int64>, localIds: Set<Int64>) throws {
      var photos: [Photo] = []
      if !photoIds.isEmpty {
        photos += try Photo.fetchAll(
          db.cachedStatement(sql: "SELECT * FROM photo WHERE photoId IN (SELECT value FROM json_each(?))"),
          arguments: [json(photoIds)]
        )
      }
      let knownLocalIds = Set(photos.compactMap(\.id))
      let missingLocal = localIds.subtracting(knownLocalIds)
      if !missingLocal.isEmpty {
        photos += try Photo.fetchAll(
          db.cachedStatement(sql: "SELECT * FROM photo WHERE id IN (SELECT value FROM json_each(?))"),
          arguments: [json(missingLocal)]
        )
      }
      let localPhotoIds = Set(photos.compactMap(\.id))
      var sizes: [Int64: [PhotoSize]] = [:]
      if !localPhotoIds.isEmpty {
        for size in try PhotoSize.fetchAll(
          db.cachedStatement(sql: """
          SELECT * FROM photoSize WHERE photoId IN (SELECT value FROM json_each(?)) ORDER BY photoId, id
          """),
          arguments: [json(localPhotoIds)]
        ) {
          sizes[size.photoId, default: []].append(size)
        }
      }
      for photo in photos {
        let info = PhotoInfo(photo: photo, sizes: photo.id.flatMap { sizes[$0] } ?? [])
        photoInfosByPhotoId[photo.photoId] = info
        if let id = photo.id { photoInfosById[id] = info }
      }
    }

    private func fetchGrouped<Record: FetchableRecord>(
      _: Record.Type,
      byChat: [Int64: [Message]],
      sql: String,
      key: (Record) -> MessageKey
    ) throws -> [MessageKey: [Record]] {
      var result: [MessageKey: [Record]] = [:]
      for (chatId, chatMessages) in byChat {
        for record in try Record.fetchAll(
          db.cachedStatement(sql: sql),
          arguments: [chatId, json(Set(chatMessages.map(\.messageId)))]
        ) {
          result[key(record), default: []].append(record)
        }
      }
      return result
    }

    private func fetchByKey<Record: FetchableRecord>(
      _: Record.Type,
      keys: Set<Int64>,
      sql: String,
      key: (Record) -> Int64?
    ) throws -> [Int64: Record] {
      guard !keys.isEmpty else { return [:] }
      var result: [Int64: Record] = [:]
      for record in try Record.fetchAll(db.cachedStatement(sql: sql), arguments: [json(keys)]) {
        if let value = key(record), result[value] == nil {
          result[value] = record
        }
      }
      return result
    }
  }

  private struct MessageKey: Hashable {
    let chatId: Int64
    let messageId: Int64
  }
}

/// A JSON array argument for `json_each`, so one statement serves any number of keys.
private func json(_ values: Set<Int64>) -> String {
  "[" + values.map(String.init).joined(separator: ",") + "]"
}

private func json(_ values: Set<String>) -> String {
  (try? JSONEncoder().encode(Array(values))).flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
}

/// A `FullMessage` query with the call shape of `FullMessage.queryRequest()` (`filter`, `order`, `limit`,
/// `fetchAll`, `fetchOne`) that reads the base rows with a plain `message` request and builds the bundles
/// with `MessageBundleLoader`. Filters and orderings apply to the `message` table, as they do on
/// `FullMessage.queryRequest()`.
public struct FullMessageQuery: @unchecked Sendable {
  public var messages: QueryInterfaceRequest<Message>
  public var currentUserId: Int64?

  public init(currentUserId: Int64? = Auth.shared.getCurrentUserId()) {
    messages = Message.all()
    self.currentUserId = currentUserId
  }

  public func filter(_ predicate: some SQLSpecificExpressible) -> Self {
    var copy = self
    copy.messages = messages.filter(predicate)
    return copy
  }

  public func filter(sql: String, arguments: StatementArguments = StatementArguments()) -> Self {
    var copy = self
    copy.messages = messages.filter(sql: sql, arguments: arguments)
    return copy
  }

  /// The message's primary key, `globalId`.
  public func filter(id globalId: Int64) -> Self {
    var copy = self
    copy.messages = messages.filter(key: globalId)
    return copy
  }

  public func order(_ orderings: any SQLOrderingTerm...) -> Self {
    var copy = self
    copy.messages = messages.order(orderings)
    return copy
  }

  public func limit(_ limit: Int, offset: Int? = nil) -> Self {
    var copy = self
    copy.messages = messages.limit(limit, offset: offset)
    return copy
  }

  public func fetchAll(_ db: Database) throws -> [FullMessage] {
    try MessageBundleLoader.load(db, messages: messages.fetchAll(db), currentUserId: currentUserId)
  }

  public func fetchOne(_ db: Database) throws -> FullMessage? {
    guard let message = try messages.fetchOne(db) else { return nil }
    return try MessageBundleLoader.load(db, messages: [message], currentUserId: currentUserId).first
  }

  public func fetchCount(_ db: Database) throws -> Int {
    try messages.fetchCount(db)
  }
}
