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

final class AuthConnectionAdapter: @unchecked Sendable {
  private let log = Log.scoped("RealtimeV2.AuthConnectionAdapter")
  private let auth: AuthHandle
  private let manager: ConnectionManager
  private let observationProbe: AuthObservationProbe
  private let generationLock = NSLock()
  private var generation: UInt64 = 0
  private var task: Task<Void, Never>?

  init(auth: AuthHandle, manager: ConnectionManager, observationProbe: AuthObservationProbe) {
    self.auth = auth
    self.manager = manager
    self.observationProbe = observationProbe
  }

  func start() {
    task?.cancel()
    let taskGeneration = generationLock.withLock { () -> UInt64 in
      generation &+= 1
      return generation
    }
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

        let isCurrentGeneration = self.generationLock.withLock {
          self.generation == taskGeneration
        }
        let currentSnapshot = auth.snapshot()
        guard isCurrentGeneration,
              auth.hasPendingAccountTransition() == false,
              currentSnapshot == snapshot
        else {
          await manager.setAuthAvailable(false)
          await manager.stop()
          authAvailable = false
          appliedSnapshot = currentSnapshot
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

  func stop(isolation: isolated (any Actor)? = #isolation) async {
    generationLock.withLock { generation &+= 1 }
    let endingTask = task
    task = nil
    endingTask?.cancel()
    await endingTask?.value
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
    case .hydrating, .unauthenticated, .locked, .reauthRequired, .loggingOut:
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
  case .loggingOut: "logging_out"
  case .authenticated: "authenticated"
  case .authenticatedV3: "authenticated_v3"
  }
}

#if canImport(UIKit)
enum IOSLifecycleSignal: Sendable {
  case willResignActive
  case didEnterBackground
  case didBecomeActive
  case retentionExpired(UInt64)
}

@MainActor
protocol IOSBackgroundConnectionRetaining: AnyObject {
  var epoch: UInt64 { get }
  var isRetained: Bool { get }
  func end()
}

typealias IOSBackgroundConnectionLeaseFactory = @MainActor @Sendable (
  _ epoch: UInt64,
  _ duration: Duration,
  _ signal: AsyncStream<IOSLifecycleSignal>.Continuation
) -> any IOSBackgroundConnectionRetaining

@MainActor
final class IOSBackgroundConnectionLease: IOSBackgroundConnectionRetaining {
  typealias ExpirationHandler = @MainActor @Sendable () -> Void
  typealias BeginBackgroundTask = @MainActor @Sendable (
    _ expirationHandler: @escaping ExpirationHandler
  ) -> UIBackgroundTaskIdentifier
  typealias EndBackgroundTask = @MainActor @Sendable (UIBackgroundTaskIdentifier) -> Void
  typealias Now = @MainActor @Sendable () -> ContinuousClock.Instant

  let epoch: UInt64

  private var identifier: UIBackgroundTaskIdentifier = .invalid
  private var expirationTask: Task<Void, Never>?
  private var ended = false
  private let deadline: ContinuousClock.Instant
  private let signal: AsyncStream<IOSLifecycleSignal>.Continuation
  private let endBackgroundTask: EndBackgroundTask
  private let now: Now

  init(
    epoch: UInt64,
    duration: Duration,
    signal: AsyncStream<IOSLifecycleSignal>.Continuation,
    now: @escaping Now = { ContinuousClock().now },
    beginBackgroundTask: @escaping BeginBackgroundTask = { expirationHandler in
      UIApplication.shared.beginBackgroundTask(
        withName: "Realtime connection retention",
        expirationHandler: expirationHandler
      )
    },
    endBackgroundTask: @escaping EndBackgroundTask = { identifier in
      UIApplication.shared.endBackgroundTask(identifier)
    }
  ) {
    self.epoch = epoch
    self.signal = signal
    self.now = now
    self.endBackgroundTask = endBackgroundTask
    deadline = now() + duration

    identifier = beginBackgroundTask { [weak self] in
      self?.expire()
    }

    guard identifier != .invalid else { return }
    expirationTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: duration)
      } catch {
        return
      }
      self?.expire()
    }
  }

  var isRetained: Bool {
    !ended && identifier != .invalid && now() < deadline
  }

  func end() {
    guard !ended else { return }
    ended = true
    expirationTask?.cancel()
    expirationTask = nil
    guard identifier != .invalid else { return }
    let endingIdentifier = identifier
    identifier = .invalid
    endBackgroundTask(endingIdentifier)
  }

  private func expire() {
    guard !ended else { return }
    end()
    signal.yield(.retentionExpired(epoch))
  }
}

final class LifecycleConnectionAdapter {
  private let manager: ConnectionManager
  private let notificationCenter: NotificationCenter
  private let applicationState: @MainActor @Sendable () -> UIApplication.State
  private let makeLease: IOSBackgroundConnectionLeaseFactory
  private let signalStream: AsyncStream<IOSLifecycleSignal>
  private let signalContinuation: AsyncStream<IOSLifecycleSignal>.Continuation
  private var observers: [NSObjectProtocol] = []
  private var task: Task<Void, Never>?

  init(
    manager: ConnectionManager,
    notificationCenter: NotificationCenter = .default,
    applicationState: @escaping @MainActor @Sendable () -> UIApplication.State = {
      UIApplication.shared.applicationState
    },
    makeLease: @escaping IOSBackgroundConnectionLeaseFactory = { epoch, duration, signal in
      IOSBackgroundConnectionLease(epoch: epoch, duration: duration, signal: signal)
    }
  ) {
    self.manager = manager
    self.notificationCenter = notificationCenter
    self.applicationState = applicationState
    self.makeLease = makeLease
    (signalStream, signalContinuation) = AsyncStream.create(
      IOSLifecycleSignal.self,
      bufferingPolicy: .unbounded
    )
  }

  func start() {
    guard task == nil else { return }
    installObservers()
    let manager = self.manager
    let signalStream = self.signalStream
    let signalContinuation = self.signalContinuation
    let applicationState = self.applicationState
    let makeLease = self.makeLease
    task = Task { @MainActor in
      await Self.run(
        manager: manager,
        signals: signalStream,
        signalContinuation: signalContinuation,
        applicationState: applicationState,
        makeLease: makeLease
      )
    }
  }

  func stop(isolation: isolated (any Actor)? = #isolation) async {
    for observer in observers {
      notificationCenter.removeObserver(observer)
    }
    observers.removeAll()
    signalContinuation.finish()
    let endingTask = task
    task = nil
    endingTask?.cancel()
    await endingTask?.value
  }

  deinit {
    for observer in observers {
      notificationCenter.removeObserver(observer)
    }
    signalContinuation.finish()
    task?.cancel()
  }

  private func installObservers() {
    let signalContinuation = self.signalContinuation
    let center = notificationCenter
    observers = [
      center.addObserver(
        forName: UIApplication.willResignActiveNotification,
        object: nil,
        queue: .main
      ) { _ in
        signalContinuation.yield(.willResignActive)
      },
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { _ in
        signalContinuation.yield(.didEnterBackground)
      },
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { _ in
        signalContinuation.yield(.didBecomeActive)
      },
    ]
  }

  @MainActor
  private static func run(
    manager: ConnectionManager,
    signals: AsyncStream<IOSLifecycleSignal>,
    signalContinuation: AsyncStream<IOSLifecycleSignal>.Continuation,
    applicationState: @escaping @MainActor @Sendable () -> UIApplication.State,
    makeLease: @escaping IOSBackgroundConnectionLeaseFactory
  ) async {
    var lease: (any IOSBackgroundConnectionRetaining)?
    var nextLeaseEpoch: UInt64 = 0
    let initialApplicationState = applicationState()
    let backgroundRetentionDuration = await manager.backgroundRetentionDuration()
    var isInBackground = initialApplicationState == .background
    var managerIsActive = initialApplicationState == .active

    if managerIsActive {
      await manager.applicationBecameActive(transportWasRetained: true)
    } else {
      await manager.applicationBecameInactive(keepConnection: false)
    }

    defer {
      lease?.end()
    }

    func beginLease() -> any IOSBackgroundConnectionRetaining {
      nextLeaseEpoch = nextLeaseEpoch &+ 1
      return makeLease(
        nextLeaseEpoch,
        backgroundRetentionDuration,
        signalContinuation
      )
    }

    for await signal in signals {
      guard !Task.isCancelled else { return }

      switch signal {
      case .willResignActive:
        if !isInBackground, lease == nil {
          lease = beginLease()
        }

      case .didEnterBackground:
        guard !isInBackground else { continue }
        isInBackground = true
        managerIsActive = false
        if lease == nil {
          lease = beginLease()
        }
        await manager.applicationBecameInactive(
          keepConnection: lease?.isRetained == true
        )

      case .didBecomeActive:
        let shouldReportForeground = !managerIsActive
        let transportWasRetained = isInBackground && lease?.isRetained == true
        isInBackground = false
        managerIsActive = true
        lease?.end()
        lease = nil
        if shouldReportForeground {
          await manager.applicationBecameActive(
            transportWasRetained: transportWasRetained
          )
        }

      case let .retentionExpired(epoch):
        guard lease?.epoch == epoch else { continue }
        lease?.end()
        lease = nil
        if applicationState() == .active {
          // The foreground notification may be queued behind this expiration.
          // The manager still owns the transport, so foreground wins without
          // turning the queued expiration into a needless reconnect.
          let shouldReportForeground = !managerIsActive
          isInBackground = false
          managerIsActive = true
          if shouldReportForeground {
            await manager.applicationBecameActive(transportWasRetained: true)
          }
        } else if isInBackground {
          await manager.applicationBecameInactive(keepConnection: false)
        }
      }
    }
  }
}
#elseif canImport(AppKit)
private enum MacLifecycleSignal: Sendable {
  case appDidBecomeActive
  case systemWillSleep
  case systemDidWake
}

final class LifecycleConnectionAdapter {
  private let manager: ConnectionManager
  private let signalStream: AsyncStream<MacLifecycleSignal>
  private let signalContinuation: AsyncStream<MacLifecycleSignal>.Continuation
  private var observersInstalled = false
  private var task: Task<Void, Never>?

  init(manager: ConnectionManager) {
    self.manager = manager
    (signalStream, signalContinuation) = AsyncStream.create(
      MacLifecycleSignal.self,
      bufferingPolicy: .unbounded
    )
  }

  func start() {
    guard !observersInstalled else { return }
    observersInstalled = true
    installObservers()
    let manager = self.manager
    let signals = signalStream
    task = Task {
      for await signal in signals {
        guard !Task.isCancelled else { return }
        switch signal {
        case .appDidBecomeActive:
          await manager.applicationBecameActive(transportWasRetained: true)
        case .systemWillSleep:
          await manager.applicationBecameInactive(keepConnection: false)
        case .systemDidWake:
          await manager.systemDidWake()
        }
      }
    }
  }

  func stop(isolation: isolated (any Actor)? = #isolation) async {
    guard observersInstalled || task != nil else { return }
    observersInstalled = false
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    signalContinuation.finish()
    let endingTask = task
    task = nil
    endingTask?.cancel()
    await endingTask?.value
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    signalContinuation.finish()
    task?.cancel()
  }

  private func installObservers() {
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
  }

  @objc private func handleAppDidBecomeActive() {
    signalContinuation.yield(.appDidBecomeActive)
  }

  @objc private func handleSystemWillSleep() {
    signalContinuation.yield(.systemWillSleep)
  }

  @objc private func handleSystemDidWake() {
    signalContinuation.yield(.systemDidWake)
  }
}
#else
final class LifecycleConnectionAdapter {
  init(manager _: ConnectionManager) {}
  func start() {}
  func stop(isolation: isolated (any Actor)? = #isolation) async {}
}
#endif

struct ConnectionPathRoute: Sendable, Equatable {
  let interfaceTypes: Set<NWInterface.InterfaceType>
  let interfaceIndexes: Set<Int>
  let gateways: Set<NWEndpoint>
  let supportsDNS: Bool
  let supportsIPv4: Bool
  let supportsIPv6: Bool

  init(path: NWPath) {
    // Public NWPath data cannot distinguish every same-interface Wi-Fi or VPN
    // replacement. This signature covers only observable route identity.
    let activeTypes = Set([
      NWInterface.InterfaceType.other,
      .wifi,
      .cellular,
      .wiredEthernet,
      .loopback,
    ].filter { path.usesInterfaceType($0) })
    interfaceTypes = activeTypes
    interfaceIndexes = Set(
      path.availableInterfaces.lazy
        .filter { activeTypes.contains($0.type) }
        .map(\.index)
    )
    gateways = Set(path.gateways)
    supportsDNS = path.supportsDNS
    supportsIPv4 = path.supportsIPv4
    supportsIPv6 = path.supportsIPv6
  }

  init(
    interfaceTypes: Set<NWInterface.InterfaceType>,
    interfaceIndexes: Set<Int> = [],
    gateways: Set<NWEndpoint> = [],
    supportsDNS: Bool = true,
    supportsIPv4: Bool = true,
    supportsIPv6: Bool = true
  ) {
    self.interfaceTypes = interfaceTypes
    self.interfaceIndexes = interfaceIndexes
    self.gateways = gateways
    self.supportsDNS = supportsDNS
    self.supportsIPv4 = supportsIPv4
    self.supportsIPv6 = supportsIPv6
  }
}

struct ConnectionPathSnapshot: Sendable, Equatable {
  let isAvailable: Bool
  let route: ConnectionPathRoute?
  let quality: ConnectionNetworkQuality

  init(path: NWPath) {
    isAvailable = path.status == .satisfied
    route = isAvailable ? ConnectionPathRoute(path: path) : nil
    quality = (path.isConstrained || path.isExpensive) ? .constrained : .good
  }

  init(
    isAvailable: Bool,
    route: ConnectionPathRoute?,
    quality: ConnectionNetworkQuality
  ) {
    self.isAvailable = isAvailable
    self.route = route
    self.quality = quality
  }

  func change(since previous: ConnectionPathSnapshot?) -> ConnectionPathChange? {
    guard previous != self else { return nil }
    let routeChanged = previous.map {
      $0.isAvailable && isAvailable && $0.route != route
    } ?? false
    return ConnectionPathChange(
      isAvailable: isAvailable,
      routeChanged: routeChanged,
      quality: quality
    )
  }
}

struct ConnectionPathChange: Sendable, Equatable {
  let isAvailable: Bool
  let routeChanged: Bool
  let quality: ConnectionNetworkQuality
}

final class NetworkConnectionAdapter {
  private let manager: ConnectionManager
  private let monitor = NWPathMonitor()
  private let snapshotStream: AsyncStream<ConnectionPathSnapshot>
  private let snapshotContinuation: AsyncStream<ConnectionPathSnapshot>.Continuation
  private var task: Task<Void, Never>?

  init(manager: ConnectionManager) {
    self.manager = manager
    (snapshotStream, snapshotContinuation) = AsyncStream.create(
      ConnectionPathSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
  }

  func start() {
    guard task == nil else { return }
    let manager = self.manager
    let snapshots = self.snapshotStream
    task = Task {
      var previous: ConnectionPathSnapshot?
      for await snapshot in snapshots {
        guard !Task.isCancelled else { return }
        guard let change = snapshot.change(since: previous) else { continue }
        previous = snapshot
        await manager.networkPathChanged(
          isAvailable: change.isAvailable,
          routeChanged: change.routeChanged,
          quality: change.quality
        )
      }
    }

    let snapshotContinuation = self.snapshotContinuation
    monitor.pathUpdateHandler = { path in
      snapshotContinuation.yield(ConnectionPathSnapshot(path: path))
    }
    monitor.start(queue: DispatchQueue(label: "RealtimeV2.ConnectionManager.path"))
  }

  func stop(isolation: isolated (any Actor)? = #isolation) async {
    monitor.pathUpdateHandler = nil
    monitor.cancel()
    snapshotContinuation.finish()
    let endingTask = task
    task = nil
    endingTask?.cancel()
    await endingTask?.value
  }

  deinit {
    monitor.pathUpdateHandler = nil
    monitor.cancel()
    snapshotContinuation.finish()
    task?.cancel()
  }
}
