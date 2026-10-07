import Auth
import GRDB
import RealtimeV2

/// Resolves the stable chat ID in a URL to the peer used by navigation.
/// A private chat's ID is distinct from its other user's ID.
public enum ChatLinkResolver {
  public static func resolvePeer(
    chatID: Int64,
    account: AuthAccountMutationToken
  ) async throws -> Peer? {
    try await resolvePeer(
      chatID: chatID,
      account: account,
      database: AppDatabase.shared,
      auth: Auth.shared.handle
    ) { chatID, account in
      try await fetchChat(chatID: chatID, account: account, realtime: Api.realtime)
    }
  }

  /// Subscribe at the URL request before starting asynchronous work, so a
  /// logout while credentials hydrate cannot be missed by a later subscriber.
  public static func waitForAccount(
    initialStatus: AuthStatus,
    snapshots: AsyncStream<AuthSnapshot>,
    auth: AuthHandle
  ) async throws -> AuthAccountMutationToken? {
    switch initialStatus {
    case .hydrating, .locked: break
    default: return nil
    }
    var expectedUserID = initialStatus.userId
    await auth.refreshFromStorage()
    for await snapshot in snapshots {
      try Task.checkCancellation()
      guard !auth.hasPendingAccountTransition() else { return nil }
      switch snapshot.status {
      case .hydrating:
        continue
      case let .locked(userID):
        if let userID {
          guard expectedUserID == nil || expectedUserID == userID else { return nil }
          expectedUserID = userID
        }
      case .authenticated, .authenticatedV3:
        let account = try auth.beginAccountMutation()
        guard snapshot.currentUserId == account.userID,
              expectedUserID == nil || expectedUserID == account.userID
        else { return nil }
        return account
      default:
        return nil
      }
    }
    try Task.checkCancellation()
    return nil
  }

  static func fetchChat(
    chatID: Int64,
    account: AuthAccountMutationToken,
    realtime: RealtimeV2
  ) async throws -> Chat? {
    try await realtime.withUserInitiatedConnection(accountToken: account) { realtime in
      let result = try await realtime.send(
        .getChat(peer: .thread(id: chatID)), expectedAccount: account
      )
      guard case let .getChat(response) = result, response.hasChat else { return nil }
      return Chat(from: response.chat)
    }
  }

  static func resolvePeer(
    chatID: Int64,
    account: AuthAccountMutationToken,
    database: AppDatabase,
    auth: AuthHandle,
    fetchChat: @Sendable (Int64, AuthAccountMutationToken) async throws -> Chat?
  ) async throws -> Peer? {
    guard chatID > 0 else { return nil }
    try Task.checkCancellation()
    try auth.validateAccountMutation(account)
    let cached = try await database.reader.read { db in
      guard let chat = try Chat.fetchOne(db, id: chatID),
            let peer = chat.deepLinkPeer else { return nil as Chat? }
      if case let .user(id) = peer {
        guard let user = try User.fetchOne(db, id: id), !user.needsDisplayNameFetch else { return nil }
      }
      // Incoming messages can create a thread-shaped placeholder before the
      // DM counterpart arrives. Only a matching dialog establishes a thread.
      if case .thread = peer,
         try Dialog
           .filter(Dialog.Columns.peerThreadId == chatID && Dialog.Columns.chatId == chatID)
           .fetchOne(db) == nil {
        return nil
      }
      return chat
    }
    try auth.validateAccountMutation(account)
    try Task.checkCancellation()

    let chat: Chat?
    if let cached {
      chat = cached
    } else {
      // The server authorizes chat-table IDs for both DMs and threads. The
      // existing getChat transaction persists its canonical chat and dialog.
      chat = try await fetchChat(chatID, account)
    }

    try auth.validateAccountMutation(account)
    try Task.checkCancellation()
    guard let chat, chat.id == chatID else { return nil }
    return chat.deepLinkPeer
  }
}
