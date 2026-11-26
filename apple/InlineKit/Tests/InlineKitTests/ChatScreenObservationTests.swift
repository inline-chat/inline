import Combine
import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

/// Observations a chat screen keeps open re-read only for writes that can change what they show,
/// and notify their views only for real changes.
@Suite("Chat screen observations")
struct ChatScreenObservationTests {
  private static let date = Date(timeIntervalSince1970: 1_700_000_000)

  /// Space 1 with users 20...29. Thread 10 is private with participants 22, 20, 21 (inserted out
  /// of order); thread 11 is public, so its participants are space 1's members. User 21 has a
  /// profile photo.
  private static func seed(_ db: Database) throws {
    try Space(id: 1, name: "Space", date: date).insert(db)
    for userId in 20 ... 29 {
      try User(id: Int64(userId), email: nil, firstName: "User \(userId)").insert(db)
    }
    try db.execute(
      sql: "INSERT INTO file (id, fileType, uploading, profileForUserId) VALUES ('photo-21', 'photo', 0, 21)"
    )
    try Chat(id: 10, date: date, type: .thread, title: "Private", spaceId: 1, isPublic: false).insert(db)
    try Chat(id: 11, date: date, type: .thread, title: "Public", spaceId: 1, isPublic: true).insert(db)
    for userId: Int64 in [22, 20, 21] {
      try ChatParticipant(chatId: 10, userId: userId, date: date).insert(db)
    }
    // Member ids order these users differently from their user ids.
    for (memberId, userId): (Int64, Int64) in [(104, 21), (101, 25), (103, 22), (102, 23)] {
      try Member(id: memberId, date: date, userId: userId, spaceId: 1).insert(db)
    }
  }

  private static func setPresence(_ db: Database, userId: Int64, online: Bool) throws {
    try db.execute(
      sql: "UPDATE user SET online = ?, lastOnline = ? WHERE id = ?",
      arguments: [online, date.addingTimeInterval(60), userId]
    )
  }

  @Test("participants are the users the old joins returned, in the same order")
  func participantsMatchTheJoins() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      try Self.seed(db)

      // The queries this replaces.
      let joinedParticipants = try ChatParticipant
        .including(
          required: ChatParticipant.user
            .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
        )
        .filter(Column("chatId") == 10)
        .asRequest(of: UserInfo.self)
        .fetchAll(db)
      let joinedMembers = try Member
        .fullMemberQuery()
        .filter(Column("spaceId") == 1)
        .fetchAll(db)
        .map(\.userInfo)

      let privateThread = try ChatParticipantsWithMembersViewModel.participantsSnapshot(db, chatId: 10)
      let publicThread = try ChatParticipantsWithMembersViewModel.participantsSnapshot(db, chatId: 11)

      #expect(privateThread.participants == joinedParticipants)
      #expect(privateThread.participants.map(\.id) == [20, 21, 22])
      #expect(privateThread.participants.first { $0.id == 21 }?.profilePhoto?.map(\.id) == ["photo-21"])
      #expect(publicThread.participants == joinedMembers)
      #expect(publicThread.participants.map(\.id) == [25, 23, 22, 21])
    }
  }

  @Test("participants re-read only for their own users")
  @MainActor
  func participantsTrackTheirUsers() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }

    for chatId: Int64 in [10, 11] {
      // `AppDatabase.empty()` is a queue: an observation fetches inside the commit, so the count
      // is exact once the write returns.
      let fetches = Counter()
      let cancellable = ValueObservation
        .tracking { db in try ChatParticipantsWithMembersViewModel.participantsSnapshot(db, chatId: chatId) }
        .handleEvents(willFetch: { fetches.increment() })
        .start(in: database.dbWriter, scheduling: .immediate, onError: { _ in }, onChange: { _ in })
      #expect(fetches.value == 1)

      // User 29 is neither a participant nor a member.
      try await database.dbWriter.write { db in try Self.setPresence(db, userId: 29, online: true) }
      #expect(fetches.value == 1, "chat \(chatId)")

      try await database.dbWriter.write { db in try Self.setPresence(db, userId: 22, online: true) }
      #expect(fetches.value == 2, "chat \(chatId)")
      cancellable.cancel()
    }
  }

  @Test("the participants model notifies only for a change it shows")
  @MainActor
  func participantsModelNotifiesOnChange() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seed(db) }

    let model = ChatParticipantsWithMembersViewModel(db: database, chatId: 10)
    #expect(model.participants.map(\.id) == [20, 21, 22])
    var notifications = 0
    let cancellable = model.objectWillChange.sink { notifications += 1 }

    // A non-participant's presence, then a media file write (the photos prefetch tracks `file`).
    try await database.dbWriter.write { db in try Self.setPresence(db, userId: 29, online: true) }
    try await database.dbWriter.write { db in
      try db.execute(sql: "INSERT INTO file (id, fileType, uploading) VALUES ('media-1', 'photo', 0)")
    }
    // A participant's presence changes what the toolbar holds.
    try await database.dbWriter.write { db in try Self.setPresence(db, userId: 20, online: true) }
    try await waitUntil { model.participants.first?.user.online == true }

    // Deliveries are in order, so the earlier writes have been delivered by now. Only
    // `participants` changed.
    #expect(notifications == 1)
    cancellable.cancel()
  }

  @Test("an agent thread's toolbar notifies nothing for a new message in the thread")
  @MainActor
  func agentToolbarIgnoresNewMessages() throws {
    var context = InlineProtocol.AgentThreadContext()
    context.botUserID = 40
    let bot = User(id: 40, email: nil, firstName: "Agent")
    let chat = Chat(
      id: 50,
      date: Self.date,
      type: .thread,
      title: "Agent",
      spaceId: nil,
      lastMsgId: 1,
      agentContext: Chat.serializedAgentContext(context)
    )

    let model = AgentThreadToolbarModel(peer: .thread(id: 50))
    model.apply(.init(chat: chat, bot: bot))
    #expect(model.context == context)
    #expect(model.presentation?.name == "Agent")

    var notifications = 0
    let cancellable = model.objectWillChange.sink { notifications += 1 }
    for lastMsgId: Int64 in 2 ... 4 {
      var next = chat
      next.lastMsgId = lastMsgId
      model.apply(.init(chat: next, bot: bot))
    }
    let afterMessages = notifications

    var renamed = context
    renamed.agentID = 7
    var retargeted = chat
    retargeted.agentContext = Chat.serializedAgentContext(renamed)
    model.apply(.init(chat: retargeted, bot: bot))
    let retargetedContext = model.context
    cancellable.cancel()
    model.cancel()

    #expect(afterMessages == 0)
    // A different agent is a change it shows.
    #expect(notifications > 0)
    #expect(retargetedContext == renamed)
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
      guard Date() < deadline else {
        Issue.record("timed out")
        return
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
