import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct CreateSubthreadTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/CreateSubthread")

  public var method: InlineProtocol.Method = .createSubthread
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var parentChatId: Int64
    public var parentMessageId: Int64?
    public var title: String?
    public var description: String?
    public var emoji: String?
    public var participants: [Int64]
    public var agentContext: Data?
    /// Server-issued id claimed on creation. With it, the thread exists locally
    /// under its final id before the server responds.
    public var reservedChatId: Int64?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(
    parentChatId: Int64,
    parentMessageId: Int64?,
    title: String? = nil,
    description: String? = nil,
    emoji: String? = nil,
    participants: [Int64] = [],
    agentContext: InlineProtocol.AgentThreadContext? = nil,
    reservedChatId: Int64? = nil
  ) {
    context = Context(
      parentChatId: parentChatId,
      parentMessageId: parentMessageId,
      title: title,
      description: description,
      emoji: emoji,
      participants: participants,
      agentContext: Chat.serializedAgentContext(agentContext),
      reservedChatId: reservedChatId
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createSubthread(.with {
      $0.parentChatID = context.parentChatId
      if let parentMessageId = context.parentMessageId {
        $0.parentMessageID = parentMessageId
      }
      if let title = context.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        $0.title = title
      }
      if let description = context.description?.trimmingCharacters(in: .whitespacesAndNewlines),
         !description.isEmpty
      {
        $0.description_p = description
      }
      if let emoji = context.emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty {
        $0.emoji = emoji
      }
      $0.participants = context.participants.map { userId in
        InputChatParticipant.with { $0.userID = userId }
      }
      if let data = context.agentContext,
         let agentContext = try? InlineProtocol.AgentThreadContext(serializedBytes: data)
      {
        $0.agentContext = agentContext
      }
      if let reservedChatId = context.reservedChatId {
        $0.reservedChatID = reservedChatId
      }
    })
  }

  // Dependents (history, first sends) wait on `.chatCreated(reservedChatId)`.
  // Not marking it satisfied here makes them consult the database instead: the
  // confirmed chat satisfies it, while a reservation that lost the race to an
  // existing reply thread is deleted locally and fails them.
  public var satisfiedBlockersOnSuccess: [TransactionBlocker] { [] }

  public func optimistic() async {
    guard context.reservedChatId != nil else { return }
    do {
      let currentUserId = Auth.shared.getCurrentUserId()
      try await AppDatabase.shared.dbWriter.write { db in
        try saveOptimisticState(db, currentUserId: currentUserId)
      }
    } catch {
      log.error("Failed to create optimistic subthread", error: error)
    }
  }

  func saveOptimisticState(_ db: Database, currentUserId: Int64?) throws {
    guard let reservedChatId = context.reservedChatId,
          let parentChat = try Chat.fetchOne(db, key: context.parentChatId)
    else { return }

    let title = context.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasTitle = title?.isEmpty == false
    let chat = Chat(
      id: reservedChatId,
      date: Date(),
      type: .thread,
      title: hasTitle ? title : nil,
      spaceId: parentChat.spaceId,
      emoji: context.emoji,
      isPublic: parentChat.isPublic,
      createdBy: currentUserId,
      isUntitled: hasTitle ? nil : true,
      parentChatId: context.parentChatId,
      parentMessageId: context.parentMessageId,
      createState: .pending,
      agentContext: context.agentContext
    )
    var dialog = Dialog(optimisticForChat: chat)
    // Matches the server: an opened reply thread stays out of the chat list.
    dialog.chatListHidden = true

    try chat.save(db)
    try dialog.save(db)
  }

  public func validateOptimisticState() async -> Bool {
    guard let reservedChatId = context.reservedChatId else { return true }
    do {
      return try await AppDatabase.shared.reader.read { db in
        try Chat.fetchOne(db, key: reservedChatId) != nil
      }
    } catch {
      log.error("Failed to validate optimistic subthread", error: error)
      return false
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .createSubthread(response) = result, response.hasChat else {
      throw TransactionExecutionError.invalid
    }

    let redirectedFrom = context.reservedChatId.flatMap { $0 == response.chat.id ? nil : $0 }
    do {
      let unsentTexts = try await AppDatabase.shared.dbWriter.write { db -> [String] in
        var chat = Chat(from: response.chat)
        if let existingChat = try Chat.fetchOne(db, key: chat.id), chat.lastMsgId == nil {
          chat.lastMsgId = existingChat.lastMsgId
        }
        _ = try chat.saveFull(db)

        if response.hasDialog {
          _ = try response.dialog.saveFull(db)
        }

        let unsentTexts: [String]
        if let redirectedFrom {
          // Save the target before moving rows, so its foreign keys exist. Queued
          // sends keep their old dependency and fail; the moved rows are explicit retries.
          unsentTexts = try Self.removeShell(db, chatId: redirectedFrom, redirectingTo: chat.id)
        } else {
          unsentTexts = []
        }

        // The returned anchor is owned by the parent bucket. Creation's
        // child metadata does not witness its freshness; parent navigation
        // hydrates through the parent's guarded getMessages/history path.
        return unsentTexts
      }
      if let redirectedFrom {
        Self.moveDraft(from: redirectedFrom, to: response.chat.id, unsentTexts: unsentTexts)
        let redirect = ReplyThreadRedirect(reservedChatId: redirectedFrom, chatId: response.chat.id)
        await MainActor.run {
          NotificationCenter.default.post(name: ReplyThreadRedirect.notification, object: redirect)
        }
      }
    } catch {
      log.error("Failed to save createSubthread result", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to create subthread", error: error)
    await markOptimisticCreationFailed()
  }

  public func commitOutcomeUnknown() async {
    log.warning("Subthread creation outcome is unknown; retaining the local shell as failed")
    await markOptimisticCreationFailed()
  }

  public func cancelled() async {
    guard let reservedChatId = context.reservedChatId else { return }
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard let chat = try Chat.fetchOne(db, key: reservedChatId), chat.createState == .pending else { return }
        try Dialog.deleteOne(db, key: Dialog.getDialogId(peerThreadId: reservedChatId))
        try Chat.deleteOne(db, key: reservedChatId)
      }
    } catch {
      log.error("Failed to remove cancelled optimistic subthread", error: error)
    }
  }

  private func markOptimisticCreationFailed() async {
    guard let reservedChatId = context.reservedChatId else { return }
    do {
      _ = try await AppDatabase.shared.dbWriter.write { db in
        try Chat
          .filter(Chat.Columns.id == reservedChatId)
          .updateAll(db, Chat.Columns.createState.set(to: ChatCreateState.failed.rawValue))
      }
    } catch {
      log.error("Failed to mark subthread creation as failed", error: error)
    }
  }

  /// Retains media sends as recoverable failed rows in the existing thread and returns
  /// plain queued text for its draft, as before. Queued sends still name the deleted shell,
  /// so they fail their `.chatCreated` dependency instead of posting twice.
  static func removeShell(_ db: Database, chatId: Int64, redirectingTo targetChatId: Int64) throws -> [String] {
    let unsent = try Message
      .filter(Message.Columns.chatId == chatId)
      .order(Message.Columns.date.asc)
      .fetchAll(db)
    guard try Chat.fetchOne(db, key: targetChatId) != nil else { throw RedirectError.targetMissing }
    for message in unsent {
      guard message.messageId < 0, message.out == true,
            message.status == .sending || message.status == .failed
      else { throw RedirectError.unexpectedMessage }
      // The local key is per chat and uses ON CONFLICT REPLACE. Never let an
      // improbable negative-ID collision erase a different target message.
      if hasRecoverableMedia(message) {
        guard try Message.fetchOne(db, key: ["messageId": message.messageId, "chatId": targetChatId]) == nil else {
          throw RedirectError.messageIdentityConflict
        }
      }
    }
    for var message in unsent where hasRecoverableMedia(message) {
      message.chatId = targetChatId
      message.peerThreadId = targetChatId
      message.peerUserId = nil
      message.status = .failed
      try message.update(db)
    }
    // Rehomed media rows are no longer in this selection. Only plain queued text remains.
    try Message.filter(Message.Columns.chatId == chatId).deleteAll(db)
    try Dialog.deleteOne(db, key: Dialog.getDialogId(peerThreadId: chatId))
    try Chat.deleteOne(db, key: chatId)
    return unsent.compactMap { message in
      guard !hasRecoverableMedia(message),
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
      else { return nil }
      return text
    }
  }

  private static func hasRecoverableMedia(_ message: Message) -> Bool {
    message.hasPhoto || message.hasVideo || message.documentId != nil || message.hasVoice
  }

  private enum RedirectError: Error {
    case targetMissing
    case unexpectedMessage
    case messageIdentityConflict
  }

  /// Carries plain queued text and the remaining composer draft into the existing thread.
  /// Media messages remain failed rows, so their captions are not duplicated in this draft.
  static func moveDraft(from reservedChatId: Int64, to chatId: Int64, unsentTexts: [String] = [], drafts: Drafts2 = .shared) {
    let reservedPeer = Peer.thread(id: reservedChatId)
    let targetPeer = Peer.thread(id: chatId)
    let reservedDraft = drafts.load(peer: reservedPeer)
    let draftParts = [reservedDraft, drafts.load(peer: targetPeer)].compactMap { draft -> (text: String, entities: MessageEntities?)? in
      guard let draft, !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return (draft.text, draft.entities)
    }
    let parts = unsentTexts.map { (text: $0, entities: Optional<MessageEntities>.none) } + draftParts
    if !parts.isEmpty {
      let text = parts.map(\.text).joined(separator: "\n\n")
      var entities: [InlineProtocol.MessageEntity] = []
      var offset: Int64 = 0
      for part in parts {
        entities += (part.entities?.entities ?? []).map { entity in
          var entity = entity
          entity.offset += offset
          return entity
        }
        offset += Int64(part.text.utf16.count) + 2
      }
      let revision = drafts.updateText(peer: targetPeer, text: text)
      drafts.updateEntities(
        peer: targetPeer,
        entities: entities.isEmpty ? nil : MessageEntities.with { $0.entities = entities },
        forRevision: revision
      )
    }
    for attachment in reservedDraft?.attachments ?? [] {
      drafts.appendAttachment(peer: targetPeer, media: attachment.media, id: attachment.id)
    }
    drafts.clear(peer: reservedPeer)
  }
}

/// Posted on the main thread when a reserved reply thread resolves to a different,
/// already existing thread. Windows showing the reserved id should switch to `chatId`.
public struct ReplyThreadRedirect: Sendable, Equatable {
  public static let notification = Notification.Name("inline.replyThreadRedirect")

  public let reservedChatId: Int64
  public let chatId: Int64
}

public extension Transaction2 where Self == CreateSubthreadTransaction {
  static func createSubthread(
    parentChatId: Int64,
    parentMessageId: Int64?,
    title: String? = nil,
    description: String? = nil,
    emoji: String? = nil,
    participants: [Int64] = [],
    agentContext: InlineProtocol.AgentThreadContext? = nil,
    reservedChatId: Int64? = nil
  ) -> CreateSubthreadTransaction {
    CreateSubthreadTransaction(
      parentChatId: parentChatId,
      parentMessageId: parentMessageId,
      title: title,
      description: description,
      emoji: emoji,
      participants: participants,
      agentContext: agentContext,
      reservedChatId: reservedChatId
    )
  }
}
