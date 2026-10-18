import AsyncAlgorithms
@testable import Auth
import Foundation
import InlineProtocol
@testable import RealtimeV2
import Testing

@Suite("Account-scoped revocation delivery", .serialized)
struct AuthInvalidationDeliveryTests {
  @Test("a queued notification cannot sign out a same-user replacement login", arguments: [false, true])
  func delayedNotificationPreservesReplacement(native: Bool) async throws {
    let fixture = try await fixture(native: native)
    let pipeline = await pipeline(auth: fixture.auth, v3: true)
    defer { pipeline.close() }
    #expect(await eventually { await pipeline.manager.currentSnapshot().state == .open })

    let lease = try fixture.auth.handle.beginAccountMutation()
    let receipt = try fixture.auth.handle.makeInvalidationReceipt()
    await pipeline.transport.emit(.authInvalidated(receipt))
    #expect(await eventually { await pipeline.receipts.value != nil })
    let forwarded = try #require(await pipeline.receipts.value)
    #expect(forwarded == receipt)

    let center = NotificationCenter()
    let (notifications, continuation) = AsyncStream<AuthInvalidationReceipt>.makeStream()
    let observer = center.addObserver(forName: .realtimeV2AuthInvalidated, object: nil, queue: nil) { notification in
      if let receipt = notification.object as? AuthInvalidationReceipt { continuation.yield(receipt) }
    }
    defer { center.removeObserver(observer); continuation.finish() }
    // Exercise the real publisher, then delay the platform's notification task until a new
    // same-user login has completed. Account generation alone deliberately cannot catch this.
    #expect(RealtimeAuthInvalidationNotification.post(forwarded, auth: fixture.auth.handle, center: center))
    if native {
      var replacement = fixture.credentials
      replacement.accountSessionId += 1
      replacement.permanent = try key(byte: 7)
      try await fixture.auth.handle.saveInlineProtocolCredentials(replacement)
    } else {
      try await fixture.auth.saveCredentials(token: "1:replacement", userId: 1)
    }
    let replacement = fixture.auth.handle.snapshot()
    // Same-user credential replacement intentionally preserves ordinary account work. The
    // revocation fence must therefore compare credential identity as well as this generation.
    try fixture.auth.handle.validateAccountMutation(lease)
    var iterator = notifications.makeAsyncIterator()
    let delivered = try #require(await iterator.next())

    // This is the same atomic durable logout admission used by both platform owners.
    #expect(try fixture.auth.beginLogoutSynchronously(ifCurrent: delivered) == nil)
    #expect(fixture.auth.handle.snapshot() == replacement)
    #expect(fixture.auth.handle.isLoggedIn())
    #expect(!fixture.auth.handle.hasPendingAccountTransition())
    #expect(await pipeline.manager.currentSnapshot().state == .open)
  }

  @Test("a delayed V2 server revocation retains the bearer actually sent in connectionInit")
  func v2HandshakeReceiptSurvivesDeferredServerReply() async throws {
    let auth = Auth.mocked(authenticated: true)
    let original = try auth.handle.makeInvalidationReceipt()
    let pipeline = await pipeline(auth: auth, v3: false)
    defer { pipeline.close() }
    #expect(await eventually { await pipeline.manager.currentSnapshot().state == .open })
    #expect(await pipeline.transport.handshakeToken == "1:mockToken")
    try await auth.saveCredentials(token: "1:replacement", userId: 1)

    var message = ServerProtocolMessage()
    message.body = .connectionError(.with { $0.reason = .sessionRevoked })
    await pipeline.transport.emit(.message(message))
    #expect(await eventually { await pipeline.receipts.value != nil })
    let forwarded = try #require(await pipeline.receipts.value)
    #expect(forwarded == original)
    #expect(!RealtimeAuthInvalidationNotification.post(forwarded, auth: auth.handle, center: NotificationCenter()))
    #expect(try auth.beginLogoutSynchronously(ifCurrent: forwarded) == nil)
    #expect(auth.handle.token() == "1:replacement")
    #expect(!auth.handle.hasPendingAccountTransition())
  }

  @Test("current revocation still closes durable login admission after temporary key rotation", arguments: [false, true])
  func genuineRevocationStillLogsOut(native: Bool) async throws {
    let fixture = try await fixture(native: native)
    let receipt = try fixture.auth.handle.makeInvalidationReceipt()
    var rotated = fixture.credentials
    rotated.temporary = try key(byte: 9, temporary: true)
    try await fixture.auth.handle.saveInlineProtocolCredentials(rotated)
    let pipeline = await pipeline(auth: fixture.auth, v3: true)
    defer { pipeline.close() }
    #expect(await eventually { await pipeline.manager.currentSnapshot().state == .open })

    let center = NotificationCenter()
    let (notifications, continuation) = AsyncStream<AuthInvalidationReceipt>.makeStream()
    let observer = center.addObserver(forName: .realtimeV2AuthInvalidated, object: nil, queue: nil) { notification in
      if let receipt = notification.object as? AuthInvalidationReceipt { continuation.yield(receipt) }
    }
    defer { center.removeObserver(observer); continuation.finish() }
    await pipeline.transport.emit(.authInvalidated(receipt))
    #expect(await eventually { await pipeline.receipts.value != nil })
    let forwarded = try #require(await pipeline.receipts.value)
    #expect(RealtimeAuthInvalidationNotification.post(forwarded, auth: fixture.auth.handle, center: center))
    var iterator = notifications.makeAsyncIterator()
    let delivered = try #require(await iterator.next())
    let admittedFence = try fixture.auth.beginLogoutSynchronously(ifCurrent: delivered)
    let fence = try #require(admittedFence)
    #expect(fixture.auth.getCurrentLogoutFence() == fence)
    #expect(fixture.auth.handle.hasPendingLogout())
    #expect(throws: AuthStorageError.self) { try fixture.auth.handle.beginAccountMutation() }
    #expect(try fixture.auth.beginLogoutSynchronously(ifCurrent: delivered) == nil)
  }

  private func fixture(native: Bool) async throws -> (auth: Auth, credentials: InlineProtocolSessionCredentials) {
    let auth = Auth.mocked(authenticated: true)
    let source = try #require({ () -> AuthCredentials? in
      if case let .authenticated(source) = auth.handle.snapshot().status { return source }
      return nil
    }())
    let credentials = InlineProtocolSessionCredentials(
      userId: source.userId, accountSessionId: 42, permanent: try key(byte: 2),
      temporary: try key(byte: 3, temporary: true)
    )
    if native {
      try await auth.handle.saveInlineProtocolCredentials(credentials)
    } else {
      try await auth.handle.stageLegacyProtocolUpgrade(credentials.permanent, for: source)
      try await auth.handle.commitLegacyProtocolUpgrade(credentials, for: source)
    }
    return (auth, credentials)
  }

  private func key(byte: UInt8, temporary: Bool = false) throws -> InlineProtocolAuthorization {
    let bytes = [UInt8](repeating: byte, count: 256)
    return try .init(
      key: bytes, keyID: InlineSecureTransport.authKeyID(bytes), serverSalt: 7,
      temporary: temporary, expiresAt: temporary ? 2_000_000_000 : nil
    )
  }

  private func pipeline(auth: Auth, v3: Bool) async -> InvalidationPipeline {
    let transport = InvalidationDeliveryTransport(v3: v3)
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    await session.start()
    let manager = ConnectionManager(session: session, constraints: .init(
      authAvailable: true, networkAvailable: true, appActive: true, userWantsConnection: true
    ))
    let receipts = InvalidationReceiptProbe()
    let observer = Task {
      for await envelope in await manager.sessionEvents() {
        if case let .authInvalidated(receipt) = envelope.event { await receipts.record(receipt) }
        await envelope.markProcessed()
      }
    }
    await manager.start()
    return InvalidationPipeline(transport: transport, manager: manager, receipts: receipts, observer: observer)
  }

  private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while await condition() == false {
      if ContinuousClock.now >= deadline { return false }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return true
  }
}

private struct InvalidationPipeline: Sendable {
  let transport: InvalidationDeliveryTransport
  let manager: ConnectionManager
  let receipts: InvalidationReceiptProbe
  let observer: Task<Void, Never>

  func close() {
    observer.cancel()
    Task {
      await manager.shutdownForTesting()
      transport.events.finish()
    }
  }
}

private actor InvalidationReceiptProbe {
  private(set) var value: AuthInvalidationReceipt?
  func record(_ receipt: AuthInvalidationReceipt) { value = receipt }
}

private actor InvalidationDeliveryTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  let v3: Bool
  private(set) var handshakeToken: String?

  init(v3: Bool) { self.v3 = v3 }
  func isApplicationAuthenticatedOnConnect() -> Bool { v3 }
  func start() async {
    await events.send(.connecting)
    await events.send(.connected)
  }
  func stop() async { await events.send(.disconnected(errorDescription: "stopped")) }
  func emit(_ event: TransportEvent) async { await events.send(event) }
  func send(_ message: ClientMessage) async throws {
    if case let .connectionInit(value) = message.body {
      handshakeToken = value.token
      var open = ServerProtocolMessage()
      open.body = .connectionOpen(.init())
      await events.send(.message(open))
    }
  }
}
