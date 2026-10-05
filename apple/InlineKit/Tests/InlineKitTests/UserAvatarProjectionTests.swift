import Combine
import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import Auth
@testable import InlineKit

@Suite("Loaded user avatar projections")
@MainActor
struct UserAvatarProjectionTests {
  private let account = AuthAccountMutationToken(generation: 1, userID: 42)

  @Test("same photo URL renewal and local attachment update only matching loaded rows")
  func changedSources() async throws {
    let database = AppDatabase.empty()
    let publisher = MessagesPublisher(database: database, validateAvatarAccount: { _ in })
    let original = user(id: 1, source: "old")
    let untouched = message(id: 2, sender: user(id: 2, source: "other"))
    let model = model(database: database, publisher: publisher, messages: [message(id: 1, sender: original), untouched])
    defer { model.dispose() }
    var changes: [[Int64]] = []
    model.observe { change in
      guard case let .updated(rows, indices, animated) = change else {
        Issue.record("Avatar change triggered a history reload or structural mutation")
        return
      }
      #expect(indices == [0])
      #expect(animated == false)
      changes.append(rows.map(\.id))
    }
    var refreshed = original
    refreshed.profileCdnUrl = "https://example.invalid/new"
    let refreshedValue = refreshed
    try await database.dbWriter.write { db in try refreshedValue.save(db) }
    await publisher.userAvatarChanged(userID: 1, accountToken: account)
    #expect(model.messages[0].senderInfo?.user.profileCdnUrl == refreshed.profileCdnUrl)
    #expect(model.messages[0].senderInfo?.stableAvatarIdentity == "unique:photo-1")
    #expect(model.messages[1] == untouched)
    #expect(model.messages[0].message == message(id: 1, sender: original).message)

    try await database.dbWriter.write { db in
      _ = try User.storeCachedProfilePhoto(
        db, userId: 1, localPath: "ready.png",
        expectedSourceURL: refreshedValue.getRemoteURL(),
        expectedAvatarIdentity: refreshedValue.stableAvatarIdentity
      )
    }
    await publisher.userAvatarChanged(userID: 1, accountToken: account)
    #expect(model.messages[0].senderInfo?.user.profileLocalPath == "ready.png")
    #expect(model.messages[1] == untouched)
    #expect(changes == [[1], [1]])
    await publisher.userAvatarChanged(userID: 1, accountToken: account)
    #expect(changes.count == 2)
  }

  @Test("name-only saves and equivalent sources do not invalidate any loaded rows")
  func equivalentSources() async throws {
    let database = AppDatabase.empty()
    let publisher = MessagesPublisher(database: database, validateAvatarAccount: { _ in })
    let original = user(id: 1, source: "same")
    let row = message(id: 1, sender: original)
    let model = model(database: database, publisher: publisher, messages: [row])
    defer { model.dispose() }
    var invalidations = 0
    model.observe { _ in invalidations += 1 }
    try await database.dbWriter.write { db in try original.save(db) }
    // The real protocol save changes a non-avatar field while retaining the source.
    let protocolUser = InlineProtocol.User.with {
      $0.id = 1
      $0.min = true
      $0.firstName = "Renamed"
      $0.profilePhoto = .with {
        $0.cdnURL = original.profileCdnUrl!
        $0.fileUniqueID = original.profileFileUniqueId!
      }
    }
    _ = try await database.dbWriter.write { db in try User.save(db, user: protocolUser) }
    await publisher.userAvatarChanged(userID: 1, accountToken: account)
    await publisher.userAvatarChanged(userID: 1, accountToken: account)
    #expect(invalidations == 0)
    #expect(model.messages == [row])
  }

  @Test("committed final source wins over intermediate values and rollback publishes nothing")
  func transactionBoundary() async throws {
    let database = AppDatabase.empty()
    let publisher = MessagesPublisher(database: database, validateAvatarAccount: { _ in })
    let original = user(id: 1, source: "original")
    let model = model(database: database, publisher: publisher, messages: [message(id: 1, sender: original)])
    defer { model.dispose() }
    let token = account
    let publish: @MainActor @Sendable (Int64, AuthAccountMutationToken) async -> Void = {
      await publisher.userAvatarChanged(userID: $0, accountToken: $1)
    }
    try await database.dbWriter.write { db in try original.save(db) }
    enum Rollback: Error { case requested }
    do {
      try await database.dbWriter.write { db in
        try User.filter(id: 1).updateAll(db, User.Columns.profileCdnUrl.set(to: "https://example.invalid/rolled-back"))
        MessagesPublisher.publishUserAvatarChangeAfterCommit(db, userID: 1, accountToken: token, publish: publish)
        throw Rollback.requested
      }
    } catch Rollback.requested {}
    for _ in 0 ..< 10 { await Task.yield() }
    #expect(model.messages[0].senderInfo?.user.profileCdnUrl == original.profileCdnUrl)

    try await database.dbWriter.write { db in
      try User.filter(id: 1).updateAll(db, User.Columns.profileCdnUrl.set(to: "https://example.invalid/intermediate"))
      MessagesPublisher.publishUserAvatarChangeAfterCommit(db, userID: 1, accountToken: token, publish: publish)
      try User.filter(id: 1).updateAll(db, User.Columns.profileCdnUrl.set(to: "https://example.invalid/final"))
    }
    for _ in 0 ..< 100 where model.messages[0].senderInfo?.user.profileCdnUrl != "https://example.invalid/final" {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.messages[0].senderInfo?.user.profileCdnUrl == "https://example.invalid/final")
  }

  @Test("publication rejects old account work and cannot alter another account's model")
  func accountFence() async throws {
    let database = AppDatabase.empty()
    enum Expired: Error { case token }
    let publisher = MessagesPublisher(database: database, validateAvatarAccount: { _ in throw Expired.token })
    let original = user(id: 1, source: "original")
    let staleModel = model(database: database, publisher: publisher, messages: [message(id: 1, sender: original)])
    let nextModel = model(database: database, publisher: publisher, messages: [message(id: 1, sender: original)], accountID: 43)
    defer { staleModel.dispose(); nextModel.dispose() }
    let replacement = user(id: 1, source: "replacement")
    try await database.dbWriter.write { db in try replacement.save(db) }
    await publisher.userAvatarChanged(userID: 1, accountToken: account)
    #expect(staleModel.messages[0].senderInfo?.user.profileCdnUrl == original.profileCdnUrl)
    publisher.publisher.send(.userAvatar(UserInfo(user: replacement), accountUserID: 42))
    #expect(staleModel.messages[0].senderInfo?.user.profileCdnUrl == replacement.profileCdnUrl)
    #expect(nextModel.messages[0].senderInfo?.user.profileCdnUrl == original.profileCdnUrl)
  }

  @Test("async message publication cannot overwrite a newer avatar", arguments: [false, true])
  func asyncMessagePublication(add: Bool) async throws {
    let gate = AvatarQueryGate()
    var configuration = AppDatabase.makeConfiguration(passphrase: "avatar-test")
    configuration.prepareDatabase { db in
      db.trace(options: .profile) { event in
        if case let .profile(statement, _) = event,
           statement.sql.contains("FROM \"message\""), statement.sql.contains("\"user\"") {
          gate.pauseOnce()
        }
      }
    }
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("avatar-projection-\(UUID().uuidString).sqlite").path
    let database = try AppDatabase(DatabasePool(path: path, configuration: configuration))
    let publisher = MessagesPublisher(database: database, validateAvatarAccount: { _ in })
    let original = user(id: 1, source: "old")
    let row = message(id: 1, sender: original)
    try await database.dbWriter.write { db in
      try original.insert(db)
      try Chat(id: 10, date: Date(), type: .thread, title: "Fixture", spaceId: nil).insert(db)
      try row.message.insert(db)
    }
    let model = model(database: database, publisher: publisher, messages: add ? [] : [row])
    defer { model.dispose(); gate.release() }
    gate.arm()
    let publication = Task {
      if add {
        await publisher.messageAdded(message: row.message, peer: .thread(id: 10))
      } else {
        await publisher.messageUpdated(message: row.message, peer: .thread(id: 10), animated: false)
      }
    }
    for _ in 0 ..< 200 where !gate.didPause { try await Task.sleep(for: .milliseconds(5)) }
    #expect(gate.didPause)
    try await database.dbWriter.write { db in
      try User.filter(id: 1).updateAll(db, User.Columns.profileCdnUrl.set(to: "https://example.invalid/new"))
    }
    await publisher.userAvatarChanged(userID: 1, accountToken: account)
    gate.release()
    await publication.value
    #expect(!gate.didTimeout)
    #expect(model.messages.count == 1)
    #expect(model.messages[0].senderInfo?.user.profileCdnUrl == "https://example.invalid/new")
  }

  @Test("an avatar event during a history read refreshes that snapshot before admission")
  func staleHistorySnapshot() async throws {
    let database = AppDatabase.empty()
    let publisher = MessagesPublisher(database: database, validateAvatarAccount: { _ in })
    let old = user(id: 1, source: "old")
    let staleSnapshot = [message(id: 1, sender: old)]
    // This user is not yet in the loaded window, so the event changes no visible row.
    let model = model(database: database, publisher: publisher, messages: [])
    defer { model.dispose() }
    var latest = user(id: 1, source: "new")
    latest.profileFileUniqueId = "replacement"
    latest.profileLocalPath = "persisted.png"
    let persisted = latest
    try await database.dbWriter.write { db in try persisted.save(db) }
    let unchanged = try await model.refreshingAvatarSources(in: staleSnapshot, since: 0)
    #expect(unchanged == staleSnapshot)
    await publisher.userAvatarChanged(userID: 1, accountToken: account)
    let admitted = try await model.refreshingAvatarSources(in: staleSnapshot, since: 0)
    #expect(admitted[0].senderInfo?.stableAvatarIdentity == "unique:replacement")
    #expect(admitted[0].senderInfo?.user.profileLocalPath == "persisted.png")
    #expect(admitted[0].message == staleSnapshot[0].message)
  }

  @Test("avatar replacement refreshes embedded projections and prepared thread anchor")
  func embeddedAndAnchor() throws {
    let database = AppDatabase.empty()
    let publisher = MessagesPublisher(database: database, validateAvatarAccount: { _ in })
    let original = user(id: 1, source: "old")
    var row = message(id: 2, sender: user(id: 2, source: "other"))
    row.repliedToMessage = EmbeddedMessage(message: message(id: 3, sender: original).message, senderInfo: UserInfo(user: original))
    row.forwardFromUserInfo = UserInfo(user: original)
    let model = model(database: database, publisher: publisher, messages: [row], anchor: message(id: 1, sender: original))
    defer { model.dispose() }
    var replacement = user(id: 1, source: "replacement")
    replacement.profileFileUniqueId = "photo-B"
    replacement.profileLocalPath = "persisted-B.png"
    publisher.publisher.send(.userAvatar(UserInfo(user: replacement), accountUserID: 42))
    #expect(model.threadAnchor?.senderInfo?.stableAvatarIdentity == "unique:photo-B")
    #expect(model.threadAnchor?.senderInfo?.user.profileLocalPath == "persisted-B.png")
    #expect(model.messages[0].repliedToMessage?.senderInfo?.user.profileLocalPath == "persisted-B.png")
    #expect(model.messages[0].forwardFromUserInfo?.stableAvatarIdentity == "unique:photo-B")
    #expect(model.messages[0].senderInfo == row.senderInfo)
  }

  private func user(id: Int64, source: String) -> User {
    var user = User(id: id, email: nil, firstName: "User")
    user.profileFileUniqueId = "photo-\(id)"
    user.profileCdnUrl = "https://example.invalid/\(source)"
    return user
  }

  private func message(id: Int64, sender: User) -> FullMessage {
    var record = Message(
      messageId: id, fromId: sender.id, date: Date(timeIntervalSince1970: 100),
      text: "Fixture", peerUserId: nil, peerThreadId: 10, chatId: 10
    )
    record.globalId = id
    return FullMessage(
      senderInfo: UserInfo(user: sender),
      message: record,
      reactions: [], repliedToMessage: nil, attachments: []
    )
  }

  private func model(
    database: AppDatabase,
    publisher: MessagesPublisher,
    messages: [FullMessage],
    anchor: FullMessage? = nil,
    accountID: Int64 = 42
  ) -> MessagesProgressiveViewModel {
    MessagesProgressiveViewModel(
      peer: .thread(id: 10),
      initialState: .init(
        messages: messages, threadAnchor: anchor,
        loadedWindowMetadata: .init(messages: messages, holes: [])
      ),
      database: database, publisher: publisher, currentUserId: accountID
    )
  }
}

/// Pause a real full-message SQL result while WAL admits the newer user-source commit.
private final class AvatarQueryGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var armed = false
  private var paused = false
  private var timedOut = false

  var didTimeout: Bool { lock.withLock { timedOut } }
  var didPause: Bool { lock.withLock { paused } }
  func arm() { lock.withLock { armed = true } }
  func release() { semaphore.signal() }
  func pauseOnce() {
    let shouldPause = lock.withLock {
      guard armed else { return false }
      armed = false
      paused = true
      return true
    }
    if shouldPause, semaphore.wait(timeout: .now() + 5) == .timedOut {
      lock.withLock { timedOut = true }
    }
  }
}
