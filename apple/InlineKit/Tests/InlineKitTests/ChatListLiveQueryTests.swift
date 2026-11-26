import Foundation
import GRDB
@testable import InlineKit
import Testing

@Suite("Chat-list live query")
struct ChatListLiveQueryTests {
  private static let chatCount = 12
  private static let parameters = ChatListLiveQuery.Parameters(
    spaceID: nil,
    includeSpaceChatsInHome: true,
    translationLanguage: "en",
    includeOpenedDate: false,
    includeTimestampText: false
  )

  @Test("starting while writes commit never delivers a partial list and ends equal to a full fetch")
  func startRacingWrites() async throws {
    for round in 0 ..< 8 {
      let database = try Self.makeDatabase()
      let recorder = SnapshotRecorder()
      let writer = Task.detached {
        for step in 0 ..< 30 {
          try await Self.write(step: step + round * 30, in: database)
        }
      }
      let cancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
        immediate: true,
        deliveryQueue: recorder.queue,
        onError: { Issue.record("live query failed: \($0)") },
        onChange: recorder.record
      )
      try await writer.value
      let expected = try Self.fullFetch(database)
      var settled = false
      for _ in 0 ..< 400 {
        if recorder.latest == expected { settled = true; break }
        try await Task.sleep(for: .milliseconds(5))
      }
      cancellable.cancel()
      #expect(settled, "round \(round): live list did not converge to a full fetch")
      #expect(recorder.smallest == Self.chatCount, "round \(round): a delivered list was partial")
    }
  }

  @Test("rows a commit can change are refreshed: messages, drafts, renames, deletes")
  func incrementalRefreshMatchesFullFetch() async throws {
    let database = try Self.makeDatabase()
    let recorder = SnapshotRecorder()
    let cancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
      immediate: true,
      deliveryQueue: recorder.queue,
      onError: { Issue.record("live query failed: \($0)") },
      onChange: recorder.record
    )
    for step in 0 ..< 24 {
      try await Self.write(step: step, in: database)
      let expected = try Self.fullFetch(database)
      var matched = false
      for _ in 0 ..< 400 {
        if recorder.latest == expected { matched = true; break }
        try await Task.sleep(for: .milliseconds(2))
      }
      #expect(matched, "step \(step) (\(Self.writeKind(step)))")
    }
    cancellable.cancel()
  }

  @Test("starting never waits for the writer, even when it installs the change router")
  func startDoesNotWaitForWriter() async throws {
    let database = try Self.makeDatabase()
    let holding = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let holder = Thread {
      try? database.dbWriter.write { _ in
        holding.signal()
        release.wait()
      }
    }
    holder.start()
    Self.block(on: holding)
    let recorder = SnapshotRecorder()
    let startedAt = Date()
    let cancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
      immediate: false,
      deliveryQueue: recorder.queue,
      onError: { Issue.record("live query failed: \($0)") },
      onChange: recorder.record
    )
    let elapsed = Date().timeIntervalSince(startedAt)
    release.signal()
    #expect(elapsed < 0.2, "start waited \(elapsed) s for the writer")
    let expected = try Self.fullFetch(database)
    #expect(try await Self.settle(recorder, to: expected))
    // The router is installed: later commits still arrive.
    try await Self.write(step: 2, in: database)
    #expect(try await Self.settle(recorder, to: Self.fullFetch(database)))
    cancellable.cancel()
  }

  @Test("a day, time zone or clock change delivers a refetched list even when no row changed")
  func clockChangeDelivers() async throws {
    let database = try Self.makeDatabase()
    let recorder = SnapshotRecorder()
    let cancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
      immediate: true,
      deliveryQueue: recorder.queue,
      onError: { Issue.record("live query failed: \($0)") },
      onChange: recorder.record
    )
    let expected = try Self.fullFetch(database)
    #expect(try await Self.settle(recorder, to: expected))
    for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
      let before = recorder.count
      NotificationCenter.default.post(name: name, object: nil)
      var delivered = false
      for _ in 0 ..< 400 {
        if recorder.count > before { delivered = true; break }
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(delivered, "\(name.rawValue) did not deliver")
      #expect(recorder.latest == expected)
    }
    cancellable.cancel()
  }

  @Test("a changed translation language refetches every row at the next refresh")
  func translationLanguageChange() async throws {
    let database = try Self.makeDatabase()
    try await database.dbWriter.write { db in
      try db.execute(
        sql: "INSERT INTO translation (messageId, chatId, translation, language, date) VALUES (1, 500, 'bonjour', 'fr', ?)",
        arguments: [Date()]
      )
    }
    // Installed first so the write below is routed. Starting without a router installs it on the first
    // refresh, and a write committed before that is only seen by that refresh's full read.
    _ = try ChatListChangeRouter.shared(for: database.dbWriter)
    let language = LanguageBox("en")
    let recorder = SnapshotRecorder()
    let cancellable = ChatListLiveQuery(
      writer: database.dbWriter,
      parameters: Self.parameters,
      translationLanguage: { language.value }
    ).start(
      immediate: true,
      deliveryQueue: recorder.queue,
      onError: { Issue.record("live query failed: \($0)") },
      onChange: recorder.record
    )
    #expect(try await Self.settle(recorder, to: Self.fullFetch(database)))
    language.value = "fr"
    // A write to another chat: the refresh it triggers refetches every row in the new language.
    try await Self.write(step: 2 + 6 * 3, in: database)
    let french = try Self.fullFetch(database, language: "fr")
    #expect(french.contains { $0.translatedPreviewText == "bonjour" })
    #expect(try await Self.settle(recorder, to: french))
    cancellable.cancel()
  }

  @Test("a failed refresh keeps its rows and retries until it succeeds, reporting the failure once")
  func failedRefreshRetries() async throws {
    let database = try Self.makeDatabase()
    let recorder = SnapshotRecorder()
    let errors = SnapshotRecorder()
    let cancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
      immediate: true,
      deliveryQueue: recorder.queue,
      onError: { _ in errors.record([]) },
      onChange: recorder.record
    )
    #expect(try await Self.settle(recorder, to: Self.fullFetch(database)))
    // Make every chat-list read fail, then change a row.
    try await database.dbWriter.write { db in
      try db.execute(sql: "ALTER TABLE translation RENAME TO translation_unavailable")
    }
    try await Self.write(step: 5, in: database)
    for _ in 0 ..< 400 where errors.count == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(errors.count == 1)
    // Leave a couple of retries to fail, then restore the table without writing any row.
    try await Task.sleep(for: .milliseconds(400))
    try await database.dbWriter.write { db in
      try db.execute(sql: "ALTER TABLE translation_unavailable RENAME TO translation")
    }
    #expect(try await Self.settle(recorder, to: Self.fullFetch(database), attempts: 800))
    #expect(errors.count == 1, "each retry reported the failure again")
    cancellable.cancel()
  }

  @Test("starting on a pool with a router already installed never delivers a partial list")
  func startRacingWritesOnPool() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-query-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Not closed explicitly: cancelled queries may still be finishing a read, and the pool closes when the
    // last of them releases it.
    let database = try AppDatabase(path: directory.appendingPathComponent("db.sqlite").path, passphrase: "live-query")
    try await database.dbWriter.write { db in try Self.seed(db) }
    // A query that is already running installed the router, as on every list restart after the first.
    let resident = SnapshotRecorder()
    let residentCancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
      immediate: true, deliveryQueue: resident.queue, onError: { Issue.record("\($0)") }, onChange: resident.record
    )
    defer { residentCancellable.cancel() }

    for round in 0 ..< 12 {
      let recorder = SnapshotRecorder()
      let writes = Task.detached {
        for step in 0 ..< 20 {
          try await Self.write(step: step + round * 20, in: database)
        }
      }
      let cancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
        immediate: round % 2 == 0,
        deliveryQueue: recorder.queue,
        onError: { Issue.record("live query failed: \($0)") },
        onChange: recorder.record
      )
      try await writes.value
      #expect(try await Self.settle(recorder, to: Self.fullFetch(database)), "round \(round) did not converge")
      #expect(recorder.smallest == Self.chatCount, "round \(round): a delivered list was partial")
      cancellable.cancel()
    }
  }

  @Test("commits that arrive while a refresh runs are read in one refresh")
  func burstsCoalesce() async throws {
    let database = try Self.makeDatabase()
    // Installed first so the write below is routed, as in the language test.
    _ = try ChatListChangeRouter.shared(for: database.dbWriter)
    let gate = RefreshGate()
    let recorder = SnapshotRecorder()
    let cancellable = ChatListLiveQuery(
      writer: database.dbWriter,
      parameters: Self.parameters,
      translationLanguage: { gate.pass(); return "en" }
    ).start(
      immediate: true,
      deliveryQueue: recorder.queue,
      onError: { Issue.record("live query failed: \($0)") },
      onChange: recorder.record
    )
    #expect(try await Self.settle(recorder, to: Self.fullFetch(database)))
    let before = recorder.count

    // The next refresh stops in the language provider, on the query's queue, until released.
    gate.arm()
    try await Self.write(step: 2, in: database)
    #expect(await gate.waitUntilHeld())
    for index in 0 ..< 20 {
      try await database.dbWriter.write { db in
        try db.execute(
          sql: "UPDATE dialog SET unreadCount = ? WHERE peerUserId = ?",
          arguments: [1000 + index, Int64(100 + index % Self.chatCount)]
        )
      }
    }
    gate.release()
    #expect(try await Self.settle(recorder, to: Self.fullFetch(database)))
    // The held refresh, then one for all 20 commits queued behind it.
    #expect(recorder.count - before <= 3, "\(recorder.count - before) deliveries for 21 commits")
    cancellable.cancel()
  }

  @Test("threads, translations, documents, visibility, inserts and deletes refresh the right rows")
  func routerCoversEveryJoin() async throws {
    let database = try Self.makeDatabase()
    try await database.dbWriter.write { db in try Self.seedThreadsAndSpace(db) }
    let initial = try Self.fullFetch(database)
    let shown = Set(initial.map(\.dialogID))
    #expect(shown.contains(Dialog.getDialogId(peerThreadId: Self.replyThreadID)), "reply thread row not in the list")
    #expect(shown.contains(Dialog.getDialogId(peerThreadId: Self.spaceThreadID)), "space thread row not in the list")

    let recorder = SnapshotRecorder()
    let cancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
      immediate: true,
      deliveryQueue: recorder.queue,
      onError: { Issue.record("live query failed: \($0)") },
      onChange: recorder.record
    )
    let date = "2026-11-01 10:00:00.000"
    let steps: [(String, String)] = [
      ("translation of a last message", "INSERT INTO translation (messageId, chatId, translation, language, date) VALUES (1, 500, 'hola', 'en', '\(date)')"),
      ("translation edit", "UPDATE translation SET translation = 'hola de nuevo' WHERE chatId = 500"),
      ("translation delete", "DELETE FROM translation WHERE chatId = 500"),
      ("document on a last message", "INSERT INTO document (documentId, date, fileName, mimeType, size) VALUES (77, '\(date)', 'plan.pdf', 'application/pdf', 10)"),
      ("last message gets the document", "UPDATE message SET documentId = 77 WHERE chatId = 501 AND messageId = 1"),
      ("document rename", "UPDATE document SET fileName = 'plan-v2.pdf' WHERE documentId = 77"),
      ("parent DM peer rename", "UPDATE user SET firstName = 'Parent peer' WHERE id = 100"),
      ("thread parent message edit", "UPDATE message SET text = 'parent edited' WHERE chatId = 500 AND messageId = 1"),
      ("reply thread title", "UPDATE chat SET title = 'Renamed thread' WHERE id = \(Self.replyThreadID)"),
      ("space rename", "UPDATE space SET name = 'Renamed space' WHERE id = \(Self.spaceID)"),
      ("hide a row", "UPDATE dialog SET chatListHidden = 1 WHERE peerUserId = 102"),
      ("show it again", "UPDATE dialog SET chatListHidden = 0 WHERE peerUserId = 102"),
      ("archive", "UPDATE dialog SET archived = 1 WHERE peerUserId = 103"),
      ("unarchive", "UPDATE dialog SET archived = 0 WHERE peerUserId = 103"),
      ("new member", "INSERT INTO member (id, date, userId, spaceId, role) VALUES (9001, '\(date)', 104, \(Self.spaceID), 'member')"),
      // As `Message.deleteMessages` does: the chat's composite last-message key is cleared first.
      ("delete the last message", "UPDATE chat SET lastMsgId = NULL WHERE id = 505; DELETE FROM message WHERE chatId = 505 AND messageId = 1"),
      ("delete a dialog", "DELETE FROM dialog WHERE peerUserId = 106"),
      ("delete a chat", """
      UPDATE chat SET lastMsgId = NULL WHERE id = \(Self.spaceThreadID);
      DELETE FROM message WHERE chatId = \(Self.spaceThreadID);
      DELETE FROM dialog WHERE chatId = \(Self.spaceThreadID);
      DELETE FROM chat WHERE id = \(Self.spaceThreadID)
      """),
    ]
    for (name, sql) in steps {
      try await database.dbWriter.write { db in try db.execute(sql: sql) }
      #expect(try await Self.settle(recorder, to: Self.fullFetch(database)), "\(name)")
    }
    // A new chat with its dialog appears.
    try await database.dbWriter.write { db in
      try User(id: 199, email: nil, firstName: "Newcomer").insert(db)
      var chat = Chat(id: 599, date: Date(timeIntervalSince1970: 1_790_100_000), type: .privateChat, title: nil,
                      spaceId: nil, peerUserId: 199)
      try chat.insert(db)
      try InlineKit.Message(
        messageId: 1, fromId: 199, date: Date(timeIntervalSince1970: 1_790_100_001), text: "hi",
        peerUserId: 199, peerThreadId: nil, chatId: 599, out: false
      ).insert(db)
      chat.lastMsgId = 1
      try chat.update(db)
      var dialog = Dialog(optimisticForChat: chat)
      dialog.open = true
      try dialog.insert(db)
    }
    #expect(try await Self.settle(recorder, to: Self.fullFetch(database)), "new chat")
    cancellable.cancel()
  }

  @Test("a batch that clears one draft and saves another refreshes both rows when the rowid is reused")
  func draftRowIDReuse() async throws {
    let database = try Self.makeDatabase()
    _ = try ChatListChangeRouter.shared(for: database.dbWriter)
    let recorder = SnapshotRecorder()
    let cancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
      immediate: true,
      deliveryQueue: recorder.queue,
      onError: { Issue.record("live query failed: \($0)") },
      onChange: recorder.record
    )
    let first: Int64 = try await database.dbWriter.write { db in
      try db.execute(sql: "INSERT INTO draft2 (peerKey, text, updatedAt, revision) VALUES ('user_100', 'first', 1, 1)")
      return db.lastInsertedRowID
    }
    let withFirstDraft = try Self.fullFetch(database)
    #expect(try await Self.settle(recorder, to: withFirstDraft))
    // As Drafts2's batch writer does: one transaction clears a draft and saves another peer's.
    let second: Int64 = try await database.dbWriter.write { db in
      try db.execute(sql: "DELETE FROM draft2 WHERE peerKey = 'user_100'")
      try db.execute(sql: "INSERT INTO draft2 (peerKey, text, updatedAt, revision) VALUES ('user_101', 'second', 1, 1)")
      return db.lastInsertedRowID
    }
    #expect(second == first, "SQLite reused the cleared draft's rowid")
    let expected = try Self.fullFetch(database)
    // Both rows changed: the first lost its draft, the second gained one.
    for userID in [Int64(100), 101] {
      let dialogID = Dialog.getDialogId(peerUserId: userID)
      #expect(withFirstDraft.first { $0.dialogID == dialogID } != expected.first { $0.dialogID == dialogID })
    }
    #expect(try await Self.settle(recorder, to: expected))
    cancellable.cancel()
  }

  @Test("the index kept at each commit equals a full read, and the list a full fetch, over 300 mixed writes")
  func indexFollowsEveryWrite() async throws {
    let database = try Self.makeDatabase()
    try await database.dbWriter.write { db in try Self.seedThreadsAndSpace(db) }
    let router = try ChatListChangeRouter.shared(for: database.dbWriter)
    let recorder = SnapshotRecorder()
    let cancellable = ChatListLiveQuery(writer: database.dbWriter, parameters: Self.parameters).start(
      immediate: true,
      deliveryQueue: recorder.queue,
      onError: { Issue.record("live query failed: \($0)") },
      onChange: recorder.record
    )
    var random = MixedWriteRandom(seed: 7)
    for step in 0 ..< 300 {
      let kind = Int(random.next() % 22)
      let a = Int(random.next() % 1000)
      let b = Int(random.next() % 1000)
      let name = try await database.dbWriter.write { db in
        try Self.mixedWrite(kind: kind, step: step, a: a, b: b, db)
      }
      let kept = try await database.dbWriter.write { db in router.currentIndex(db) }
      let read = try await database.dbWriter.read { db in try ChatListRowIndex.primed(db) }
      #expect(kept == read, "step \(step): \(name)")
      #expect(try await Self.settle(recorder, to: Self.fullFetch(database)), "step \(step): \(name)")
    }
    cancellable.cancel()
  }

  @Test("a message insert, edit or delete refreshes only its chat's row, though the search index writes too")
  func messageWritesStayIncremental() async throws {
    let database = try Self.makeDatabase()
    let router = try ChatListChangeRouter.shared(for: database.dbWriter)
    let log = ChangeLog()
    let subscription = router.subscribe { log.append($0) }
    defer { router.unsubscribe(subscription) }
    let dialog = Dialog.getDialogId(peerUserId: 100)
    let date = Date(timeIntervalSince1970: 1_790_300_000)

    try await database.dbWriter.write { db in
      try InlineKit.Message(
        messageId: 2, fromId: 100, date: date, text: "searchable words", peerUserId: 100, peerThreadId: nil,
        chatId: 500, out: false
      ).insert(db)
      try db.execute(sql: "UPDATE chat SET lastMsgId = 2 WHERE id = 500")
    }
    try await database.dbWriter.write { db in
      try db.execute(sql: "UPDATE message SET text = 'other words' WHERE chatId = 500 AND messageId = 2")
    }
    // As `Message.deleteMessages` does: the chat's last message key moves first.
    try await database.dbWriter.write { db in
      try db.execute(sql: "UPDATE chat SET lastMsgId = 1 WHERE id = 500")
      try db.execute(sql: "DELETE FROM message WHERE chatId = 500 AND messageId = 2")
    }
    #expect(log.all == Array(repeating: ChatListChange(dialogIDs: [dialog]), count: 3))
  }

  @Test("a commit's resolution reads rows by key, never by scanning a table")
  func resolutionReadsByKey() async throws {
    let database = try Self.makeDatabase()
    let draftRowID: Int64 = try await database.dbWriter.write { db in
      try Self.seedThreadsAndSpace(db)
      try db.execute(sql: "INSERT INTO draft2 (peerKey, text, updatedAt, revision) VALUES ('user_100', 'draft', 1, 1)")
      return db.lastInsertedRowID
    }
    let router = try ChatListChangeRouter.shared(for: database.dbWriter)
    try await database.dbWriter.write { db in
      var statements: [String] = []
      db.trace(options: .statement) { statements.append($0.expandedDescription) }
      _ = try router.resolve(db, tables: [
        "dialog": [100], "chat": [500, Self.replyThreadID], "message": [1, 2], "user": [100, 101],
        "draft2": [draftRowID], "translation": [1], "document": [1],
      ], deletes: [])
      db.trace(options: .statement, nil)
      // Dialog, message, chat, draft, translation and document keys.
      #expect(statements.count == 6, "\(statements)")
      for sql in statements {
        let details = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
        let scans = details.filter { $0.hasPrefix("SCAN") && !$0.contains("json_each") }
        #expect(scans.isEmpty, "\(sql): \(details)")
      }
    }
  }

  // MARK: Fixture

  private static let spaceID: Int64 = 9
  private static let spaceThreadID: Int64 = 900
  private static let replyThreadID: Int64 = 901

  private static func makeDatabase() throws -> AppDatabase {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in try seed(db) }
    return database
  }

  /// One write of `kind` over the fixture (12 DMs, a space thread and a reply thread), for the index test.
  private static func mixedWrite(kind: Int, step: Int, a: Int, b: Int, _ db: Database) throws -> String {
    let dm = Int64(a % chatCount)
    let user = 100 + dm
    let dmChat = 500 + dm
    let otherUser = Int64(100 + b % chatCount)
    let date = Date(timeIntervalSince1970: 1_790_200_000 + Double(step))
    func lastMessageID(_ chat: Int64) throws -> Int64? {
      try Int64.fetchOne(db, sql: "SELECT lastMsgId FROM chat WHERE id = ?", arguments: [chat])
    }
    func addMessage(_ chat: Int64, from: Int64, peerUser: Int64?) throws {
      let next = (try Int64.fetchOne(db, sql: "SELECT MAX(messageId) FROM message WHERE chatId = ?", arguments: [chat]) ?? 0) + 1
      try InlineKit.Message(
        messageId: next, fromId: from, date: date, text: "m\(step)",
        peerUserId: peerUser, peerThreadId: peerUser == nil ? chat : nil, chatId: chat, out: false
      ).insert(db)
      try db.execute(sql: "UPDATE chat SET lastMsgId = ? WHERE id = ?", arguments: [next, chat])
    }
    let threads = try Int64.fetchAll(db, sql: "SELECT id FROM chat WHERE parentChatId IS NOT NULL ORDER BY id")
    switch kind {
      case 0:
        try addMessage(dmChat, from: user, peerUser: user)
        try db.execute(sql: "UPDATE dialog SET unreadCount = COALESCE(unreadCount, 0) + 1 WHERE peerUserId = ?", arguments: [user])
        return "message in a DM"
      case 1:
        let thread = b % 2 == 0 ? spaceThreadID : (threads.last ?? replyThreadID)
        try addMessage(thread, from: otherUser, peerUser: nil)
        return "message in a thread from another sender"
      case 2:
        try db.execute(
          sql: "UPDATE message SET text = ? WHERE chatId = ? AND messageId = (SELECT lastMsgId FROM chat WHERE id = ?)",
          arguments: ["edited \(step)", dmChat, dmChat]
        )
        return "last message edit"
      case 3:
        try db.execute(
          sql: "UPDATE message SET fromId = ? WHERE chatId = ? AND messageId = (SELECT lastMsgId FROM chat WHERE id = ?)",
          arguments: [otherUser, dmChat, dmChat]
        )
        return "last message sender change"
      case 4:
        try db.execute(sql: "UPDATE user SET firstName = ? WHERE id = ?", arguments: ["User \(step)", otherUser])
        return "user rename"
      case 5:
        try db.execute(sql: "UPDATE user SET online = NOT COALESCE(online, 0) WHERE id = ?", arguments: [otherUser])
        return "presence"
      case 6:
        let documentID = Int64(5000 + step)
        try db.execute(
          sql: "INSERT INTO document (documentId, date, fileName, mimeType, size) VALUES (?, ?, ?, 'application/pdf', 10)",
          arguments: [documentID, date, "doc \(step).pdf"]
        )
        try db.execute(
          sql: "UPDATE message SET documentId = ? WHERE chatId = ? AND messageId = (SELECT lastMsgId FROM chat WHERE id = ?)",
          arguments: [documentID, dmChat, dmChat]
        )
        return "document on a last message"
      case 7:
        try db.execute(
          sql: "UPDATE document SET fileName = ? WHERE documentId = (SELECT MAX(documentId) FROM document)",
          arguments: ["renamed \(step).pdf"]
        )
        return "document rename"
      case 8:
        guard let anchor = try lastMessageID(dmChat) else { return "no anchor" }
        let id = Int64(2000 + step)
        var chat = Chat(id: id, date: date, type: .thread, title: "Reply \(step)", spaceId: nil)
        chat.parentChatId = dmChat
        chat.parentMessageId = anchor
        try chat.insert(db)
        try addMessage(id, from: otherUser, peerUser: nil)
        chat.lastMsgId = try lastMessageID(id)
        var dialog = Dialog(optimisticForChat: chat)
        dialog.open = true
        try dialog.insert(db)
        return "new reply thread"
      case 9:
        guard let thread = threads.isEmpty ? nil : threads[b % threads.count] else { return "no thread" }
        try db.execute(sql: "UPDATE chat SET parentChatId = ?, parentMessageId = 1 WHERE id = ?", arguments: [dmChat, thread])
        return "reply thread moves to another DM"
      case 10:
        guard let thread = threads.isEmpty ? nil : threads[b % threads.count] else { return "no thread" }
        try db.execute(
          sql: """
          UPDATE message SET text = ? WHERE (chatId, messageId) =
            (SELECT parentChatId, parentMessageId FROM chat WHERE id = ?)
          """,
          arguments: ["anchor \(step)", thread]
        )
        return "anchor message edit"
      case 11:
        if let cleared = try String.fetchOne(db, sql: "SELECT peerKey FROM draft2 ORDER BY rowid DESC LIMIT 1") {
          try db.execute(sql: "DELETE FROM draft2 WHERE peerKey = ?", arguments: [cleared])
        }
        try db.execute(
          sql: """
          INSERT INTO draft2 (peerKey, text, updatedAt, revision) VALUES (?, ?, 1, 1)
          ON CONFLICT(peerKey) DO UPDATE SET text = excluded.text, revision = revision + 1
          """,
          arguments: [b % 3 == 0 ? "thread_\(spaceThreadID)" : "user_\(otherUser)", "draft \(step)"]
        )
        return "draft batch: clear one, save another"
      case 12:
        let chatID = try Int64?.fetchOne(db, sql: "SELECT chatId FROM dialog WHERE peerUserId = ?", arguments: [user]) ?? nil
        try db.execute(sql: "UPDATE dialog SET chatId = ? WHERE peerUserId = ?", arguments: [chatID == nil ? dmChat : nil, user])
        return "dialog chat link toggles"
      case 13:
        try db.execute(sql: "UPDATE chat SET peerUserId = ? WHERE id = ?", arguments: [otherUser, dmChat])
        return "DM chat peer changes"
      case 15:
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dialog WHERE id = ?)", arguments: [user]) == true {
          try db.execute(sql: "DELETE FROM dialog WHERE id = ?", arguments: [user])
          return "dialog delete"
        }
        try db.execute(sql: "INSERT INTO dialog (id, peerUserId, chatId, open) VALUES (?, ?, ?, 1)", arguments: [user, user, dmChat])
        return "dialog insert"
      case 16:
        guard let thread = threads.isEmpty ? nil : threads[b % threads.count],
              let anchor = try Row.fetchOne(db, sql: "SELECT parentChatId, parentMessageId FROM chat WHERE id = ?", arguments: [thread]),
              let parent: Int64 = anchor[0], let message: Int64 = anchor[1]
        else { return "no anchor" }
        // A chat's last message key moves off the message first, as `Message.deleteMessages` does.
        try db.execute(
          sql: """
          UPDATE chat SET lastMsgId = (SELECT MAX(messageId) FROM message WHERE chatId = ? AND messageId < ?)
          WHERE id = ? AND lastMsgId = ?
          """,
          arguments: [parent, message, parent, message]
        )
        try db.execute(sql: "DELETE FROM message WHERE chatId = ? AND messageId = ?", arguments: [parent, message])
        return "anchor message delete"
      case 17:
        let existing = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM translation WHERE chatId = ?", arguments: [dmChat]) ?? 0
        if existing > 0 {
          try db.execute(sql: "UPDATE translation SET translation = ? WHERE chatId = ?", arguments: ["tr \(step)", dmChat])
          return "translation edit"
        }
        try db.execute(
          sql: """
          INSERT INTO translation (messageId, chatId, translation, language, date)
          SELECT lastMsgId, id, ?, 'en', ? FROM chat WHERE id = ? AND lastMsgId IS NOT NULL
          """,
          arguments: ["tr \(step)", date, dmChat]
        )
        return "translation insert"
      case 18:
        try db.inSavepoint {
          try db.execute(sql: "UPDATE user SET firstName = 'Rolled back' WHERE id = ?", arguments: [otherUser])
          try db.execute(sql: "UPDATE chat SET parentChatId = NULL WHERE parentChatId IS NOT NULL")
          return .rollback
        }
        try db.execute(sql: "UPDATE dialog SET unreadCount = ? WHERE id = ?", arguments: [step, user])
        return "rolled-back savepoint and a committed unread count"
      case 19:
        try addMessage(dmChat, from: otherUser, peerUser: user)
        try db.execute(
          sql: "INSERT INTO draft2 (peerKey, text, updatedAt, revision) VALUES (?, ?, 1, 1) ON CONFLICT(peerKey) DO UPDATE SET text = excluded.text",
          arguments: ["user_\(user)", "mixed \(step)"]
        )
        try db.execute(sql: "UPDATE user SET lastName = ? WHERE id = ?", arguments: ["L\(step)", otherUser])
        return "message, draft and rename in one transaction"
      case 20:
        guard let last = try lastMessageID(dmChat),
              try Bool.fetchOne(
                db, sql: "SELECT NOT EXISTS(SELECT 1 FROM translation WHERE chatId = ? AND messageId = ?)", arguments: [dmChat, last]
              ) == true
        else { return "no message to renumber" }
        // A sent message getting its server id; the chat's last message key follows by cascade.
        try db.execute(
          sql: "UPDATE message SET messageId = ? WHERE chatId = ? AND messageId = ?",
          arguments: [10_000 + step, dmChat, last]
        )
        return "message id rewrite"
      case 21:
        guard let thread = threads.isEmpty ? nil : threads[b % threads.count], thread != replyThreadID else {
          return "no thread to delete"
        }
        try db.execute(sql: "UPDATE chat SET lastMsgId = NULL WHERE id = ?", arguments: [thread])
        try db.execute(sql: "DELETE FROM message WHERE chatId = ?", arguments: [thread])
        try db.execute(sql: "DELETE FROM dialog WHERE peerThreadId = ? OR chatId = ?", arguments: [thread, thread])
        try db.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [thread])
        return "reply thread delete"
      default:
        guard let last = try lastMessageID(dmChat),
              let previous = try Int64.fetchOne(
                db, sql: "SELECT MAX(messageId) FROM message WHERE chatId = ? AND messageId < ?", arguments: [dmChat, last]
              )
        else { return "nothing to delete" }
        try db.execute(sql: "UPDATE chat SET lastMsgId = ? WHERE id = ?", arguments: [previous, dmChat])
        try db.execute(sql: "DELETE FROM message WHERE chatId = ? AND messageId = ?", arguments: [dmChat, last])
        return "last message delete"
    }
  }

  /// A thread in a space, and a reply thread under the first DM's first message.
  private static func seedThreadsAndSpace(_ db: Database) throws {
    let date = Date(timeIntervalSince1970: 1_790_050_000)
    try Space(id: spaceID, name: "Space", date: date).insert(db)
    try Member(id: 9000, date: date, userId: 100, spaceId: spaceID, role: .owner).insert(db)
    for (id, title, spaceId, parent) in [
      (spaceThreadID, "Space thread", Optional(spaceID), Optional<(Int64, Int64)>.none),
      (replyThreadID, "Reply thread", nil, (Int64(500), Int64(1))),
    ] {
      var chat = Chat(id: id, date: date, type: .thread, title: title, spaceId: spaceId)
      chat.parentChatId = parent?.0
      chat.parentMessageId = parent?.1
      try chat.insert(db)
      try InlineKit.Message(
        messageId: 1, fromId: 101, date: date.addingTimeInterval(1), text: "\(title) message",
        peerUserId: nil, peerThreadId: id, chatId: id, out: false
      ).insert(db)
      chat.lastMsgId = 1
      try chat.update(db)
      var dialog = Dialog(optimisticForChat: chat)
      dialog.open = true
      try dialog.insert(db)
    }
  }

  private static func seed(_ db: Database) throws {
    do {
      for index in 0 ..< chatCount {
        let userID = Int64(100 + index)
        let chatID = Int64(500 + index)
        try User(id: userID, email: nil, firstName: "User \(index)").insert(db)
        var chat = Chat(
          id: chatID,
          date: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
          type: .privateChat,
          title: nil,
          spaceId: nil,
          peerUserId: userID
        )
        try chat.insert(db)
        try InlineKit.Message(
          messageId: 1, fromId: userID, date: Date(timeIntervalSince1970: 1_790_000_100), text: "hello \(index)",
          peerUserId: userID, peerThreadId: nil, chatId: chatID, out: false
        ).insert(db)
        chat.lastMsgId = 1
        try chat.update(db)
        var dialog = Dialog.previewDm
        dialog.id = Dialog.getDialogId(peerUserId: userID)
        dialog.peerUserId = userID
        dialog.chatId = chatID
        dialog.open = true
        try dialog.insert(db)
      }
    }
  }

  private static func writeKind(_ step: Int) -> String {
    ["message", "draft", "unread", "rename", "draft clear", "edit"][step % 6]
  }

  private static func write(step: Int, in database: AppDatabase) async throws {
    let index = step % chatCount
    let userID = Int64(100 + index)
    let chatID = Int64(500 + index)
    try await database.dbWriter.write { db in
      switch step % 6 {
        case 0:
          let next = (try Int64.fetchOne(db, sql: "SELECT MAX(messageId) FROM message WHERE chatId = ?", arguments: [chatID]) ?? 0) + 1
          try InlineKit.Message(
            messageId: next, fromId: userID, date: Date(timeIntervalSince1970: 1_790_001_000 + Double(step)),
            text: "message \(step)", peerUserId: userID, peerThreadId: nil, chatId: chatID, out: false
          ).insert(db)
          try db.execute(sql: "UPDATE chat SET lastMsgId = ? WHERE id = ?", arguments: [next, chatID])
        case 1:
          try db.execute(
            sql: """
            INSERT INTO draft2 (peerKey, text, updatedAt, revision) VALUES (?, ?, 1, 1)
            ON CONFLICT(peerKey) DO UPDATE SET text = excluded.text, revision = revision + 1
            """,
            arguments: ["user_\(userID)", "draft \(step)"]
          )
        case 2:
          try db.execute(sql: "UPDATE dialog SET unreadCount = ? WHERE peerUserId = ?", arguments: [step, userID])
        case 3:
          try db.execute(sql: "UPDATE user SET firstName = ? WHERE id = ?", arguments: ["Renamed \(step)", userID])
        case 4:
          try db.execute(sql: "DELETE FROM draft2 WHERE peerKey = ?", arguments: ["user_\(userID)"])
        default:
          try db.execute(
            sql: "UPDATE message SET text = ? WHERE chatId = ? AND messageId = (SELECT lastMsgId FROM chat WHERE id = ?)",
            arguments: ["edited \(step)", chatID, chatID]
          )
      }
    }
  }

  /// Waits for the writer-holding thread outside the async context.
  private static func block(on semaphore: DispatchSemaphore) {
    semaphore.wait()
  }

  private static func settle(
    _ recorder: SnapshotRecorder,
    to expected: [ChatListItemSnapshot],
    attempts: Int = 400
  ) async throws -> Bool {
    for _ in 0 ..< attempts {
      if recorder.latest == expected { return true }
      try await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  private static func fullFetch(_ database: AppDatabase, language: String? = nil) throws -> [ChatListItemSnapshot] {
    try database.dbWriter.read { db in
      try ChatListDatabaseQuery.fetchSnapshots(
        db,
        spaceID: parameters.spaceID,
        includeSpaceChatsInHome: parameters.includeSpaceChatsInHome,
        translationLanguage: language ?? parameters.translationLanguage,
        includeOpenedDate: parameters.includeOpenedDate,
        includeTimestampText: parameters.includeTimestampText
      )
    }
  }
}

private final class SnapshotRecorder: @unchecked Sendable {
  /// Serial, like the main queue and the worker queues the apps deliver on: a concurrent queue could
  /// run two deliveries out of order and leave an older list as the latest.
  let queue = DispatchQueue(label: "ChatListLiveQueryTests.delivery")
  private let lock = NSLock()
  private var _latest: [ChatListItemSnapshot] = []
  private var _smallest = Int.max
  private var _count = 0

  var latest: [ChatListItemSnapshot] { lock.withLock { _latest } }
  var smallest: Int { lock.withLock { _smallest } }
  var count: Int { lock.withLock { _count } }

  func record(_ snapshot: [ChatListItemSnapshot]) {
    lock.withLock {
      _latest = snapshot
      _smallest = min(_smallest, snapshot.count)
      _count += 1
    }
  }
}

private final class LanguageBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: String

  init(_ value: String) { _value = value }

  var value: String {
    get { lock.withLock { _value } }
    set { lock.withLock { _value = newValue } }
  }
}

/// Holds one refresh in the language provider, which runs on the live query's queue.
private final class RefreshGate: @unchecked Sendable {
  private let lock = NSLock()
  private var armed = false
  private let held = DispatchSemaphore(value: 0)
  private let released = DispatchSemaphore(value: 0)

  func arm() { lock.withLock { armed = true } }

  func pass() {
    let shouldHold = lock.withLock { () -> Bool in
      defer { armed = false }
      return armed
    }
    guard shouldHold else { return }
    held.signal()
    released.wait()
  }

  func waitUntilHeld() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: self.held.wait(timeout: .now() + 5) == .success)
      }
    }
  }

  func release() { released.signal() }
}

/// Deterministic random numbers for the mixed-write test.
private struct MixedWriteRandom {
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

private final class ChangeLog: @unchecked Sendable {
  private let lock = NSLock()
  private var changes: [ChatListChange] = []
  var all: [ChatListChange] { lock.withLock { changes } }
  func append(_ change: ChatListChange) { lock.withLock { changes.append(change) } }
}
