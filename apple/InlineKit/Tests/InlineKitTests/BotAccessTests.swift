import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import Auth
@testable import InlineKit

/// Answers `getAgentAccess` from a fixed table and records what was asked.
private actor AccessRealtime: InlineRPCRealtime {
  private var answers: [Int64: InlineProtocol.AgentAccess]
  private var fails: Bool
  private(set) var asked: [[Int64]] = []
  private(set) var listed: [Int64] = []

  init(answers: [InlineProtocol.AgentAccess], fails: Bool = false) {
    self.answers = Dictionary(uniqueKeysWithValues: answers.map { ($0.botUserID, $0) })
    self.fails = fails
  }

  func set(_ answer: InlineProtocol.AgentAccess) { answers[answer.botUserID] = answer }
  func setFails(_ fails: Bool) { self.fails = fails }

  func callRpcDirect(
    method: InlineProtocol.Method,
    input: InlineProtocol.RpcCall.OneOf_Input?,
    timeout _: Duration?,
    accountToken _: AuthAccountMutationToken?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    switch input {
    case let .getAgentAccess(request):
      asked.append(request.botUserIds)
      if fails { throw CancellationError() }
      return .getAgentAccess(.with { $0.access = request.botUserIds.compactMap { answers[$0] } })
    case let .listAgentGrants(request):
      listed.append(request.botUserID)
      throw CancellationError()
    default:
      _ = method
      return nil
    }
  }

  func applyUpdatesAndWait(_: [InlineProtocol.Update], accountToken _: AuthAccountMutationToken) async throws {}
}

@MainActor
@Suite("Bot access", .serialized)
struct BotAccessTests {
  private nonisolated static let me: Int64 = 42
  private nonisolated static let owner: Int64 = 7

  private nonisolated static func answer(
    _ botUserID: Int64,
    canMessage: Bool,
    operations: [InlineProtocol.AgentGrantOperation] = [],
    isOwner: Bool = false
  ) -> InlineProtocol.AgentAccess {
    .with {
      $0.botUserID = botUserID
      $0.canMessage = canMessage
      $0.operations = operations
      $0.isOwner = isOwner
      $0.ownerUserID = isOwner ? me : owner
    }
  }

  private static func makeAuth() -> AuthHandle {
    let initial = AuthSnapshot(status: .authenticated(AuthCredentials(userId: me, token: "test")), didHydrate: true)
    let cache = AuthSnapshotCache(initial: initial)
    let store = AuthStore(cache: cache, mocked: true, namespace: UUID().uuidString,
                          readSnapshot: { @Sendable _, _, _ in initial })
    return AuthHandle(cache: cache, store: store)
  }

  /// Bots 901 (shared with me), 902 (not shared), 903 (never asked about), 904 (mine), and a person, 905.
  private nonisolated static func seed(_ db: Database) throws {
    for (id, name, bot) in [
      (Int64(901), "Shared", true), (902, "Private", true), (903, "Unasked", true), (904, "Mine", true),
      (905, "Dena", false),
    ] {
      var user = User(id: id, email: nil, firstName: name)
      user.bot = bot
      try user.insert(db)
    }
    try BotOwner.set(db, botUserId: 904, ownerUserId: me)
    try BotOwner.set(db, botUserId: 902, ownerUserId: owner)
    try BotAccess.set(db, BotAccess(botUserId: 901, canMessage: true, operations: [.invoke]))
    try BotAccess.set(db, BotAccess(botUserId: 902, canMessage: false, operations: []))
  }

  private func stored(_ database: AppDatabase) async throws -> [Int64: Bool] {
    try await database.reader.read { db in
      Dictionary(uniqueKeysWithValues: try BotAccess.fetchAll(db).map { ($0.botUserId, $0.canMessage) })
    }
  }

  private func waitUntil(_ condition: @escaping () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while clock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition was not met in time")
  }

  @Test("a bot is offered only when the viewer is known to reach it; only a known no takes a chat away")
  func visibility() async throws {
    let database = AppDatabase.empty()
    let (mine, other) = try await database.dbWriter.write { db in
      try Self.seed(db)
      return try (
        BotVisibility.fetch(db, viewerUserId: Self.me),
        BotVisibility.fetch(db, viewerUserId: Self.owner)
      )
    }
    #expect(mine.notOffered == [902, 903])
    #expect(mine.unreachable == [902])
    // The same rows read for the other bot's owner: their own bot is never hidden from them.
    #expect(other.notOffered == [903, 904])
    #expect(other.unreachable == [])
  }

  @Test("before the server has answered about any bot, nothing is hidden")
  func nothingHiddenBeforeFirstAnswer() async throws {
    let database = AppDatabase.empty()
    let (visibility, roster) = try await database.dbWriter.write { db in
      try Self.seed(db)
      // An older server, or a first launch offline: no answers stored yet.
      try BotAccess.deleteAll(db)
      let date = Date(timeIntervalSince1970: 1)
      try Chat(id: 1_000, date: date, type: .thread, title: "Thread", spaceId: nil).insert(db)
      for id in [Int64(901), 902, 903] {
        try ChatParticipant(chatId: 1_000, userId: id, date: date).insert(db)
      }
      return try (
        BotVisibility.fetch(db, viewerUserId: Self.me),
        MentionCandidatesSource.roster(db, scope: .chat(chatId: 1_000, peer: .thread(id: 1_000)), currentUserId: Self.me)
      )
    }
    #expect(visibility == .none)
    #expect(Set(roster.candidates.users.map(\.userInfo.id)).isSuperset(of: [901, 902, 903]))

    let store = AgentGrantStore(database: database, auth: Self.makeAuth(), realtime: { AccessRealtime(answers: []) })
    var bot = User(id: 902, email: nil, firstName: "Private")
    bot.bot = true
    #expect(store.offers(bot))
  }

  @Test("a bot that wrote to someone lately keeps its composer and is offered nowhere")
  func invitedReply() async throws {
    let database = AppDatabase.empty()
    let visibility = try await database.dbWriter.write { db in
      try Self.seed(db)
      try BotAccess.set(db, BotAccess(botUserId: 902, canMessage: false, canReply: true, operations: []))
      return try BotVisibility.fetch(db, viewerUserId: Self.me)
    }
    #expect(visibility.notOffered.contains(902))
    #expect(!visibility.unreachable.contains(902))

    let store = AgentGrantStore(database: database, auth: Self.makeAuth(), realtime: { AccessRealtime(answers: []) })
    #expect(!store.isUnreachable(botUserID: 902))
    var bot = User(id: 902, email: nil, firstName: "Claude")
    bot.bot = true
    #expect(BotNoAccessNotice.make(bot: bot, access: store.access(botUserID: 902), owner: nil) == nil)
    #expect(!store.offers(bot))
  }

  @Test("a message from a bot whose chat had no composer asks the server again")
  func incomingMessageRefreshes() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }
    let realtime = AccessRealtime(answers: [
      .with { $0.botUserID = 902; $0.ownerUserID = Self.owner; $0.canReply = true },
    ])
    let store = AgentGrantStore(database: database, auth: Self.makeAuth(), realtime: { realtime })
    #expect(store.isUnreachable(botUserID: 902))

    // A person, and a bot the viewer can already reach, cost nothing.
    store.noteIncomingDirectMessage(fromUserID: 905)
    store.noteIncomingDirectMessage(fromUserID: 901)
    store.noteIncomingDirectMessage(fromUserID: 902)
    try await waitUntil { await MainActor.run { !store.isUnreachable(botUserID: 902) } }
    #expect(await realtime.asked == [[902]])
  }

  @Test("the operations bitmask round-trips and ignores what it can't name")
  func operationsMask() {
    let record = BotAccess(botUserId: 1, canMessage: true, operations: [.invoke, .configure, .unspecified])
    #expect(record.grantOperations == [.invoke, .configure])
    #expect(BotAccess.operations(mask: 1 << 40) == [])
  }

  @Test("mention menus leave out bots the viewer can't reach, wherever they come from")
  func mentionRoster() async throws {
    let database = AppDatabase.empty()
    let (thread, dm) = try await database.dbWriter.write { db in
      try Self.seed(db)
      let date = Date(timeIntervalSince1970: 1)
      try Chat(id: 1_000, date: date, type: .thread, title: "Thread", spaceId: nil).insert(db)
      for id in [Int64(901), 902, 903, 904, 905] {
        try ChatParticipant(chatId: 1_000, userId: id, date: date).insert(db)
      }
      // A DM with the private bot from before it was private.
      try Chat(id: 1_001, date: date, type: .privateChat, title: nil, spaceId: nil, peerUserId: 902, lastMsgId: nil)
        .insert(db)
      return try (
        MentionCandidatesSource.roster(db, scope: .chat(chatId: 1_000, peer: .thread(id: 1_000)), currentUserId: Self.me),
        MentionCandidatesSource.roster(db, scope: .chat(chatId: 1_001, peer: .user(id: 902)), currentUserId: Self.me)
      )
    }
    #expect(Set(thread.candidates.users.map(\.userInfo.id)) == [901, 904, 905])
    #expect(!dm.candidates.users.contains { $0.userInfo.id == 902 })
  }

  @Test("Cmd+K offers reachable bots as people and drops chats with bots known to be unreachable")
  func commandBarCatalog() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      try Self.seed(db)
      let date = Date(timeIntervalSince1970: 1)
      for (chatId, peer) in [(Int64(2_001), Int64(901)), (2_002, 902), (2_003, 903)] {
        try Chat(id: chatId, date: date, type: .privateChat, title: nil, spaceId: nil, peerUserId: peer, lastMsgId: nil)
          .insert(db)
        var dialog = Dialog.previewDm
        dialog.id = Dialog.getDialogId(peerUserId: peer)
        dialog.peerUserId = peer
        dialog.chatId = chatId
        dialog.open = true
        try dialog.insert(db)
      }
    }
    let snapshot = try await database.fetchCommandBarCatalogSnapshot(viewerUserId: Self.me)
    #expect(Set(snapshot.knownUsers.map(\.id)) == [901, 904, 905])
    // The unasked bot's chat stays until the server answers; the private one goes.
    #expect(Set(snapshot.chats.map(\.peerId)) == [.user(id: 901), .user(id: 903)])
  }

  @Test("stored answers are there on the first read after launch")
  func hydratesFromDatabase() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }
    let store = AgentGrantStore(
      database: database, auth: Self.makeAuth(), realtime: { AccessRealtime(answers: []) }
    )
    #expect(store.access(botUserID: 901)?.canMessage == true)
    #expect(store.access(botUserID: 901)?.operations == [.invoke])
    #expect(store.isUnreachable(botUserID: 902))
    #expect(store.access(botUserID: 902)?.ownerUserID == Self.owner)
    // Never asked: no answer, so nothing is taken away.
    #expect(store.access(botUserID: 903) == nil)
    #expect(!store.isUnreachable(botUserID: 903))
  }

  @Test("resolving stores the server's answers, and treats bots it leaves out as unreachable")
  func resolveStoresAnswers() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }
    let realtime = AccessRealtime(answers: [
      Self.answer(901, canMessage: false),
      Self.answer(902, canMessage: true),
      Self.answer(904, canMessage: true, isOwner: true),
    ])
    let store = AgentGrantStore(database: database, auth: Self.makeAuth(), realtime: { realtime })

    #expect(await store.resolveAccess(botUserIDs: [901, 902, 903, 904]))
    #expect(store.isUnreachable(botUserID: 901))
    #expect(store.access(botUserID: 902)?.canMessage == true)
    #expect(store.isUnreachable(botUserID: 903))
    #expect(store.access(botUserID: 904)?.isOwner == true)
    try await waitUntil { try await stored(database) == [901: false, 902: true, 903: false, 904: true] }
  }

  @Test("a failed lookup changes nothing: offline never turns into no access")
  func failedResolveKeepsStoredAnswers() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }
    let realtime = AccessRealtime(answers: [], fails: true)
    let store = AgentGrantStore(database: database, auth: Self.makeAuth(), realtime: { realtime })

    #expect(await !store.resolveAccess(botUserIDs: [901, 903]))
    #expect(store.access(botUserID: 901)?.canMessage == true)
    #expect(store.access(botUserID: 903) == nil)
    #expect(try await stored(database) == [901: true, 902: false])
  }

  @Test("a bot saved for the first time is asked about without anyone opening it")
  func asksAboutNewBots() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }
    let realtime = AccessRealtime(answers: [
      Self.answer(901, canMessage: true, operations: [.invoke]),
      Self.answer(902, canMessage: false),
      Self.answer(903, canMessage: true),
      Self.answer(904, canMessage: true, isOwner: true),
      Self.answer(906, canMessage: false),
    ])
    let store = AgentGrantStore(database: database, auth: Self.makeAuth(), realtime: { realtime })
    store.start()
    try await waitUntil { try await stored(database)[903] == true }

    try await database.dbWriter.write { db in
      var user = User(id: 906, email: nil, firstName: "New")
      user.bot = true
      try user.insert(db)
    }
    try await waitUntil { try await stored(database)[906] == false }
    #expect(store.isUnreachable(botUserID: 906))
    store.removeAll()
  }

  @Test("a listing never overrides the resolved answer for someone who isn't the owner")
  func listingKeepsResolvedAccess() async throws {
    let realtime = AccessRealtime(answers: [Self.answer(901, canMessage: true, operations: [.invoke])])
    let store = AgentGrantStore(database: nil, auth: Self.makeAuth(), realtime: { realtime })
    #expect(await store.resolveAccess(botUserIDs: [901]))

    // The viewer's access comes from a space, so their own entry isn't listed.
    store.apply(
      InlineProtocol.ListAgentGrantsResult.with { $0.ownerUserID = Self.owner; $0.revision = 9 },
      botUserID: 901,
      viewerUserID: Self.me
    )
    #expect(store.access(botUserID: 901)?.operations == [.invoke])
    #expect(store.access(botUserID: 901)?.canMessage == true)
  }

  @Test("an owner's list keeps people, spaces and groups apart")
  func subjects() {
    let list = InlineProtocol.ListAgentGrantsResult.with {
      $0.ownerUserID = Self.me
      $0.revision = 5
      $0.grants = [
        .with { $0.botUserID = 904; $0.userID = 905; $0.operations = [.invoke]; $0.revision = 1 },
        .with {
          $0.botUserID = 904; $0.operations = [.invoke]; $0.revision = 2
          $0.subject = .with { $0.spaceID = 30 }
        },
        .with {
          $0.botUserID = 904; $0.operations = [.invoke]; $0.revision = 3
          $0.subject = .with { $0.groupID = 40 }
        },
      ]
    }
    var owned = OwnedAgentGrants(list, botUserID: 904)
    #expect(owned.userIDs == [905])
    #expect(owned.spaceIDs == [30])
    #expect(owned.groupIDs == [40])
    #expect(owned.sharedWithSummary(openToEveryone: false, spaceNames: ["Acme"]) == "Acme, 1 group, and 1 person")
    #expect(owned.sharedWithSummary(openToEveryone: true) == "Everyone")

    let removed = owned.apply(subject: .space(30), operations: [], revision: 6)
    #expect(removed)
    #expect(owned.spaceIDs.isEmpty)
    #expect(OwnedAgentGrants(.with { $0.ownerUserID = Self.me }, botUserID: 904)
      .sharedWithSummary(openToEveryone: false) == "Only you")
  }

  @Test("an admin gets the whole list and a role is a change of operations")
  func admins() {
    let store = AgentGrantStore(database: nil, auth: Self.makeAuth(), realtime: { AccessRealtime(answers: []) })
    let list = InlineProtocol.ListAgentGrantsResult.with {
      $0.ownerUserID = Self.owner
      $0.revision = 4
      $0.grants = [
        .with { $0.botUserID = 902; $0.userID = Self.me; $0.operations = [.invoke, .steer, .configure]; $0.revision = 1 },
        .with { $0.botUserID = 902; $0.userID = 905; $0.operations = [.invoke, .steer, .approve]; $0.revision = 2 },
      ]
    }
    store.apply(list, botUserID: 902, viewerUserID: Self.me)

    // The viewer doesn't own the bot, but manages it.
    let access = try? #require(store.access(botUserID: 902))
    #expect(access?.isOwner == false)
    #expect(access?.canManage == true)
    let owned = try? #require(store.ownedGrants(botUserID: 902))
    #expect(owned?.adminUserIDs == [Self.me])
    #expect(owned?.role(userID: 905) == .member)
    #expect(owned?.role(userID: 999) == nil)
    // Becoming an admin keeps what the role doesn't cover; going back drops only the role.
    #expect(owned?.operations(for: .admin, userID: 905) == [.invoke, .steer, .configure, .approve])
    #expect(owned?.operations(for: .member, userID: Self.me) == [.invoke, .steer])

    // Someone who only uses the bot sees their own entry and no list.
    let plain = InlineProtocol.ListAgentGrantsResult.with {
      $0.ownerUserID = Self.owner
      $0.grants = [.with { $0.botUserID = 901; $0.userID = Self.me; $0.operations = [.invoke] }]
    }
    store.apply(plain, botUserID: 901, viewerUserID: Self.me)
    #expect(store.ownedGrants(botUserID: 901) == nil)
    #expect(store.access(botUserID: 901)?.canManage == false)
  }

  @Test("listing with managed bots keeps each bot with its real owner")
  func managedBotsKeepTheirOwner() async throws {
    let database = AppDatabase.empty()
    func bot(_ id: Int64, owner: Int64) -> InlineProtocol.User {
      .with {
        $0.id = id
        $0.firstName = "Bot \(id)"
        $0.bot = true
        $0.botInfo = .with { $0.ownerUserID = owner }
      }
    }
    let mine = bot(910, owner: Self.me)
    let managed = bot(911, owner: Self.owner)
    #expect(mine.isOwned(by: Self.me))
    #expect(!managed.isOwned(by: Self.me))

    let owners = try await database.dbWriter.write { db in
      try ListBotsTransaction.saveOwnedBots([mine, managed], ownerUserId: Self.me, in: db)
      return try (
        BotOwner.ownedBotIds(db, ownerUserId: Self.me),
        BotOwner.ownedBotIds(db, ownerUserId: Self.owner)
      )
    }
    #expect(owners.0 == [910])
    #expect(owners.1 == [911])
  }

  @Test("the notice names the owner when known and exists only for a known no")
  func noAccessNotice() {
    var bot = User(id: 902, email: nil, firstName: "Claude")
    bot.bot = true
    let owner = User(id: Self.owner, email: nil, firstName: "Mo")
    func access(_ canMessage: Bool?, ownerUserID: Int64 = Self.owner) -> AgentGrantAccess {
      .init(botUserID: 902, ownerUserID: ownerUserID, viewerUserID: Self.me, operations: [], revision: 0,
            canMessage: canMessage)
    }

    let named = BotNoAccessNotice.make(bot: bot, access: access(false), owner: owner)
    #expect(named?.text == "Mo hasn’t shared Claude with you")
    #expect(named?.actionTitle == "Message Mo")
    #expect(named?.ownerUserID == Self.owner)

    let unnamed = BotNoAccessNotice.make(bot: bot, access: access(false), owner: nil)
    #expect(unnamed?.text == "Claude hasn’t been shared with you")
    #expect(unnamed?.actionTitle == nil)

    #expect(BotNoAccessNotice.make(bot: bot, access: access(true), owner: owner) == nil)
    #expect(BotNoAccessNotice.make(bot: bot, access: access(nil), owner: owner) == nil)
    #expect(BotNoAccessNotice.make(bot: bot, access: nil, owner: owner) == nil)
    #expect(BotNoAccessNotice.make(bot: owner, access: access(false), owner: owner) == nil)
    // Open to everyone, no grant: words for the access row.
    #expect(access(true).viewerAccessSummary == "Can message")
    #expect(access(false).viewerAccessSummary == "No access")
  }
}
