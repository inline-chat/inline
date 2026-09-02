import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatHistoryTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/GetChatHistory")

  // Properties
  public var method: InlineProtocol.Method = .getChatHistory
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var offsetID: Int64?
    public var limit: Int32?
    public var modeRawValue: Int?
    public var anchorID: Int64?
    public var beforeID: Int64?
    public var afterID: Int64?
    public var beforeLimit: Int32?
    public var afterLimit: Int32?
    public var includeAnchor: Bool?
  }

  public init(peer: Peer, offsetID: Int64? = nil, limit: Int32? = nil) {
    context = Context(
      peer: peer,
      offsetID: offsetID,
      limit: limit,
      modeRawValue: (offsetID == nil
        ? InlineProtocol.GetChatHistoryMode.historyModeLatest
        : .historyModeOlder).rawValue,
      anchorID: nil,
      beforeID: offsetID,
      afterID: nil,
      beforeLimit: nil,
      afterLimit: nil,
      includeAnchor: nil
    )
  }

  public init(
    peer: Peer,
    mode: InlineProtocol.GetChatHistoryMode,
    anchorID: Int64? = nil,
    beforeID: Int64? = nil,
    afterID: Int64? = nil,
    limit: Int32? = nil,
    beforeLimit: Int32? = nil,
    afterLimit: Int32? = nil,
    includeAnchor: Bool? = nil
  ) {
    context = Context(
      peer: peer,
      offsetID: nil,
      limit: limit,
      modeRawValue: mode.rawValue,
      anchorID: anchorID,
      beforeID: beforeID,
      afterID: afterID,
      beforeLimit: beforeLimit,
      afterLimit: afterLimit,
      includeAnchor: includeAnchor
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChatHistory(.with {
      $0.peerID = context.peer.toInputPeer()

      if let offsetID = context.offsetID {
        $0.offsetID = offsetID
      }

      if let limit = context.limit {
        $0.limit = limit
      }
      if let modeRawValue = context.modeRawValue,
         let mode = InlineProtocol.GetChatHistoryMode(rawValue: modeRawValue) {
        $0.mode = mode
      }
      if let anchorID = context.anchorID { $0.anchorID = anchorID }
      if let beforeID = context.beforeID { $0.beforeID = beforeID }
      if let afterID = context.afterID { $0.afterID = afterID }
      if let beforeLimit = context.beforeLimit { $0.beforeLimit = beforeLimit }
      if let afterLimit = context.afterLimit { $0.afterLimit = afterLimit }
      if let includeAnchor = context.includeAnchor { $0.includeAnchor = includeAnchor }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func optimistic() async {
    // GetChatHistory is a query transaction, no optimistic updates needed
    log.debug("GetChatHistory transaction - no optimistic updates")
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChatHistory(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getChatHistory result: \(response)")

    let peerId = context.peer

    do {
      _ = try await AppDatabase.shared.dbWriter.write { db in
        try Self.apply(response, context: context, db: db)
      }

      // Publish and reload messages
      Task.detached(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messagesReload(peer: peerId, animated: false)
      }

      log.trace("getChatHistory saved")
    } catch {
      log.error("Failed to save chat history", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get chat history", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled getChatHistory transaction")
  }

  /// Applies message rows and their proven numeric coverage in one writer transaction.
  public static func apply(
    _ response: InlineProtocol.GetChatHistoryResult,
    context: Context,
    db: Database
  ) throws {
    let chatID: Int64
    switch context.peer {
      case let .thread(id):
        chatID = id
      case let .user(userID):
        guard let chat = try Chat
          .filter(Chat.Columns.peerUserId == userID)
          .fetchOne(db)
        else { throw TransactionExecutionError.invalid }
        chatID = chat.id
    }

    guard response.messages.allSatisfy({
      $0.id > 0 && $0.chatID == chatID
    }) else {
      throw TransactionExecutionError.invalid
    }

    var savedMessages: [Message] = []
    savedMessages.reserveCapacity(response.messages.count)
    for message in response.messages {
      savedMessages.append(try Message.save(
        db,
        protocolMessage: message,
        publishChanges: false,
        materializeMissingReferences: true
      ))
    }
    try Chat.updateLastMsgIds(db, messages: savedMessages)

    if let range = provenCoverage(context: context, messageIDs: response.messages.map(\.id)) {
      try MessageHistoryCoverageStore.subtract(
        db,
        chatId: chatID,
        lowerId: range.lowerBound,
        upperId: range.upperBound
      )
    }
  }

  static func provenCoverage(
    context: Context,
    messageIDs: [Int64]
  ) -> ClosedRange<Int64>? {
    guard messageIDs.allSatisfy({ 1 ... MessageHistoryHole.positiveMessageIDMax ~= $0 }) else {
      return nil
    }
    let ids = messageIDs.sorted()
    let mode = context.modeRawValue
      .flatMap(InlineProtocol.GetChatHistoryMode.init(rawValue:))
      ?? (context.offsetID == nil ? .historyModeLatest : .historyModeOlder)
    switch mode {
      case .historyModeLatest, .historyModeUnspecified:
        guard let minimum = ids.first else {
          return 1 ... MessageHistoryHole.positiveMessageIDMax
        }
        return minimum ... MessageHistoryHole.positiveMessageIDMax

      case .historyModeOlder:
        guard let before = context.beforeID ?? context.offsetID, before > 1 else { return nil }
        let upper = min(before - 1, MessageHistoryHole.positiveMessageIDMax)
        let lower = ids.first ?? 1
        guard lower <= upper, ids.allSatisfy({ $0 < before }) else { return nil }
        return lower ... upper

      case .historyModeNewer:
        guard let after = context.afterID, after < MessageHistoryHole.positiveMessageIDMax else { return nil }
        let lower = max(1, after + 1)
        let upper = ids.last ?? MessageHistoryHole.positiveMessageIDMax
        guard lower <= upper, ids.allSatisfy({ $0 > after }) else { return nil }
        return lower ... upper

      case .historyModeAround:
        guard let coordinate = context.anchorID,
              1 ... MessageHistoryHole.positiveMessageIDMax ~= coordinate
        else { return nil }

        let includeAnchor = context.includeAnchor ?? true
        let anchorCount = ids.count(where: { $0 == coordinate })
        guard anchorCount <= 1, includeAnchor || anchorCount == 0 else { return nil }

        let requestedLimit = max(0, Int(context.limit ?? 60))
        let defaultBeforeLimit = requestedLimit / 2
        let defaultAfterLimit = max(requestedLimit - defaultBeforeLimit - anchorCount, 0)
        let beforeLimit = max(0, Int(context.beforeLimit ?? Int32(clamping: defaultBeforeLimit)))
        let afterLimit = max(0, Int(context.afterLimit ?? Int32(clamping: defaultAfterLimit)))
        let olderIDs = ids.filter { $0 < coordinate }
        let newerIDs = ids.filter { $0 > coordinate }
        guard olderIDs.count <= beforeLimit, newerIDs.count <= afterLimit else { return nil }

        // AROUND queries the exact coordinate and both numeric sides in one
        // repeatable-read server snapshot. A short side proves its absolute
        // boundary; otherwise only the returned extent is certified. Always
        // include a requested anchor that the snapshot proved was deleted.
        let lower = olderIDs.count < beforeLimit ? 1 : (olderIDs.first ?? coordinate)
        let upper = newerIDs.count < afterLimit
          ? MessageHistoryHole.positiveMessageIDMax
          : (newerIDs.last ?? coordinate)
        return min(lower, coordinate) ... max(upper, coordinate)

      case .UNRECOGNIZED:
        return nil
    }
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetChatHistoryTransaction {
  static func getChatHistory(
    peer: Peer,
    offsetID: Int64? = nil,
    limit: Int32? = nil
  ) -> GetChatHistoryTransaction {
    GetChatHistoryTransaction(peer: peer, offsetID: offsetID, limit: limit)
  }

  static func getChatHistory(
    peer: Peer,
    mode: InlineProtocol.GetChatHistoryMode,
    anchorID: Int64? = nil,
    beforeID: Int64? = nil,
    afterID: Int64? = nil,
    limit: Int32? = nil,
    beforeLimit: Int32? = nil,
    afterLimit: Int32? = nil,
    includeAnchor: Bool? = nil
  ) -> GetChatHistoryTransaction {
    GetChatHistoryTransaction(
      peer: peer,
      mode: mode,
      anchorID: anchorID,
      beforeID: beforeID,
      afterID: afterID,
      limit: limit,
      beforeLimit: beforeLimit,
      afterLimit: afterLimit,
      includeAnchor: includeAnchor
    )
  }
}
