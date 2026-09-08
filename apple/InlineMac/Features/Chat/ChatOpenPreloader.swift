import Foundation
import Auth
import GRDB
import InlineKit
import InlineMacUI
import InlineUI
import os.signpost

struct PreparedChatPayload: Sendable {
  let peer: Peer
  let targetMessageId: Int64?
  let chatItem: SpaceChatItem?
  let messagesInitialState: MessagesProgressiveViewModel.InitialState
  let pinnedMessage: PreparedPinnedMessage?
  var experimentalPosition: MessageListInitialPosition? = nil
  var experimentalRequestedMessageID: Int64? = nil
}

struct PreparedPinnedMessage: Sendable, Equatable {
  let messageId: Int64
  let message: FullMessage?
}

actor ChatOpenPreloader {
  static let shared = ChatOpenPreloader()
  private static let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")

  enum TargetError: Error {
    case unavailable
  }

  func prepare(
    peer: Peer,
    targetMessageId: Int64? = nil,
    database: AppDatabase,
    experimentalMessageList: Bool? = nil
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

    let (initialLimit, usesExperimentalList, accountID) = await MainActor.run {
      (MessagesProgressiveViewModel.defaultInitialLimit(),
       ExperimentalMessageListFeature.isAvailable && (experimentalMessageList ?? ExperimentalMessageListFeature.isEnabled),
       Auth.shared.getCurrentUserId())
    }
    try Task.checkCancellation()

    var initialPosition: MessageListInitialPosition?
    var requestedMessageID: Int64?
    if usesExperimentalList {
      let openingChat = try await database.reader.read { db in
        try Self.fetchChatItem(peer: peer, db: db)
      }
      let saved: MessageListInitialPosition?
      if let accountID, let chatID = openingChat?.chat?.id ?? openingChat?.dialog.chatId {
        saved = await ExperimentalChatPositionStore.shared.load(accountID: accountID, chatID: chatID)
      } else {
        saved = nil
      }
      if let targetMessageId, let anchor = MessageListViewportAnchor(messageID: targetMessageId, offsetY: 0) {
        initialPosition = .anchor(anchor)
        requestedMessageID = targetMessageId
      } else if case .anchor = saved {
        initialPosition = saved
        requestedMessageID = saved?.messageID
      } else if let dialog = openingChat?.dialog, (dialog.unreadCount ?? 0) > 0,
                (dialog.readInboxMaxId ?? 0) < MessageHistoryHole.positiveMessageIDMax,
                let anchor = MessageListViewportAnchor(messageID: max(1, (dialog.readInboxMaxId ?? 0) + 1), offsetY: 0) {
        initialPosition = .anchor(anchor)
      } else {
        initialPosition = .latest
      }
      if let collapsedMaxID = openingChat?.dialog.collapsedMaxId,
         let target = initialPosition?.messageID, target <= collapsedMaxID,
         collapsedMaxID < MessageHistoryHole.positiveMessageIDMax,
         let anchor = MessageListViewportAnchor(messageID: collapsedMaxID + 1, offsetY: 0) {
        initialPosition = .anchor(anchor)
      }
    }
    let preparedPosition = initialPosition
    let preparedRequestedMessageID = requestedMessageID
    let windowTargetID = initialPosition?.messageID ?? targetMessageId

    if let windowTargetID {
      let hasCachedTarget = usesExperimentalList ? try await database.reader.read { db in
        var query = Message.filter(Message.Columns.messageId == windowTargetID)
        switch peer {
          case let .thread(id): query = query.filter(Message.Columns.peerThreadId == id)
          case let .user(id): query = query.filter(Message.Columns.peerUserId == id)
        }
        return try query.fetchCount(db) > 0
      } : false
      if !hasCachedTarget {
        let outcome = try await MessageHistoryRepairCoordinator.shared.loadAround(
          peer: peer,
          anchorID: windowTargetID,
          limit: initialLimit,
          database: database
        )
        guard outcome != .empty else { throw TargetError.unavailable }
      }
      try Task.checkCancellation()
    }

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
          targetMessageId: windowTargetID,
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

      let loadedWindowMetadata: MessagesProgressiveViewModel.LoadedWindowMetadata
      do {
        try Task.checkCancellation()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(
          .begin,
          log: Self.signpostLog,
          name: "ChatPreloaderFetchWindowMetadata",
          signpostID: signpostID
        )
        defer {
          os_signpost(
            .end,
            log: Self.signpostLog,
            name: "ChatPreloaderFetchWindowMetadata",
            signpostID: signpostID
          )
        }
        loadedWindowMetadata = try MessagesProgressiveViewModel.loadedWindowMetadata(
          db,
          peer: peer,
          messages: messages
        )
      }

      let messagesInitialState = MessagesProgressiveViewModel.InitialState(
        messages: messages,
        threadAnchor: threadAnchor,
        loadedWindowMetadata: loadedWindowMetadata
      )

      return PreparedChatPayload(
        peer: peer,
        targetMessageId: targetMessageId,
        chatItem: chatItem,
        messagesInitialState: messagesInitialState,
        pinnedMessage: pinnedMessage,
        experimentalPosition: preparedPosition,
        experimentalRequestedMessageID: preparedRequestedMessageID
      )
    }
    try Task.checkCancellation()

    preparedMessageCount = payload.messagesInitialState.messages.count
    let likelyVisibleMessages = Self.likelyVisibleMessages(
      in: payload.messagesInitialState.messages,
      targetMessageId: windowTargetID,
      limit: InlineTinyThumbnailWarmupPolicy.firstPresentationMessageLimit
    )
    let thumbnailWarmup = await InlineTinyThumbnailPrewarmer.beginWarmup(
      for: likelyVisibleMessages,
      includeSupportingMedia: false,
      priority: .visible
    )
    if !usesExperimentalList {
      _ = await InlineTinyThumbnailPrewarmer.waitUntilReady(
        thumbnailWarmup,
        timeout: InlineTinyThumbnailWarmupPolicy.firstPresentationTimeout
      )
    }
    if Task.isCancelled {
      await InlineTinyThumbnailPrewarmer.cancel(thumbnailWarmup)
      throw CancellationError()
    }
    return payload
  }

  private static func likelyVisibleMessages(
    in messages: [FullMessage],
    targetMessageId: Int64?,
    limit: Int
  ) -> [FullMessage] {
    guard !messages.isEmpty, limit > 0 else { return [] }

    guard let targetMessageId,
          let targetIndex = messages.firstIndex(where: { $0.message.messageId == targetMessageId })
    else {
      return Array(messages.suffix(limit))
    }

    let desiredStart = max(0, targetIndex - (limit / 3))
    let end = min(messages.count, desiredStart + limit)
    let start = max(0, end - limit)
    return Array(messages[start ..< end])
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
    if let targetMessageId {
      guard let messages = try MessagesProgressiveViewModel.localWindowAroundCoordinate(
        db,
        peer: peer,
        messageID: targetMessageId,
        limit: limit
      ), !messages.isEmpty else {
        // A target route must remain a coordinate route. Falling back to the
        // latest rows would silently open the wrong transcript location.
        throw TargetError.unavailable
      }
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

}
