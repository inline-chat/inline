import Foundation
import GRDB
import InlineKit
import os.signpost

struct PreparedChatPayload: Sendable {
  let peer: Peer
  let targetMessageId: Int64?
  let chatItem: SpaceChatItem?
  let messagesInitialState: MessagesProgressiveViewModel.InitialState
  let pinnedMessage: PreparedPinnedMessage?
}

struct PreparedPinnedMessage: Sendable {
  let messageId: Int64
  let message: FullMessage?
}

actor ChatOpenPreloader {
  static let shared = ChatOpenPreloader()
  private static let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")

  private enum MessageDirection {
    case older
    case newer
  }

  func prepare(
    peer: Peer,
    targetMessageId: Int64? = nil,
    database: AppDatabase
  ) async throws -> PreparedChatPayload {
    let prepareSignpostID = OSSignpostID(log: Self.signpostLog)
    var preparedMessageCount = 0
    os_signpost(
      .begin,
      log: Self.signpostLog,
      name: "ChatPreloaderPrepare",
      signpostID: prepareSignpostID,
      "%{public}s",
      String(describing: peer)
    )
    defer {
      os_signpost(
        .end,
        log: Self.signpostLog,
        name: "ChatPreloaderPrepare",
        signpostID: prepareSignpostID,
        "%{public}s",
        "messages=\(preparedMessageCount)"
      )
    }

    let initialLimit = await MainActor.run {
      MessagesProgressiveViewModel.defaultInitialLimit()
    }
    try Task.checkCancellation()

    let payload = try await database.reader.read { db in
      let readSignpostID = OSSignpostID(log: Self.signpostLog)
      os_signpost(
        .begin,
        log: Self.signpostLog,
        name: "ChatPreloaderDatabaseRead",
        signpostID: readSignpostID,
        "%{public}s",
        String(describing: peer)
      )
      defer {
        os_signpost(
          .end,
          log: Self.signpostLog,
          name: "ChatPreloaderDatabaseRead",
          signpostID: readSignpostID
        )
      }

      let chatItem: SpaceChatItem?
      do {
        try Task.checkCancellation()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "ChatPreloaderFetchChatItem", signpostID: signpostID)
        defer { os_signpost(.end, log: Self.signpostLog, name: "ChatPreloaderFetchChatItem", signpostID: signpostID) }
        chatItem = try Self.fetchChatItem(peer: peer, db: db)
      }

      let threadAnchor: FullMessage?
      do {
        try Task.checkCancellation()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "ChatPreloaderFetchThreadAnchor", signpostID: signpostID)
        defer { os_signpost(.end, log: Self.signpostLog, name: "ChatPreloaderFetchThreadAnchor", signpostID: signpostID) }
        threadAnchor = try Self.fetchThreadAnchorMessage(peer: peer, chatItem: chatItem, db: db)
      }

      let messages: [FullMessage]
      do {
        try Task.checkCancellation()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        var messageCount = 0
        os_signpost(
          .begin,
          log: Self.signpostLog,
          name: "ChatPreloaderFetchInitialMessages",
          signpostID: signpostID,
          "%{public}s",
          "limit=\(initialLimit)"
        )
        defer {
          os_signpost(
            .end,
            log: Self.signpostLog,
            name: "ChatPreloaderFetchInitialMessages",
            signpostID: signpostID,
            "%{public}s",
            "messages=\(messageCount)"
          )
        }
        messages = try Self.fetchInitialMessages(
          peer: peer,
          limit: initialLimit,
          targetMessageId: targetMessageId,
          db: db
        )
        messageCount = messages.count
      }

      let pinnedMessage: PreparedPinnedMessage?
      do {
        try Task.checkCancellation()
        pinnedMessage = try Self.fetchPinnedMessage(
          peer: peer,
          chatItem: chatItem,
          messages: messages,
          db: db
        )
      }

      let messageIds = messages.map(\.message.messageId)
      let oldestLoadedMessageId = messageIds.min()
      let newestLoadedMessageId = messageIds.max()

      let canLoadOlderFromLocal: Bool
      let canLoadNewerFromLocal: Bool
      do {
        try Task.checkCancellation()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "ChatPreloaderFetchAvailability", signpostID: signpostID)
        defer { os_signpost(.end, log: Self.signpostLog, name: "ChatPreloaderFetchAvailability", signpostID: signpostID) }
        canLoadOlderFromLocal = try Self.hasLocalMessages(
          peer: peer,
          referenceMessageId: oldestLoadedMessageId,
          direction: .older,
          db: db
        )
        canLoadNewerFromLocal = try Self.hasLocalMessages(
          peer: peer,
          referenceMessageId: newestLoadedMessageId,
          direction: .newer,
          db: db
        )
      }

      let messagesInitialState = MessagesProgressiveViewModel.InitialState(
        messages: messages,
        threadAnchor: threadAnchor,
        oldestLoadedMessageId: oldestLoadedMessageId,
        newestLoadedMessageId: newestLoadedMessageId,
        canLoadOlderFromLocal: canLoadOlderFromLocal,
        canLoadNewerFromLocal: canLoadNewerFromLocal
      )

      return PreparedChatPayload(
        peer: peer,
        targetMessageId: targetMessageId,
        chatItem: chatItem,
        messagesInitialState: messagesInitialState,
        pinnedMessage: pinnedMessage
      )
    }
    try Task.checkCancellation()

    preparedMessageCount = payload.messagesInitialState.messages.count
    return payload
  }

  private static func fetchChatItem(peer: Peer, db: Database) throws -> SpaceChatItem? {
    let item: SpaceChatItem?
    switch peer {
      case .user:
        item = try Dialog
          .spaceChatItemQueryForUser()
          .filter(id: Dialog.getDialogId(peerId: peer))
          .fetchOne(db)

      case .thread:
        item = try Dialog
          .spaceChatItemQueryForChat()
          .filter(id: Dialog.getDialogId(peerId: peer))
          .fetchOne(db)
    }

    return try item.map { try fillMissingChat(in: $0, peer: peer, db: db) }
  }

  private static func fetchInitialMessages(
    peer: Peer,
    limit: Int,
    targetMessageId: Int64?,
    db: Database
  ) throws -> [FullMessage] {
    if let targetMessageId,
       let messages = try fetchMessagesAround(peer: peer, messageId: targetMessageId, limit: limit, db: db) {
      return messages
    }

    return try fetchLatestMessages(peer: peer, limit: limit, db: db)
  }

  private static func fetchLatestMessages(peer: Peer, limit: Int, db: Database) throws -> [FullMessage] {
    let batch = try baseQuery(peer: peer)
      .order(Column("date").desc, Column("messageId").desc)
      .limit(limit)
      .fetchAll(db)

    return batch.reversed()
  }

  private static func fetchMessagesAround(
    peer: Peer,
    messageId: Int64,
    limit: Int,
    db: Database
  ) throws -> [FullMessage]? {
    guard messageId > 0 else { return nil }

    let totalWindow = max(60, limit)
    let beforeLimit = max(20, totalWindow / 2)
    let afterLimit = max(20, totalWindow - beforeLimit - 1)

    guard let target = try baseQuery(peer: peer)
      .filter(Column("messageId") == messageId)
      .fetchOne(db)
    else {
      return nil
    }

    let targetDate = target.message.date
    let targetMessageId = target.message.messageId

    let olderOrTarget = try baseQuery(peer: peer)
      .filter(
        (Column("date") < targetDate)
          || ((Column("date") == targetDate) && (Column("messageId") <= targetMessageId))
      )
      .order(Column("date").desc, Column("messageId").desc)
      .limit(beforeLimit + 1)
      .fetchAll(db)

    let newer = try baseQuery(peer: peer)
      .filter(
        (Column("date") > targetDate)
          || ((Column("date") == targetDate) && (Column("messageId") > targetMessageId))
      )
      .order(Column("date").asc, Column("messageId").asc)
      .limit(afterLimit)
      .fetchAll(db)

    return sortMessages(Array(olderOrTarget.reversed()) + newer)
  }

  private static func baseQuery(peer: Peer) -> QueryInterfaceRequest<FullMessage> {
    var query = FullMessage.queryRequest()
    switch peer {
      case let .thread(id):
        query = query.filter(Column("peerThreadId") == id)
      case let .user(id):
        query = query.filter(Column("peerUserId") == id)
    }
    return query
  }

  private static func sortMessages(_ batch: [FullMessage]) -> [FullMessage] {
    guard batch.count > 1 else { return batch }

    return batch
      .enumerated()
      .sorted { lhs, rhs in
        let left = lhs.element.message
        let right = rhs.element.message

        if left.date != right.date {
          return left.date < right.date
        }
        if (left.globalId ?? 0) != (right.globalId ?? 0) {
          return (left.globalId ?? 0) < (right.globalId ?? 0)
        }
        if left.messageId != right.messageId {
          return left.messageId < right.messageId
        }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private static func fetchThreadAnchorMessage(
    peer: Peer,
    chatItem: SpaceChatItem?,
    db: Database
  ) throws -> FullMessage? {
    guard case let .thread(threadId) = peer else { return nil }

    let chat: Chat?
    if let cachedChat = chatItem?.chat {
      chat = cachedChat
    } else {
      chat = try Chat.fetchOne(db, id: threadId)
    }
    guard let chat, let parentChatId = chat.parentChatId, let parentMessageId = chat.parentMessageId else {
      return nil
    }

    return try FullMessage.queryRequest()
      .filter(Column("chatId") == parentChatId)
      .filter(Column("messageId") == parentMessageId)
      .fetchOne(db)
  }

  private static func fetchPinnedMessage(
    peer: Peer,
    chatItem: SpaceChatItem?,
    messages: [FullMessage],
    db: Database
  ) throws -> PreparedPinnedMessage? {
    guard let chatId = try resolveChatId(peer: peer, chatItem: chatItem, db: db) else { return nil }
    guard let pinned = try PinnedMessage
      .filter(Column("chatId") == chatId)
      .order(PinnedMessage.Columns.position.asc)
      .fetchOne(db)
    else {
      return nil
    }

    var message = messages.first {
      $0.message.chatId == chatId && $0.message.messageId == pinned.messageId
    }
    if message == nil {
      message = try FullMessage.queryRequest()
        .filter(Column("messageId") == pinned.messageId && Column("chatId") == chatId)
        .fetchOne(db)
    }

    return PreparedPinnedMessage(messageId: pinned.messageId, message: message)
  }

  private static func fillMissingChat(in item: SpaceChatItem, peer: Peer, db: Database) throws -> SpaceChatItem {
    guard item.chat == nil else { return item }

    var item = item
    if let chatId = item.dialog.chatId {
      item.chat = try Chat.fetchOne(db, id: chatId)
    }
    if item.chat == nil {
      item.chat = try Chat.getByPeerId(db: db, peerId: peer)
    }
    return item
  }

  private static func resolveChatId(peer: Peer, chatItem: SpaceChatItem?, db: Database) throws -> Int64? {
    if let chatId = chatItem?.chat?.id {
      return chatId
    }
    if let chatId = chatItem?.dialog.chatId {
      return chatId
    }
    return try Chat.getByPeerId(db: db, peerId: peer)?.id
  }

  private static func hasLocalMessages(
    peer: Peer,
    referenceMessageId: Int64?,
    direction: MessageDirection,
    db: Database
  ) throws -> Bool {
    guard let referenceMessageId else { return false }

    var query = Message.all()
    switch peer {
      case let .thread(id):
        query = query.filter(Message.Columns.peerThreadId == id)
      case let .user(id):
        query = query.filter(Message.Columns.peerUserId == id)
    }

    query = switch direction {
      case .older:
        query.filter(Message.Columns.messageId < referenceMessageId)
      case .newer:
        query.filter(Message.Columns.messageId > referenceMessageId)
    }

    return try query.limit(1).fetchCount(db) > 0
  }
}
