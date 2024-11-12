import Combine
import GRDB

public final class FullChatViewModel: ObservableObject {
  @Published public private(set) var chatItem: SpaceChatItem?
  @Published public private(set) var messages: [Message] = []

  public var chat: Chat? {
    chatItem?.chat
  }

  public var peerUser: User? {
    chatItem?.user
  }

  private var chatCancellable: AnyCancellable?
  private var messagesCancellable: AnyCancellable?
  private var peerUserCancellable: AnyCancellable?

  private var db: AppDatabase
  private var peer: Peer

  public init(db: AppDatabase, peer: Peer) {
    self.db = db
    self.peer = peer
    fetchChat()
    // TODO: Improve this
    fetchMessages()
  }

  func fetchChat() {
    let peerId = peer
    chatCancellable = ValueObservation
      .tracking { db in
        try Dialog.filter(id: Dialog.getDialogId(peerId: peerId))
          .including(
            optional: Dialog.peerThread
              .including(optional: Chat.lastMessage)
          )
          .including(
            optional: Dialog.peerUser
              .including(optional: User.chat)
          )
          .asRequest(of: SpaceChatItem.self)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { print("Failed to get full chat \($0)") },
        receiveValue: { [weak self] chats in
          self?.chatItem = chats.first
          
          // TODO: improve this
          if self?.chatItem != nil {
            self?.fetchMessages()
          }
        }
      )
  }

  func fetchMessages() {
    guard let chatId = chat?.id else { return }

    messagesCancellable =
      ValueObservation
        .tracking { db in
          try Message.filter(Column("chatId") == chatId)
            .order(Column("date").desc)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { _ in /* ignore error */ },
          receiveValue: { [weak self] messages in
            self?.messages = messages
          }
        )
  }
}
