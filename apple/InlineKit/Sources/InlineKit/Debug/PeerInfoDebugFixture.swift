#if DEBUG
import Foundation
import GRDB
import InlineProtocol

/// Debug builds only: chats of every kind chat info handles, seeded into the
/// in-memory database `--peerinfo-harness` selects, so the page can be shown
/// and captured without signing in or reaching the server.
public enum PeerInfoDebugFixture {
  public static var isRequested: Bool { CommandLine.arguments.contains("--peerinfo-harness") }

  public struct Case: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let peer: Peer
  }

  public static let me: Int64 = 1
  public static let spaceId: Int64 = 900

  public static let cases: [Case] = [
    Case(id: "person", title: "Teammate", peer: .user(id: 2)),
    Case(id: "external", title: "Outside your spaces", peer: .user(id: 3)),
    Case(id: "bot-owned", title: "Your bot", peer: .user(id: 10)),
    Case(id: "bot-shared", title: "Someone else’s bot", peer: .user(id: 11)),
    Case(id: "self", title: "Your own chat", peer: .user(id: me)),
    Case(id: "thread-private", title: "Private thread", peer: .thread(id: 501)),
    Case(id: "thread-public", title: "Public thread", peer: .thread(id: 502)),
    Case(id: "thread-home", title: "Home thread", peer: .thread(id: 503)),
    Case(id: "subthread", title: "Reply thread", peer: .thread(id: 504)),
  ]

  /// Seeds bot state the server would send: your bot (owned, shared with
  /// Sara, online on a MacBook Air) and Leo's bot (shared with you).
  @MainActor
  public static func seedAgents() {
    var owned = InlineProtocol.ListAgentGrantsResult()
    owned.ownerUserID = me
    owned.revision = 1
    owned.grants = [.with {
      $0.id = 1
      $0.botUserID = 10
      $0.userID = 2
      $0.operations = [.invoke, .steer]
      $0.revision = 1
    }]
    AgentGrantStore.shared.apply(owned, botUserID: 10, viewerUserID: me)

    var shared = InlineProtocol.ListAgentGrantsResult()
    shared.ownerUserID = 4
    shared.revision = 1
    shared.grants = [.with {
      $0.id = 2
      $0.botUserID = 11
      $0.userID = me
      $0.operations = [.invoke]
      $0.revision = 1
    }]
    AgentGrantStore.shared.apply(shared, botUserID: 11, viewerUserID: me)

    AgentWorkStateStore.shared.apply(runtime: .with {
      $0.botUserID = 10
      $0.provider = .claude
      $0.status = .online
      $0.machineLabel = "Mo’s MacBook Air"
      $0.executableVersion = "2.1.319"
      $0.bridgeVersion = "0.7.26-alpha.2"
      $0.defaultOutputMode = .detailed
    })
  }

  /// Seeds the database once. Safe to call again.
  public static func seed(_ database: AppDatabase = .shared) {
    try? database.dbWriter.write { db in
      guard try User.fetchOne(db, id: me) == nil else { return }
      let now = Date()

      func user(_ id: Int64, _ first: String, _ last: String?, username: String?, bio: String? = nil,
                email: String? = nil, timeZone: String? = nil, bot: Bool = false) throws
      {
        var user = User(id: id, email: email, firstName: first, lastName: last, username: username, bio: bio)
        user.timeZone = timeZone
        user.bot = bot
        if bot { user.online = id == 10 }
        try user.save(db)
      }

      try user(me, "Mo", "Rajabi", username: "mo", email: "mo@example.com")
      try user(2, "Sara", "Lin", username: "sara", bio: "Design and iOS. Usually around 9–6 Toronto time.",
               email: "sara@example.com", timeZone: "America/Vancouver")
      try user(3, "Alex", "Moreau", username: "alexm", timeZone: "Europe/Paris")
      try user(4, "Leo", "Park", username: "leo")
      try user(5, "Nadia", "Okafor", username: "nadia")
      try user(10, "Mo’s Claude · MacBook Air", nil, username: "mos_claude_mba_7f3",
               bio: "Works on the Inline repo from Mo’s laptop.", bot: true)
      try user(11, "Release Bot", nil, username: "release_bot", bio: "Ships TestFlight builds. Try /release.", bot: true)
      try UserFocus(userId: 2, focused: true, updatedAt: now).save(db)

      try Space(id: spaceId, name: "Noor", date: now).save(db)
      for (userId, role) in [(me, MemberRole.admin), (2, .admin), (4, .owner), (5, .member), (10, .member)] {
        try Member(id: Int64(1000 + userId), date: now, userId: userId, spaceId: spaceId, role: role).save(db)
      }

      func chat(_ chat: Chat, participants: [Int64]) throws {
        try chat.save(db)
        var dialog = Dialog(optimisticForChat: chat)
        dialog.open = true
        try dialog.save(db)
        for userId in participants {
          try ChatParticipant(chatId: chat.id, userId: userId, date: now).save(db)
        }
      }

      for (index, peerUserId) in [Int64(2), 3, 10, 11, me].enumerated() {
        try chat(
          Chat(id: Int64(400 + index), date: now, type: .privateChat, title: nil, spaceId: nil, peerUserId: peerUserId),
          participants: []
        )
      }
      try chat(
        Chat(id: 501, date: now.addingTimeInterval(-86_400), type: .thread, title: "design crit", spaceId: spaceId,
             emoji: "🌙", isPublic: false, createdBy: me),
        participants: [me, 2, 4, 5, 10]
      )
      try chat(
        Chat(id: 502, date: now.addingTimeInterval(-3_600), type: .thread, title: "eng", spaceId: spaceId,
             emoji: "🛠", isPublic: true, createdBy: 4),
        participants: []
      )
      try chat(
        Chat(id: 503, date: now.addingTimeInterval(-7_200), type: .thread, title: "Trip planning", spaceId: nil,
             emoji: "🏕", isPublic: false, createdBy: me),
        participants: [me, 5]
      )
      try chat(
        Chat(id: 504, date: now.addingTimeInterval(-600), type: .thread, title: "ship the download fix?", spaceId: spaceId,
             isPublic: false, createdBy: 2, parentChatId: 501, parentMessageId: 42),
        participants: [me, 2]
      )
    }
  }
}
#endif
