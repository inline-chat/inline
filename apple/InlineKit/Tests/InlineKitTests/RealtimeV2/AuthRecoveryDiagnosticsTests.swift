import Auth
import Foundation
import InlineProtocol
import Logger
import Testing

@testable import RealtimeV2

@Suite("Realtime auth recovery diagnostics", .serialized)
struct AuthRecoveryDiagnosticsTests {
  @Test("temporary V3 refresh preserves the realtime session authority")
  func temporaryV3RefreshPreservesRealtimeAuthority() throws {
    let first = try inlineProtocolSnapshot(permanentByte: 0x11, temporaryByte: 0x21)
    let refreshed = try inlineProtocolSnapshot(permanentByte: 0x11, temporaryByte: 0x22)
    let replacementPermanent = try inlineProtocolSnapshot(permanentByte: 0x12, temporaryByte: 0x22)
    let replacementSession = try inlineProtocolSnapshot(
      permanentByte: 0x11,
      temporaryByte: 0x22,
      accountSessionId: 8
    )
    let removedTemporary = try inlineProtocolSnapshot(permanentByte: 0x11, temporaryByte: nil)

    #expect(first != refreshed)
    #expect(RealtimeAuthAuthority(snapshot: first) == RealtimeAuthAuthority(snapshot: refreshed))
    #expect(RealtimeAuthTransition(from: first, to: refreshed).temporaryRefreshed)
    #expect(!RealtimeAuthTransition(from: first, to: refreshed).requiresReconnect)
    #expect(RealtimeAuthTransition(from: refreshed, to: removedTemporary).requiresReconnect)
    #expect(RealtimeAuthTransition(from: removedTemporary, to: refreshed).requiresReconnect)
    #expect(
      RealtimeAuthAuthority(snapshot: refreshed) !=
        RealtimeAuthAuthority(snapshot: replacementPermanent)
    )
    #expect(
      RealtimeAuthAuthority(snapshot: refreshed) !=
        RealtimeAuthAuthority(snapshot: replacementSession)
    )
  }

  @Test("bearer replacement changes the realtime session authority")
  func bearerReplacementChangesRealtimeAuthority() {
    let first = authenticatedSnapshot(token: "first")
    let replacement = authenticatedSnapshot(token: "replacement")

    #expect(RealtimeAuthAuthority(snapshot: first) != RealtimeAuthAuthority(snapshot: replacement))
  }

  @Test("only the authenticated V3 revocation close becomes terminal auth invalidation")
  func v3RevocationCloseBecomesTerminalAuthInvalidation() {
    #expect(
      InlineProtocolV3Transport.authenticationInvalidationReason(
        for: InlineProtocolV3ConnectionError.authorizationInvalidated
      ) == .sessionRevoked
    )
    #expect(
      InlineProtocolV3Transport.authenticationInvalidationReason(
        for: InlineProtocolV3ConnectionError.closed
      ) == nil
    )
    #expect(
      InlineProtocolV3Transport.authenticationInvalidationReason(
        for: InlineProtocolV3ConnectionError.protocolFailure
      ) == nil
    )
  }

  @Test("captures an authenticated snapshot missed by the auth observer")
  func observerMissedCapture() {
    let sink = RecordingLogSink()
    Log.addSink(sink, id: "auth-recovery-diagnostics-tests")
    defer { Log.removeSink(id: "auth-recovery-diagnostics-tests") }

    let diagnostics = RealtimeAuthRecoveryDiagnostics()
    let outcome = diagnostics.check(
      sequence: 1,
      authAvailable: true,
      observerObserved: false,
      observerApplied: false,
      connection: connectionSnapshot(authAvailable: false),
      stage: .propagation
    )

    #expect(outcome == .observerMissed)
    #expect(sink.errorMessages.count == 1)
    #expect(sink.errorMessages[0].contains(RealtimeAuthRecoveryDiagnostics.observerMissedMessage))
  }

  @Test("observer acknowledgement distinguishes replacement credentials")
  func observerAcknowledgementDistinguishesReplacementCredentials() {
    let probe = AuthObservationProbe()
    let first = authenticatedSnapshot(token: "first")
    let replacement = authenticatedSnapshot(token: "replacement")

    probe.recordObserved(first)
    probe.recordApplied(first)
    probe.recordObserved(replacement)

    #expect(probe.hasObserved(replacement))
    #expect(!probe.hasApplied(replacement))
  }

  @Test("captures an authenticated snapshot consumed but not applied by the auth observer")
  func observerDidNotApplyCapture() {
    let sink = RecordingLogSink()
    Log.addSink(sink, id: "auth-recovery-diagnostics-tests")
    defer { Log.removeSink(id: "auth-recovery-diagnostics-tests") }

    let diagnostics = RealtimeAuthRecoveryDiagnostics()
    let outcome = diagnostics.check(
      sequence: 2,
      authAvailable: true,
      observerObserved: true,
      observerApplied: false,
      connection: connectionSnapshot(authAvailable: true, state: .open),
      stage: .propagation
    )

    #expect(outcome == .observerDidNotApply)
    #expect(sink.errorMessages.count == 1)
    #expect(sink.errorMessages[0].contains(RealtimeAuthRecoveryDiagnostics.observerDidNotApplyMessage))
  }

  @Test("captures an authenticated snapshot not applied by the connection manager")
  func managerMissedCapture() {
    let sink = RecordingLogSink()
    Log.addSink(sink, id: "auth-recovery-diagnostics-tests")
    defer { Log.removeSink(id: "auth-recovery-diagnostics-tests") }

    let diagnostics = RealtimeAuthRecoveryDiagnostics()
    let outcome = diagnostics.check(
      sequence: 3,
      authAvailable: true,
      observerObserved: true,
      observerApplied: true,
      connection: connectionSnapshot(authAvailable: false),
      stage: .propagation
    )

    #expect(outcome == .managerMissed)
    #expect(sink.errorMessages.count == 1)
    #expect(sink.errorMessages[0].contains(RealtimeAuthRecoveryDiagnostics.managerMissedMessage))
  }

  @Test("captures an authenticated connection that remains stalled at the deadline")
  func connectionStalledCapture() {
    let sink = RecordingLogSink()
    Log.addSink(sink, id: "auth-recovery-diagnostics-tests")
    defer { Log.removeSink(id: "auth-recovery-diagnostics-tests") }

    let diagnostics = RealtimeAuthRecoveryDiagnostics()
    let outcome = diagnostics.check(
      sequence: 4,
      authAvailable: true,
      observerObserved: true,
      observerApplied: true,
      connection: connectionSnapshot(authAvailable: true),
      stage: .deadline
    )

    #expect(outcome == .connectionStalled)
    #expect(sink.errorMessages.count == 1)
    #expect(sink.errorMessages[0].contains(RealtimeAuthRecoveryDiagnostics.connectionStalledMessage))
  }

  @Test("does not capture expected deferred or successful states")
  func expectedStatesDoNotCapture() {
    let sink = RecordingLogSink()
    Log.addSink(sink, id: "auth-recovery-diagnostics-tests")
    defer { Log.removeSink(id: "auth-recovery-diagnostics-tests") }

    let diagnostics = RealtimeAuthRecoveryDiagnostics()
    let deferred = diagnostics.check(
      sequence: 5,
      authAvailable: true,
      observerObserved: true,
      observerApplied: true,
      connection: connectionSnapshot(authAvailable: true, networkAvailable: false),
      stage: .deadline
    )
    let connected = diagnostics.check(
      sequence: 6,
      authAvailable: true,
      observerObserved: true,
      observerApplied: true,
      connection: connectionSnapshot(authAvailable: true, state: .open),
      stage: .deadline
    )
    let cancelled = diagnostics.check(
      sequence: 7,
      authAvailable: false,
      observerObserved: false,
      observerApplied: false,
      connection: connectionSnapshot(authAvailable: false),
      stage: .deadline
    )

    #expect(deferred == .deferred)
    #expect(connected == .connected)
    #expect(cancelled == .cancelled)
    #expect(sink.errorMessages.isEmpty)
  }
}

private func inlineProtocolSnapshot(
  permanentByte: UInt8,
  temporaryByte: UInt8?,
  accountSessionId: Int64 = 7
) throws -> AuthSnapshot {
  let permanentKey = [UInt8](repeating: permanentByte, count: 256)
  let permanent = try InlineProtocolAuthorization(
    key: permanentKey,
    keyID: InlineSecureTransport.authKeyID(permanentKey),
    serverSalt: 1,
    temporary: false,
    expiresAt: nil
  )
  let temporary = try temporaryByte.map { temporaryByte in
    let temporaryKey = [UInt8](repeating: temporaryByte, count: 256)
    return try InlineProtocolAuthorization(
      key: temporaryKey,
      keyID: InlineSecureTransport.authKeyID(temporaryKey),
      serverSalt: 2,
      temporary: true,
      expiresAt: 1_900_000_000
    )
  }
  return AuthSnapshot(
    status: .authenticatedV3(userId: 1),
    didHydrate: true,
    inlineProtocol: InlineProtocolSessionCredentials(
      userId: 1,
      accountSessionId: accountSessionId,
      permanent: permanent,
      temporary: temporary,
      createdAt: Date(timeIntervalSince1970: 1)
    )
  )
}

private func authenticatedSnapshot(token: String) -> AuthSnapshot {
  AuthSnapshot(
    status: .authenticated(
      AuthCredentials(
        userId: 1,
        token: token,
        createdAt: Date(timeIntervalSince1970: 1)
      )
    ),
    didHydrate: true
  )
}

private func connectionSnapshot(
  authAvailable: Bool,
  networkAvailable: Bool = true,
  state: ConnectionState = .waitingForConstraints
) -> ConnectionSnapshot {
  ConnectionSnapshot(
    state: state,
    reason: .constraintUnavailable,
    attempt: 0,
    since: Date(),
    sessionID: 1,
    constraints: ConnectionConstraints(
      authAvailable: authAvailable,
      networkAvailable: networkAvailable,
      appActive: true,
      userWantsConnection: true
    ),
    lastErrorDescription: nil
  )
}

private final class RecordingLogSink: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []

  var errorMessages: [String] {
    lock.withLock { messages }
  }

  func write(_ event: LogEvent) {
    guard event.entry.level == .error else { return }
    lock.withLock {
      messages.append(event.entry.message)
    }
  }
}
