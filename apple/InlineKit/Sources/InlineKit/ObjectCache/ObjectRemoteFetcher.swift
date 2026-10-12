import Foundation
import GRDB
import InlineObjectCache
import InlineProtocol
import Logger
import RealtimeV2

/// The network half of `ObjectCache.ensure`: turns a batch of IDs into RPCs and
/// saves what comes back. `ObjectRemoteLoader` decides when and how often it runs.
@MainActor
enum ObjectRemoteFetcher {
  /// Server limit for one `getUsers` call.
  private static let usersPerCall = 50
  /// Client limit for one `getMessages` call.
  private static let messagesPerCall = 100

  static func fetch(_ ids: [ObjectID]) async -> ObjectFetchOutcome<ObjectID> {
    var userIDs: [Int64] = []
    var spaceIDs: [Int64] = []
    var messageIDsByChat: [Int64: [Int64]] = [:]
    var outcome = ObjectFetchOutcome<ObjectID>()
    for id in ids {
      switch id {
        case let .user(id): userIDs.append(id)
        case let .space(id): spaceIDs.append(id)
        case let .message(chatId, messageId): messageIDsByChat[chatId, default: []].append(messageId)
        // Not fetched: the server's getChat creates a dialog for the caller, which
        // a background repair must not do. Reported absent, so it is left alone.
        case .chat: break
      }
    }

    for batch in userIDs.chunked(usersPerCall) {
      await attempt(batch.map(ObjectID.user), into: &outcome) {
        try await DataManager.shared.getUsers(ids: batch).map(ObjectID.user)
      }
    }
    for spaceID in spaceIDs {
      await attempt([.space(spaceID)], into: &outcome) {
        try await DataManager.shared.getSpace(spaceId: spaceID)
        return [.space(spaceID)]
      }
    }
    for (chatID, messageIDs) in messageIDsByChat {
      // History is fetched through its chat; an unknown chat has nothing to ask for.
      guard let peer = try? await AppDatabase.shared.reader.read({ db in
        try Chat.fetchOne(db, id: chatID).map { chat in
          chat.peerUserId.map { Peer.user(id: $0) } ?? Peer.thread(id: chatID)
        }
      }) else { continue }
      for batch in messageIDs.chunked(messagesPerCall) {
        await attempt(batch.map { .message(chatId: chatID, messageId: $0) }, into: &outcome) {
          let result = try await Api.realtime.send(.getMessages(peer: peer, messageIds: batch))
          guard case let .getMessages(page)? = result else { return [] }
          return page.messages.map { .message(chatId: chatID, messageId: $0.id) }
        }
      }
    }
    return outcome
  }

  /// Runs one RPC. A server refusal means the records are not there for us; any
  /// other error (offline, timeout) leaves them worth another attempt.
  private static func attempt(
    _ ids: [ObjectID],
    into outcome: inout ObjectFetchOutcome<ObjectID>,
    _ call: () async throws -> [ObjectID]
  ) async {
    do {
      try await outcome.resolved.formUnion(call())
    } catch RealtimeDirectRpcError.rpcError {
      return
    } catch TransactionError2.rpcError {
      return
    } catch {
      outcome.failed.formUnion(ids)
    }
  }
}

private extension Array {
  func chunked(_ size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
  }
}
