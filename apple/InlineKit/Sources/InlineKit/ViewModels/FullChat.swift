import Combine
import GRDB

public struct FullMessage: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable,
  Identifiable, Equatable
{
  public var user: User?
  public var message: Message

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

  // Descending order (newest first) if true
  private var reversed: Bool

  public init(db: AppDatabase, peer: Peer, reversed: Bool = true) {
    self.db = db
    self.peer = peer
    self.reversed = reversed
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
        receiveCompletion: { print("Failed to get full chat \($0)") },
        receiveValue: { [weak self] chats in
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

        if case .thread(let id) = peer {
          return
            try Message
            .filter(Column("peerThreadId") == id)
            .including(optional: Message.from)
            .asRequest(of: FullMessage.self)
            .fetchAll(db)
            .sorted(by: { $0.message.date < $1.message.date })

        } else if case .user(let id) = peer {
          return
            try Message
            .filter(Column("peerUserId") == id)
            .including(optional: Message.from)
            .asRequest(of: FullMessage.self)
            .fetchAll(db)
            .sorted(by: { $0.message.date < $1.message.date })

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

          if self?.reversed == true {
            self?.fullMessages = messages.reversed()
          } else {
            self?.fullMessages = messages
          }
          self?.updateMessagesInSections()
        }
      )
  }

  public func getGlobalId(forMessageId messageId: Int64) -> Int64? {
    messageIdToGlobalId[messageId]
  }

  func updateMessagesInSections() {
    let groupedMessages = Dictionary(grouping: fullMessages) { fullMessage -> Date in
      // Use the date component to group by day
      Calendar.current.startOfDay(for: fullMessage.message.date)
    }

    fullMessages.forEach { fullMessage in
      messageIdToGlobalId[fullMessage.message.id] = fullMessage.id
    }

    // Convert the dictionary to an array of sections
    messagesInSections = groupedMessages.map { date, messages in
      if self.reversed {
        // Create a section header for each date
        return FullChatSection(id: date, date: date, messages: messages)
      } else {
        return FullChatSection(id: date, date: date, messages: messages)
      }
    }
    .sorted(by: { if self.reversed { return $0.date > $1.date } else { return $0.date < $1.date } })
  }

  // Utils

  public func getNextSectionDate(section: FullChatSection) -> Date? {
    let index = messagesInSections.firstIndex(where: { $0.id == section.id }) ?? 0
    let nextIndex = index + 1
    if nextIndex < messagesInSections.count {
      return messagesInSections[nextIndex].date
    } else {
      return nil
    }
  }

  public func getPrevSectionDate(section: FullChatSection) -> Date? {
    let index = messagesInSections.firstIndex(where: { $0.id == section.id }) ?? 0
    let prevIndex = index - 1
    if prevIndex >= 0 {
      return messagesInSections[prevIndex].date
    } else {
      return nil
    }
  }
}
