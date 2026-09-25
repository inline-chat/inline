import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct CreateChatTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .createChat
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var title: String?
    public var placeholderTitle: String?
    public var emoji: String?
    public var isPublic: Bool
    public var spaceId: Int64?
    public var participants: [Int64]
    public var reservedChatId: Int64?
    public var agentContext: Data?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions.CreateChat")

  public init(
    title: String?,
    placeholderTitle: String? = nil,
    emoji: String?,
    isPublic: Bool,
    spaceId: Int64?,
    participants: [Int64],
    reservedChatId: Int64? = nil,
    agentContext: InlineProtocol.AgentThreadContext? = nil
  ) {
    context = Context(
      title: title,
      placeholderTitle: placeholderTitle,
      emoji: emoji,
      isPublic: isPublic,
      spaceId: spaceId,
      participants: participants,
      reservedChatId: reservedChatId,
      agentContext: Chat.serializedAgentContext(agentContext)
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createChat(.with {
      if let title = Self.normalizedTitle(context.title) {
        $0.title = title
      }
      if let placeholderTitle = Self.normalizedTitle(context.placeholderTitle) {
        $0.placeholderTitle = placeholderTitle
      }
      if let spaceId = context.spaceId { $0.spaceID = spaceId }
      if let emoji = context.emoji { $0.emoji = emoji }
      if let reservedChatId = context.reservedChatId { $0.reservedChatID = reservedChatId }
      $0.isPublic = context.isPublic
      $0.participants = context.participants.map { userId in
        InputChatParticipant.with { $0.userID = Int64(userId) }
      }
      if let data = context.agentContext,
         let agentContext = try? InlineProtocol.AgentThreadContext(serializedBytes: data)
      {
        $0.agentContext = agentContext
      }
    })
  }

  public var satisfiedBlockersOnSuccess: [TransactionBlocker] {
    guard let reservedChatId = context.reservedChatId else { return [] }
    return [.chatCreated(chatId: reservedChatId)]
  }

  // Methods
  public func optimistic() async {
    guard let reservedChatId = context.reservedChatId else { return }

    let explicitTitle = Self.normalizedTitle(context.title)
    let title = explicitTitle ?? Self.normalizedTitle(context.placeholderTitle)
    let chat = Chat(
      id: reservedChatId,
      date: Date(),
      type: .thread,
      title: title,
      spaceId: context.spaceId,
      emoji: context.emoji,
      isPublic: context.isPublic,
      createdBy: Auth.shared.getCurrentUserId(),
      isUntitled: explicitTitle == nil ? true : nil,
      createState: .pending,
      agentContext: context.agentContext
    )
    let dialog = Dialog(optimisticForChat: chat)

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try chat.save(db)
        try dialog.save(db)
      }
    } catch {
      log.error("Failed to create optimistic chat", error: error)
    }
  }

  public func validateOptimisticState() async -> Bool {
    guard let reservedChatId = context.reservedChatId else { return true }

    do {
      return try await AppDatabase.shared.reader.read { db in
        try Chat.fetchOne(db, key: reservedChatId) != nil
          && Dialog.fetchOne(db, key: Dialog.getDialogId(peerThreadId: reservedChatId)) != nil
      }
    } catch {
      log.error("Failed to validate optimistic chat", error: error)
      return false
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .createChat(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      // Reconciliation must succeed before dependents are told that the chat
      // exists. Preserve an optimistic first message written while creation was
      // in flight, then atomically install the authoritative chat and dialog.
      try await AppDatabase.shared.dbWriter.write { db in
        var chat = Chat(from: response.chat)
        if let existingChat = try Chat.fetchOne(db, key: chat.id), chat.lastMsgId == nil {
          chat.lastMsgId = existingChat.lastMsgId
        }
        _ = try chat.saveFull(db)
        try response.dialog.saveFull(db)
      }
    } catch {
      log.error("Failed to reconcile created chat", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    let failure = CreateChatFailureTelemetryError(error: error, context: context)
    log.error(
      "Failed to create chat [\(failure.privacySafeErrorCategory)]",
      error: failure
    )
    await markOptimisticCreationFailed()
  }

  public func commitOutcomeUnknown() async {
    log.warning("Chat creation outcome is unknown; retaining the local shell as failed")
    await markOptimisticCreationFailed()
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
      log.error("Failed to mark chat creation as failed", error: error)
    }
  }

  public func cancelled() async {
    guard let reservedChatId = context.reservedChatId else { return }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard let chat = try Chat.fetchOne(db, key: reservedChatId),
              chat.createState == .pending
        else {
          return
        }

        try Dialog.deleteOne(db, key: Dialog.getDialogId(peerThreadId: reservedChatId))
        try Chat.deleteOne(db, key: reservedChatId)
      }
    } catch {
      log.error("Failed to remove cancelled optimistic chat", error: error)
    }
  }

  private static func normalizedTitle(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }
}

struct CreateChatFailureTelemetryError: Error, PrivacySafeErrorCategoryProviding {
  let underlyingCategory: String
  let hasReservation: Bool
  let hasAgentContext: Bool
  let hasAgentID: Bool
  let hasConfiguration: Bool
  let hasProject: Bool
  let hasModel: Bool
  let hasReasoning: Bool
  let hasSpace: Bool
  let isPublic: Bool

  init(error: TransactionError2, context: CreateChatTransaction.Context) {
    let agentContext = context.agentContext.flatMap {
      try? InlineProtocol.AgentThreadContext(serializedBytes: $0)
    }
    underlyingCategory = error.privacySafeErrorCategory
    hasReservation = context.reservedChatId != nil
    hasAgentContext = agentContext != nil
    hasAgentID = agentContext?.hasAgentID == true
    hasConfiguration = agentContext?.hasConfiguration == true
    hasProject = agentContext?.configuration.hasProjectID == true
    hasModel = agentContext?.configuration.hasModelID == true
    hasReasoning = agentContext?.configuration.hasReasoningEffortID == true
    hasSpace = context.spaceId != nil
    isPublic = context.isPublic
  }

  var privacySafeErrorCategory: String {
    "create_chat:\(underlyingCategory)" +
      ":r\(hasReservation ? 1 : 0)" +
      ":a\(hasAgentContext ? 1 : 0)" +
      ":i\(hasAgentID ? 1 : 0)" +
      ":c\(hasConfiguration ? 1 : 0)" +
      ":cp\(hasProject ? 1 : 0)" +
      ":cm\(hasModel ? 1 : 0)" +
      ":cr\(hasReasoning ? 1 : 0)" +
      ":s\(hasSpace ? 1 : 0)" +
      ":p\(isPublic ? 1 : 0)"
  }
}

// Helper

public extension Transaction2 where Self == CreateChatTransaction {
  static func createChat(
    title: String?,
    placeholderTitle: String? = nil,
    emoji: String?,
    isPublic: Bool,
    spaceId: Int64?,
    participants: [Int64],
    reservedChatId: Int64? = nil,
    agentContext: InlineProtocol.AgentThreadContext? = nil
  ) -> CreateChatTransaction {
    CreateChatTransaction(
      title: title,
      placeholderTitle: placeholderTitle,
      emoji: emoji,
      isPublic: isPublic,
      spaceId: spaceId,
      participants: participants,
      reservedChatId: reservedChatId,
      agentContext: agentContext
    )
  }
}
