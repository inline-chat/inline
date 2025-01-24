import Combine
import GRDB
import SwiftUI

public struct FullMessage: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var file: File?
  public var from: User?
  public var message: Message
  public var reactions: [Reaction]
  public var repliedToMessage: Message?

  // stable id
  public var id: Int64 {
    message.globalId ?? message.id
    //    message.id
  }

  //  public static let preview = FullMessage(user: User, message: Message)
  public init(from: User?, message: Message, reactions: [Reaction], repliedToMessage: Message?, file: File?) {
    self.from = from
    self.message = message
    self.reactions = reactions
    self.repliedToMessage = repliedToMessage
    self.file = file
  }
}

public extension FullMessage {
  static func queryRequest() -> QueryInterfaceRequest<FullMessage> {
    return
      Message
        .including(optional: Message.from)
        .including(optional: Message.file)
        .including(all: Message.reactions)
        .asRequest(of: FullMessage.self)
  }
}

public struct FullChatSection: Identifiable, Equatable, Hashable {
  public var id: Date
  public var date: Date
}

public final class FullChatViewModel: ObservableObject, @unchecked Sendable {
  @Published public private(set) var chatItem: SpaceChatItem?
  @Published public private(set) var fullMessages: [FullMessage] = []

  public var messageIdToGlobalId: [Int64: Int64] = [:]

  public var chat: Chat? {
    chatItem?.chat
  }

  public var peerUser: User? {
    chatItem?.user
  }

  public var topMessage: FullMessage? {
    reversed ? fullMessages.first : fullMessages.last
  }

  private var chatCancellable: AnyCancellable?

  private var peerUserCancellable: AnyCancellable?

  private var db: AppDatabase
  public var peer: Peer
  public var limit: Int?

  // Descending order (newest first) if true
  private var reversed: Bool

  public init(
    db: AppDatabase, peer: Peer, reversed: Bool = true, limit: Int? = nil,
    fetchesMessages: Bool = true
  ) {
    self.db = db
    self.peer = peer
    self.reversed = reversed
    self.limit = limit
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
                      .including(optional: Chat.lastMessage))
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
          receiveValue: { [weak self] chats in
            self?.chatItem = chats.first
          }
        )
  }

  public func getGlobalId(forMessageId messageId: Int64) -> Int64? {
    messageIdToGlobalId[messageId]
  }
}
