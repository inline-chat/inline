import AsyncAlgorithms
@testable import Auth
import Foundation
import InlineProtocol
@testable import RealtimeV2
import Testing

@Suite("V3 carrier account authority", .serialized)
struct InlineProtocolV3AuthorityFenceTests {
  @Test("late live revocation cannot invalidate a replacement bearer or native session", arguments: [false, true])
  func lateRevocationPreservesReplacement(native: Bool) async throws {
    let fixture = try await fixture(native: native)
    let transport = InlineProtocolV3Transport(auth: fixture.auth.handle)
    let events = AuthorityFenceEvents()
    let observer = observe(transport, events: events)
    defer { observer.cancel() }
    let termination = AuthorityFenceTermination()
    let callback = Task {
      await transport.handleConnectionClosure(generation: 0, authority: fixture.authority) {
        await termination.read()
      }
    }
    await termination.waitUntilReading()

    if native {
      var replacement = fixture.credentials
      replacement.accountSessionId += 1
      replacement.permanent = try key(byte: 4)
      try await fixture.auth.handle.saveInlineProtocolCredentials(replacement)
    } else {
      try await fixture.auth.saveCredentials(
        token: "\(fixture.source.userId):replacement", userId: fixture.source.userId
      )
    }
    let replacement = fixture.auth.handle.snapshot()
    await termination.finish(.sessionRevoked)
    await callback.value

    // These are the actual transport events consumed by ProtocolSession, not a test of a
    // comparison helper. Neither a terminal auth event nor an old disconnect may escape.
    #expect(await events.values.isEmpty)
    #expect(fixture.auth.handle.snapshot() == replacement)
    #expect(fixture.auth.handle.snapshot().isLoggedIn)
    #expect(!fixture.auth.handle.hasPendingAccountTransition())
  }

  @Test("a current revoked carrier still emits the terminal auth event followed by disconnect")
  func currentRevocationStillInvalidates() async throws {
    let fixture = try await fixture(native: false)
    let transport = InlineProtocolV3Transport(auth: fixture.auth.handle)
    let events = AuthorityFenceEvents()
    let observer = observe(transport, events: events)
    defer { observer.cancel() }

    await transport.handleConnectionClosure(generation: 0, authority: fixture.authority) { .sessionRevoked }
    await events.waitForCount(2)
    #expect(await events.values == ["session_revoked", "disconnected:session_revoked"])
    #expect(await events.invalidations == [fixture.authority])
  }

  @Test("optional upgrade storage loss does not hide closure of the same bearer session")
  func optionalUpgradeRecordDoesNotOwnLiveCarrier() async throws {
    let namespace = UUID().uuidString
    let source = AuthCredentials(userId: 7, token: "7:retained-fixture")
    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
    defer {
      for key in ["token", "credentials_v2", AuthStore.legacyProtocolUpgradeKey] {
        AuthKeychainConfig.mockDelete(key, namespace: namespace)
      }
      UserDefaults.standard.removeObject(forKey: "\(prefix)userId")
    }
    AuthKeychainConfig.mockSet(source.token, forKey: "token", namespace: namespace)
    let cache = AuthSnapshotCache(initial: .init(status: .hydrating, didHydrate: false))
    let store = AuthStore(cache: cache, mocked: true, namespace: namespace)
    let auth = AuthHandle(cache: cache, store: store)
    let permanent = try key(byte: 2)
    let credentials = InlineProtocolSessionCredentials(
      userId: source.userId, accountSessionId: 42,
      permanent: permanent, temporary: try key(byte: 3, temporary: true)
    )
    try await auth.stageLegacyProtocolUpgrade(permanent, for: source)
    try await auth.commitLegacyProtocolUpgrade(credentials, for: source)
    let authority = try auth.makeInvalidationReceipt()
    AuthKeychainConfig.mockDelete(AuthStore.legacyProtocolUpgradeKey, namespace: namespace)
    await auth.refreshFromStorage()
    #expect(auth.inlineProtocolCredentials() == nil)
    #expect(auth.token() == source.token)

    let transport = InlineProtocolV3Transport(auth: auth)
    let events = AuthorityFenceEvents()
    let observer = observe(transport, events: events)
    defer { observer.cancel() }
    await transport.handleConnectionClosure(generation: 0, authority: authority) { .closed }
    await events.waitForCount(1)
    #expect(await events.values == ["disconnected:connection_closed"])
  }

  @Test("a stopped carrier cannot publish a delayed terminal event even for unchanged credentials")
  func stoppedCarrierCannotInvalidate() async throws {
    let fixture = try await fixture(native: false)
    let transport = InlineProtocolV3Transport(auth: fixture.auth.handle)
    let events = AuthorityFenceEvents()
    let observer = observe(transport, events: events)
    defer { observer.cancel() }
    let termination = AuthorityFenceTermination()
    let callback = Task {
      await transport.handleConnectionClosure(generation: 0, authority: fixture.authority) {
        await termination.read()
      }
    }
    await termination.waitUntilReading()
    await transport.stop()
    await events.waitForCount(1)
    await termination.finish(.sessionRevoked)
    await callback.value
    #expect(await events.values == ["disconnected:stopped"])
  }

  private func fixture(native: Bool) async throws -> (
    auth: Auth, source: AuthCredentials, credentials: InlineProtocolSessionCredentials,
    authority: AuthInvalidationReceipt
  ) {
    let auth = Auth.mocked(authenticated: true)
    guard case let .authenticated(source) = auth.handle.snapshot().status else {
      throw AuthStorageError.loginUnavailable
    }
    let permanent = try key(byte: 2)
    let credentials = InlineProtocolSessionCredentials(
      userId: source.userId, accountSessionId: 42,
      permanent: permanent, temporary: try key(byte: 3, temporary: true)
    )
    if native {
      try await auth.handle.saveInlineProtocolCredentials(credentials)
    } else {
      try await auth.handle.stageLegacyProtocolUpgrade(permanent, for: source)
      try await auth.handle.commitLegacyProtocolUpgrade(credentials, for: source)
    }
    return (auth, source, credentials, try auth.handle.makeInvalidationReceipt())
  }

  private func key(byte: UInt8, temporary: Bool = false) throws -> InlineProtocolAuthorization {
    let bytes = [UInt8](repeating: byte, count: 256)
    return try .init(
      key: bytes, keyID: InlineSecureTransport.authKeyID(bytes), serverSalt: 9,
      temporary: temporary, expiresAt: temporary ? 2_000_000_000 : nil
    )
  }

  private func observe(_ transport: InlineProtocolV3Transport, events: AuthorityFenceEvents) -> Task<Void, Never> {
    Task {
      for await event in transport.events {
        guard !Task.isCancelled else { return }
        await events.record(event)
      }
    }
  }
}

private actor AuthorityFenceTermination {
  private var reading = false
  private var readingWaiter: CheckedContinuation<Void, Never>?
  private var result: CheckedContinuation<InlineProtocolV3ConnectionError?, Never>?

  func read() async -> InlineProtocolV3ConnectionError? {
    reading = true
    readingWaiter?.resume()
    readingWaiter = nil
    return await withCheckedContinuation { result = $0 }
  }

  func waitUntilReading() async {
    guard !reading else { return }
    await withCheckedContinuation { readingWaiter = $0 }
  }

  func finish(_ error: InlineProtocolV3ConnectionError) {
    result?.resume(returning: error)
    result = nil
  }
}

private actor AuthorityFenceEvents {
  private(set) var values: [String] = []
  private(set) var invalidations: [AuthInvalidationReceipt] = []
  private var countWaiter: (Int, CheckedContinuation<Void, Never>)?

  func record(_ event: TransportEvent) {
    switch event {
    case let .authInvalidated(receipt):
      invalidations.append(receipt)
      values.append("session_revoked")
    case let .message(message):
      if case let .connectionError(error) = message.body, error.reason == .sessionRevoked {
        values.append("session_revoked")
      } else { values.append("message") }
    case let .disconnected(errorDescription): values.append("disconnected:\(errorDescription ?? "nil")")
    default: values.append("other")
    }
    if let (count, waiter) = countWaiter, values.count >= count {
      countWaiter = nil
      waiter.resume()
    }
  }

  func waitForCount(_ count: Int) async {
    guard values.count < count else { return }
    await withCheckedContinuation { countWaiter = (count, $0) }
  }
}
