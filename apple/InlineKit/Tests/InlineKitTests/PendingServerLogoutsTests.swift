import Foundation
@testable import InlineKit
import Testing

private final class MemoryPendingLogoutStorage: PendingServerLogoutStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [PendingServerLogouts.Entry] = []
  var tokens: [String] { lock.withLock { entries.map(\.token) } }
  func load() -> [PendingServerLogouts.Entry] { lock.withLock { entries } }
  func save(_ entries: [PendingServerLogouts.Entry]) -> Bool {
    lock.withLock { self.entries = entries }
    return true
  }
}

private final class SignOutScript: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [String: Error?] = [:]
  private(set) var calls: [String] = []
  func set(_ token: String, _ error: Error?) { lock.withLock { results[token] = error } }
  func call(_ token: String) throws {
    let error = lock.withLock { () -> Error? in
      calls.append(token)
      return results[token] ?? nil
    }
    if let error { throw error }
  }
}

@Suite("Pending server logouts")
struct PendingServerLogoutsTests {
  @Test("keeps a token until the server answers for it")
  func retriesUntilAnswered() async {
    let storage = MemoryPendingLogoutStorage()
    let script = SignOutScript()
    let logouts = PendingServerLogouts(storage: storage, signOut: { try script.call($0) })

    script.set("offline", APIError.networkError)
    script.set("revoked", APIError.httpError(statusCode: 401))
    await logouts.enqueue(token: "offline")
    await logouts.enqueue(token: "revoked")
    await logouts.enqueue(token: "revoked")
    await logouts.drain()
    // An already revoked session is settled; a transport failure is retried later.
    #expect(storage.tokens == ["offline"])

    script.set("offline", nil)
    await logouts.drain()
    #expect(storage.tokens.isEmpty)
  }

  @Test("stops retrying tokens older than the retry window")
  func expiresOldTokens() async {
    let storage = MemoryPendingLogoutStorage()
    let script = SignOutScript()
    script.set("old", APIError.networkError)
    let start = Date()
    let clock = Clock(start)
    let logouts = PendingServerLogouts(storage: storage, signOut: { try script.call($0) }, now: { clock.now })
    await logouts.enqueue(token: "old")
    clock.now = start.addingTimeInterval(PendingServerLogouts.maximumAge + 1)
    await logouts.drain()
    #expect(storage.tokens.isEmpty)
  }

  @Test("server errors and rate limits are retried; client errors are settled")
  func classification() {
    #expect(!PendingServerLogouts.serverAnswered(APIError.networkError))
    #expect(!PendingServerLogouts.serverAnswered(APIError.rateLimited))
    #expect(!PendingServerLogouts.serverAnswered(APIError.httpError(statusCode: 503)))
    #expect(!PendingServerLogouts.serverAnswered(URLError(.timedOut)))
    #expect(PendingServerLogouts.serverAnswered(APIError.httpError(statusCode: 401)))
    let unauthorized = APIError.error(error: "UNAUTHORIZED", errorCode: 401, description: nil)
    #expect(PendingServerLogouts.serverAnswered(unauthorized))
  }
}

private final class Clock: @unchecked Sendable {
  var now: Date
  init(_ now: Date) { self.now = now }
}
