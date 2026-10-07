@testable import Auth
import RealtimeV2
import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

private typealias Chat = InlineKit.Chat
private typealias Peer = InlineKit.Peer

@Suite("Chat-ID link resolution", .serialized)
struct ChatLinkResolverTests {
  @Test("cached bot and human DMs use their counterpart; groups use the chat ID")
  func cachedPeers() async throws {
    let (database, auth, account) = try await fixture()
    try await database.dbWriter.write { db in
      var bot = User(id: 23, email: nil, firstName: "Bot")
      bot.bot = true
      try bot.insert(db)
      try User(id: 24, email: nil, firstName: "Human").insert(db)
      try Self.chat(id: 12, peerUserID: 23).insert(db)
      try Self.chat(id: 13, peerUserID: 24).insert(db)
      try Self.chat(id: 34).insert(db)
      var dialog = InlineProtocol.Dialog()
      dialog.peer = .with { $0.chat.chatID = 34 }
      dialog.chatID = 34
      try Dialog(from: dialog).save(db)
    }
    for (chatID, expected): (Int64, Peer) in [(12, .user(id: 23)), (13, .user(id: 24)), (34, .thread(id: 34))] {
      let peer = try await ChatLinkResolver.resolvePeer(
        chatID: chatID, account: account, database: database, auth: auth.handle
      ) { _, _ in
        Issue.record("Cached chat links should not fetch")
        return nil
      }
      #expect(peer == expected)
    }
  }

  @Test("a provisional thread-shaped row does not misroute a DM link")
  func provisionalChat() async throws {
    let (database, auth, account) = try await fixture()
    try await database.dbWriter.write { db in
      try Self.chat(id: 12).insert(db)
    }
    let peer = try await ChatLinkResolver.resolvePeer(
      chatID: 12, account: account, database: database, auth: auth.handle
    ) { requestedID, _ in
      return Self.chat(id: requestedID, peerUserID: 23)
    }
    #expect(peer == .user(id: 23))
  }

  @Test("uncached DM message links retain the requested message and resolve by chat ID")
  func uncachedMessageLink() async throws {
    let (database, auth, account) = try await fixture()
    let link = try #require(InlineDeepLink(url: URL(string: "in://chat/12/message/456")!))
    guard case let .message(chatID, messageID) = link else {
      Issue.record("Expected a message link")
      return
    }
    let peer = try await ChatLinkResolver.resolvePeer(
      chatID: chatID, account: account, database: database, auth: auth.handle
    ) { requestedID, expectedAccount in
      #expect(requestedID == 12)
      #expect(expectedAccount == account)
      return Self.chat(id: requestedID, peerUserID: 23)
    }
    #expect(peer == .user(id: 23))
    #expect(messageID == 456)
  }

  @Test("missing, malformed, and mismatched chats never invent a thread peer")
  func unavailableChats() async throws {
    let (database, auth, account) = try await fixture()
    for response: Chat? in [nil, Self.chat(id: 12, privateWithoutPeer: true), Self.chat(id: 99)] {
      let peer = try await ChatLinkResolver.resolvePeer(
        chatID: 12, account: account, database: database, auth: auth.handle
      ) { _, _ in response }
      #expect(peer == nil)
    }
  }

  @Test("access denial cannot produce a navigation peer")
  func accessDenied() async throws {
    let (database, auth, account) = try await fixture()
    await #expect(throws: FetchError.denied) {
      try await ChatLinkResolver.resolvePeer(
        chatID: 12, account: account, database: database, auth: auth.handle
      ) { _, _ in throw FetchError.denied }
    }
  }

  @Test("account transition during a fetch rejects the old result")
  func accountTransition() async throws {
    let (database, auth, account) = try await fixture()
    await #expect(throws: (any Error).self) {
      try await ChatLinkResolver.resolvePeer(
        chatID: 12, account: account, database: database, auth: auth.handle
      ) { _, _ in
        _ = try await auth.beginLogout()
        return Self.chat(id: 12, peerUserID: 23)
      }
    }
  }

  @Test("the real getChat transaction imports the counterpart before a fresh DM")
  func freshChatProfileImport() async throws {
    // Legacy transaction apply uses the singleton, which is explicitly an
    // in-memory database in test processes. Unique IDs isolate these fixtures.
    let database = AppDatabase.shared
    let placeholderPeerID: Int64 = 8_409_210
    let enrichedPeerID: Int64 = 8_409_211
    for (chatID, peerID, includesUser) in [
      (Int64(8_409_209), placeholderPeerID, false),
      (Int64(8_409_212), enrichedPeerID, true),
    ] {
      var result = InlineProtocol.GetChatResult()
      result.chat = .with {
        $0.id = chatID
        $0.date = 10
        $0.peerID.user.userID = peerID
      }
      result.dialog = .with {
        $0.peer.user.userID = peerID
        $0.chatID = chatID
      }
      if includesUser {
        result.user = .with {
          $0.id = peerID
          $0.firstName = "Linked Bot"
          $0.bot = true
        }
      }
      try await GetChatTransaction(peer: .thread(id: chatID)).apply(.getChat(result))
      try await database.reader.read { db in
        let savedPeer = try #require(try User.fetchOne(db, id: peerID))
        let savedChat = try #require(try Chat.fetchOne(db, id: chatID))
        #expect(savedChat.deepLinkPeer == .user(id: peerID))
        #expect(savedPeer.firstName == (includesUser ? "Linked Bot" : nil))
        #expect(savedPeer.bot == includesUser)
        #expect(try Dialog.filter(Dialog.Columns.chatId == chatID).fetchOne(db)?.peerUserId == peerID)
      }
    }
  }

  @Test("message-created DM placeholders fetch and import a no-photo bot profile")
  func messagePlaceholderProfile() async throws {
    let database = AppDatabase.shared
    let auth = Auth.mocked(authenticated: true)
    let account = try auth.handle.beginAccountMutation()
    let chatID: Int64 = 8_409_220
    let peerID: Int64 = 8_409_221
    try await database.dbWriter.write { db in
      _ = try Message.save(db, protocolMessage: .with {
        $0.id = 456
        $0.chatID = chatID
        $0.peerID.user.userID = peerID
        $0.fromID = peerID
        $0.date = 10
        $0.message = "linked target"
      }, materializeMissingReferences: true)
      #expect(try User.fetchOne(db, id: peerID)?.needsDisplayNameFetch == true)
    }
    let peer = try await ChatLinkResolver.resolvePeer(
      chatID: chatID, account: account, database: database, auth: auth.handle
    ) { requestedID, _ in
      var result = InlineProtocol.GetChatResult()
      result.chat = .with { $0.id = requestedID; $0.date = 10; $0.peerID.user.userID = peerID }
      result.dialog = .with { $0.chatID = requestedID; $0.peer.user.userID = peerID }
      result.user = .with { $0.id = peerID; $0.firstName = "Linked Bot"; $0.bot = true }
      try await GetChatTransaction(peer: .thread(id: requestedID)).apply(.getChat(result))
      return Chat(from: result.chat)
    }
    #expect(peer == .user(id: peerID))
    try await database.reader.read { db in
      let user = try #require(try User.fetchOne(db, id: peerID))
      #expect(user.firstName == "Linked Bot")
      #expect(user.bot)
      let message = try #require(try Message.filter(Message.Columns.chatId == chatID).fetchOne(db))
      #expect(message.messageId == 456)
      #expect(message.peerUserId == peerID)
    }
  }

  @Test("a replaced account lease is rejected before reading cached peers")
  func staleCachedAccount() async throws {
    let (database, auth, account) = try await fixture()
    try await database.dbWriter.write { db in
      try User(id: 23, email: nil, firstName: "Bot").insert(db)
      try Self.chat(id: 12, peerUserID: 23).insert(db)
    }
    try await auth.saveCredentials(token: "2:replacement", userId: 2)
    await #expect(throws: (any Error).self) {
      try await ChatLinkResolver.resolvePeer(
        chatID: 12, account: account, database: database, auth: auth.handle
      ) { _, _ in
        Issue.record("A stale account must not fetch")
        return Self.chat(id: 12, peerUserID: 23)
      }
    }
  }

  @Test("cancellation during resolution cannot return a navigation peer")
  func cancelledFetch() async throws {
    let (database, auth, account) = try await fixture()
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let task = Task {
      try await ChatLinkResolver.resolvePeer(
        chatID: 12, account: account, database: database, auth: auth.handle
      ) { _, _ in
        started.continuation.yield(())
        for await _ in release.stream { break }
        return Self.chat(id: 12, peerUserID: 23)
      }
    }
    for await _ in started.stream { break }
    task.cancel()
    release.continuation.finish()
    started.continuation.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test("locked link admission waits for credentials and binds the hinted account")
  func lockedAccountRecovery() async throws {
    let (auth, driver) = accountFixture(status: .locked(userIdHint: 1))
    let snapshots = auth.snapshots
    let wait = Task {
      try await ChatLinkResolver.waitForAccount(
        initialStatus: .locked(userIdHint: 1), snapshots: snapshots, auth: auth
      )
    }
    driver.set(.authenticated(AuthCredentials(userId: 1, token: "1:test")))
    await auth.refreshFromStorage()
    let account = try #require(try await wait.value)
    #expect(account.userID == 1)
    try auth.validateAccountMutation(account)
  }

  @Test("hydrating admission sees a logout buffered before its task starts")
  func hydrationCannotCrossLogout() async throws {
    let (auth, driver) = accountFixture(status: .locked(userIdHint: nil))
    let snapshots = auth.snapshots
    driver.set(.unauthenticated)
    await auth.refreshFromStorage()
    driver.set(.authenticated(AuthCredentials(userId: 2, token: "2:test")))
    await auth.refreshFromStorage()
    let account = try await ChatLinkResolver.waitForAccount(
      initialStatus: .hydrating, snapshots: snapshots, auth: auth
    )
    #expect(account == nil)
  }

  @Test("locked hints and queued authenticated events cannot admit another account")
  func wrongHydratedAccount() async throws {
    let (auth, driver) = accountFixture(status: .locked(userIdHint: 1))
    let snapshots = auth.snapshots
    driver.set(.authenticated(AuthCredentials(userId: 2, token: "2:test")))
    await auth.refreshFromStorage()
    #expect(try await ChatLinkResolver.waitForAccount(
      initialStatus: .locked(userIdHint: 1), snapshots: snapshots, auth: auth
    ) == nil)
  }

  @Test("cold resolution wakes the real realtime connection and persists the canonical DM", .timeLimit(.minutes(1)))
  func coldRealtimeResolution() async throws {
    let database = AppDatabase.shared
    let (auth, driver) = accountFixture(status: .locked(userIdHint: 1))
    let storage = StorageGate()
    let transport = ChatLinkTestTransport()
    let realtime = RealtimeV2(
      transport: transport, auth: auth,
      applyUpdates: InlineApplyUpdates(), syncStorage: StubSyncStorage(),
      storageIsReady: { storage.isReady }
    )
    driver.set(.authenticated(AuthCredentials(userId: 1, token: "1:test")))
    await auth.refreshFromStorage()
    let account = try auth.beginAccountMutation()
    // Auth alone must neither drop this request nor open transaction admission.
    do {
      try await realtime.withUserInitiatedConnection(accountToken: account, timeout: .milliseconds(100)) { _ in
        Issue.record("No operation may run before persistent storage admission")
      }
      Issue.record("Pending storage should exhaust the bounded request deadline")
    } catch {
      guard case RealtimeDirectRpcError.timeout = error else { throw error }
    }
    #expect(await transport.requestedChatID == nil)
    let resolve = Task {
      try await ChatLinkResolver.resolvePeer(
        chatID: 8_409_230, account: account, database: database, auth: auth
      ) { chatID, account in
        try await ChatLinkResolver.fetchChat(chatID: chatID, account: account, realtime: realtime)
      }
    }
    storage.admit()
    #expect(await realtime.admitPersistentStorage())
    for await _ in transport.didStart { break }
    #expect(await transport.requestedChatID == nil)
    await transport.allowConnection()
    do {
      #expect(try await resolve.value == .user(id: 8_409_231))
      #expect(await transport.requestedChatID == 8_409_230)
      try await database.reader.read { db in
        let chat = try Chat.fetchOne(db, id: 8_409_230)
        let user = try User.fetchOne(db, id: 8_409_231)
        #expect(chat?.deepLinkPeer == .user(id: 8_409_231))
        #expect(user?.firstName == "Cold Bot")
      }
    } catch {
      await realtime.prepareForTermination()
      throw error
    }
    await realtime.prepareForTermination()
  }

  private func accountFixture(status: AuthStatus) -> (AuthHandle, SnapshotDriver) {
    let driver = SnapshotDriver(status)
    let cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    let store = AuthStore(cache: cache, mocked: true, namespace: UUID().uuidString,
                          readSnapshot: { _, _, _ in driver.get() })
    return (AuthHandle(cache: cache, store: store), driver)
  }

  private final class StorageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool { lock.withLock { ready } }
    func admit() { lock.withLock { ready = true } }
  }

  private final class SnapshotDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: AuthSnapshot
    init(_ status: AuthStatus) { snapshot = AuthSnapshot(status: status, didHydrate: true) }
    func set(_ status: AuthStatus) {
      lock.withLock { snapshot = AuthSnapshot(status: status, didHydrate: true) }
    }
    func get() -> AuthSnapshot { lock.withLock { snapshot } }
  }

  private enum FetchError: Error, Equatable {
    case denied
  }

  private func fixture() async throws -> (AppDatabase, Auth, AuthAccountMutationToken) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let auth = Auth.mocked(authenticated: true)
    await auth.refreshFromStorage()
    return (database, auth, try auth.handle.beginAccountMutation())
  }

  private static func chat(id: Int64, peerUserID: Int64? = nil, privateWithoutPeer: Bool = false) -> Chat {
    Chat(
      id: id, date: Date(timeIntervalSince1970: 10),
      type: peerUserID != nil || privateWithoutPeer ? .privateChat : .thread,
      title: nil, spaceId: nil, peerUserId: peerUserID
    )
  }
}
