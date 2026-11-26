import Foundation
import GRDB
import Testing

@testable import InlineKit

/// `MessageBundleLoader` must return exactly what `FullMessage.queryRequest` returns, relations and their
/// order included, on a corpus that has every relation `FullMessage` reads.
@Suite("Message bundle loader parity")
struct MessageBundleLoaderParityTests {
  private static let currentUserId: Int64 = 1
  private static let spaceId: Int64 = 950
  private static let threadChats: [Int64] = [10_000, 10_001, 10_002]
  private static let dmChat: Int64 = 10_003
  private static let dmPeer: Int64 = 7

  @Test("pages and single messages match the association graph, field by field")
  func loaderMatchesAssociationGraph() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try Self.seedCorpus(db)
      try Self.seedRichRelations(db, chats: Self.threadChats + [Self.dmChat])
    }
    try Self.seedEdgeCases(database)

    var compared = 0
    var mismatches: [String] = []
    var expectedByKey: [String: FullMessage] = [:]
    try database.dbWriter.read { db in
      for chatId in Self.threadChats + [Self.dmChat] {
        let expected = try FullMessage.queryRequest(currentUserId: Self.currentUserId)
          .filter(Column("chatId") == chatId)
          .order(Column("messageId").desc)
          .limit(200)
          .fetchAll(db)
        let base = try Message.filter(Column("chatId") == chatId)
          .order(Column("messageId").desc)
          .limit(200)
          .fetchAll(db)
        let loaded = try MessageBundleLoader.load(db, messages: base, currentUserId: Self.currentUserId)
        let queried = try FullMessageQuery(currentUserId: Self.currentUserId)
          .filter(Column("chatId") == chatId)
          .order(Column("messageId").desc)
          .limit(200)
          .fetchAll(db)
        #expect(expected.count == loaded.count)
        #expect(expected.count == queried.count)
        for (index, value) in expected.enumerated() {
          expectedByKey["\(value.message.chatId):\(value.message.messageId)"] = value
          compared += 1
          let diff = Self.diff(value, loaded[index]) + Self.diff(value, queried[index]).map { "query." + $0 }
          if !diff.isEmpty {
            mismatches.append("chat \(chatId) message \(value.message.messageId): \(diff)")
          }
        }

        // Single-message reads, as message updates and the publisher read them.
        for message in base.prefix(40) {
          compared += 1
          let single = try FullMessage.queryRequest(currentUserId: Self.currentUserId)
            .filter(Column("chatId") == chatId && Column("messageId") == message.messageId)
            .fetchOne(db)
          let byKey = try MessageBundleLoader.fetchOne(
            db, chatId: chatId, messageId: message.messageId, currentUserId: Self.currentUserId
          )
          let byGlobalId = try MessageBundleLoader.fetchOne(
            db, globalId: try #require(message.globalId), currentUserId: Self.currentUserId
          )
          if single != byKey || single != byGlobalId {
            mismatches.append("single chat \(chatId) message \(message.messageId)")
          }
        }
      }

      // One batch across every chat, as pending-send recovery and home translations load: relations
      // keyed by message id must not leak between chats whose message ids repeat.
      var mixed: [Message] = []
      for chatId in Self.threadChats + [Self.dmChat] {
        mixed += try Message.filter(Column("chatId") == chatId).order(Column("messageId").desc).limit(60).fetchAll(db)
      }
      var generator = SeededGenerator(seed: 9)
      let mixedLoaded = try MessageBundleLoader.load(
        db, messages: mixed.shuffled(using: &generator), currentUserId: Self.currentUserId
      )
      #expect(mixedLoaded.count == mixed.count)
      for value in mixedLoaded {
        compared += 1
        let key = "\(value.message.chatId):\(value.message.messageId)"
        guard let expected = expectedByKey[key] else {
          mismatches.append("mixed \(key): not in a page")
          continue
        }
        let diff = Self.diff(expected, value)
        if !diff.isEmpty { mismatches.append("mixed \(key): \(diff)") }
      }

      let latest = try MessageBundleLoader.fetchLatest(
        db, chatId: Self.threadChats[0], limit: 50, currentUserId: Self.currentUserId
      )
      let expectedLatest = try FullMessage.queryRequest(currentUserId: Self.currentUserId)
        .filter(Column("chatId") == Self.threadChats[0])
        .order(Column("messageId").desc)
        .limit(50)
        .fetchAll(db)
      #expect(latest == expectedLatest)
      #expect(try MessageBundleLoader.fetchOne(db, chatId: Self.dmChat, messageId: 99_999) == nil)
      #expect(try MessageBundleLoader.load(db, messages: []).isEmpty)

      // The corpus must exercise every relation, or parity says little.
      let coverage = try #require(try Row.fetchOne(db, sql: """
      SELECT
        (SELECT count(*) FROM message WHERE photoId IS NOT NULL) AS photos,
        (SELECT count(*) FROM message WHERE videoId IS NOT NULL) AS videos,
        (SELECT count(*) FROM message WHERE documentId IS NOT NULL) AS documents,
        (SELECT count(*) FROM message WHERE fileId IS NOT NULL) AS files,
        (SELECT count(*) FROM message WHERE forwardFromUserId IS NOT NULL) AS forwardsFromUser,
        (SELECT count(*) FROM message WHERE forwardFromPeerUserId IS NOT NULL) AS forwardsFromPeerUser,
        (SELECT count(*) FROM message WHERE forwardFromPeerThreadId IS NOT NULL) AS forwardsFromThread,
        (SELECT count(*) FROM message WHERE repliedToMessageId IS NOT NULL) AS replies,
        (SELECT count(*) FROM reaction) AS reactions,
        (SELECT count(*) FROM attachment WHERE externalTaskId IS NOT NULL) AS taskAttachments,
        (SELECT count(*) FROM attachment WHERE urlPreviewId IS NOT NULL) AS previewAttachments,
        (SELECT count(*) FROM translation) AS translations,
        (SELECT count(*) FROM acknowledgement) AS acknowledgements,
        (SELECT count(*) FROM chat WHERE parentChatId IS NOT NULL) AS replyThreads,
        (SELECT count(*) FROM file WHERE profileForUserId IS NOT NULL) AS profilePhotos,
        (SELECT count(*) FROM acknowledgement WHERE cleared = 1) AS clearedAcknowledgements,
        (SELECT count(*) FROM message WHERE messageId <= 0) AS pendingMessages,
        (SELECT count(*) FROM message m WHERE m.repliedToMessageId IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM message r WHERE r.chatId = m.chatId AND r.messageId = m.repliedToMessageId
        )) AS repliesToMissingMessages,
        (SELECT count(*) FROM message m WHERE m.photoId IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM photo p WHERE p.photoId = m.photoId
        )) AS photosWithoutRows,
        (SELECT count(*) FROM chat c WHERE c.id IN (\(Self.threadChats.map(String.init).joined(separator: ",")), \(Self.dmChat))
          AND NOT EXISTS (SELECT 1 FROM acknowledgement a WHERE a.chatId = c.id AND a.userId = \(Self.currentUserId))
        ) AS chatsWithoutOwnAcknowledgement
      """))
      for column in coverage.columnNames {
        let count: Int = coverage[column]
        #expect(count > 0, "no \(column) in the parity corpus")
      }
    }
    // 4 pages (181 rows in the chat with a pending send), 40 single reads each, one 240-message mixed batch.
    #expect(compared == 181 + 3 * 180 + 4 * 40 + 240)
    #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
  }

  @Test("an observed bundle updates when a relation is added later", .timeLimit(.minutes(1)))
  func observationFollowsRelationsAddedLater() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in try Self.seedCorpus(db) }
    let chatId = Self.threadChats[0]
    let messageId: Int64 = 180
    let globalId = try #require(try await database.dbWriter.read { db in
      try Int64.fetchOne(
        db, sql: "SELECT globalId FROM message WHERE chatId = ? AND messageId = ?", arguments: [chatId, messageId]
      )
    })
    let observation = ValueObservation.tracking { db in
      try FullMessageQuery(currentUserId: Self.currentUserId)
        .filter(Column("chatId") == chatId && Column("messageId") == messageId)
        .fetchOne(db)
    }
    var values = observation.values(in: database.dbWriter).makeAsyncIterator()

    let initial = try #require(try await values.next() ?? nil)
    #expect(initial.translations.isEmpty)
    #expect(initial.attachments.isEmpty)

    try await database.dbWriter.write { db in
      try db.execute(
        sql: "INSERT INTO translation (messageId, chatId, translation, language, date) VALUES (?, ?, 'bonjour', 'fr', ?)",
        arguments: [messageId, chatId, Date()]
      )
    }
    let translated = try #require(try await values.next() ?? nil)
    #expect(translated.translations.map(\.translation) == ["bonjour"])

    // A link preview arrives with its photo after the message: attachment, preview, photo and one size.
    try await database.dbWriter.write { db in
      try db.execute(sql: "INSERT INTO photo (id, photoId, date, format) VALUES (5001, 501, ?, 'jpeg')", arguments: [Date()])
      try db.execute(
        sql: "INSERT INTO photoSize (photoId, type, width, height, size) VALUES (5001, 's', 100, 80, 1000)"
      )
      try db.execute(sql: "INSERT INTO urlPreview (id, url, title, photoId) VALUES (50, 'https://inline.chat', 'Inline', 501)")
      try db.execute(sql: "INSERT INTO attachment (messageId, urlPreviewId) VALUES (?, 50)", arguments: [globalId])
    }
    let previewed = try #require(try await values.next() ?? nil)
    #expect(previewed.attachments.first?.urlPreview?.id == 50)
    #expect(previewed.attachments.first?.photoInfo?.sizes.count == 1)

    // A larger size of the preview photo is stored later: only photoSize changes.
    try await database.dbWriter.write { db in
      try db.execute(
        sql: "INSERT INTO photoSize (photoId, type, width, height, size) VALUES (5001, 'm', 800, 640, 9000)"
      )
    }
    let resized = try #require(try await values.next() ?? nil)
    #expect(resized.attachments.first?.photoInfo?.sizes.count == 2)

    // The sender renames.
    try await database.dbWriter.write { db in
      try db.execute(sql: "UPDATE user SET firstName = 'Renamed' WHERE id = ?", arguments: [resized.message.fromId])
    }
    let renamed = try #require(try await values.next() ?? nil)
    #expect(renamed.senderInfo?.user.firstName == "Renamed")
  }

  // MARK: - Corpus

  /// Rows the generated corpus doesn't produce: a pending send, a reply to a message that isn't stored,
  /// a photo id without its row, a cleared acknowledgement, and a chat without the current user's
  /// acknowledgement.
  private static func seedEdgeCases(_ database: AppDatabase) throws {
    try database.dbWriter.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
      try Message(
        messageId: -456,
        randomId: 4560,
        fromId: currentUserId,
        date: Date(timeIntervalSince1970: 1_794_000_100),
        text: "Pending send",
        peerUserId: nil,
        peerThreadId: threadChats[0],
        chatId: threadChats[0],
        out: true,
        status: .sending
      ).insert(db)
      try db.execute(
        sql: "UPDATE message SET repliedToMessageId = 99999 WHERE chatId = ? AND messageId = 170",
        arguments: [threadChats[2]]
      )
      try db.execute(
        sql: "UPDATE message SET photoId = 777, videoId = NULL, documentId = NULL WHERE chatId = ? AND messageId = 171",
        arguments: [threadChats[2]]
      )
      try db.execute(
        sql: """
        UPDATE acknowledgement SET cleared = 1
        WHERE rowid = (SELECT rowid FROM acknowledgement WHERE chatId = ? AND userId != ? LIMIT 1)
        """,
        arguments: [threadChats[1], currentUserId]
      )
      try db.execute(
        sql: "DELETE FROM acknowledgement WHERE chatId = ? AND userId = ?",
        arguments: [dmChat, currentUserId]
      )
    }
  }

  private static func seedCorpus(_ db: Database) throws {
    let now = Date(timeIntervalSince1970: 1_794_000_000)
    for id in Int64(1) ... 40 {
      try User(id: id, email: "u\(id)@example.com", firstName: "First\(id)", lastName: "Last\(id)", username: "user\(id)")
        .save(db)
    }
    try Space(id: spaceId, name: "Parity", date: now).save(db)
    var rng = SeededGenerator(seed: 77)
    var reactionId: Int64 = 1
    let chats: [(id: Int64, peerUserId: Int64?)] = threadChats.map { ($0, nil) } + [(dmChat, dmPeer)]
    for (index, spec) in chats.enumerated() {
      let participants: [Int64] = spec.peerUserId.map { [currentUserId, $0] }
        ?? Array(Set([currentUserId] + (0 ..< 6).map { _ in Int64(2 + rng.next() % 38) })).sorted()
      var chat = Chat(
        id: spec.id,
        date: now.addingTimeInterval(-Double(index) * 60),
        type: spec.peerUserId == nil ? .thread : .privateChat,
        title: spec.peerUserId == nil ? "Thread \(index)" : nil,
        spaceId: spec.peerUserId == nil ? spaceId : nil,
        peerUserId: spec.peerUserId,
        emoji: nil
      )
      try chat.save(db)
      for userId in participants {
        try ChatParticipant(chatId: spec.id, userId: userId, date: now).save(db)
      }
      var date = now.addingTimeInterval(-180 * 600)
      for messageId in Int64(1) ... 180 {
        date = date.addingTimeInterval(Double(20 + rng.next() % 400))
        let sender = participants[Int(rng.next() % UInt64(participants.count))]
        try Message(
          messageId: messageId,
          fromId: sender,
          date: date,
          text: "Message \(messageId) in \(spec.id)",
          peerUserId: spec.peerUserId,
          peerThreadId: spec.peerUserId == nil ? spec.id : nil,
          chatId: spec.id,
          out: sender == currentUserId,
          repliedToMessageId: messageId > 10 && rng.next() % 12 == 0 ? messageId - 1 - Int64(rng.next() % 9) : nil
        ).insert(db)
        if rng.next() % 8 == 0 {
          for _ in 0 ..< (1 + Int(rng.next() % 3)) {
            reactionId += 1
            try Reaction(
              id: reactionId,
              messageId: messageId,
              userId: participants[Int(rng.next() % UInt64(participants.count))],
              emoji: ["👍", "❤️", "😂", "🎉"][Int(rng.next() % 4)],
              date: date,
              chatId: spec.id
            ).insert(db, onConflict: .ignore)
          }
        }
      }
      chat.lastMsgId = 180
      try chat.save(db)
    }
  }

  /// Media with sizes and thumbnails, files, profile photos, forwards, replies to media messages,
  /// translations, acknowledgements, reply threads, task and URL-preview attachments.
  private static func seedRichRelations(_ db: Database, chats richChats: [Int64]) throws {
    let date = "2026-11-01 10:00:00.000"
    // Photos inserted in reverse so relation order can't come from insertion order.
    for p in (1 ... 60).reversed() {
      try db.execute(
        sql: "INSERT INTO photo (id, photoId, date, format) VALUES (?, ?, ?, 'jpeg')",
        arguments: [1000 + p, p, date]
      )
      for (i, type) in ["x", "s", "m"].enumerated() {
        try db.execute(
          sql: "INSERT INTO photoSize (photoId, type, width, height, size, cdnUrl) VALUES (?, ?, ?, ?, ?, ?)",
          arguments: [1000 + p, type, 100 * (i + 1), 80 * (i + 1), 1000 * (i + 1), "https://cdn/p\(p)/\(type)"]
        )
      }
    }
    for v in 1 ... 12 {
      try db.execute(
        sql: "INSERT INTO video (videoId, date, width, height, duration, thumbnailPhotoId) VALUES (?, ?, 640, 360, 12, ?)",
        arguments: [v, date, v % 3 == 0 ? nil : 1040 + v]
      )
    }
    for d in 1 ... 12 {
      try db.execute(
        sql: """
        INSERT INTO document (documentId, date, fileName, mimeType, size, thumbnailPhotoId)
        VALUES (?, ?, ?, 'application/pdf', 2048, ?)
        """,
        arguments: [d, date, "doc\(d).pdf", d % 2 == 0 ? 1052 + (d % 8) : nil]
      )
    }
    for f in 1 ... 20 {
      try db.execute(
        sql: "INSERT INTO file (id, fileType, fileSize, width, height) VALUES (?, 'photo', 100, 10, 10)",
        arguments: ["f\(f)"]
      )
    }
    // Two profile photos for some users, one for others, none for the rest.
    for u in Int64(2) ... 40 where u % 5 != 0 {
      try db.execute(sql: "INSERT INTO file (id, fileType, profileForUserId) VALUES (?, 'photo', ?)", arguments: ["pb\(u)", u])
      if u % 3 == 0 {
        try db.execute(sql: "INSERT INTO file (id, fileType, profileForUserId) VALUES (?, 'photo', ?)", arguments: ["pa\(u)", u])
      }
    }
    for t in 1 ... 6 {
      try db.execute(
        sql: """
        INSERT INTO externalTask (id, application, taskId, status, assignedUserId, title, date)
        VALUES (?, 'notion', ?, 'todo', ?, ?, ?)
        """,
        arguments: [t, "t\(t)", t == 6 ? nil : 2 + t, "Task \(t)", date]
      )
    }
    for u in 1 ... 8 {
      try db.execute(
        sql: "INSERT INTO urlPreview (id, url, title, photoId, authorPhotoId) VALUES (?, ?, ?, ?, ?)",
        arguments: [u, "https://example.com/\(u)", "Preview \(u)", u % 4 == 0 ? nil : 20 + u, u % 2 == 0 ? 30 + u : nil]
      )
    }
    var rng = SeededGenerator(seed: 5)
    var threadId: Int64 = 90_000
    for chatId in richChats {
      let ids = try Int64.fetchAll(
        db,
        sql: "SELECT messageId FROM message WHERE chatId = ? ORDER BY messageId DESC LIMIT 160",
        arguments: [chatId]
      )
      let users = try Int64.fetchAll(db, sql: "SELECT userId FROM chatParticipant WHERE chatId = ?", arguments: [chatId])
      for (i, messageId) in ids.enumerated() {
        let kind = rng.next() % 16
        var sets: [String] = []
        var arguments: [DatabaseValueConvertible?] = []
        switch kind {
          case 0: sets.append("photoId = ?"); arguments.append(Int64(1 + i % 60))
          case 1: sets.append("videoId = ?"); arguments.append(Int64(1 + i % 12))
          case 2: sets.append("documentId = ?"); arguments.append(Int64(1 + i % 12))
          case 3: sets.append("fileId = ?"); arguments.append("f\(1 + i % 20)")
          case 4:
            sets.append("forwardFromUserId = ?"); arguments.append(Int64(2 + i % 30))
            sets.append("forwardFromMessageId = ?"); arguments.append(Int64(5))
          case 5:
            sets.append("forwardFromPeerUserId = ?"); arguments.append(Int64(3 + i % 30))
            sets.append("forwardFromPeerThreadId = NULL")
          case 6: sets.append("forwardFromPeerThreadId = ?"); arguments.append(richChats.first { $0 != chatId } ?? chatId)
          case 7, 8:
            if i + 3 < ids.count { sets.append("repliedToMessageId = ?"); arguments.append(ids[i + 3]) }
          case 9: sets.append("fromId = ?"); arguments.append(Int64(5)) // a sender without profile photos
          default: break
        }
        if !sets.isEmpty {
          arguments.append(chatId)
          arguments.append(messageId)
          try db.execute(
            sql: "UPDATE message SET \(sets.joined(separator: ", ")) WHERE chatId = ? AND messageId = ?",
            arguments: StatementArguments(arguments)
          )
        }
        if rng.next() % 4 == 0 {
          for language in ["fr", "de", "en"].prefix(1 + Int(rng.next() % 3)) {
            try db.execute(
              sql: "INSERT INTO translation (messageId, chatId, translation, language, date) VALUES (?, ?, ?, ?, ?)",
              arguments: [messageId, chatId, "[\(language)] \(messageId)", language, date]
            )
          }
        }
        if rng.next() % 6 == 0 {
          let globalId = try #require(try Int64.fetchOne(
            db,
            sql: "SELECT globalId FROM message WHERE chatId = ? AND messageId = ?",
            arguments: [chatId, messageId]
          ))
          for _ in 0 ..< (1 + Int(rng.next() % 3)) {
            if rng.next() % 2 == 0 {
              try db.execute(
                sql: "INSERT INTO attachment (messageId, externalTaskId) VALUES (?, ?)",
                arguments: [globalId, Int64(1 + rng.next() % 6)]
              )
            } else {
              try db.execute(
                sql: "INSERT INTO attachment (messageId, urlPreviewId) VALUES (?, ?)",
                arguments: [globalId, Int64(1 + rng.next() % 8)]
              )
            }
          }
        }
        if rng.next() % 10 == 0 {
          threadId += 1
          try db.execute(
            sql: "INSERT INTO chat (id, type, date, title, parentChatId, parentMessageId) VALUES (?, 'thread', ?, ?, ?, ?)",
            arguments: [threadId, date, "Reply thread \(threadId)", chatId, messageId]
          )
        }
        // Replied-to messages that carry media themselves.
        if kind == 7 || kind == 8, i + 3 < ids.count {
          try db.execute(
            sql: "UPDATE message SET photoId = ?, videoId = ?, documentId = ? WHERE chatId = ? AND messageId = ?",
            arguments: [
              i % 2 == 0 ? Int64(1 + i % 60) : nil,
              i % 3 == 0 ? Int64(1 + i % 12) : nil,
              i % 5 == 0 ? Int64(1 + i % 12) : nil,
              chatId,
              ids[i + 3],
            ]
          )
        }
      }
      // Read acknowledgements at a spread of messages, the current user's included.
      for (k, userId) in users.enumerated() {
        try db.execute(
          sql: "INSERT OR REPLACE INTO acknowledgement (chatId, userId, maxId, revision, cleared) VALUES (?, ?, ?, 1, 0)",
          arguments: [chatId, userId, ids[min(ids.count - 1, k * 3)]]
        )
      }
    }
  }

  private static func diff(_ a: FullMessage, _ b: FullMessage) -> [String] {
    var out: [String] = []
    if a.message != b.message { out.append("message") }
    if a.senderInfo != b.senderInfo { out.append("senderInfo") }
    if a.forwardFromUserInfo != b.forwardFromUserInfo { out.append("forwardFromUserInfo") }
    if a.forwardFromPeerUserInfo != b.forwardFromPeerUserInfo { out.append("forwardFromPeerUserInfo") }
    if a.forwardFromChatInfo != b.forwardFromChatInfo { out.append("forwardFromChatInfo") }
    if a.replyThread != b.replyThread { out.append("replyThread") }
    if a.reactions != b.reactions { out.append("reactions") }
    if a.acknowledgements != b.acknowledgements { out.append("acknowledgements") }
    if a.currentUserAcknowledgement != b.currentUserAcknowledgement { out.append("currentUserAcknowledgement") }
    if a.repliedToMessage != b.repliedToMessage { out.append("repliedToMessage") }
    if a.attachments != b.attachments { out.append("attachments") }
    if a.photoInfo != b.photoInfo { out.append("photoInfo") }
    if a.videoInfo != b.videoInfo { out.append("videoInfo") }
    if a.documentInfo != b.documentInfo { out.append("documentInfo") }
    if a.translations != b.translations { out.append("translations") }
    if a.file != b.file { out.append("file") }
    if out.isEmpty, a != b { out.append("other") }
    return out
  }
}

/// SplitMix64, so the corpus is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
