import Combine
import GRDB

public struct FullMessage: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var user: User?
  public var message: Message
  public var reactions: [Reaction]
  // stable id
  public var id: Int64 {
    message.globalId ?? message.id
    //    message.id
  }

  //  public static let preview = FullMessage(user: User, message: Message)
}

public struct FullChatSection: Identifiable, Equatable, Hashable {
  public var id: Date
  public var date: Date
  public var messages: [FullMessage]
}

public final class FullChatViewModel: ObservableObject, @unchecked Sendable {
  @Published public private(set) var chatItem: SpaceChatItem?
  @Published public private(set) var fullMessages: [FullMessage] = []
  @Published public private(set) var messagesInSections: [FullChatSection] = []

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
  private var messagesCancellable: AnyCancellable?
  private var peerUserCancellable: AnyCancellable?

  private var db: AppDatabase
  public var peer: Peer
  public var limit: Int?

  // Descending order (newest first) if true
  private var reversed: Bool

  public init(db: AppDatabase, peer: Peer, reversed: Bool = true, limit: Int? = nil) {
    self.db = db
    self.peer = peer
    self.reversed = reversed
    self.limit = limit
    fetchChat()
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
        receiveCompletion: { Log.shared.error("Failed to get full chat \($0)") },
        receiveValue: { [weak self] chats in
          self?.chatItem = chats.first
        }
      )
  }

  func fetchMessages() {
    let peer = self.peer
    messagesCancellable =
      ValueObservation
      .tracking { db in

        if case .thread(let id) = peer {
          return
            try Message
            .filter(Column("peerThreadId") == id)
            .including(optional: Message.from)
            .asRequest(of: FullMessage.self)
            .order(Column("date").asc)
            .fetchAll(db)

        } else if case .user(let id) = peer {
          if let limit = self.limit {
            return
              try Message
              .filter(Column("peerUserId") == id)
              .including(optional: Message.from)
              .including(all: Message.reactions)
              .asRequest(of: FullMessage.self)
              .order(Column("date").desc)
              .limit(limit)
              .fetchAll(db)
          } else {
            return
              try Message
              .filter(Column("peerUserId") == id)
              .including(optional: Message.from)
              .asRequest(of: FullMessage.self)
              .order(Column("date").asc)

              .fetchAll(db)
          }
        } else {
          return []
        }
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { error in
          Log.shared.error("Failed to get messages \(error)")
        },
        receiveValue: { [weak self] messages in

          print("messages are \(messages)")
          if self?.reversed == true {
            self?.fullMessages = messages.reversed()
          } else {
            self?.fullMessages = messages
          }
        }
      )
  }

  public func getGlobalId(forMessageId messageId: Int64) -> Int64? {
    messageIdToGlobalId[messageId]
  }

  // Send message
  public func sendMessage(text: String) {
    guard let chatId = chat?.id else {
      Log.shared.warning("Chat ID is nil, cannot send message")
      return
    }

    Task {
      let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      do {
        guard !messageText.isEmpty else { return }

        let peerUserId: Int64? = if case .user(let id) = peer { id } else { nil }
        let peerThreadId: Int64? = if case .thread(let id) = peer { id } else { nil }

        let randomId = Int64.random(in: Int64.min...Int64.max)
        let message = Message(
          messageId: -randomId,
          randomId: randomId,
          fromId: Auth.shared.getCurrentUserId()!,
          date: Date(),
          text: messageText,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          chatId: chatId,
          out: true
        )

        try await db.dbWriter.write { db in
          try message.save(db)
        }

        // TODO: Scroll to bottom

        try await DataManager.shared.sendMessage(
          chatId: chatId,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          text: messageText,
          peerId: peer,
          randomId: randomId,
          repliedToMessageId: nil
        )

      } catch {
        Log.shared.error("Failed to send message", error: error)
        // Optionally show error to user
      }
    }
  }
}
