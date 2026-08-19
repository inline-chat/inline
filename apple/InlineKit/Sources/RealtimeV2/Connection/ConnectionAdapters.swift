import Auth
import Foundation
import Logger
import Network

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

final class AuthConnectionAdapter {
  private let log = Log.scoped("RealtimeV2.AuthConnectionAdapter")
  private let auth: AuthHandle
  private let manager: ConnectionManager
  private let observationProbe: AuthObservationProbe
  private var task: Task<Void, Never>?

  init(auth: AuthHandle, manager: ConnectionManager, observationProbe: AuthObservationProbe) {
    self.auth = auth
    self.manager = manager
    self.observationProbe = observationProbe
  }

  func start() {
    task?.cancel()
    let auth = self.auth
    let log = self.log
    let manager = self.manager
    let observationProbe = observationProbe
    // Subscribe before sampling the baseline or scheduling observation. The stream buffers any
    // logout/login transitions that occur before the task gets an opportunity to run.
    let snapshots = auth.snapshots
    let initial = auth.snapshot()
    let initialAuthAvailable = initial.isLoggedIn
    log.info("Realtime auth observer started baseline_available=\(initialAuthAvailable ? 1 : 0)")
    task = Task {
      var authAvailable = initialAuthAvailable
      var appliedSnapshot = initial
      var sequence: UInt64 = 0

      for await snapshot in snapshots {
        guard !Task.isCancelled else { return }
        sequence = sequence &+ 1
        observationProbe.recordObserved(snapshot)
        let nextAuthAvailable = snapshot.isLoggedIn
        let changed = nextAuthAvailable != authAvailable
        let transition = RealtimeAuthTransition(from: appliedSnapshot, to: snapshot)
        log.info(
          "Realtime auth observer received snapshot sequence=\(sequence)" +
            " status=\(diagnosticName(for: snapshot.status))" +
            " available=\(nextAuthAvailable ? 1 : 0)" +
            " changed=\(changed ? 1 : 0)" +
            " authority_changed=\(transition.authorityChanged ? 1 : 0)" +
            " credentials_changed=\(transition.credentialsChanged ? 1 : 0)" +
            " temporary_refreshed=\(transition.temporaryRefreshed ? 1 : 0)" +
            " temporary_presence_changed=\(transition.temporaryPresenceChanged ? 1 : 0)"
        )
        guard changed || transition.requiresReconnect else {
          appliedSnapshot = snapshot
          observationProbe.recordApplied(snapshot)
          continue
        }

        if nextAuthAvailable {
          if authAvailable, transition.requiresReconnect {
            await manager.stop()
          }
          await manager.setAuthAvailable(true)
          await manager.connectNow()
        } else {
          await manager.setAuthAvailable(false)
          await manager.stop()
        }
        authAvailable = nextAuthAvailable
        appliedSnapshot = snapshot
        observationProbe.recordApplied(snapshot)
        log.info(
          "Realtime auth observer queued transition sequence=\(sequence)" +
            " available=\(nextAuthAvailable ? 1 : 0)"
        )
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  deinit {
    task?.cancel()
    task = nil
  }
}

/// The account/session authority that owns one realtime connection lifecycle.
///
/// Temporary V3 authorizations are transport-owned, replaceable application keys. Refreshing one
/// must not tear down the connection that just created it. Bearer tokens and permanent V3 account
/// session credentials remain authority changes and therefore require a new connection lifecycle.
enum RealtimeAuthAuthority: Equatable {
  case unavailable
  case bearer(userId: Int64, token: String)
  case inlineProtocol(userId: Int64, accountSessionId: Int64?, permanentKey: [UInt8]?)

  init(snapshot: AuthSnapshot) {
    switch snapshot.status {
    case .authenticated(let credentials):
      self = .bearer(userId: credentials.userId, token: credentials.token)
    case .authenticatedV3(let userId):
      self = .inlineProtocol(
        userId: userId,
        accountSessionId: snapshot.inlineProtocol?.accountSessionId,
        permanentKey: snapshot.inlineProtocol?.permanent.key
      )
    case .hydrating, .unauthenticated, .locked, .reauthRequired:
      self = .unavailable
    }
  }
}

struct RealtimeAuthTransition: Equatable {
  let authorityChanged: Bool
  let credentialsChanged: Bool
  let temporaryRefreshed: Bool
  let temporaryPresenceChanged: Bool

  var requiresReconnect: Bool { authorityChanged || temporaryPresenceChanged }

  init(from previous: AuthSnapshot, to next: AuthSnapshot) {
    let previousAuthority = RealtimeAuthAuthority(snapshot: previous)
    let nextAuthority = RealtimeAuthAuthority(snapshot: next)
    authorityChanged = previousAuthority != nextAuthority
    credentialsChanged = previous.token != next.token || previous.inlineProtocol != next.inlineProtocol

    let sameV3Authority: Bool = switch (previousAuthority, nextAuthority) {
    case (.inlineProtocol, .inlineProtocol) where !authorityChanged: true
    default: false
    }
    let previousTemporary = previous.inlineProtocol?.temporary
    let nextTemporary = next.inlineProtocol?.temporary
    temporaryRefreshed = sameV3Authority && previousTemporary != nil && nextTemporary != nil &&
      previousTemporary != nextTemporary
    temporaryPresenceChanged = sameV3Authority &&
      ((previousTemporary == nil) != (nextTemporary == nil))
  }
}

final class AuthObservationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var latestObserved: AuthSnapshot?
  private var latestApplied: AuthSnapshot?

  func recordObserved(_ snapshot: AuthSnapshot) {
    lock.withLock {
      latestObserved = snapshot
    }
  }

  func hasObserved(_ snapshot: AuthSnapshot) -> Bool {
    lock.withLock { latestObserved == snapshot }
  }

  func recordApplied(_ snapshot: AuthSnapshot) {
    lock.withLock {
      latestApplied = snapshot
    }
  }

  func hasApplied(_ snapshot: AuthSnapshot) -> Bool {
    lock.withLock { latestApplied == snapshot }
  }
}

enum RealtimeAuthRecoveryCheckStage: Sendable, Equatable {
  case propagation
  case deadline
}

enum RealtimeAuthRecoveryOutcome: Sendable, Equatable {
  case cancelled
  case connected
  case deferred
  case pending
  case observerMissed
  case observerDidNotApply
  case managerMissed
  case connectionStalled
}

final class RealtimeAuthRecoveryDiagnostics: @unchecked Sendable {
  static let observerMissedMessage = "Realtime auth observer did not consume authenticated state"
  static let observerDidNotApplyMessage = "Realtime auth observer did not apply authenticated state"
  static let managerMissedMessage = "Realtime connection manager did not apply authenticated state"
  static let connectionStalledMessage = "Realtime authentication did not reach an open connection"

  private let log = Log.scoped("RealtimeV2.AuthRecovery")

  func recordSnapshot(sequence: UInt64, snapshot: AuthSnapshot) {
    log.info(
      "Realtime auth diagnostic snapshot sequence=\(sequence)" +
        " status=\(diagnosticName(for: snapshot.status))" +
        " hydrated=\(snapshot.didHydrate ? 1 : 0)"
    )
  }

  @discardableResult
  func check(
    sequence: UInt64,
    authAvailable: Bool,
    observerObserved: Bool,
    observerApplied: Bool,
    connection: ConnectionSnapshot,
    stage: RealtimeAuthRecoveryCheckStage
  ) -> RealtimeAuthRecoveryOutcome {
    guard authAvailable else { return .cancelled }

    log.info(
      "Realtime auth recovery check sequence=\(sequence)" +
        " stage=\(stage == .propagation ? "propagation" : "deadline")" +
        " state=\(connection.state) reason=\(connection.reason) session=\(connection.sessionID)" +
        " observed=\(observerObserved ? 1 : 0) applied=\(observerApplied ? 1 : 0)" +
        " auth=\(connection.constraints.authAvailable ? 1 : 0)" +
        " network=\(connection.constraints.networkAvailable ? 1 : 0)" +
        " active=\(connection.constraints.appActive ? 1 : 0)" +
        " wants=\(connection.constraints.userWantsConnection ? 1 : 0)"
    )

    guard observerObserved else {
      log.error(Self.observerMissedMessage)
      return .observerMissed
    }

    guard observerApplied else {
      log.error(Self.observerDidNotApplyMessage)
      return .observerDidNotApply
    }

    guard connection.constraints.authAvailable else {
      log.error(Self.managerMissedMessage)
      return .managerMissed
    }

    if connection.state == .open {
      log.info("Realtime auth recovery completed sequence=\(sequence) session=\(connection.sessionID)")
      return .connected
    }

    guard connection.constraints.networkAvailable,
          connection.constraints.appActive,
          connection.constraints.userWantsConnection
    else {
      return .deferred
    }

    guard stage == .deadline else { return .pending }

    log.error(Self.connectionStalledMessage)
    return .connectionStalled
  }
}

private func diagnosticName(for status: AuthStatus) -> String {
  switch status {
  case .hydrating: "hydrating"
  case .unauthenticated: "unauthenticated"
  case .locked: "locked"
  case .reauthRequired: "reauth_required"
  case .authenticated: "authenticated"
  case .authenticatedV3: "authenticated_v3"
  }
}

final class LifecycleConnectionAdapter {
  private let manager: ConnectionManager

  #if canImport(UIKit)
  private var observersInstalled = false
  #endif

  init(manager: ConnectionManager) {
    self.manager = manager
    installObservers()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    #if canImport(AppKit)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    #endif
  }

  private func installObservers() {
    #if canImport(UIKit)
    guard !observersInstalled else { return }
    observersInstalled = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    #elseif canImport(AppKit)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleSystemWillSleep),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleSystemDidWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    #endif
  }

  @objc private func handleAppDidBecomeActive() {
    Task { [manager] in
      await manager.setAppActive(true)
    }
  }

  @objc private func handleAppDidEnterBackground() {
    Task { [manager] in
      await manager.setAppActive(false)
    }
  }

  @objc private func handleSystemWillSleep() {
    Task { [manager] in
      await manager.setAppActive(false)
    }
  }

  @objc private func handleSystemDidWake() {
    Task { [manager] in
      await manager.systemDidWake()
    }
  }
}

final class NetworkConnectionAdapter {
  private let manager: ConnectionManager
  private let monitor: NWPathMonitor

  init(manager: ConnectionManager) {
    self.manager = manager
    self.monitor = NWPathMonitor()

    let manager = self.manager
    monitor.pathUpdateHandler = { path in
      let isSatisfied = path.status == .satisfied
      let quality: ConnectionNetworkQuality = (path.isConstrained || path.isExpensive) ? .constrained : .good
      Task {
        await manager.setNetworkAvailable(isSatisfied)
        await manager.setNetworkQuality(quality)
      }
    }

    monitor.start(queue: DispatchQueue(label: "RealtimeV2.ConnectionManager.path"))
  }

  deinit {
    monitor.cancel()
  }
}
