import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

private final class AttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func next() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
}

private final class KeyLog: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [MentionRosterRefresher.Key] = []

  var keys: [MentionRosterRefresher.Key] {
    lock.withLock { entries }
  }

  var count: Int {
    keys.count
  }

  func append(_ key: MentionRosterRefresher.Key) {
    lock.withLock { entries.append(key) }
  }
}

private final class PostedCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}

@MainActor
@Suite("Mention candidate sources")
struct MentionCompletionCandidatesTests {
  private nonisolated static let me: Int64 = 1

  private nonisolated func roster(
    _ db: Database,
    _ scope: MentionCandidatesSource.Scope
  ) throws -> MentionCompletionCandidates {
    try MentionCandidatesSource.roster(db, scope: scope, currentUserId: Self.me).candidates
  }

  @Test("Home and space projections carry DM recency and pins without changing eligibility")
  func newThreadProjections() async throws {
    let database = AppDatabase.empty()
    let (home, space) = try await database.dbWriter.write { db in
      try Self.seed(db)
      return try (roster(db, .newThread(spaceId: nil)), roster(db, .newThread(spaceId: 900)))
    }

    #expect(Set(home.users.map(\.userInfo.id)) == [901, 902])
    #expect(home.users.allSatisfy { $0.source == .directChat })
    #expect(Set(space.users.map(\.userInfo.id)) == [901, 902, 903])
    let danny = try #require(space.users.first { $0.userInfo.id == 902 })
    #expect(danny.source == .spaceMember)
    #expect(danny.isPinned)
    #expect(danny.lastDirectMessageDate == Date(timeIntervalSince1970: 10))
    // An optimistic pinned DM without history boosts an already-eligible member,
    // but does not make them a new Home candidate.
    #expect(space.users.first { $0.userInfo.id == 903 }?.isPinned == true)

    let ranker = MentionCompletionViewModel(currentUserId: { Self.me })
    for candidates in [home, space] {
      ranker.updateCandidates(candidates)
      ranker.filter(with: "dan")
      #expect(ranker.items.map(\.id) == ["user:902", "user:901"])
    }
  }

  @Test(
    "existing Home and private/public space threads rank people in the chat first",
    arguments: [nil, false, true] as [Bool?]
  )
  func existingThreadProjections(isPublic: Bool?) async throws {
    let database = AppDatabase.empty()
    let candidates = try await database.dbWriter.write { db in
      try Self.seed(db)
      let date = Date(timeIntervalSince1970: 1)
      try Chat(
        id: 1_000, date: date, type: .thread, title: "Thread",
        spaceId: isPublic == nil ? nil : 900, isPublic: isPublic
      ).insert(db)
      try ChatParticipant(chatId: 1_000, userId: 901, date: date).insert(db)
      return try roster(db, .chat(chatId: 1_000, peer: .thread(id: 1_000)))
    }

    let ranker = MentionCompletionViewModel(currentUserId: { Self.me })
    ranker.updateCandidates(candidates)
    ranker.filter(with: "dan")
    let daniel = try #require(candidates.users.first { $0.userInfo.id == 901 })
    #expect(daniel.source == .participant)
    if isPublic == true {
      // Every member can read a public thread, so pinned Danny leads its members.
      #expect(ranker.items.map(\.id) == ["user:902", "user:901"])
    } else {
      // Pinned Danny isn't in the thread, so the participant wins.
      #expect(ranker.items.map(\.id) == ["user:901", "user:902"])
    }
  }

  @Test("existing DMs keep the peer first and still hide other DMs at bare at")
  func existingDirectChatProjection() async throws {
    let database = AppDatabase.empty()
    let candidates = try await database.dbWriter.write { db in
      try Self.seed(db)
      return try roster(db, .chat(chatId: 912, peer: .user(id: 902)))
    }
    let ranker = MentionCompletionViewModel(currentUserId: { Self.me })
    ranker.updateCandidates(candidates)
    #expect(ranker.items.map(\.id) == ["user:902"])
    ranker.filter(with: "dan")
    #expect(ranker.items.map(\.id) == ["user:902", "user:901"])
  }

  @Test("a fresh owned bot with an empty DM is offered everywhere, before any chat")
  func ownedBotWithoutHistory() async throws {
    let database = AppDatabase.empty()
    let (home, space, thread, otherUser) = try await database.dbWriter.write { db in
      try Self.seed(db)
      try Self.joinSpace(as: .admin, in: db)
      try Self.makeOwnedBot(904, owner: Self.me, in: db)
      return try (
        roster(db, .newThread(spaceId: nil)),
        roster(db, .newThread(spaceId: 900)),
        roster(db, .chat(chatId: 912, peer: .user(id: 902))),
        MentionCandidatesSource.roster(db, scope: .newThread(spaceId: nil), currentUserId: 2).candidates
      )
    }

    let ranker = MentionCompletionViewModel(currentUserId: { Self.me })
    for candidates in [home, space, thread] {
      let bot = try #require(candidates.users.first { $0.userInfo.id == 904 })
      #expect(bot.source == .ownedBot)
      ranker.updateCandidates(candidates)
      #expect(ranker.items.contains { $0.id == "user:904" })
      ranker.filter(with: "no h")
      #expect(ranker.items.map(\.id) == ["user:904"])
      ranker.filter(with: "")
    }
    // Someone else's bot stays theirs.
    #expect(!otherUser.users.contains { $0.userInfo.id == 904 })
  }

  @Test(
    "a space offers the user's bots outside it only to people who can add members",
    arguments: [nil, MemberRole.member, .admin] as [MemberRole?]
  )
  func ownedBotInSpaceChat(role: MemberRole?) async throws {
    let database = AppDatabase.empty()
    let (thread, newThread, afterJoining) = try await database.dbWriter.write { db in
      try Self.seed(db)
      if let role { try Self.joinSpace(as: role, in: db) }
      try Self.makeOwnedBot(904, owner: Self.me, in: db)
      try Chat(id: 1_001, date: Date(), type: .thread, title: "Space Thread", spaceId: 900).insert(db)
      let scope = MentionCandidatesSource.Scope.chat(chatId: 1_001, peer: .thread(id: 1_001))
      let thread = try roster(db, scope)
      let newThread = try roster(db, .newThread(spaceId: 900))
      try Member(id: 990, date: Date(), userId: 904, spaceId: 900, role: .member).insert(db)
      return try (thread, newThread, roster(db, scope))
    }
    let offered = role == .admin
    #expect(thread.users.contains { $0.userInfo.id == 904 } == offered)
    #expect(newThread.users.contains { $0.userInfo.id == 904 } == offered)
    // Once the bot is a member, anyone can add it to a thread.
    #expect(afterJoining.users.first { $0.userInfo.id == 904 }?.source == .ownedBot)
  }

  @Test("mentioning the user's bot outside the space asks it to join, with public access only in public threads")
  func ownedBotAdmissionNeed() async throws {
    let database = AppDatabase.empty()
    let (privateNeed, publicNeed, childNeed, memberNeed, otherBots) = try await database.dbWriter.write { db in
      try Self.seed(db)
      try Self.joinSpace(as: .member, in: db)
      try Self.makeOwnedBot(904, owner: Self.me, in: db)
      try User(id: 905, email: nil, firstName: "Not Mine").insert(db)
      try Self.makeOwnedBot(905, owner: 2, in: db)
      let date = Date()
      let privateThread = Chat(id: 1_001, date: date, type: .thread, title: "Private", spaceId: 900, isPublic: false)
      let publicThread = Chat(id: 1_002, date: date, type: .thread, title: "Public", spaceId: 900, isPublic: true)
      var child = Chat(id: 1_003, date: date, type: .thread, title: "Child", spaceId: 900, isPublic: true)
      child.parentChatId = 1_002
      for chat in [privateThread, publicThread, child] { try chat.insert(db) }
      func need(_ chat: InlineKit.Chat, _ ids: Set<Int64> = [904, 901]) throws -> OwnedBotSpaceAdmission.Need? {
        try OwnedBotSpaceAdmission.need(db, chat: chat, mentionedUserIds: ids, currentUserId: Self.me)
      }
      let privateNeed = try need(privateThread)
      let publicNeed = try need(publicThread)
      let childNeed = try need(child)
      let otherBots = try need(privateThread, [905])
      try Member(id: 990, date: date, userId: 904, spaceId: 900, role: .member).insert(db)
      return try (privateNeed, publicNeed, childNeed, need(privateThread), otherBots)
    }
    let need = try #require(privateNeed)
    #expect(need.botIds == [904])
    #expect(need.spaceName == "Space")
    #expect(!need.grantsPublicAccess)
    #expect(!need.canAddMembers)
    #expect(publicNeed?.grantsPublicAccess == true)
    // A subthread of a public thread grants access on the child, not the space's public threads.
    #expect(childNeed?.grantsPublicAccess == false)
    #expect(memberNeed == nil)
    #expect(otherBots == nil)
  }

  @Test("recent senders in the chat are ranked by who spoke last")
  func recentSenders() async throws {
    let database = AppDatabase.empty()
    let candidates = try await database.dbWriter.write { db in
      try Self.seed(db)
      let date = Date(timeIntervalSince1970: 1)
      try Chat(id: 1_000, date: date, type: .thread, title: "Thread", spaceId: 900).insert(db)
      for userId in [Int64(901), 902, 903] {
        try ChatParticipant(chatId: 1_000, userId: userId, date: date).insert(db)
      }
      for (messageId, fromId) in [(Int64(1), Int64(903)), (2, 901), (3, 903)] {
        try Message(
          messageId: messageId, fromId: fromId, date: date, text: "Hi",
          peerUserId: nil, peerThreadId: 1_000, chatId: 1_000
        ).insert(db)
      }
      return try roster(db, .chat(chatId: 1_000, peer: .thread(id: 1_000)))
    }
    let ranks = Dictionary(uniqueKeysWithValues: candidates.users.map { ($0.userInfo.id, $0.recentSenderRank) })
    #expect(ranks[903] == 0)
    #expect(ranks[901] == 1)
    #expect(ranks[902] == .some(nil))

    let ranker = MentionCompletionViewModel(currentUserId: { Self.me })
    ranker.updateCandidates(candidates)
    #expect(ranker.items.prefix(3).map(\.id) == ["user:903", "user:901", "user:902"])
  }

  @Test("listing bots saves their owner and drops bots no longer listed")
  func listingSavesOwnedBots() async throws {
    let database = AppDatabase.empty()
    let owned = try await database.dbWriter.write { db in
      try Self.seed(db)
      try User(id: 905, email: nil, firstName: "Deleted Elsewhere").insert(db)
      try Self.makeOwnedBot(905, owner: Self.me, in: db)
      var bot = InlineProtocol.User()
      bot.id = 904
      bot.firstName = "No History"
      bot.bot = true
      try ListBotsTransaction.saveOwnedBots([bot], ownerUserId: Self.me, in: db)
      return try BotOwner.ownedBotIds(db, ownerUserId: Self.me).sorted()
    }
    #expect(owned == [904])
  }

  @Test("a protocol user keeps its bot owner across saves that omit it")
  func botOwnerSurvivesPartialSaves() async throws {
    let database = AppDatabase.empty()
    let owner = try await database.dbWriter.write { db in
      var bot = InlineProtocol.User()
      bot.id = 906
      bot.firstName = "Claude"
      bot.bot = true
      bot.botInfo = .with { $0.owner = .ownerUserID(Self.me) }
      _ = try User.save(db, user: bot)

      var min = InlineProtocol.User()
      min.id = 906
      min.firstName = "Claude 2"
      min.min = true
      _ = try User.save(db, user: min)
      return try BotOwner.fetchOne(db, key: 906)?.ownerUserId
    }
    #expect(owner == Self.me)
  }

  @Test("sending only adds the user's own bots that aren't members yet")
  func botsToAddToSpace() {
    #expect(OwnedBotSpaceAdmission.botsToAdd(
      requested: [1, 2, 3, 4],
      ownedBots: [2, 3, 5],
      members: [1, 3]
    ) == [2])
    #expect(OwnedBotSpaceAdmission.botsToAdd(requested: [7], ownedBots: [], members: []).isEmpty)
  }

  @Test("an owned bot with DM history stays unique and keeps its chat priority")
  func ownedBotWithHistory() throws {
    let bot = UserInfo(user: User(id: 950, email: nil, firstName: "Claude"))
    let date = Date(timeIntervalSince1970: 30)
    let candidates = MentionCompletionCandidates(
      users: [MentionCompletionUser(userInfo: bot, source: .directChat, lastDirectMessageDate: date, isPinned: true)],
      groups: []
    ).addingOwnedBots([bot])
    #expect(candidates.users.count == 1)
    let user = try #require(candidates.users.first)
    #expect(user.source == .ownedBot)
    #expect(user.lastDirectMessageDate == date)
    #expect(user.isPinned)
  }

  @Test("creating or deleting a bot asks mention sources to reload")
  func botTransactionsPostChange() async throws {
    let botId: Int64 = 951_001
    let posted = PostedCount()
    let observer = NotificationCenter.default.addObserver(
      forName: .botAgentsChanged,
      object: nil,
      queue: nil
    ) { note in
      if note.object as? Int64 == botId { posted.increment() }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    try await CreateBotTransaction(name: "Claude", username: "claude_bot").apply(
      .createBot(.with { $0.bot = .with { $0.id = botId } })
    )
    #expect(posted.value == 1)
    try await DeleteBotTransaction(botUserId: botId).apply(.deleteBot(.init()))
    #expect(posted.value == 2)
  }

  @Test("the source follows pin and DM changes and observes only during a session")
  func liveSourceUpdates() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }
    let source = MentionCandidatesSource(
      db: database,
      scope: .newThread(spaceId: 900),
      services: .offline,
      currentUserId: { Self.me }
    )
    source.beginSession()
    // The first session reads synchronously for the menu's first frame.
    #expect(source.candidates.users.contains { $0.userInfo.id == 902 })

    let ranker = MentionCompletionViewModel(currentUserId: { Self.me })
    ranker.updateCandidates(source.candidates)
    ranker.filter(with: "dan")
    #expect(ranker.items.first?.id == "user:902")

    try await database.dbWriter.write { db in
      _ = try Dialog.filter(Dialog.Columns.peerUserId == 902)
        .updateAll(db, Dialog.Columns.pinned.set(to: false))
    }
    try await waitFor { source.candidates.users.first { $0.userInfo.id == 902 }?.isPinned == false }
    ranker.updateCandidates(source.candidates)
    // Daniel's DM is newer once pins are equal.
    #expect(ranker.items.first?.id == "user:901")
    #expect(ranker.selectedItem?.id == "user:902")

    try await database.dbWriter.write { db in
      try Message(
        messageId: 11, fromId: 902, date: Date(timeIntervalSince1970: 500),
        text: "New message", peerUserId: 902, peerThreadId: nil, chatId: 912
      ).insert(db)
      _ = try Chat.filter(Chat.Columns.id == 912)
        .updateAll(db, Chat.Columns.lastMsgId.set(to: 11))
    }
    try await waitFor {
      source.candidates.users.first { $0.userInfo.id == 902 }?.lastDirectMessageDate ==
        Date(timeIntervalSince1970: 500)
    }
    ranker.updateCandidates(source.candidates)
    #expect(ranker.items.first?.id == "user:902")

    // Ending the session stops observing but keeps the last candidates.
    source.endSession()
    try await database.dbWriter.write { db in
      try Member(id: 990, date: Date(), userId: 904, spaceId: 900).insert(db)
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!source.candidates.users.contains { $0.userInfo.id == 904 })
    source.beginSession()
    try await waitFor { source.candidates.users.contains { $0.userInfo.id == 904 } }
  }

  @Test("a failed owned-bot refresh keeps the bots and Agents already shown")
  func ownedBotsSurviveFailedRefresh() async throws {
    let attempts = AttemptCounter()
    var now = Date(timeIntervalSince1970: 1_000)
    let bot = UserInfo(user: User(id: 904, email: nil, firstName: "No History"))
    var profile = BotAgentProfile()
    profile.id = 70
    profile.botUserID = 904
    profile.name = "Researcher"
    let agent = MentionableBotAgent(profile: profile, botUserInfo: bot)
    let directory = OwnedBotsDirectory(
      fetcher: {
        if attempts.next() == 1 {
          return OwnedBotsDirectory.Listing(bots: [bot], agentsByBotId: [904: .some([agent])])
        }
        throw CancellationError()
      },
      now: { now },
      freshness: 60,
      retryDelay: 10
    )
    await directory.refreshIfNeeded()
    #expect(directory.snapshot.agents.map(\.id) == [70])

    await directory.refreshIfNeeded()
    #expect(attempts.value == 1)

    now.addTimeInterval(61)
    await directory.refreshIfNeeded()
    #expect(attempts.value == 2)
    #expect(directory.snapshot.bots.map(\.id) == [904])
    #expect(directory.snapshot.agents.map(\.id) == [70])

    // A failure waits out its retry delay instead of refetching every session.
    await directory.refreshIfNeeded()
    #expect(attempts.value == 2)
  }

  @Test("roster refreshes are throttled per key, and failures retry later")
  func rosterRefreshThrottle() async throws {
    let log = KeyLog()
    var now = Date(timeIntervalSince1970: 1_000)
    let refresher = MentionRosterRefresher(
      fetcher: { key in
        log.append(key)
        if key == .userGroups(900) { throw CancellationError() }
      },
      now: { now },
      freshness: 300,
      retryDelay: 15
    )
    let keys: [MentionRosterRefresher.Key] = [.chatParticipants(1), .spaceMembers(900), .userGroups(900)]
    await refresher.refresh(keys)
    #expect(log.count == 3)
    await refresher.refresh(keys)
    #expect(log.count == 3)
    now.addTimeInterval(16)
    await refresher.refresh(keys)
    #expect(log.count == 4)
    #expect(log.keys.last == .userGroups(900))
    await refresher.refresh(keys, force: true)
    #expect(log.count == 7)
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "Candidate observation did not refresh")
  }

  private nonisolated static func joinSpace(as role: MemberRole, in db: Database) throws {
    try User(id: me, email: nil, firstName: "Me").insert(db)
    try Member(id: me, date: Date(), userId: me, spaceId: 900, role: role).insert(db)
  }

  private nonisolated static func makeOwnedBot(_ id: Int64, owner: Int64, in db: Database) throws {
    guard var user = try User.fetchOne(db, id: id) else { return }
    user.bot = true
    try user.save(db)
    try BotOwner(botUserId: id, ownerUserId: owner).save(db)
  }

  private nonisolated static func seed(_ db: Database) throws {
    let date = Date(timeIntervalSince1970: 1)
    try Space(id: 900, name: "Space", date: date).insert(db)
    for (id, name) in [(Int64(901), "Daniel"), (902, "Danny"), (903, "Zoe"), (904, "No History")] {
      try User(id: id, email: nil, firstName: name).insert(db)
      if id != 904 {
        try Member(id: id, date: date, userId: id, spaceId: 900).insert(db)
      }
    }
    try Chat(
      id: 911,
      date: date,
      type: .privateChat,
      title: nil,
      spaceId: nil,
      peerUserId: 901,
      lastMsgId: 200
    ).insert(db)
    try Chat(
      id: 912,
      date: date,
      type: .privateChat,
      title: nil,
      spaceId: nil,
      peerUserId: 902,
      lastMsgId: 10
    ).insert(db)
    try Chat(
      id: 914,
      date: date,
      type: .privateChat,
      title: nil,
      spaceId: nil,
      peerUserId: 904,
      lastMsgId: nil
    ).insert(db)
    try Message(
      messageId: 200, fromId: 901, date: Date(timeIntervalSince1970: 200), text: "History",
      peerUserId: 901, peerThreadId: nil, chatId: 911
    ).insert(db)
    try Message(
      messageId: 10, fromId: 902, date: Date(timeIntervalSince1970: 10), text: "History",
      peerUserId: 902, peerThreadId: nil, chatId: 912
    ).insert(db)
    for userId in [Int64(902), 903, 904] {
      var dialog = Dialog(optimisticForUserId: userId)
      dialog.pinned = true
      try dialog.insert(db)
    }
  }
}
