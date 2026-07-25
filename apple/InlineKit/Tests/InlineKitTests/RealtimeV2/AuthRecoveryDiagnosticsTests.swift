import Auth
import Foundation
import Logger
import Testing

@testable import RealtimeV2

@Suite("Realtime auth recovery diagnostics", .serialized)
struct AuthRecoveryDiagnosticsTests {
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
