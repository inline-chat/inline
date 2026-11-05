import Auth
import Foundation
import GRDB
import InlineProtocol
import RealtimeV2

/// One message that matches an in-chat search, from the local index or the server.
public struct InChatSearchHit: Identifiable, Sendable, Hashable {
  public var id: Int64 { messageId }

  public let messageId: Int64
  public let date: Date
  public let senderId: Int64
  public let sender: User?
  /// Message text (the caption for a file); empty when there is none.
  public let text: String
  /// The attached document's file name; the server matches it as well as the text.
  public let fileName: String?
  public let isOutgoing: Bool

  public init(
    messageId: Int64,
    date: Date,
    senderId: Int64,
    sender: User?,
    text: String,
    fileName: String? = nil,
    isOutgoing: Bool
  ) {
    self.messageId = messageId
    self.date = date
    self.senderId = senderId
    self.sender = sender
    self.text = text
    self.fileName = fileName
    self.isOutgoing = isOutgoing
  }

  public var senderName: String {
    sender?.displayName ?? "Unknown"
  }
}

/// A newest-first page of hits. `oldestMessageId` is the keyset cursor for the next page.
public struct InChatSearchPage: Sendable, Equatable {
  public var hits: [InChatSearchHit]
  public var oldestMessageId: Int64?
  public var hasMore: Bool

  public init(hits: [InChatSearchHit], oldestMessageId: Int64?, hasMore: Bool) {
    self.hits = hits
    self.oldestMessageId = oldestMessageId
    self.hasMore = hasMore
  }

  public static let empty = InChatSearchPage(hits: [], oldestMessageId: nil, hasMore: false)
}

public enum InChatSearchError: Error, Sendable {
  case unsupportedResponse
}

/// Fetches in-chat search pages. Local reads the FTS index; remote calls `searchMessages`
/// for the peer without saving the hits.
public enum InChatMessageSearch {
  /// The first page, kept small so results show fast.
  public static let pageLimit = 50
  /// Later pages, loaded in the background until the total is exact.
  public static let countPageLimit = 200
  static let remoteTimeout: Duration = .seconds(15)

  public static func searchLocal(
    db: AppDatabase,
    peer: Peer,
    query: String,
    beforeMessageId: Int64?,
    limit: Int = pageLimit
  ) async throws -> InChatSearchPage {
    guard LocalMessageSearch.isSearchable(query) else { return .empty }
    let limit = max(1, min(limit, LocalMessageSearch.maxLimit))
    let results = try await LocalMessageSearch.search(
      db: db,
      query: query,
      options: LocalMessageSearchOptions(
        peer: peer,
        limit: limit,
        includeArchived: true,
        matchPrefixes: true,
        sort: .messageIdDescending,
        beforeMessageId: beforeMessageId
      )
    )
    let hits = results.map { hit(from: $0.message) }
    return InChatSearchPage(
      hits: hits,
      oldestMessageId: hits.last?.messageId,
      hasMore: results.count >= limit
    )
  }

  public static func searchRemote(
    db: AppDatabase,
    peer: Peer,
    query: String,
    beforeMessageId: Int64?,
    limit: Int = pageLimit,
    expectedAccount: AuthAccountMutationToken?
  ) async throws -> InChatSearchPage {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .empty }
    let limit = max(1, min(limit, countPageLimit))

    // A direct call: hits stay in memory, so an open chat is not reloaded for every page.
    // Jumping to a hit loads its surrounding history through the normal history path.
    let result = try await Api.realtime.callRpcDirect(
      method: .searchMessages,
      input: .searchMessages(.with {
        $0.peerID = peer.toInputPeer()
        $0.queries = [trimmed]
        $0.limit = Int32(limit)
        if let beforeMessageId { $0.offsetID = beforeMessageId }
      }),
      timeout: remoteTimeout,
      accountToken: expectedAccount
    )
    guard case let .searchMessages(response) = result else {
      throw InChatSearchError.unsupportedResponse
    }

    let messages = response.messages
    let senderIds = Array(Set(messages.map(\.fromID)))
    let users: [Int64: User] = if senderIds.isEmpty {
      [:]
    } else {
      try await db.reader.read { db in
        let users = try User.fetchAll(db, keys: senderIds)
        return Dictionary(users.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      }
    }

    let hits = messages.map { message in
      InChatSearchHit(
        messageId: message.id,
        date: Date(timeIntervalSince1970: TimeInterval(message.date)),
        senderId: message.fromID,
        sender: users[message.fromID],
        text: message.hasMessage ? message.message : "",
        fileName: fileName(of: message),
        isOutgoing: message.out
      )
    }
    // Rows come newest first; the smallest ID is the next cursor even if the order drifts.
    let oldest = messages.map(\.id).min()
    return InChatSearchPage(hits: hits, oldestMessageId: oldest, hasMore: messages.count >= limit && oldest != nil)
  }

  static func hit(from fullMessage: FullMessage) -> InChatSearchHit {
    let message = fullMessage.message
    return InChatSearchHit(
      messageId: message.messageId,
      date: message.date,
      senderId: message.fromId,
      sender: fullMessage.from,
      text: message.text ?? "",
      fileName: fullMessage.documentInfo?.document.fileName.flatMap { $0.isEmpty ? nil : $0 },
      isOutgoing: message.out == true
    )
  }

  private static func fileName(of message: InlineProtocol.Message) -> String? {
    guard message.hasMedia, case let .document(document)? = message.media.media else { return nil }
    let name = document.document.fileName
    return name.isEmpty ? nil : name
  }
}

/// Pages of hits for one chat. The live source reads the local index and the server.
public protocol InChatSearchSource: Sendable {
  func local(query: String, beforeMessageId: Int64?, limit: Int) async throws -> InChatSearchPage
  func remote(query: String, beforeMessageId: Int64?, limit: Int) async throws -> InChatSearchPage
}

public struct InChatSearchLiveSource: InChatSearchSource {
  let db: AppDatabase
  let peer: Peer
  let account: AuthAccountMutationToken?

  public init(db: AppDatabase, peer: Peer) {
    self.db = db
    self.peer = peer
    account = try? Auth.shared.handle.beginAccountMutation()
  }

  public func local(query: String, beforeMessageId: Int64?, limit: Int) async throws -> InChatSearchPage {
    try await InChatMessageSearch.searchLocal(
      db: db, peer: peer, query: query, beforeMessageId: beforeMessageId, limit: limit
    )
  }

  public func remote(query: String, beforeMessageId: Int64?, limit: Int) async throws -> InChatSearchPage {
    try await InChatMessageSearch.searchRemote(
      db: db, peer: peer, query: query, beforeMessageId: beforeMessageId, limit: limit,
      expectedAccount: account
    )
  }
}
