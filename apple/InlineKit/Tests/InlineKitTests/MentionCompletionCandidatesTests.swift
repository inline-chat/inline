import Foundation
import GRDB
@testable import InlineKit
import Testing

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
