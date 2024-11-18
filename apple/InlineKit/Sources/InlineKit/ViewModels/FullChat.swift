import Combine
import GRDB

public struct FullMessage: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable,
  Identifiable
{
  public var user: User?
  public var message: Message

  public var id: Int64 {
    message.id
  }
}

public final class FullChatViewModel: ObservableObject, @unchecked Sendable {
  @Published public private(set) var chatItem: SpaceChatItem?
  @Published public private(set) var fullMessages: [FullMessage] = []

  public struct Section: Identifiable {
    public var id: Date
    public var date: Date
    public var messages: [FullMessage]
  }

  @Published public private(set) var messagesInSections: [Section] = []

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
  private var reversed: Bool

  public init(db: AppDatabase, peer: Peer, reversed: Bool = false) {
    self.db = db
    self.peer = peer
    self.reversed = reversed
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
          return
            try Message
            .filter(Column("peerThreadId") == id)
            .including(optional: Message.from)
            .asRequest(of: FullMessage.self)
            .fetchAll(db)
            .sorted(by: { $0.message.messageId > $1.message.messageId })

        } else if case .user(let id) = peer {
          return
            try Message
            .filter(Column("peerUserId") == id)
            .including(optional: Message.from)
            .asRequest(of: FullMessage.self)
            .fetchAll(db)
            .sorted(by: { $0.message.messageId > $1.message.messageId })

          //          if let chatId = self.chat?.id {
          //            return try Message
          //              .filter(Column("chatId") == chatId)
          //              .fetchAll(db)
          //              .sorted(by: { $0.date < $1.date })
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
          if self?.reversed == true {
            self?.fullMessages = messages.reversed()
          } else {
            self?.fullMessages = messages
          }
          self?.updateMessagesInSections()
        }
      )
  }

  func updateMessagesInSections() {
    let groupedMessages = Dictionary(grouping: self.fullMessages) { (fullMessage) -> Date in
      // Use the date component to group by day
      return Calendar.current.startOfDay(for: fullMessage.message.date)
    }

    // Convert the dictionary to an array of sections
    self.messagesInSections = groupedMessages.map { (date, messages) in
      if self.reversed {
        // Create a section header for each date
        return Section(id: date, date: date, messages: messages.reversed())
      } else {
        return Section(id: date, date: date, messages: messages)
      }
    }
    .sorted(by: { if self.reversed { return $0.date < $1.date } else { return $0.date > $1.date } })
  }
}
