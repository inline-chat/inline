import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatHistoryTransaction: Transaction2 {
  /// Private
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
    public var admissionToken: HistoryPageAdmissionToken?
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
      beforeID: nil,
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

  public var historyReadChatID: Int64? {
    context.admissionToken?.chatId
  }

  public var historyReadBucket: BucketKey? {
    .chat(peer: context.peer.toHistoryProtocolPeer())
  }

  public func preparingForDispatch() async throws(TransactionExecutionError) -> any Transaction2 {
    do {
      var prepared = self
      let admission = try await AppDatabase.shared.dbWriter.write { db in
        let peer = try HistoryPageAdmissionToken.canonicalPeer(db, peer: context.peer)
        return try (peer, HistoryPageAdmissionToken.capture(db, peer: peer))
      }
      prepared.context.peer = admission.0
      prepared.context.admissionToken = admission.1
      return prepared
    } catch HistoryPageAdmissionError.missingChat { throw .historyUnavailable }
    catch { throw .invalid }
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
         let mode = InlineProtocol.GetChatHistoryMode(rawValue: modeRawValue)
      {
        $0.mode = mode
      }
      if let anchorID = context.anchorID {
        $0.anchorID = anchorID
      }
      if let beforeID = context.beforeID {
        $0.beforeID = beforeID
      }
      if let afterID = context.afterID {
        $0.afterID = afterID
      }
      if let beforeLimit = context.beforeLimit {
        $0.beforeLimit = beforeLimit
      }
      if let afterLimit = context.afterLimit {
        $0.afterLimit = afterLimit
      }
      if let includeAnchor = context.includeAnchor {
        $0.includeAnchor = includeAnchor
      }
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
    } catch HistoryPageAdmissionError.stale {
      throw .staleHistory
    } catch HistoryPageAdmissionError.unavailable {
      throw .historyUnavailable
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
    var context = context
    context.peer = try HistoryPageAdmissionToken.canonicalPeer(db, peer: context.peer)

    let chatID = try HistoryPageAdmissionToken.resolveChatId(db, peer: context.peer)
    guard let token = context.admissionToken else { throw HistoryPageAdmissionError.stale }
    try token.validateSnapshot(db, peer: context.peer, seq: response.hasSeq ? response.seq : nil)
    try HistoryPageReducer.validateMessages(response.messages, chatId: chatID, peer: context.peer)
    guard let ranges = provenCoverages(context: context, messageIDs: response.messages.map(\.id))
    else { throw HistoryPageAdmissionError.malformedPage }
    let savedMessages = try HistoryPageReducer.save(response.messages, db: db)
    try Acknowledgement.save(db, cursors: response.acknowledgements.cursors, chatId: chatID)
    try Chat.updateLastMsgIds(db, messages: savedMessages)
    try HistoryPageReducer.admitCoverage(
      ranges, messages: response.messages, chatId: chatID, scope: .timeline,
      token: token, db: db
    )
  }

  static func provenCoverage(context: Context, messageIDs: [Int64]) -> ClosedRange<Int64>? {
    guard let ranges = provenCoverages(context: context, messageIDs: messageIDs), ranges.count == 1 else { return nil }
    return ranges[0]
  }

  /// Empty sides and excluded anchors never acquire coverage accidentally.
  static func provenCoverages(context: Context, messageIDs: [Int64]) -> [ClosedRange<Int64>]? {
    let maximum = MessageHistoryHole.positiveMessageIDMax
    guard messageIDs.allSatisfy({ 1 ... maximum ~= $0 }), Set(messageIDs).count == messageIDs.count,
          let requested = validLimit(context.limit, fallback: 60)
    else { return nil }
    let ids = messageIDs.sorted()
    let mode = context.modeRawValue.flatMap(InlineProtocol.GetChatHistoryMode.init(rawValue:))
      ?? (context.offsetID == nil ? .historyModeLatest : .historyModeOlder)
    for id in [context.offsetID, context.anchorID, context.beforeID, context.afterID].compactMap(\.self) {
      guard 1 ... maximum ~= id else { return nil }
    }
    guard context.offsetID == nil || context.beforeID == nil || context.offsetID == context.beforeID else { return nil }
    if mode != .historyModeAround {
      guard context.beforeLimit == nil, context.afterLimit == nil, context.includeAnchor == nil else { return nil }
    }
    switch mode {
      case .historyModeLatest, .historyModeUnspecified:
        guard context.offsetID == nil, context.beforeID == nil, context.afterID == nil, context.anchorID == nil,
              ids.count <= requested else { return nil }
        return [(ids.count < requested ? 1 : ids.first ?? 1) ... maximum]
      case .historyModeOlder:
        guard let before = context.beforeID ?? context.offsetID, context.afterID == nil, context.anchorID == nil,
              ids.count <= requested, ids.allSatisfy({ $0 < before }) else { return nil }
        guard before > 1 else { return [] }
        return [(ids.count < requested ? 1 : ids.first ?? 1) ... (before - 1)]
      case .historyModeNewer:
        guard let after = context.afterID, context.offsetID == nil, context.beforeID == nil, context.anchorID == nil,
              ids.count <= requested, ids.allSatisfy({ $0 > after }) else { return nil }
        guard after < maximum else { return [] }
        return [(after + 1) ... (ids.count < requested ? maximum : ids.last ?? maximum)]
      case .historyModeAround:
        guard let anchor = context.anchorID, context.offsetID == nil, context.beforeID == nil, context.afterID == nil
        else { return nil }
        let includeAnchor = context.includeAnchor ?? true
        let anchorCount = includeAnchor && ids.contains(anchor) ? 1 : 0
        guard let beforeLimit = validLimit(context.beforeLimit, fallback: requested / 2, allowZero: true),
              let afterLimit = validLimit(
                context.afterLimit,
                fallback: max(0, requested - requested / 2 - anchorCount),
                allowZero: true
              ),
              beforeLimit + afterLimit + anchorCount <= 100
        else { return nil }
        let older = ids.filter { $0 < anchor }
        let newer = ids.filter { $0 > anchor }
        guard older.count <= beforeLimit, newer.count <= afterLimit,
              includeAnchor || !ids.contains(anchor) else { return nil }
        var ranges: [ClosedRange<Int64>] = []
        if beforeLimit > 0, anchor > 1 {
          ranges.append((older.count < beforeLimit ? 1 : older.first ?? 1) ... (anchor - 1))
        }
        if includeAnchor {
          ranges.append(anchor ... anchor)
        }
        if afterLimit > 0, anchor < maximum {
          ranges.append((anchor + 1) ... (newer.count < afterLimit ? maximum : newer.last ?? maximum))
        }
        // Merge adjacent proof intervals, retaining a real excluded-anchor gap.
        var merged: [ClosedRange<Int64>] = []
        for range in ranges {
          if let last = merged.last, last.upperBound + 1 == range.lowerBound {
            merged[merged.count - 1] = last.lowerBound ... range.upperBound
          } else {
            merged.append(range)
          }
        }
        return merged
      case .UNRECOGNIZED: return nil
    }
  }

  private static func validLimit(_ value: Int32?, fallback: Int, allowZero: Bool = false) -> Int? {
    let limit = value.map(Int.init) ?? fallback
    return (allowZero ? 0 : 1) ... 100 ~= limit ? limit : nil
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
