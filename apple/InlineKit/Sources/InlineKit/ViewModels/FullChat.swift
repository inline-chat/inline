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
  public var userInfo: UserInfo?

  enum CodingKeys: String, CodingKey {
    case attachment
    case externalTask
    case urlPreview
    case userInfo
    case photoInfo
  }

  public init(
    attachment: Attachment,
    externalTask: ExternalTask? = nil,
    urlPreview: UrlPreview? = nil,
    photoInfo: PhotoInfo? = nil,
    userInfo: UserInfo? = nil
  ) {
    self.attachment = attachment
    self.externalTask = externalTask
    self.urlPreview = urlPreview
    self.photoInfo = photoInfo
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
  public var reactions: [FullReaction]
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
    guard let status = message.status else { return true }
    switch status {
      case .sent:
        return true
      case .sending, .failed:
        return false
    }
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
  static func queryRequest() -> QueryInterfaceRequest<FullMessage> {
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
  private var historyRefetchTask: Task<Void, Never>?
  private var lastHistoryRefetchTime: CFTimeInterval = 0
  private let historyRefetchCooldown: CFTimeInterval = 1.0

  private var db: AppDatabase
  public var peer: Peer

  public init(db: AppDatabase, peer: Peer) {
    self.db = db
    self.peer = peer

    fetchChat()
  }

  func fetchChat() {
    let peerId = peer
    db.warnIfInMemoryDatabaseForObservation("FullChatViewModel.chatItem")
    chatCancellable =
      ValueObservation
        .tracking { db in
          switch peerId {
            case .user:
              // Fetch private chat
              try Dialog
                .spaceChatItemQueryForUser()
                .filter(id: Dialog.getDialogId(peerId: peerId))
                .fetchAll(db)

            case .thread:
              // Fetch thread chat
              try Dialog
                .spaceChatItemQueryForChat()
                .filter(id: Dialog.getDialogId(peerId: peerId))
                .fetchAll(db)
          }
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { Log.shared.error("Failed to get full chat \($0)") },
          receiveValue: { [weak self] (chats: [SpaceChatItem]) in
            if let self,
               let fullChat = chats.first,

               fullChat.dialog != self.chatItem?.dialog ||
               fullChat.chat?.title != self.chatItem?.chat?.title ||
               fullChat.chat?.isPublic != self.chatItem?.chat?.isPublic ||
               fullChat.user != self.chatItem?.user
            {
              // Important Note
              // Only update if the dialog is different, ignore chat and message for performance reasons
              chatItem = chats.first
            }
          }
        )
  }

  public func refetchChatViewAsync() async {
    let peer_ = peer

    let chatExists = await (try? queryChatFromDatabase()) != nil

    if chatExists {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try? await Api.realtime.send(.getChat(peer: peer_))
        }

        group.addTask {
          _ = try? await Api.realtime.send(.getChatHistory(peer: peer_))
        }

        group.addTask {
          if self.peerUser == nil {
            do {
              if let userId = peer_.asUserId() {
                try await DataManager.shared.getUser(id: userId)
              }
            } catch {
              Log.shared.error("Failed to refetch user info \(error)")
            }
          }
        }
      }
    } else {
      if self.peerUser == nil {
        do {
          if let userId = peer_.asUserId() {
            try await DataManager.shared.getUser(id: userId)
          }
        } catch {
          Log.shared.error("Failed to refetch user info \(error)")
        }
      }

      _ = try? await Api.realtime.send(.getChat(peer: peer_))

      _ = try? await Api.realtime.send(.getChatHistory(peer: peer_))
    }
  }

  public func refetchChatView() {
    Log.shared.debug("Refetching chat view for peer \(peer)")
    Task {
      await refetchChatViewAsync()
    }
  }

  @MainActor
  public func refetchHistoryOnly() {
    Log.shared.debug("Refetching history only for peer \(peer)")
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

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        _ = try? await Api.realtime.send(.getChatHistory(peer: peer_))
      }

      group.addTask {
        if self.peerUser == nil, let userId = peer_.asUserId() {
          do {
            try await DataManager.shared.getUser(id: userId)
          } catch {
            Log.shared.error("Failed to refetch user info \(error)")
          }
        }
      }
    }
  }

  /// Query chat from database directly
  private func queryChatFromDatabase() async throws -> Chat? {
    let peer_ = peer
    let chatItem = try await db.reader.read { db in
      switch peer_ {
        case .user:
          try Dialog
            .spaceChatItemQueryForUser()
            .filter(id: Dialog.getDialogId(peerId: peer_))
            .fetchOne(db)
        case .thread:
          try Dialog
            .spaceChatItemQueryForChat()
            .filter(id: Dialog.getDialogId(peerId: peer_))
            .fetchOne(db)
      }
    }
    return chatItem?.chat
  }

  /// Ensure chat is loaded, if not fetch it
  public func ensureChat() async throws -> Chat? {
    if let chatItem, let chat = chatItem.chat {
      return chat
    }

    let peer_ = peer
    do {
      // Wait for getChat transaction to complete and save to database
      _ = try await Api.realtime.send(.getChat(peer: peer_))

      // Also fetch user info if it's a DM
      if let userId = peer_.asUserId() {
        try? await DataManager.shared.getUser(id: userId)
      }

      // Update UI by fetching from database observation
      await MainActor.run {
        fetchChat()
      }

      return chatItem?.chat
    } catch {
      Log.shared.error("Failed to ensure chat", error: error)
      throw error
    }
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
