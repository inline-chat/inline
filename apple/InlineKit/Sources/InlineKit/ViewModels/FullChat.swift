import Combine
import GRDB
import SwiftUI

public struct FullMessage: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var user: User?
  public var file: File?
  public var from: User?
  public var message: Message
  public var reactions: [Reaction]
  public var repliedToMessage: Message?
  public var replyToMessageSender: User?

  // stable id
  public var id: Int64 {
    message.globalId ?? message.id
    //    message.id
  }

  //  public static let preview = FullMessage(user: User, message: Message)
  public init(from: User?, message: Message, reactions: [Reaction], repliedToMessage: Message?) {
    self.from = from
    self.message = message
    self.reactions = reactions
    self.repliedToMessage = repliedToMessage
  }
}

public extension FullMessage {
  static func queryRequest() -> QueryInterfaceRequest<FullMessage> {
    Message
      .including(optional: Message.from.forKey("from"))
      .including(optional: Message.file)
      .including(all: Message.reactions)
      .including(optional: Message.repliedToMessage.forKey("repliedToMessage").including(optional: Message.from.forKey("replyToMessageSender")))
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
                .filter(id: Dialog.getDialogId(peerId: peerId))
                .including(
                  optional: Dialog.peerUser
                    .including(
                      optional: User.chat
                        .including(optional: Chat.lastMessage)
                    )
                )
                .asRequest(of: SpaceChatItem.self)
                .fetchAll(db)

            case .thread:
              // Fetch thread chat
              try Dialog
                .filter(id: Dialog.getDialogId(peerId: peerId))
                .including(
                  optional: Dialog.peerThread
                    .including(optional: Chat.lastMessage)
                )
                .asRequest(of: SpaceChatItem.self)
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
}
