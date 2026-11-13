#if DEBUG
import Foundation
import GRDB
import InlineProtocol

/// A signed-out, in-memory chat for list development (debug builds only):
/// hundreds of messages with names, replies, reactions, photos, RTL text,
/// service messages, day boundaries and an unread boundary, plus scripted
/// live updates published through its own `MessagesPublisher`.
@MainActor
public final class DebugChatFixture {
  public enum Opening: String, Sendable {
    case latest, unread, saved
  }

  public let database: AppDatabase
  public let publisher: MessagesPublisher
  public let peer: Peer
  public let chatId: Int64 = 1
  public let currentUserId: Int64 = 1
  /// The last read message id when opening at the unread line.
  public let unreadBoundary: Int64
  /// The saved reading place used by `.saved`.
  public let savedPlace: ChatReadingPlace
  private(set) var nextMessageId: Int64
  private var nextTemporaryId: Int64 = -1

  private static let users: [(Int64, String, String)] = [
    (1, "Me", "Self"), (2, "Alice", "Moreno"), (3, "Bob", "Okafor"), (4, "رنا", "حداد"), (5, "Dana", "Levi"),
  ]

  private static let texts = [
    "ok",
    "On my way 🚲",
    "Can you look at the build when you have a minute? CI is red on main again.",
    "I pushed a fix for the keyboard glitch. The list now follows the composer on open and close, and interactive dismissal keeps the content under the finger. Let me know if anything looks off on the iPad.",
    "Three things before Friday:\n1. finish the adapter\n2. measure the first window\n3. write down what is missing compared to the old list",
    "مرحبا، هل يمكنك مراجعة التغييرات قبل الاجتماع؟",
    "שלום, אני אבדוק את זה אחרי הצהריים",
    "👍",
    "😂😂",
    "Here is a longer note with a link https://inline.chat/docs and a mention of the plan. We should keep paging smooth in both directions and never move the reading row when older messages arrive above it.",
    "Lunch?",
    "Agreed. Shipping it behind the debug switch first.",
  ]

  /// Seeds `messageCount` messages ending now.
  public init(messageCount: Int = 420) throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "debug-fixture"))
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    peer = .thread(id: 1)
    let total = Int64(messageCount)
    unreadBoundary = total - 40
    savedPlace = ChatReadingPlace(messageId: total - 180, offset: 140)
    nextMessageId = total + 1
    let chatId = chatId
    let now = Date()
    try queue.write { db in
      for (id, first, last) in Self.users {
        try User(id: id, email: nil, firstName: first, lastName: last).insert(db)
      }
      try Chat(id: chatId, date: now.addingTimeInterval(-86_400 * 30), type: .thread, title: "List lab",
               spaceId: nil, lastMsgId: total).insert(db)
      // Spread over four days so day separators fall inside the window.
      let start = now.addingTimeInterval(-86_400 * 3.2)
      let step = (now.timeIntervalSince(start) - 60) / Double(messageCount)
      for index in 1 ... messageCount {
        let id = Int64(index)
        let run = (index / 3) % 7
        let from: Int64 = [2, 2, 3, 1, 4, 5, 1][run]
        var text: String? = Self.texts[(index * 7 + run) % Self.texts.count]
        var payload: Client_MessageContentPayload?
        var photoId: Int64?
        if index % 97 == 0 {
          text = "Pinned a message"
          payload = .with { $0.serviceMessage = .with { $0.pinnedMessage = .with { $0.messageID = id - 3 } } }
        } else if index % 29 == 0 {
          photoId = 9_000 + id
          let photo = try Photo(photoId: 9_000 + id, date: now, format: .jpeg).insertAndFetch(db)
          // Sizes reference the photo's local row id.
          try PhotoSize(photoId: photo.id ?? 0, type: "f", width: 1_200, height: index % 2 == 0 ? 800 : 1_600)
            .insert(db)
          if index % 2 == 0 { text = nil }
        }
        var message = Message(
          messageId: id, fromId: from, date: start.addingTimeInterval(Double(index) * step), text: text,
          peerUserId: nil, peerThreadId: chatId, chatId: chatId, out: from == 1, status: from == 1 ? .sent : nil,
          repliedToMessageId: index % 11 == 0 && index > 5 ? id - 5 : nil, photoId: photoId,
          contentPayload: payload
        )
        try message.saveMessage(db)
        if index % 7 == 0 {
          for (offset, emoji) in ["👍", "❤️", "😂"].prefix(index % 3 + 1).enumerated() {
            try Reaction(id: id * 10 + Int64(offset), messageId: id, userId: Int64(offset + 2), emoji: emoji, date: now, chatId: chatId)
              .insert(db)
          }
        }
      }
      try MessageHistoryCoverageStore.subtract(
        db, chatId: chatId, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax
      )
      var dialog = Dialog(optimisticForChat: Chat(id: chatId, date: now, type: .thread, title: "List lab", spaceId: nil))
      dialog.unreadCount = 0
      try dialog.insert(db)
    }
    #if os(iOS)
    // On iOS, deletes and reloads reach only chats a screen has activated, as `ChatView` does.
    activeChat = publisher.activateChat(peer: peer)
    #endif
  }

  #if os(iOS)
  private var activeChat: MessagesPublisher.ActiveChatToken?
  #endif

  /// The prepared first frame for an opening, as `ChatOpenPreparation` reads it.
  public func initialState(for opening: Opening) async throws -> MessagesProgressiveViewModel.InitialState {
    let unreadCount = opening == .unread ? Int(nextMessageId - 1 - unreadBoundary) : 0
    let boundary: Int64? = opening == .unread ? unreadBoundary : nil
    let chatId = chatId
    try await database.dbWriter.write { db in
      try Dialog.filter(Column("chatId") == chatId).updateAll(
        db, Column("unreadCount").set(to: unreadCount), Column("readInboxMaxId").set(to: boundary)
      )
    }
    return try await MessagesProgressiveViewModel.prepareInitialState(
      peer: peer, chatId: chatId, savedPlace: opening == .saved ? savedPlace : nil,
      database: database, publisher: publisher, currentUserId: currentUserId
    )
  }

  // MARK: Scripted updates

  private func fetch(globalId: Int64) throws -> FullMessage? {
    try database.reader.read { db in
      try FullMessage.queryRequest(currentUserId: currentUserId).filter(id: globalId).fetchOne(db)
    }
  }

  private func insert(text: String, from: Int64, messageId: Int64, status: MessageSendingStatus? = nil) throws
    -> FullMessage?
  {
    let chatId = chatId
    let saved = try database.dbWriter.write { db -> Message in
      var message = Message(
        messageId: messageId, randomId: messageId < 0 ? Int64.random(in: 1 ... .max) : nil, fromId: from,
        date: Date(), text: text, peerUserId: nil, peerThreadId: chatId, chatId: chatId, out: from == currentUserId,
        status: status
      )
      return try message.saveMessage(db)
    }
    return try saved.globalId.flatMap(fetch(globalId:))
  }

  /// Someone else's message arrives.
  public func receive() throws {
    defer { nextMessageId += 1 }
    guard let message = try insert(text: "Incoming \(nextMessageId)", from: 2, messageId: nextMessageId) else { return }
    publisher.publisher.send(.add(.init(messages: [message], peer: peer)))
  }

  /// The current user sends; the server acknowledges after `delay`.
  public func sendAndAcknowledge(after delay: Duration = .milliseconds(700)) async throws {
    let temporary = nextTemporaryId
    nextTemporaryId -= 1
    guard let pending = try insert(text: "Sent from the harness", from: currentUserId, messageId: temporary,
                                   status: .sending) else { return }
    publisher.publisher.send(.add(.init(messages: [pending], peer: peer)))
    try await Task.sleep(for: delay)
    let serverId = nextMessageId
    nextMessageId += 1
    try await database.dbWriter.write { db in
      try Message.filter(Column("globalId") == pending.id).updateAll(
        db, Column("messageId").set(to: serverId), Column("status").set(to: MessageSendingStatus.sent.rawValue)
      )
    }
    if let acked = try fetch(globalId: pending.id) {
      publisher.publisher.send(.update(.init(message: acked, animated: true, peer: peer)))
    }
  }

  private func newest() throws -> FullMessage? {
    try database.reader.read { db in
      try FullMessage.queryRequest(currentUserId: currentUserId)
        .filter(Column("chatId") == chatId).order(Column("date").desc).fetchOne(db)
    }
  }

  private func setText(_ text: String, of message: FullMessage) throws {
    try database.dbWriter.write { db in
      try Message.filter(Column("globalId") == message.id).updateAll(
        db, Column("text").set(to: text), Column("editDate").set(to: Date())
      )
    }
    if let updated = try fetch(globalId: message.id) {
      publisher.publisher.send(.update(.init(message: updated, animated: true, peer: peer)))
    }
  }

  /// The newest message is edited once.
  public func edit() throws {
    guard let message = try newest() else { return }
    try setText((message.message.text ?? "") + " (edited, now a bit longer than before)", of: message)
  }

  /// The newest message grows by a few words `steps` times, like a streaming reply.
  public func stream(steps: Int = 12, every interval: Duration = .milliseconds(120)) async throws {
    guard var message = try newest() else { return }
    var text = message.message.text ?? ""
    for step in 1 ... steps {
      text += step % 4 == 0 ? "\nNext line \(step)." : " more words \(step)"
      try setText(text, of: message)
      message = try fetch(globalId: message.id) ?? message
      try await Task.sleep(for: interval)
    }
  }

  /// The newest message is deleted.
  public func deleteNewest() throws {
    guard let message = try newest() else { return }
    _ = try database.dbWriter.write { db in
      try Message.filter(Column("globalId") == message.id).deleteAll(db)
    }
    publisher.messagesDeleted(messageIds: [message.message.messageId], peer: peer)
  }

  /// A reload whose content is unchanged.
  public func refreshIdentical() {
    publisher.messagesReload(peer: peer, animated: false)
  }

  /// A catch-up that wrote three messages to the database, then a reload.
  public func refreshAddingThree() throws {
    for _ in 0 ..< 3 {
      _ = try insert(text: "Caught up \(nextMessageId)", from: 3, messageId: nextMessageId)
      nextMessageId += 1
    }
    publisher.messagesReload(peer: peer, animated: false)
  }
}
#endif
