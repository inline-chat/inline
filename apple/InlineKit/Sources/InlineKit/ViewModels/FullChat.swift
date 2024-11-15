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
          receiveCompletion: { print("Failed to get full chat \($0)") },
          receiveValue: { [weak self] chats in
            print("Got full chat \(chats.first)")
            self?.chatItem = chats.first

            // TODO: improve this
          }
        )
  }

  func fetchMessages() {
    let peer = self.peer
    messagesCancellable =
      ValueObservation
        .tracking { db in
          print("I'm getting messages \(peer)")
          if case .thread(let id) = peer {
            return try Message.filter(Column("peerThreadId") == id)
              .fetchAll(db)
              .sorted(by: { $0.date > $1.date })

          } else if case .user(let id) = peer {
            return try Message.filter(Column("peerUserId") == id)
              .fetchAll(db)
              .sorted(by: { $0.date > $1.date })
          } else {
            return []
          }
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { error in
            print("Failed to get messages \(error)")
          },
          receiveValue: { [weak self] messages in
            print("Got messages \(messages)")
            self?.messages = messages
          }
        )
  }
}
