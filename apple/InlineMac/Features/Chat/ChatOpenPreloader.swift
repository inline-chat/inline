import Foundation
import GRDB
import InlineKit
import InlineUI
import Logger
import os.signpost

struct PreparedChatPayload: Sendable {
  let peer: Peer
  let targetMessageId: Int64?
  let chatItem: SpaceChatItem?
  let messagesInitialState: MessagesProgressiveViewModel.InitialState
  let pinnedMessage: PreparedPinnedMessage?
  /// The unread line's boundary when the history around it isn't cached and is being fetched.
  /// The list holds a loading state over these latest messages until the fetch lands, then
  /// opens at the line. Nil when nothing is fetched, including offline.
  let unreadFetchBoundary: Int64?
}

struct PreparedPinnedMessage: Sendable, Equatable {
  /// Every pin in the chat, oldest first, so the header's first frame shows the right count.
  let messageIds: [Int64]
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

    if let targetMessageId {
      let outcome = try await MessageHistoryRepairCoordinator.shared.loadAround(
        peer: peer,
        anchorID: targetMessageId,
        limit: initialLimit,
        database: database
      )
      guard outcome != .empty else { throw TargetError.unavailable }
      try Task.checkCancellation()
    }

    // The dialog decides the window, and the chat view reads the same snapshot for its
    // unread line, so both agree on where the chat opens.
    let chatItem = try await database.reader.read { db in
      try Self.fetchChatItem(peer: peer, db: db)
    }
    let unreadBoundary = targetMessageId == nil
      ? chatItem.flatMap {
        ChatUnreadOpening.boundary(unreadCount: $0.dialog.unreadCount, readInboxMaxId: $0.dialog.readInboxMaxId)
      }
      : nil
    // An explicit target owns the first viewport; without one the saved reading place comes
    // before the unread line.
    let savedPlace: ChatReadingPlace? = if targetMessageId == nil {
      await MainActor.run { ChatReadingPlaceStore.shared.place(for: peer) }
    } else {
      nil
    }
    let opening: (resolution: ChatOpening.Resolution, publicationRevision: UInt64)? =
      if savedPlace != nil || unreadBoundary != nil {
        try await localOpening(
          peer: peer,
          savedPlace: savedPlace,
          unreadCount: chatItem?.dialog.unreadCount,
          readInboxMaxId: chatItem?.dialog.readInboxMaxId,
          latestLimit: initialLimit,
          database: database
        )
      } else {
        nil
      }
    if opening?.resolution.droppedSavedPlace == true {
      // A saved place is never fetched; the chat opens by the next rule and forgets it.
      await MainActor.run { ChatReadingPlaceStore.shared.clear(for: peer) }
    }
    // The saved place's or the unread line's cached window. Nil opens on the latest messages,
    // read below with the rest of the payload.
    let openingWindow: (messages: [FullMessage], publicationRevision: UInt64)? =
      if let opening, opening.resolution.anchor != .latest {
        (opening.resolution.messages, opening.publicationRevision)
      } else {
        nil
      }
    let openAnchor: ChatOpenAnchor = openingWindow == nil ? .latest : opening?.resolution.anchor ?? .latest
    // Opening never waits on the network. Uncached history is fetched behind a loading state, but
    // only when a fetch can actually run: offline, the latest cached messages open as they are.
    let unreadFetchBoundary: Int64?
    if let uncachedBoundary = opening?.resolution.uncachedUnreadBoundary,
       await MainActor.run(body: { Api.realtime.stateObject.connectionState != .connecting })
    {
      unreadFetchBoundary = uncachedBoundary
    } else {
      unreadFetchBoundary = nil
    }
    try Task.checkCancellation()

    // Taken before the read, so updates published while it runs are reconciled by the view model.
    // An opening window was read earlier, after its own revision.
    let currentRevision = await MainActor.run {
      MessagesPublisher.shared.publicationRevision(for: peer)
    }
    let publicationRevision = openingWindow?.publicationRevision ?? currentRevision
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
        messages = try openingWindow?.messages ?? Self.fetchInitialMessages(
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
        threadAnchor: .resolved(threadAnchor),
        loadedWindowMetadata: loadedWindowMetadata,
        publicationRevision: publicationRevision,
        openAnchor: openAnchor,
        unreadBoundary: unreadBoundary
      )

      return PreparedChatPayload(
        peer: peer,
        targetMessageId: targetMessageId,
        chatItem: chatItem,
        messagesInitialState: messagesInitialState,
        pinnedMessage: pinnedMessage,
        unreadFetchBoundary: unreadFetchBoundary
      )
    }
    try Task.checkCancellation()

    preparedMessageCount = payload.messagesInitialState.messages.count
    let likelyVisibleMessages = Self.likelyVisibleMessages(
      in: payload.messagesInitialState.messages,
      targetMessageId: targetMessageId,
      openAnchor: openAnchor,
      limit: InlineTinyThumbnailWarmupPolicy.firstPresentationMessageLimit
    )
    let thumbnailWarmup = await InlineTinyThumbnailPrewarmer.beginWarmup(
      for: likelyVisibleMessages,
      includeSupportingMedia: false,
      priority: .visible
    )
    _ = await InlineTinyThumbnailPrewarmer.waitUntilReady(
      thumbnailWarmup,
      timeout: InlineTinyThumbnailWarmupPolicy.firstPresentationTimeout
    )
    if Task.isCancelled {
      await InlineTinyThumbnailPrewarmer.cancel(thumbnailWarmup)
      throw CancellationError()
    }
    return payload
  }

  private static func likelyVisibleMessages(
    in messages: [FullMessage],
    targetMessageId: Int64?,
    openAnchor: ChatOpenAnchor,
    limit: Int
  ) -> [FullMessage] {
    guard !messages.isEmpty, limit > 0 else { return [] }

    // The list opens with the saved row or the unread line near the top, so the rows from
    // there down are the visible ones.
    let firstVisible: Int? = switch openAnchor {
      case let .saved(place) where targetMessageId == nil:
        messages.firstIndex(where: { $0.message.messageId == place.messageId })
      case let .unread(boundary) where targetMessageId == nil:
        messages.firstIndex(where: { $0.message.messageId > boundary })
      default:
        nil
    }
    if let firstVisible {
      let end = min(messages.count, firstVisible + limit)
      let start = max(0, end - limit)
      return Array(messages[start ..< end])
    }

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

  /// Where a chat with a saved reading place or unread messages opens, from the cache only
  /// (`ChatOpening.resolve`), read with the publication revision taken before it.
  private func localOpening(
    peer: Peer,
    savedPlace: ChatReadingPlace?,
    unreadCount: Int?,
    readInboxMaxId: Int64?,
    latestLimit: Int,
    database: AppDatabase
  ) async throws -> (resolution: ChatOpening.Resolution, publicationRevision: UInt64) {
    let revision = await MainActor.run { MessagesPublisher.shared.publicationRevision(for: peer) }
    let resolution = try await database.reader.read { db in
      let latest = try Self.fetchLatestMessages(peer: peer, limit: latestLimit, db: db)
      return try ChatOpening.resolve(
        db,
        peer: peer,
        saved: savedPlace,
        unreadCount: unreadCount,
        readInboxMaxId: readInboxMaxId,
        latest: latest
      )
    }
    return (resolution, revision)
  }

  /// The first window for a chat view built without a prepared payload (back, forward, the
  /// history menu, restored routes, the reply pane) when the chat has a saved reading place.
  /// Read synchronously on the main actor, in place of the view model's own synchronous first
  /// read on that path, so the list still places the saved row in its first layout. Nil
  /// without a saved place, leaving that path exactly as before, and when the cache cannot
  /// show the place, which is then cleared.
  @MainActor
  static func coldOpeningState(peer: Peer, database: AppDatabase) -> MessagesProgressiveViewModel.InitialState? {
    let store = ChatReadingPlaceStore.shared
    guard let saved = store.place(for: peer) else { return nil }
    // Taken before the read; nothing is published on the main actor while it runs.
    let publicationRevision = MessagesPublisher.shared.publicationRevision(for: peer)
    let limit = MessagesProgressiveViewModel.defaultInitialLimit()
    let state: MessagesProgressiveViewModel.InitialState?
    do {
      state = try database.reader.read { db -> MessagesProgressiveViewModel.InitialState? in
        let dialog = try Dialog.filter(id: Dialog.getDialogId(peerId: peer)).fetchOne(db)
        let latest = try fetchLatestMessages(peer: peer, limit: limit, db: db)
        let opening = try ChatOpening.resolve(
          db,
          peer: peer,
          saved: saved,
          unreadCount: dialog?.unreadCount,
          readInboxMaxId: dialog?.readInboxMaxId,
          latest: latest
        )
        guard case .saved = opening.anchor else { return nil }
        return try MessagesProgressiveViewModel.InitialState(
          messages: opening.messages,
          loadedWindowMetadata: MessagesProgressiveViewModel.loadedWindowMetadata(
            db,
            peer: peer,
            messages: opening.messages
          ),
          publicationRevision: publicationRevision,
          openAnchor: opening.anchor,
          unreadBoundary: opening.unreadBoundary
        )
      }
    } catch {
      Log.shared.error("Failed to read the saved reading place window", error: error)
      return nil
    }
    if state == nil {
      store.clear(for: peer)
    }
    return state
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
    let bar = try PinnedMessageBar(messageIds: PinnedMessage
      .filter(PinnedMessage.Columns.chatId == chatId)
      .select(PinnedMessage.Columns.messageId, as: Int64.self)
      .fetchAll(db))
    guard let messageId = bar.displayedMessageId else { return nil }

    var message = messages.first {
      $0.message.chatId == chatId && $0.message.messageId == messageId
    }
    if message == nil {
      message = try FullMessage.queryRequest()
        .filter(Column("messageId") == messageId && Column("chatId") == chatId)
        .fetchOne(db)
    }

    return PreparedPinnedMessage(messageIds: bar.messageIds, messageId: messageId, message: message)
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
