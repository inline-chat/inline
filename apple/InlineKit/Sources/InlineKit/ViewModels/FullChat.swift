import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger
import SwiftUI

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
  public var user: User?

  enum CodingKeys: String, CodingKey {
    case attachment
    case externalTask
    case urlPreview
    case user
    case photoInfo
  }

  public init(
    attachment: Attachment,
    externalTask: ExternalTask? = nil,
    urlPreview: UrlPreview? = nil,
    photoInfo: PhotoInfo? = nil,
    user: User? = nil
  ) {
    self.attachment = attachment
    self.externalTask = externalTask
    self.urlPreview = urlPreview
    self.photoInfo = photoInfo
    self.user = user
  }
}

public struct FullMessage: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var file: File?
  public var senderInfo: UserInfo?
  public var message: Message
  public var reactions: [Reaction]
  public var repliedToMessage: Message?
  public var replyToMessageSender: User?
  public var replyToMessageFile: File?
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

  public var currentTranslation: Translation? {
    translation(for: UserLocale.getCurrentLanguage())
  }

  /// Grouped reactions by emoji
  public var groupedReactions: [GroupedReaction] {
    let groupedDictionary = Dictionary(grouping: reactions, by: { $0.emoji })
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
    message: Message,
    reactions: [Reaction],
    repliedToMessage: Message?,
    attachments: [FullAttachment],
    translations: [Translation] = []
  ) {
    self.senderInfo = senderInfo
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
}

public extension FullMessage {
  /// Translation text for the message, without falling back to the original text
  var translationText: String? {
    if TranslationState.shared.isTranslationEnabled(for: peerId) {
      currentTranslation?.translation
    } else {
      message.text ?? nil
    }
  }

  var isTranslated: Bool {
    translationText != nil
  }

  /// Display text for the message
  /// If translation is enabled, use the current translation
  /// Otherwise, use the message text
  var displayText: String? {
    if let translationText {
      translationText
    } else {
      message.text
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
        replyToMessageSender: \(String(describing: replyToMessageSender)),
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
      .including(optional: Message.file)
      .including(all: Message.reactions)
      .including(
        optional: Message.repliedToMessage.forKey("repliedToMessage")
          .including(optional: Message.from.forKey("replyToMessageSender"))
          .including(optional: Message.file.forKey("replyToMessageFile"))
      )
      .including(
        all: Message.attachments
          .including(
            optional: Attachment.externalTask
              .including(optional: ExternalTask.assignedUser)
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

  private var db: AppDatabase
  public var peer: Peer

  public init(db: AppDatabase, peer: Peer) {
    self.db = db
    self.peer = peer

    fetchChat()
  }

  func fetchChat() {
    let peerId = peer
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
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        // Fetch user before hand
        if self.peerUser == nil {
          do {
            if let userId = peer_.asUserId() {
              try await DataManager.shared.getUser(id: userId)
            }
          } catch {
            Log.shared.error("Failed to refetch user info \(error)")
          }
        }

        _ = try? await Realtime.shared
          .invokeWithHandler(.getChatHistory, input: .getChatHistory(.with { input in
            input.peerID = peer_.toInputPeer()
          }))
      }

      group.addTask {
        do {
          if let userId = peer_.asUserId() {
            return try await DataManager.shared.getUser(id: userId)
          }
        } catch {
          Log.shared.error("Failed to refetch user info \(error)")
        }
      }
    }
  }

  public func refetchChatView() {
    Log.shared.debug("Refetching chat view for peer \(peer)")
    Task {
      await refetchChatViewAsync()
    }
  }

  /// Ensure chat is loaded, if not fetch it
  public func ensureChat() async -> Chat? {
    if let chatItem, let chat = chatItem.chat {
      return chat
    } else {
      await refetchChatViewAsync()
      await MainActor.run {
        fetchChat()
      }
      return chatItem?.chat
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
