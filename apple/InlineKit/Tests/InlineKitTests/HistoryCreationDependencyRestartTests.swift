import AsyncAlgorithms
import Foundation
import GRDB
import InlineProtocol
import protocol RealtimeV2.Transport
import Testing

@testable import Auth
@testable import InlineKit
@testable import RealtimeV2

@Suite("History creation dependency restart", .serialized)
struct HistoryCreationDependencyRestartTests {
  @Test("a reopened pending shell with no durable creation settles history while offline")
  func orphanedPendingHistoryTimesOutOffline() async throws {
    let auth = Auth.mocked(authenticated: true)
    let account = try auth.handle.beginAccountMutation()
    let fixture = try RestartFixture(accountID: account.userID)
    defer { fixture.removeFiles() }
    let database = try fixture.reopen()
    let before = try await fixture.snapshot(database)
    #expect(before.chat?.createState == .pending)
    #expect(before.dialog != nil)
    #expect(before.messages.map(\.messageId) == [-123])
    #expect(before.messages.first?.status == .sending)
    #expect(before.draft == "Recovery draft")
    #expect(before.draftRevision == 1)
    #expect(before.holes == [.init(chatId: 70, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax)])
    let owner = TransactionOwner(accountID: account.userID, generation: account.generation)
    #expect(try await fixture.persistence.loadTransactions(for: owner).isEmpty)
    #expect(await ChatTransactionBlockerResolver(database: database).state(for: .chatCreated(chatId: 70)) == .blocked)

    let transport = OfflineHistoryTransport()
    let realtime = RealtimeV2(
      transport: transport, auth: auth.handle, applyUpdates: HistoryTestApplyUpdates(),
      syncStorage: HistoryTestSyncStorage(), persistenceHandler: fixture.persistence,
      blockerResolver: ChatTransactionBlockerResolver(database: database)
    )
    var history = GetChatHistoryTransaction(peer: .thread(id: 70))
    #expect(history.dependencyTimeout == .seconds(30))
    history.dependencyTimeout = .milliseconds(50)
    let send = Task { try await realtime.send(history) }
    let watchdog = cancelIfStalled(send)
    defer { watchdog.cancel() }
    do {
      _ = try await send.value
      Issue.record("Unresolved history must fail at its dependency deadline")
    } catch let error as TransactionError2 {
      switch error {
        case .timeout: break
        default: Issue.record(error)
      }
    } catch { Issue.record(error) }

    #expect(await transport.rpcCount == 0)
    #expect(try await fixture.snapshot(database) == before)
    #expect(try await fixture.persistence.loadTransactions(for: owner).isEmpty)
    await realtime.loggedOut()
  }

  @Test("ready history stays pending offline after the actual dependency timer fires", .timeLimit(.minutes(1)))
  func readyHistoryDoesNotExpireOffline() async throws {
    let auth = Auth.mocked(authenticated: true)
    let account = try auth.handle.beginAccountMutation()
    let fixture = try RestartFixture(accountID: account.userID)
    defer { fixture.removeFiles() }
    let database = try fixture.reopen()
    try await fixture.confirmCreation(database)
    let before = try await fixture.snapshot(database)
    let resolver = HeldHistoryResolver(database: database)
    let transport = OfflineHistoryTransport()
    let realtime = RealtimeV2(
      transport: transport, auth: auth.handle, applyUpdates: HistoryTestApplyUpdates(),
      syncStorage: HistoryTestSyncStorage(), blockerResolver: resolver
    )
    var history = GetChatHistoryTransaction(peer: .thread(id: 70))
    history.dependencyTimeout = .milliseconds(50)
    let send = Task { try await realtime.send(history) }
    let watchdog = cancelIfStalled(send)
    defer { watchdog.cancel() }
    // Offline dispatch never reads blockers; this arrival proves the real
    // dependency deadline fired, rather than relying on queue polling.
    defer { Task { await resolver.release() } }
    try await resolver.waitUntilReadCaptured()
    await resolver.release()
    try await Task.sleep(for: .milliseconds(50))
    send.cancel()
    await #expect(throws: CancellationError.self) { _ = try await send.value }
    #expect(await transport.rpcCount == 0)
    #expect(try await fixture.snapshot(database) == before)
    await realtime.loggedOut()
  }

  @Test("a persisted creation restores once and still precedes its history")
  func persistedCreationRestoresBeforeHistory() async throws {
    let fixture = try RestartFixture(accountID: 101)
    defer { fixture.removeFiles() }
    let originalOwner = TransactionOwner(accountID: 101, generation: 1)
    let restartedOwner = TransactionOwner(accountID: 101, generation: 2)
    let creation = TransactionWrapper(id: .generate(), date: Date(), transaction: fixture.creation)
    try await fixture.persistence.saveTransaction(creation, for: originalOwner)
    let database = try fixture.reopen()
    let transactions = Transactions(
      persistenceHandler: fixture.persistence, blockerResolver: ChatTransactionBlockerResolver(database: database)
    )
    await transactions.activate(owner: restartedOwner)
    let restored = try await fixture.persistence.loadTransactions(for: restartedOwner)
    #expect(restored.map(\.id) == [creation.id])
    let historyID = try #require(await transactions.queue(
      transaction: GetChatHistoryTransaction(peer: .thread(id: 70)), owner: restartedOwner
    ))
    guard case let .ready(first)? = await transactions.dequeue(owner: restartedOwner) else {
      Issue.record("Restored creation must be ready before history")
      return
    }
    #expect(first.id == creation.id)
    #expect(first.transaction is CreateChatTransaction)
    #expect(await transactions.dequeue(owner: restartedOwner) == nil)

    try await fixture.confirmCreation(database)
    await transactions.satisfy(blockers: first.transaction.satisfiedBlockersOnSuccess)
    await transactions.finishExecution(for: first)
    #expect(await transactions.failUnresolvedDependency(transactionId: historyID, owner: restartedOwner) == nil)
    guard case let .ready(next)? = await transactions.dequeue(owner: restartedOwner) else {
      Issue.record("Successful creation must release history")
      return
    }
    #expect(next.id == historyID)
  }

  @Test("dependency failure bypasses dispatch pressure without changing the shell")
  func dependencyFailureDoesNotNeedCapacity() async throws {
    let fixture = try RestartFixture(accountID: 101)
    defer { fixture.removeFiles() }
    let database = try fixture.reopen()
    let before = try await fixture.snapshot(database)
    let owner = TransactionOwner(accountID: 101, generation: 2)
    let transactions = Transactions(blockerResolver: ChatTransactionBlockerResolver(database: database))
    await transactions.activate(owner: owner)
    let id = try #require(await transactions.queue(transaction: GetChatHistoryTransaction(peer: .thread(id: 70)), owner: owner))
    guard case .capacityLimited? = await transactions.dequeue(owner: owner, maximumOutstanding: 0) else {
      Issue.record("The control must have no dispatch capacity")
      return
    }
    let failure = try #require(await transactions.failUnresolvedDependency(transactionId: id, owner: owner))
    #expect(failure.wrapper.id == id)
    guard case .timeout = failure.error else {
      Issue.record("Unresolved creation must report a dependency timeout")
      return
    }
    #expect(await transactions.isInQueue(transactionId: id) == false)
    #expect(try await fixture.snapshot(database) == before)
  }

  @Test("canonical, in-flight and requeued history survive dependency expiry")
  func resolvedHistoryKeepsNormalQueueBehavior() async throws {
    let fixture = try RestartFixture(accountID: 101)
    defer { fixture.removeFiles() }
    let database = try fixture.reopen()
    try await fixture.confirmCreation(database)
    let owner = TransactionOwner(accountID: 101, generation: 2)
    let transactions = Transactions(blockerResolver: ChatTransactionBlockerResolver(database: database))
    await transactions.activate(owner: owner)
    let id = try #require(await transactions.queue(transaction: GetChatHistoryTransaction(peer: .thread(id: 70)), owner: owner))
    #expect(await transactions.failUnresolvedDependency(transactionId: id, owner: owner) == nil)
    #expect(await transactions.isInQueue(transactionId: id))
    guard case .ready? = await transactions.dequeue(owner: owner) else {
      Issue.record("Canonical history must dispatch normally")
      return
    }
    #expect(await transactions.failUnresolvedDependency(transactionId: id, owner: owner) == nil)
    #expect(await transactions.isInFlight(transactionId: id))
    await transactions.requeueBeforeDispatch(transactionId: id, signal: false)
    #expect(await transactions.failUnresolvedDependency(transactionId: id, owner: owner) == nil)
    #expect(await transactions.isInQueue(transactionId: id))
  }

  @Test("creation success wins over a suspended read of its earlier pending state")
  func successfulCreationWinsPendingReadRace() async throws {
    let fixture = try RestartFixture(accountID: 101)
    defer { fixture.removeFiles() }
    let database = try fixture.reopen()
    let resolver = HeldHistoryResolver(database: database)
    let owner = TransactionOwner(accountID: 101, generation: 2)
    let transactions = Transactions(blockerResolver: resolver)
    await transactions.activate(owner: owner)
    let id = try #require(await transactions.queue(transaction: GetChatHistoryTransaction(peer: .thread(id: 70)), owner: owner))
    let expiry = Task { await transactions.failUnresolvedDependency(transactionId: id, owner: owner) }
    defer { Task { await resolver.release() } }
    try await resolver.waitUntilReadCaptured()
    try await fixture.confirmCreation(database)
    await transactions.satisfy(blockers: [.chatCreated(chatId: 70)])
    await resolver.release()
    #expect(await expiry.value == nil)
    #expect(await transactions.isInQueue(transactionId: id))
    guard case let .ready(wrapper)? = await transactions.dequeue(owner: owner) else {
      Issue.record("Success during the held pending read must release history")
      return
    }
    #expect(wrapper.id == id)
  }

  @Test("owner reset fences a suspended expiry and its blocker cache")
  func ownerResetFencesSuspendedExpiry() async throws {
    let fixture = try RestartFixture(accountID: 101)
    defer { fixture.removeFiles() }
    let database = try fixture.reopen()
    let before = try await fixture.snapshot(database)
    let resolver = HeldHistoryResolver(database: database)
    let ownerA = TransactionOwner(accountID: 101, generation: 2)
    let ownerB = TransactionOwner(accountID: 202, generation: 3)
    let transactions = Transactions(blockerResolver: resolver)
    await transactions.activate(owner: ownerA)
    let idA = try #require(await transactions.queue(transaction: GetChatHistoryTransaction(peer: .thread(id: 70)), owner: ownerA))
    let expiry = Task { await transactions.failUnresolvedDependency(transactionId: idA, owner: ownerA) }
    defer { Task { await resolver.release() } }
    try await resolver.waitUntilReadCaptured()
    await transactions.reset(owner: ownerA, deletePersisted: true)
    await transactions.activate(owner: ownerB)
    // A stale satisfied read must not populate the new owner's blocker cache.
    await resolver.release(override: .satisfied)
    #expect(await expiry.value == nil)
    let idB = try #require(await transactions.queue(transaction: GetChatHistoryTransaction(peer: .thread(id: 70)), owner: ownerB))
    #expect(await transactions.dequeue(owner: ownerB) == nil)
    #expect(await transactions.isInQueue(transactionId: idB))
    #expect(try await fixture.snapshot(database) == before)
  }
}

private struct RestartFixture {
  let root: URL
  let creation = CreateChatTransaction(
    title: nil, placeholderTitle: "Pending thread", emoji: nil, isPublic: false,
    spaceId: nil, participants: [], reservedChatId: 70
  )

  var persistence: DefaultTransactionPersistenceHandler {
    .init(baseDirectory: root.appendingPathComponent("queue", isDirectory: true))
  }

  init(accountID: Int64) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-history-restart-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Execute the actual atomic optimistic write, then close the writer before
    // the separate durable queue write: the process-death boundary under test.
    let database = try reopen()
    try database.dbWriter.write { db in
      try User(id: accountID, email: nil, firstName: "Author").insert(db)
      try creation.saveOptimisticState(db, currentUserId: accountID)
      var message = Message(
        messageId: -123, randomId: 123, fromId: accountID, date: Date(), text: "First message",
        peerUserId: nil, peerThreadId: 70, chatId: 70, out: true, status: .sending
      )
      try message.saveMessage(db)
      try Chat.updateLastMsgId(db, chatId: 70, lastMsgId: message.messageId, date: message.date)
      try Drafts2Row(snapshot: .init(peer: .thread(id: 70), text: "Recovery draft", revision: 1)).save(db)
      try MessageHistoryCoverageStore.invalidate(db, chatId: 70)
    }
  }

  func reopen() throws -> AppDatabase {
    try AppDatabase(DatabaseQueue(path: root.appendingPathComponent("chat.sqlite").path,
                                 configuration: AppDatabase.makeConfiguration(passphrase: "123")))
  }

  func removeFiles() { try? FileManager.default.removeItem(at: root) }

  func confirmCreation(_ database: AppDatabase) async throws {
    try await database.dbWriter.write { db in
      var chat = try #require(try Chat.fetchOne(db, key: 70))
      chat.createState = nil
      try chat.save(db)
    }
  }

  struct Snapshot: Equatable, Sendable {
    let chat: InlineKit.Chat?
    let dialog: InlineKit.Dialog?
    let messages: [InlineKit.Message]
    let draft: String?
    let draftRevision: Int64?
    let holes: [MessageHistoryHole]
  }

  func snapshot(_ database: AppDatabase) async throws -> Snapshot {
    try await database.reader.read { db in
      let draft = try Drafts2Row.fetchOne(db, key: Peer.thread(id: 70).toString())
      return Snapshot(
        chat: try Chat.fetchOne(db, key: 70),
        dialog: try Dialog.fetchOne(db, key: Dialog.getDialogId(peerThreadId: 70)),
        messages: try Message.filter(Column("chatId") == 70).fetchAll(db),
        draft: draft?.text, draftRevision: draft?.revision,
        holes: try MessageHistoryCoverageStore.holes(db, chatId: 70)
      )
    }
  }
}

private actor HeldHistoryResolver: TransactionBlockerResolver {
  private let resolver: ChatTransactionBlockerResolver
  private var captured = false
  private var released = false
  private var gate: CheckedContinuation<TransactionBlockerState?, Never>?

  init(database: AppDatabase) { resolver = .init(database: database) }

  func state(for blocker: TransactionBlocker) async -> TransactionBlockerState {
    let state = await resolver.state(for: blocker)
    guard !captured, !released else { return state }
    captured = true
    let override = await withCheckedContinuation { gate = $0 }
    return override ?? state
  }

  func waitUntilReadCaptured() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !captured, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    _ = try #require(captured, "Dependency resolution never reached the held database read")
  }

  func release(override: TransactionBlockerState? = nil) {
    released = true
    gate?.resume(returning: override)
    gate = nil
  }
}

private func cancelIfStalled<T: Sendable>(_ task: Task<T, any Error>) -> Task<Void, Never> {
  Task {
    do { try await Task.sleep(for: .seconds(10)) } catch { return }
    task.cancel()
  }
}

private actor OfflineHistoryTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  private(set) var rpcCount = 0
  func start() async { await events.send(.connecting) }
  func stop() async { await events.send(.disconnected(errorDescription: "offline")) }
  func send(_ message: ClientMessage) async throws {
    if case .rpcCall = message.body { rpcCount += 1 }
  }
}

private actor HistoryTestApplyUpdates: ApplyUpdates {
  func apply(updates: [InlineProtocol.Update], source: UpdateApplySource,
             sidecars: InlineProtocol.UpdateSidecars?) async -> UpdateApplyResult { .success(count: updates.count) }
}

private actor HistoryTestSyncStorage: SyncStorage {
  func canonicalPeer(forChatID chatID: Int64) -> InlineProtocol.Peer? { .with { $0.chat.chatID = chatID } }
  func getState() -> SyncState { .init(lastSyncDate: 0) }
  func setState(_ state: SyncState) -> Bool { true }
  func getBucketState(for key: BucketKey) -> BucketState { .init(date: 0, seq: 0) }
  func setBucketState(for key: BucketKey, state: BucketState) -> Bool { true }
  func advanceBucketState(for key: BucketKey, state: BucketState) -> BucketState? { state }
  func removeBucketState(for key: BucketKey) -> Bool { true }
  func setBucketStates(states: [BucketKey: BucketState]) -> Bool { true }
  func clearSyncState() -> Bool { true }
}
