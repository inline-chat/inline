import Foundation
import GRDB
@testable import InlineKit
import Testing

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
@Suite("Mention candidate chat priority")
struct MentionCompletionCandidatesTests {
  @Test("Home and space projections carry chat priority without changing eligibility")
  func newThreadProjections() async throws {
    let database = AppDatabase.empty()
    let (home, space) = try await database.dbWriter.write { db in
      try Self.seed(db)
      return try (
        ChatParticipantsWithMembersViewModel.newThreadMentionCandidates(db, spaceID: nil),
        ChatParticipantsWithMembersViewModel.newThreadMentionCandidates(db, spaceID: 900)
      )
    }

    #expect(Set(home.users.map(\.userInfo.id)) == [901, 902])
    #expect(home.users.allSatisfy { $0.source == .directChat })
    #expect(Set(space.users.map(\.userInfo.id)) == [901, 902, 903])
    #expect(space.users.count == 3)
    let danny = try #require(space.users.first { $0.userInfo.id == 902 })
    #expect(danny.source == .spaceMember)
    #expect(danny.isPinned)
    #expect(danny.lastMsgId == 10)
    // An optimistic pinned DM without history boosts an already-eligible member,
    // but does not make them a new Home candidate.
    #expect(space.users.first { $0.userInfo.id == 903 }?.isPinned == true)

    let ranker = MentionCompletionViewModel(currentUserId: { nil })
    for candidates in [home, space] {
      ranker.updateCandidates(candidates)
      ranker.filter(with: "dan")
      #expect(ranker.items.map(\.id) == ["user:902", "user:901"])
    }
  }

  @Test(
    "existing Home and private/public space threads retain participant source and chat signals",
    arguments: [nil, false, true] as [Bool?]
  )
  func existingThreadProjections(isPublic: Bool?) async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      try Self.seed(db)
      let date = Date(timeIntervalSince1970: 1)
      try Chat(
        id: 1_000, date: date, type: .thread, title: "Thread",
        spaceId: isPublic == nil ? nil : 900, isPublic: isPublic
      ).insert(db)
      try ChatParticipant(chatId: 1_000, userId: 902, date: date).insert(db)
    }

    let source = ChatParticipantsWithMembersViewModel(db: database, chatId: 1_000, purpose: .mentionCandidates)
    let ranker = MentionCompletionViewModel(currentUserId: { nil })
    ranker.updateCandidates(source.mentionCandidates)
    ranker.filter(with: "dan")
    #expect(ranker.items.map(\.id) == ["user:902", "user:901"])
    guard case let .user(danny) = ranker.items.first else {
      Issue.record("Expected Danny first")
      return
    }
    #expect(danny.source == .participant)
    #expect(danny.isPinned)
    #expect(danny.lastMsgId == 10)
  }

  @Test("existing DMs retain peer priority and still hide other DMs at bare at")
  func existingDirectChatProjection() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }
    let source = ChatParticipantsWithMembersViewModel(db: database, chatId: 912, purpose: .mentionCandidates)
    let ranker = MentionCompletionViewModel(currentUserId: { nil })
    ranker.updateCandidates(source.mentionCandidates)
    #expect(ranker.items.map(\.id) == ["user:902"])
    ranker.filter(with: "dan")
    #expect(ranker.items.map(\.id) == ["user:902", "user:901"])
  }

  @Test("an owned bot with an empty DM is listed at bare at and when searched")
  func ownedBotWithoutHistory() async throws {
    let database = AppDatabase.empty()
    let home = try await database.dbWriter.write { db in
      try Self.seed(db)
      return try ChatParticipantsWithMembersViewModel.newThreadMentionCandidates(db, spaceID: nil)
    }
    // 904 has an opened but empty DM, as a bot does right after setup.
    #expect(!home.users.contains { $0.userInfo.id == 904 })

    let bot = UserInfo(user: User(id: 904, email: nil, firstName: "No History"))
    let ranker = MentionCompletionViewModel(currentUserId: { nil })
    ranker.updateCandidates(home.addingOwnedBots([bot]))
    #expect(ranker.items.map(\.id) == ["user:904"])
    ranker.filter(with: "no h")
    #expect(ranker.items.map(\.id) == ["user:904"])
  }

  @Test("an owned bot with DM history stays unique and keeps its chat priority")
  func ownedBotWithHistory() throws {
    let bot = UserInfo(user: User(id: 950, email: nil, firstName: "Claude"))
    let candidates = MentionCompletionCandidates(
      users: [MentionCompletionUser(userInfo: bot, source: .directChat, lastMsgId: 30, isPinned: true)],
      groups: []
    ).addingOwnedBots([bot])
    #expect(candidates.users.count == 1)
    let user = try #require(candidates.users.first)
    #expect(user.source == .ownedBot)
    #expect(user.lastMsgId == 30)
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

  @Test("the existing observation refreshes pin and message signals")
  func liveChatPriorityUpdates() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }
    let source = NewThreadMentionCandidatesViewModel(db: database, spaceID: 900)
    source.startObserving()
    let ranker = MentionCompletionViewModel(currentUserId: { nil })
    ranker.updateCandidates(source.candidates)
    ranker.filter(with: "dan")
    #expect(ranker.items.first?.id == "user:902")

    try await database.dbWriter.write { db in
      _ = try Dialog.filter(Dialog.Columns.peerUserId == 902)
        .updateAll(db, Dialog.Columns.pinned.set(to: false))
    }
    try await waitFor { source.candidates.users.first { $0.userInfo.id == 902 }?.isPinned == false }
    ranker.updateCandidates(source.candidates)
    #expect(ranker.items.first?.id == "user:901")
    #expect(ranker.selectedItem?.id == "user:902")

    try await database.dbWriter.write { db in
      try Message(
        messageId: 300, fromId: 902, date: Date(timeIntervalSince1970: 2),
        text: "New message", peerUserId: 902, peerThreadId: nil, chatId: 912
      ).insert(db)
      _ = try Chat.filter(Chat.Columns.id == 912)
        .updateAll(db, Chat.Columns.lastMsgId.set(to: 300))
    }
    try await waitFor { source.candidates.users.first { $0.userInfo.id == 902 }?.lastMsgId == 300 }
    ranker.updateCandidates(source.candidates)
    #expect(ranker.items.first?.id == "user:902")
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "Candidate observation did not refresh")
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
      messageId: 200, fromId: 901, date: date, text: "History",
      peerUserId: 901, peerThreadId: nil, chatId: 911
    ).insert(db)
    try Message(
      messageId: 10, fromId: 902, date: date, text: "History",
      peerUserId: 902, peerThreadId: nil, chatId: 912
    ).insert(db)
    for userId in [Int64(902), 903, 904] {
      var dialog = Dialog(optimisticForUserId: userId)
      dialog.pinned = true
      try dialog.insert(db)
    }
  }
}
