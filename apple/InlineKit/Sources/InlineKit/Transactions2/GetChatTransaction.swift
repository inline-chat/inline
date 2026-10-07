import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatTransaction: Transaction2 {
  /// Private
  private var log = Log.scoped("Transactions/GetChat")

  // Properties
  public var method: InlineProtocol.Method = .getChat
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var admissionToken: HistoryPageAdmissionToken?
  }

  public init(peer: Peer) {
    context = Context(peer: peer)
  }

  public var historyReadChatID: Int64? {
    if let id = context.admissionToken?.chatId, id > 0 {
      return id
    }
    if case let .thread(id) = context.peer {
      return id
    }
    return nil
  }

  public var historyReadBucket: BucketKey? {
    .chat(peer: context.peer.toHistoryProtocolPeer())
  }

  public func preparingForDispatch() async throws(TransactionExecutionError) -> any Transaction2 {
    do {
      var prepared = self
      let admission = try await AppDatabase.shared.dbWriter.write { db in
        let peer = try HistoryPageAdmissionToken.canonicalPeer(db, peer: context.peer)
        return try (peer, Self.captureAdmission(db, peer: peer))
      }
      prepared.context.peer = admission.0
      prepared.context.admissionToken = admission.1
      return prepared
    } catch { throw .invalid }
  }

  static func captureAdmission(_ db: Database, peer: Peer) throws -> HistoryPageAdmissionToken {
    if let chat = try Chat.getByPeerId(db: db, peerId: peer) {
      return try HistoryPageAdmissionToken.capture(db, chatId: chat.id)
    }
    // A cold DM has no canonical chat ID until its metadata arrives. Preserve
    // the account removal fence without creating an invented local identity.
    return try HistoryPageAdmissionToken(
      chatId: 0, revision: 0, knownMaxMessageId: 0,
      removalRevision: SyncRemovalRevision.read(db)
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChat(.with {
      $0.peerID = context.peer.toInputPeer()
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChat(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try Self.apply(response, context: context, db: db)
      }
      log.trace("getChat saved")
    } catch HistoryPageAdmissionError.stale {
      throw .staleHistory
    } catch {
      log.error("Failed to save chat/dialog in transaction", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  static func apply(_ response: InlineProtocol.GetChatResult, context: Context, db: Database) throws {
    var context = context
    guard response.hasChat, response.hasDialog, response.chat.id > 0 else {
      throw HistoryPageAdmissionError.malformedPage
    }
    switch context.peer {
      case let .thread(id):
        guard response.chat.id == id else { throw HistoryPageAdmissionError.malformedPage }
        switch response.chat.peerID.type {
          case let .user(user) where user.userID > 0: context.peer = .user(id: user.userID)
          case let .chat(chat) where chat.chatID == id: break
          default: throw HistoryPageAdmissionError.malformedPage
        }
      case .user: break
    }
    guard response.hasChat, response.hasDialog, response.chat.hasSeq,
          response.chat.id > 0,
          response.chat.peerID.toPeer() == context.peer,
          response.dialog.peer.toPeer() == context.peer,
          !response.dialog.hasChatID || response.dialog.chatID == response.chat.id,
          let token = context.admissionToken
    else { throw HistoryPageAdmissionError.malformedPage }

    let sequence = Int64(response.chat.seq)
    guard sequence >= 0 else { throw HistoryPageAdmissionError.malformedPage }
    if token.chatId > 0 {
      guard token.chatId == response.chat.id else { throw HistoryPageAdmissionError.stale }
      try token.validateSnapshot(db, peer: context.peer, seq: sequence)
    } else {
      guard try SyncRemovalRevision.read(db) == token.removalRevision else { throw HistoryPageAdmissionError.stale }
      if let existing = try Chat.getByPeerId(db: db, peerId: context.peer) {
        guard existing.id == response.chat.id,
              try Int64.fetchOne(
                db,
                sql: "SELECT historyAdmissionRevision FROM chat WHERE id = ?",
                arguments: [existing.id]
              ) == 0
        else { throw HistoryPageAdmissionError.stale }
      }
    }

    let entityId: Int64 = switch context.peer {
      case let .thread(id): -id
      case let .user(id): id
    }
    let committed = try Int64.fetchOne(
      db, sql: "SELECT seq FROM sync_bucket_state WHERE bucketType = 1 AND entityId = ?", arguments: [entityId]
    ) ?? 0
    guard committed >= sequence else { throw HistoryPageAdmissionError.stale }
    // New text messages do not bump the deletion/admission revision. Their
    // newer committed cursor must still prevent metadata, pins and read-state
    // regression from this older response.
    guard committed == sequence else { return }

    if response.hasUser {
      do { try Self.repairPeerProfilePhoto(response.user, in: db) }
      catch { Log.shared.warning("Skipping peer enrichment for getChat because it could not be saved: \(error)") }
    }

    var chat = Chat(from: response.chat)
    try Self.clearMissingOptionalReferences(in: &chat, db: db)
    try chat.saveWithValidLastMsg(db)
    try Acknowledgement.save(db, cursors: response.chat.acknowledgements.cursors, chatId: chat.id, publishChanges: true)
    _ = try response.dialog.saveFull(db)
    try PinnedMessage.replaceAll(db, chatId: chat.id, messageIds: response.pinnedMessageIds)

    // Metadata reads confer no message-range authority. In particular, a
    // reply-thread anchor belongs to the parent bucket, not this Chat.seq.
    // Parent navigation fetches it through the parent's guarded getMessages.
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get chat", error: error)
  }

  @discardableResult
  static func repairPeerProfilePhoto(_ user: InlineProtocol.User, in db: Database) throws -> Bool {
    if let existing = try User.fetchOne(db, id: user.id) {
      // Message imports may create a nameless peer before its full profile arrives.
      let fillsDisplayName = existing.needsDisplayNameFetch && !User(from: user).needsDisplayNameFetch
      guard fillsDisplayName || profilePhotoNeedsRepair(existing: existing, incoming: user) else { return false }
    }

    _ = try User.save(db, user: user)
    return true
  }

  private static func profilePhotoNeedsRepair(existing: User, incoming: InlineProtocol.User) -> Bool {
    let existingIdentity = normalized(existing.profileFileUniqueId)
    let existingURL = normalized(existing.profileCdnUrl)
    let existingHasPhoto = existingIdentity != nil
      || normalized(existing.profileFileId) != nil
      || existingURL != nil
      || normalized(existing.profileLocalPath) != nil

    guard incoming.hasProfilePhoto else { return existingHasPhoto }

    let incomingIdentity = incoming.profilePhoto.hasFileUniqueID
      ? normalized(incoming.profilePhoto.fileUniqueID)
      : nil
    let incomingURL = incoming.profilePhoto.hasCdnURL
      ? normalized(incoming.profilePhoto.cdnURL)
      : nil

    if incomingIdentity != existingIdentity {
      return true
    }
    if let incomingURL, incomingURL != existingURL {
      return true
    }
    return false
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static func clearMissingOptionalReferences(in chat: inout Chat, db: Database) throws {
    if let spaceId = chat.spaceId, try Space.fetchOne(db, id: spaceId) == nil {
      Log.shared.warning("Dropping missing space reference while saving getChat result for chat \(chat.id)")
      chat.spaceId = nil
    }

    if let createdBy = chat.createdBy, try User.fetchOne(db, id: createdBy) == nil {
      Log.shared.warning("Dropping missing creator reference while saving getChat result for chat \(chat.id)")
      chat.createdBy = nil
    }

    if let parentChatId = chat.parentChatId, try Chat.fetchOne(db, id: parentChatId) == nil {
      Log.shared.warning("Dropping missing parent chat reference while saving getChat result for chat \(chat.id)")
      chat.parentChatId = nil
    }
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetChatTransaction {
  static func getChat(peer: Peer) -> GetChatTransaction {
    GetChatTransaction(peer: peer)
  }
}
