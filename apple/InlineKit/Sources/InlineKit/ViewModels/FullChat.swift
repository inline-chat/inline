import Auth
import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger
import SwiftUI
import QuartzCore

public struct FullAttachment: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var id: Int64 {
    attachment.id ?? 0
  }

  public var attachment: Attachment
  public var externalTask: ExternalTask?
  public var urlPreview: UrlPreview?
  public var photoInfo: PhotoInfo?
  public var authorPhotoInfo: PhotoInfo?
  public var userInfo: UserInfo?

  enum CodingKeys: String, CodingKey {
    case attachment
    case externalTask
    case urlPreview
    case userInfo
    case photoInfo
    case authorPhotoInfo
  }

  public init(
    attachment: Attachment,
    externalTask: ExternalTask? = nil,
    urlPreview: UrlPreview? = nil,
    photoInfo: PhotoInfo? = nil,
    authorPhotoInfo: PhotoInfo? = nil,
    userInfo: UserInfo? = nil
  ) {
    self.attachment = attachment
    self.externalTask = externalTask
    self.urlPreview = urlPreview
    self.photoInfo = photoInfo
    self.authorPhotoInfo = authorPhotoInfo
    self.userInfo = userInfo
  }
}

public struct FullReaction: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var id: Int64 {
    reaction.id ?? 0
  }

  public var reaction: Reaction
  public var userInfo: UserInfo?

  public init(reaction: Reaction, userInfo: UserInfo? = nil) {
    self.reaction = reaction
    self.userInfo = userInfo
  }
}

public struct FullMessage: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var file: File?
  public var senderInfo: UserInfo?
  public var forwardFromUserInfo: UserInfo?
  public var forwardFromPeerUserInfo: UserInfo?
  public var forwardFromChatInfo: Chat?
  public var message: Message
  public var replyThread: Chat?
  public var reactions: [FullReaction]
  public var acknowledgements: [FullAcknowledgement]? = nil
  public var currentUserAcknowledgement: Acknowledgement? = nil
  public var repliedToMessage: EmbeddedMessage?
  public var attachments: [FullAttachment]
  public var photoInfo: PhotoInfo?
  public var videoInfo: VideoInfo?
  public var documentInfo: DocumentInfo?
  public var translations: [Translation]

  public var from: User? {
    senderInfo?.user
  }

  public func translation(for language: String) -> Translation? {
    translations.first { $0.language == language }
  }

  public var groupedReactions: [GroupedReaction] {
    let groupedDictionary = Dictionary(grouping: reactions, by: { $0.reaction.emoji })
    return groupedDictionary.enumerated().map { _, item in
      let (emoji, reactions) = item
      return GroupedReaction(emoji: emoji, reactions: reactions)
    }.sorted { $0.maxDate < $1.maxDate }
  }

  // stable id
  public var id: Int64 {
    message.globalId ?? message.id
  }

  public var hasMedia: Bool {
    photoInfo != nil || videoInfo != nil || documentInfo != nil || file != nil
  }

  //  public static let preview = FullMessage(user: User, message: Message)
  public init(
    senderInfo: UserInfo?,
    forwardFromUserInfo: UserInfo? = nil,
    forwardFromPeerUserInfo: UserInfo? = nil,
    forwardFromChatInfo: Chat? = nil,
    message: Message,
    replyThread: Chat? = nil,
    reactions: [FullReaction],
    repliedToMessage: EmbeddedMessage?,
    attachments: [FullAttachment],
    translations: [Translation] = []
  ) {
    self.senderInfo = senderInfo
    self.forwardFromUserInfo = forwardFromUserInfo
    self.forwardFromPeerUserInfo = forwardFromPeerUserInfo
    self.forwardFromChatInfo = forwardFromChatInfo
    self.message = message
    self.replyThread = replyThread
    self.reactions = reactions
    self.repliedToMessage = repliedToMessage
    self.attachments = attachments
    self.translations = translations

    // Group reactions and store on a property
//    if reactions.count > 0 {
//      let groupedDictionary = Dictionary(grouping: reactions, by: { $0.emoji })
//      groupedReactions = groupedDictionary.enumerated().map { _, item in
//        let (emoji, reactions) = item
//        return GroupedReaction(emoji: emoji, reactions: reactions)
//      }
//    }
  }

  public init(from embeddedMessage: EmbeddedMessage) {
    message = embeddedMessage.message
    senderInfo = embeddedMessage.senderInfo
    forwardFromUserInfo = nil
    forwardFromPeerUserInfo = nil
    forwardFromChatInfo = nil
    replyThread = nil
    translations = embeddedMessage.translations
    photoInfo = embeddedMessage.photoInfo
    videoInfo = embeddedMessage.videoInfo
    reactions = []
    repliedToMessage = nil
    attachments = []
  }
}

public extension FullMessage {
  var canReply: Bool {
    guard !message.isServiceMessage else { return false }
    guard let status = message.status else { return true }
    switch status {
      case .sent:
        return true
      case .sending, .failed:
        return false
    }
  }

  var serviceDisplayText: String? {
    message.serviceDisplayText(actorName: senderInfo?.user.shortDisplayName)
  }

  var serviceDisplaySegments: [MessageServiceDisplaySegment]? {
    message.serviceDisplaySegments(actorName: senderInfo?.user.shortDisplayName)
  }
}

public extension EmbeddedMessage {
  var serviceDisplayText: String? {
    message.serviceDisplayText(actorName: senderInfo?.user.shortDisplayName)
  }

  var serviceDisplaySegments: [MessageServiceDisplaySegment]? {
    message.serviceDisplaySegments(actorName: senderInfo?.user.shortDisplayName)
  }
}

public extension FullMessage {
  var threadCardTitle: String? {
    if let title = message.threadCard?.title {
      return title
    }
    return replyThreadCustomTitle
  }

  var replyThreadCustomTitle: String? {
    guard replyThread?.isUntitled != true,
          let title = replyThread?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
          title.isEmpty == false
    else {
      return nil
    }

    return title
  }
}

public extension FullMessage {
  var debugDescription: String {
    """
    FullMessage(
        id: \(id),
        file: \(String(describing: file)),
        from: \(String(describing: from)),
        message: \(message),
        reactions: \(reactions),
        repliedToMessage: \(String(describing: repliedToMessage)),
        attachments: \(attachments)
    )
    """
  }
}

// Helpers
public extension FullMessage {
  var peerId: Peer {
    message.peerId
  }

  var chatId: Int64 {
    message.chatId
  }
}

public extension FullMessage {
  static func queryRequest(currentUserId: Int64? = Auth.shared.getCurrentUserId()) -> QueryInterfaceRequest<FullMessage> {
    Message
      // user info
      .including(
        optional:
        Message.from
          .forKey(CodingKeys.senderInfo)
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      )
      .including(
        optional:
        Message.forwardFromUser
          .forKey(CodingKeys.forwardFromUserInfo)
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      )
      .including(
        optional:
        Message.forwardFromPeerUser
          .forKey(CodingKeys.forwardFromPeerUserInfo)
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      )
      .including(
        optional:
        Message.forwardFromPeerThread
          .forKey(CodingKeys.forwardFromChatInfo)
      )
      .including(
        all: Message.acknowledgements.forKey("acknowledgements")
          .order(Column("userId"))
          .including(optional: Acknowledgement.user.forKey("userInfo")
            .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto)))
      )
      .including(optional: Message.currentUserAcknowledgement
        .filter(Acknowledgement.Columns.userId == (currentUserId ?? 0))
        .forKey("currentUserAcknowledgement"))
      .including(optional: Message.replyThread.forKey(CodingKeys.replyThread))
      .including(optional: Message.file)
      .including(
        all: Message.reactions
          .including(
            optional: Reaction.user.forKey("userInfo")
              .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
          )
      )
      .including(
        optional: Message.repliedToMessage.forKey("repliedToMessage")
          .including(
            optional: Message.from
              .forKey(EmbeddedMessage.CodingKeys.senderInfo)
              .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
          )
          .including(all: Message.translations.forKey(EmbeddedMessage.CodingKeys.translations))
          .including(
            optional: Message.photo.forKey(EmbeddedMessage.CodingKeys.photoInfo)
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          )
          .including(
            optional: Message.video.forKey(EmbeddedMessage.CodingKeys.videoInfo)
              .including(
                optional: Video.thumbnail
                  .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
                  .forKey(VideoInfo.CodingKeys.thumbnail)
              )
          )
          .including(
            optional: Message.document.forKey(EmbeddedMessage.CodingKeys.document)
          )
      )
      .including(
        all: Message.attachments
          .including(
            optional: Attachment.externalTask
              .including(
                optional: ExternalTask.assignedUser
                  .forKey(FullAttachment.CodingKeys.userInfo)
                  .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
              )
          )
          .including(
            optional: Attachment.urlPreview
              .including(
                optional: UrlPreview.photo.forKey(FullAttachment.CodingKeys.photoInfo)
                  .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
              )
              .including(
                optional: UrlPreview.authorPhoto.forKey(FullAttachment.CodingKeys.authorPhotoInfo)
                  .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
              )
          )
      )
      // Include photo info with sizes
      .including(
        optional: Message.photo.forKey(CodingKeys.photoInfo)
          .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
      )
      // Include video info with thumbnail
      .including(
        optional: Message.video.forKey(CodingKeys.videoInfo)
          .including(
            optional: Video.thumbnail
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
              .forKey(VideoInfo.CodingKeys.thumbnail)
          )
      )
      // Include document info with thumbnail
      .including(
        optional: Message.document.forKey(CodingKeys.documentInfo)
          .including(
            optional: Document.thumbnail
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
              .forKey(DocumentInfo.CodingKeys.thumbnail)
          )
      )
      // Include all translations
      .including(all: Message.translations.forKey(CodingKeys.translations))
      .asRequest(of: FullMessage.self)
  }
}

/// The identities read by the projection above. Keep this beside queryRequest:
/// a new joined relation must also declare its raw keys and shared rows here.
/// These values exist only while an async publisher SQL attempt is suspended.
struct MessageProjectionDependencies: Sendable {
  enum Identity: Hashable, Sendable {
    case peer(Peer), message(chatId: Int64, messageId: Int64), user(Int64)
    case photo(Int64), serverPhoto(Int64), video(Int64), serverVideo(Int64)
    case document(Int64), serverDocument(Int64), file(String)
    case attachment(Int64), task(Int64), urlPreview(Int64)

    var isSharedRow: Bool {
      switch self {
      case .peer, .message, .user: false
      default: true
      }
    }
  }

  var identities: Set<Identity> = []
  // A coarse reload cannot prove which shared media/card rows its writer changed.
  // It remains conservative for projections that actually read those rows.
  var unknownSharedRows = false

  init(identities: Set<Identity> = []) { self.identities = identities }

  mutating func formUnion(_ other: Self) {
    identities.formUnion(other.identities)
    unknownSharedRows = unknownSharedRows || other.unknownSharedRows
  }

  func overlaps(_ other: Self) -> Bool {
    !identities.isDisjoint(with: other.identities)
      || (unknownSharedRows && other.identities.contains(where: \.isSharedRow))
      || (other.unknownSharedRows && identities.contains(where: \.isSharedRow))
  }

  /// Explicit row writers also report keys that may be absent from a later
  /// message projection. Rollback discards this signal with the transaction.
  func publishAfterCommit(_ db: Database, publisher: MessagesPublisher? = nil,
                          beforeAsyncNotification: (@Sendable () async -> Void)? = nil) {
    guard !identities.isEmpty || unknownSharedRows else { return }
    db.afterNextTransaction { _ in
      // A suspended SQL result can resume before the next MainActor job. The
      // committed keys must reach the existing read fence before returning.
      (publisher ?? .shared).projectionRowsCommitted(self)
      if let beforeAsyncNotification {
        // Internal scheduling seam only; it cannot omit/delay registration.
        Task { @MainActor in await beforeAsyncNotification() }
      }
    }
  }

  mutating func include(_ photo: Photo) {
    if let id = photo.id { identities.insert(.photo(id)) }
    identities.insert(.serverPhoto(photo.photoId))
  }

  mutating func include(_ video: Video) {
    if let id = video.id { identities.insert(.video(id)) }
    identities.insert(.serverVideo(video.videoId))
    if let id = video.thumbnailPhotoId { identities.insert(.photo(id)) }
  }

  mutating func include(_ user: UserInfo?) {
    guard let user else { return }
    identities.insert(.user(user.id))
    if let fileId = user.user.profileFileId { identities.insert(.file(fileId)) }
    for file in user.profilePhoto ?? [] { include(file) }
  }

  mutating func include(_ file: File) {
    identities.insert(.file(file.id))
    // User.photos is an inverse collection: a new file can enter a held
    // snapshot without its new primary key appearing in that old result.
    if let userId = file.profileForUserId { identities.insert(.user(userId)) }
  }

  mutating func include(_ photo: PhotoInfo?) {
    guard let photo else { return }
    include(photo.photo)
    for size in photo.sizes { identities.insert(.photo(size.photoId)) }
  }

  mutating func include(_ video: VideoInfo?) {
    guard let video else { return }
    include(video.video)
    include(video.thumbnail)
  }

  mutating func include(_ document: DocumentInfo?) {
    guard let document else { return }
    include(document.document)
    include(document.thumbnail)
  }

  mutating func include(_ document: Document?) {
    guard let document else { return }
    if let id = document.id { identities.insert(.document(id)) }
    identities.insert(.serverDocument(document.documentId))
    if let id = document.thumbnailPhotoId { identities.insert(.photo(id)) }
  }

  mutating func include(_ message: Message) {
    identities.insert(.peer(message.peerId))
    identities.insert(.peer(.thread(id: message.chatId)))
    identities.insert(.message(chatId: message.chatId, messageId: message.messageId))
    identities.insert(.user(message.fromId))
    if let id = message.repliedToMessageId {
      identities.insert(.message(chatId: message.chatId, messageId: id))
    }
    if let id = message.forwardFromUserId { identities.insert(.user(id)) }
    if let id = message.forwardFromPeerUserId { identities.insert(.user(id)) }
    if let id = message.forwardFromPeerThreadId { identities.insert(.peer(.thread(id: id))) }
    if let id = message.fileId { identities.insert(.file(id)) }
    if let id = message.photoId { identities.insert(.serverPhoto(id)) }
    if let id = message.videoId { identities.insert(.serverVideo(id)) }
    if let id = message.documentId { identities.insert(.serverDocument(id)) }
    // Block images are embedded protobuf snapshots, rather than SQL joins.
    // A replacement of that snapshot is still a mutation of this message/peer.
  }

  mutating func includeChatMutation(_ chat: Chat) {
    identities.insert(.peer(.thread(id: chat.id)))
    // The replyThread association joins both columns. An absent/new/moved
    // child invalidates that exact anchor, not unrelated rows in its parent.
    if let parentChatId = chat.parentChatId, let parentMessageId = chat.parentMessageId {
      identities.insert(.message(chatId: parentChatId, messageId: parentMessageId))
    }
  }

  mutating func include(_ chat: Chat) {
    includeChatMutation(chat)
    // Parent deletion can SET NULL this raw FK on an otherwise surviving
    // forwarded child Chat. Its snapshot must respect the parent removal.
    if let parentChatId = chat.parentChatId { identities.insert(.peer(.thread(id: parentChatId))) }
  }

  mutating func include(_ acknowledgement: FullAcknowledgement) {
    identities.insert(.peer(.thread(id: acknowledgement.acknowledgement.chatId)))
    identities.insert(.user(acknowledgement.acknowledgement.userId))
    include(acknowledgement.userInfo)
  }
}

extension FullMessage {
  var projectionDependencies: MessageProjectionDependencies {
    var dependencies = MessageProjectionDependencies()
    dependencies.include(message)
    dependencies.include(senderInfo)
    dependencies.include(forwardFromUserInfo)
    dependencies.include(forwardFromPeerUserInfo)
    if let chat = forwardFromChatInfo { dependencies.include(chat) }
    if let chat = replyThread { dependencies.include(chat) }
    if let file { dependencies.include(file) }
    dependencies.include(photoInfo)
    dependencies.include(videoInfo)
    dependencies.include(documentInfo)
    if let reply = repliedToMessage {
      dependencies.include(reply.message)
      dependencies.include(reply.senderInfo)
      dependencies.include(reply.photoInfo)
      dependencies.include(reply.videoInfo)
      dependencies.include(reply.document)
    }
    for reaction in reactions {
      dependencies.identities.insert(.user(reaction.reaction.userId))
      dependencies.include(reaction.userInfo)
    }
    for acknowledgement in acknowledgements ?? [] { dependencies.include(acknowledgement) }
    if let currentUserAcknowledgement { dependencies.identities.insert(.user(currentUserAcknowledgement.userId)) }
    for attachment in attachments {
      if let id = attachment.attachment.id { dependencies.identities.insert(.attachment(id)) }
      if let id = attachment.attachment.externalTaskId { dependencies.identities.insert(.task(id)) }
      if let id = attachment.attachment.urlPreviewId { dependencies.identities.insert(.urlPreview(id)) }
      if let task = attachment.externalTask {
        if let id = task.id { dependencies.identities.insert(.task(id)) }
        if let id = task.assignedUserId { dependencies.identities.insert(.user(id)) }
      }
      if let preview = attachment.urlPreview {
        dependencies.identities.insert(.urlPreview(preview.id))
        if let id = preview.photoId { dependencies.identities.insert(.serverPhoto(id)) }
        if let id = preview.authorPhotoId { dependencies.identities.insert(.serverPhoto(id)) }
        if let id = preview.videoId { dependencies.identities.insert(.serverVideo(id)) }
        if let id = preview.documentId { dependencies.identities.insert(.serverDocument(id)) }
      }
      dependencies.include(attachment.userInfo)
      dependencies.include(attachment.photoInfo)
      dependencies.include(attachment.authorPhotoInfo)
    }
    // Translations, action/block content and cursor membership belong to the
    // owning message/chat; their ordinary update/reload invalidates that peer.
    return dependencies
  }
}

public final class FullChatViewModel: ObservableObject, @unchecked Sendable {
  @Published public private(set) var chatItem: SpaceChatItem?

  public var messageIdToGlobalId: [Int64: Int64] = [:]

  public var chat: Chat? {
    chatItem?.chat
  }

  public var peerUser: User? {
    chatItem?.user
  }

  public var peerUserInfo: UserInfo? {
    chatItem?.userInfo
  }

  private var chatCancellable: AnyCancellable?
  private var refetchTask: Task<Void, Never>?
  private var historyRefetchTask: Task<Void, Never>?
  private var lastHistoryRefetchTime: CFTimeInterval = 0
  private let historyRefetchCooldown: CFTimeInterval = 1.0
  private var didStartChatObservation = false
  private let log = Log.scoped("FullChat")

  private var db: AppDatabase
  public var peer: Peer

  public init(
    db: AppDatabase,
    peer: Peer,
    initialChatItem: SpaceChatItem? = nil,
    startObservation: Bool = true
  ) {
    self.db = db
    self.peer = peer
    chatItem = initialChatItem

    if startObservation {
      startChatObservationIfNeeded()
    }
  }

  public func startChatObservationIfNeeded() {
    guard !didStartChatObservation else { return }
    didStartChatObservation = true
    fetchChat()
  }

  func fetchChat() {
    let peerId = peer
    db.warnIfInMemoryDatabaseForObservation("FullChatViewModel.chatItem")
    chatCancellable =
      ValueObservation
        .tracking { db in
          try Self.fetchChatItem(peer: peerId, db: db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { [log] in log.error("Failed to get full chat \($0)") },
          receiveValue: { [weak self] (fullChat: SpaceChatItem?) in
            if let self,
               let fullChat,

               fullChat.dialog != self.chatItem?.dialog ||
               fullChat.chat?.title != self.chatItem?.chat?.title ||
               fullChat.chat?.emoji != self.chatItem?.chat?.emoji ||
               fullChat.chat?.parentChatId != self.chatItem?.chat?.parentChatId ||
               fullChat.chat?.parentMessageId != self.chatItem?.chat?.parentMessageId ||
               fullChat.chat?.isPublic != self.chatItem?.chat?.isPublic ||
               fullChat.chat?.canUpdateInfo != self.chatItem?.chat?.canUpdateInfo ||
               fullChat.user != self.chatItem?.user
            {
              // Important Note
              // Only update if the dialog is different, ignore chat and message for performance reasons
              chatItem = fullChat
            }
          }
        )
  }

  public func refetchChatViewAsync() async {
    let peer_ = peer

    let cachedChatItem = await (try? queryChatItemFromDatabase())
    guard !Task.isCancelled else { return }

    if cachedChatItem?.chat != nil {
      await refetchHistoryAndUser(peer: peer_, cachedUser: cachedChatItem?.user)
      return
    }

    _ = try? await Api.realtime.send(.getChat(peer: peer_))

    guard !Task.isCancelled else { return }
    _ = try? await Api.realtime.send(.getChatHistory(peer: peer_))
  }

  public func refetchChatView() {
    log.trace("Refetching chat view for peer \(peer)")
    refetchTask?.cancel()
    refetchTask = Task { [weak self] in
      await self?.refetchChatViewAsync()
    }
  }

  @MainActor
  public func refetchHistoryOnly() {
    log.trace("Refetching history only for peer \(peer)")
    let now = CACurrentMediaTime()
    if historyRefetchTask != nil || now - lastHistoryRefetchTime < historyRefetchCooldown {
      return
    }
    lastHistoryRefetchTime = now
    historyRefetchTask?.cancel()
    historyRefetchTask = Task { [weak self] in
      await self?.refetchHistoryOnlyAsync()
      await MainActor.run { [weak self] in
        self?.historyRefetchTask = nil
      }
    }
  }

  private func refetchHistoryOnlyAsync() async {
    let peer_ = peer
    await refetchHistoryAndUser(peer: peer_, cachedUser: chatItem?.user)
  }

  private func refetchHistoryAndUser(peer: Peer, cachedUser: User?) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        guard !Task.isCancelled else { return }
        _ = try? await Api.realtime.send(.getChatHistory(peer: peer))
      }

      group.addTask {
        guard !Task.isCancelled else { return }
        await self.fetchPeerUserIfNeeded(peer: peer, cachedUser: cachedUser)
      }
    }
  }

  private func fetchPeerUserIfNeeded(peer: Peer, cachedUser: User?) async {
    guard peer.asUserId() != nil else { return }
    guard cachedUser?.needsDisplayNameFetch ?? true else { return }

    do {
      try Task.checkCancellation()
      _ = try await Api.realtime.send(.getChat(peer: peer))
    } catch {
      if Self.isCancellation(error) { return }
      log.error("Failed to refetch user info", error: error)
    }
  }

  /// Query chat item from database directly.
  private func queryChatItemFromDatabase() async throws -> SpaceChatItem? {
    let peer_ = peer
    return try await db.reader.read { db in
      try Self.fetchChatItem(peer: peer_, db: db)
    }
  }

  private static func fetchChatItem(peer: Peer, db: Database) throws -> SpaceChatItem? {
    let item: SpaceChatItem?
    switch peer {
      case .user:
        item = try Dialog
          .spaceChatItemQueryForUser()
          .filter(id: Dialog.getDialogId(peerId: peer))
          .fetchOne(db)

      case .thread:
        item = try Dialog
          .spaceChatItemQueryForChat()
          .filter(id: Dialog.getDialogId(peerId: peer))
          .fetchOne(db)
    }

    return try item.map { try fillMissingChat(in: $0, peer: peer, db: db) }
  }

  private static func fillMissingChat(in item: SpaceChatItem, peer: Peer, db: Database) throws -> SpaceChatItem {
    guard item.chat == nil else { return item }

    var item = item
    if let chatId = item.dialog.chatId {
      item.chat = try Chat.fetchOne(db, id: chatId)
    }
    if item.chat == nil {
      item.chat = try Chat.getByPeerId(db: db, peerId: peer)
    }
    return item
  }

  /// Ensure chat is loaded, if not fetch it
  public func ensureChat() async throws -> Chat? {
    if let chatItem, let chat = chatItem.chat {
      return chat
    }

    let peer_ = peer
    let cachedChatItem = try await queryChatItemFromDatabase()
    try Task.checkCancellation()

    if let cachedChatItem {
      await MainActor.run {
        self.chatItem = cachedChatItem
      }

      if let chat = cachedChatItem.chat {
        return chat
      }
    }

    do {
      try Task.checkCancellation()
      // Wait for getChat transaction to complete and save to database
      _ = try await Api.realtime.send(.getChat(peer: peer_))
      try Task.checkCancellation()

      if let loadedChatItem = try await queryChatItemFromDatabase() {
        await MainActor.run {
          self.chatItem = loadedChatItem
        }
        return loadedChatItem.chat
      }

      return cachedChatItem?.chat
    } catch {
      if Self.isCancellation(error) { throw error }
      if let cachedChatItem, let chat = cachedChatItem.chat {
        Log.shared.warning("Failed to refresh chat from server; using cached chat")
        return chat
      }
      log.error("Failed to ensure chat", error: error)
      throw error
    }
  }

  public func dispose() {
    chatCancellable?.cancel()
    chatCancellable = nil
    refetchTask?.cancel()
    refetchTask = nil
    historyRefetchTask?.cancel()
    historyRefetchTask = nil
  }

  deinit {
    dispose()
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? URLError)?.code == .cancelled
  }
}

public extension FullMessage {
  static func get(messageId: Int64, chatId: Int64) throws -> FullMessage? {
    try AppDatabase.shared.reader.read { db in
      try FullMessage
        .queryRequest()
        .filter(Column("messageId") == messageId)
        .filter(Column("chatId") == chatId)
        .fetchOne(db)
    }
  }
}
