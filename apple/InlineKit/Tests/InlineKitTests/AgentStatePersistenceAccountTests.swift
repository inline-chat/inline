import Foundation
import GRDB
import InlineProtocol
import os
import Testing

@testable import Auth
@testable import InlineKit

@Suite("Agent state persistence account fences", .serialized)
struct AgentStatePersistenceAccountTests {
  enum Mutation: CaseIterable, Sendable { case save, remove, clear }

  @Test("a write queued behind the database cannot affect a replacement account", arguments: Mutation.allCases)
  @MainActor
  func staleWriteIsRejected(_ mutation: Mutation) async throws {
    let initial = AuthSnapshot(status: .authenticated(AuthCredentials(userId: 42, token: "test")), didHydrate: true)
    let cache = AuthSnapshotCache(initial: initial)
    let authStore = AuthStore(cache: cache, mocked: true, namespace: UUID().uuidString,
                              readSnapshot: { @Sendable _, _, _ in initial })
    let auth = AuthHandle(cache: cache, store: authStore)
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "test"))
    let database = try AppDatabase(queue)
    let store = AgentWorkStateStore(database: database, auth: auth)
    let key = AgentWorkState.Key(peer: .thread(id: 7), botUserID: 9)
    let value = AgentWorkState(key: key, sessionID: 3, runState: .working, revision: 1)
    let replacementPayload = try JSONEncoder().encode(value)
    let storageKey = key.storageKey
    store.apply(value)
    try await Task.sleep(for: .milliseconds(100))

    // Hold the actual database writer while a detached store mutation queues.
    let entered = OSAllocatedUnfairLock(initialState: false)
    let release = DispatchSemaphore(value: 0)
    let held = Task.detached {
      try await queue.write { db in
        entered.withLock { $0 = true }
        release.wait()
        // Simulate the new account's projection, in the writer before old work resumes.
        try db.execute(sql: "DELETE FROM agentClientState")
        try db.execute(sql: "INSERT INTO agentClientState (kind, key, payload) VALUES (?, ?, ?)",
                       arguments: ["session", storageKey, replacementPayload])
      }
    }
    while !entered.withLock({ $0 }) { await Task.yield() }
    switch mutation {
    case .save: store.apply(AgentWorkState(key: key, sessionID: 3, runState: .idle, revision: 2))
    case .remove: store.remove(key)
    case .clear: store.removeAll()
    }
    let logout = cache.beginLogout()
    #expect(cache.completeLogout(logout, snapshot: AuthSnapshot(status: .unauthenticated, didHydrate: true), publish: {}))
    release.signal()
    try await held.value
    try await Task.sleep(for: .milliseconds(100))
    let payloads = try await queue.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM agentClientState") }
    #expect(payloads == [replacementPayload])
  }
}
