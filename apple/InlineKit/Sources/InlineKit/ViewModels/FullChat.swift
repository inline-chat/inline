import Combine
import GRDB
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
  public var user: User?
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

  public var from: User? {
    senderInfo?.user
  }

  // stable id
  public var id: Int64 {
    message.globalId ?? message.id
    //    message.id
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
    attachments: [FullAttachment]
  ) {
    self.senderInfo = senderInfo
    self.message = message
    self.reactions = reactions
    self.repliedToMessage = repliedToMessage
    self.attachments = attachments
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

  public func refetchChatView() {
    Log.shared.debug("Refetching chat view for peer \(peer)")
//    Task {
//      do {
//        return try await DataManager.shared.getChatHistory(peerUserId: nil, peerThreadId: nil, peerId: peer)
//      } catch {
//        Log.shared.error("Failed to refetch chat view \(error)")
//      }
//    }

    Task {
      // Fetch user before hand
      if peerUser == nil {
        do {
          if let userId = peer.asUserId() {
            try await DataManager.shared.getUser(id: userId)
          }
        } catch {
          Log.shared.error("Failed to refetch user info \(error)")
        }
      }

      await Realtime.shared
        .invokeWithHandler(.getChatHistory, input: .getChatHistory(.with { input in
          input.peerID = peer.toInputPeer()
        }))
    }

    // Refetch user info (online, lastSeen)
    Task {
      do {
        if let userId = peer.asUserId() {
          return try await DataManager.shared.getUser(id: userId)
        }
      } catch {
        Log.shared.error("Failed to refetch user info \(error)")
      }
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
