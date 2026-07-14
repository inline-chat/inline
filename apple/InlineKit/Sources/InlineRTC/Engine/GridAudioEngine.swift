import Foundation
import Logger

protocol GridAudioDriver: Sendable {
  var events: AsyncStream<GridAudioDriverEvent> { get }

  func configure(_ configuration: InlineRTCConfiguration) async throws
  func setPrepared(_ prepared: Bool) async throws
  func recoverPreparedAudio(preserving target: AudioInputRouteTarget?) async throws
  func isAudioEngineRunning() async -> Bool
  func runtimeHealth() async -> GridAudioRuntimeHealth
  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio: Bool
  ) async throws
  func inputDeviceInventory() async -> AudioInputDeviceInventory
}

extension GridAudioDriver {
  var events: AsyncStream<GridAudioDriverEvent> {
    AsyncStream { continuation in continuation.finish() }
  }

  func recoverPreparedAudio(preserving _: AudioInputRouteTarget?) async throws {}

  func isAudioEngineRunning() async -> Bool { true }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    GridAudioRuntimeHealth(isEngineRunning: await isAudioEngineRunning(), route: nil)
  }
}

actor GridAudioEngine {
  nonisolated let snapshots: AsyncStream<InlineRTCAudioSnapshot>
  nonisolated let deviceSnapshots: AsyncStream<AudioInputDeviceSnapshot>

  private let driver: any GridAudioDriver
  private let permissionDriver: any GridMicrophonePermissionDriver
  private let configuration: InlineRTCConfiguration
  private let captureCooldown: Duration
  private let deviceChangeSettleDelay: Duration
  private let engineRecoveryDelay: Duration
  private let engineHealthCheckDelay: Duration
  private let lifetimeHealthCheckInterval: Duration
  private let snapshotContinuation: AsyncStream<InlineRTCAudioSnapshot>.Continuation
  private let deviceSnapshotContinuation: AsyncStream<AudioInputDeviceSnapshot>.Continuation
  private let log = Log.scoped("GridAudioEngine")

  private var state: InlineRTCAudioState = .cold
  private var started = false
  private var captureLeases = Set<GridAudioLease>()
  private var driverMutationInFlight = false
  private var currentDriverOperation: String?
  private var configured = false
  private var appliedPrepared = false
  private var captureEngineHealthy = false
  private var engineRecoveryPending = false
  private var engineRecoveryInFlight = false
  private var engineRecoveryAttempt = 0
  private var recoveryDemandGeneration = 0
  private var engineHealthGeneration = 0
  private var deviceRouteGeneration = 0
  private var keepPreparedThroughCooldown = false
  private var cooldownGeneration = 0
  private var reconcileTask: Task<Void, Never>?
  private var driverEventsTask: Task<Void, Never>?
  private var deviceReconcileTask: Task<Void, Never>?
  private var engineRecoveryTask: Task<Void, Never>?
  private var engineHealthCheckTask: Task<Void, Never>?
  private var lifetimeHealthTask: Task<Void, Never>?
  private var lifetimeHealthCheckCount = 0
  private var inputRoute = AudioInputRouteState()
  /// Inventory reads are side-effect free. A route is only applied after the
  /// product supplies input intent. A capture lease cannot invent an Auto
  /// intent because complete media demand already contains the persisted input
  /// preference. This prevents a cold Auto graph from racing the real route.
  private var hasInputIntent = false
  private var inputRouteRetrySuspended = false
  private var lastInputRouteError: String?
  private var routeSnapshot: InlineRTCAudioRoute?
  private var desiredOutputVolume: Float = 1
  private var lastTransitionMilliseconds: Int?
  private var microphonePermission: InlineRTCMicrophonePermission = .notDetermined
  /// Configuration/prepare failures require an explicit retry. Input-route
  /// failures have their own narrower suspension and never block leave/stop.
  private var engineReconcileSuspended = false

  init(
    driver: any GridAudioDriver = LiveKitGridAudioDriver(),
    permissionDriver: any GridMicrophonePermissionDriver = SystemGridMicrophonePermissionDriver(),
    configuration: InlineRTCConfiguration = .voice,
    captureCooldown: Duration = .seconds(2),
    deviceChangeSettleDelay: Duration = .milliseconds(350),
    engineRecoveryDelay: Duration = .milliseconds(500),
    engineHealthCheckDelay: Duration = .milliseconds(150),
    lifetimeHealthCheckInterval: Duration = .seconds(15)
  ) {
    self.driver = driver
    self.permissionDriver = permissionDriver
    self.configuration = configuration
    self.captureCooldown = captureCooldown
    self.deviceChangeSettleDelay = deviceChangeSettleDelay
    self.engineRecoveryDelay = engineRecoveryDelay
    self.engineHealthCheckDelay = engineHealthCheckDelay
    self.lifetimeHealthCheckInterval = lifetimeHealthCheckInterval
    let stream = AsyncStream.makeStream(
      of: InlineRTCAudioSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    snapshots = stream.stream
    snapshotContinuation = stream.continuation
    let deviceStream = AsyncStream.makeStream(
      of: AudioInputDeviceSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    deviceSnapshots = deviceStream.stream
    deviceSnapshotContinuation = deviceStream.continuation
  }

  deinit {
    reconcileTask?.cancel()
    driverEventsTask?.cancel()
    deviceReconcileTask?.cancel()
    engineRecoveryTask?.cancel()
    engineHealthCheckTask?.cancel()
    lifetimeHealthTask?.cancel()
    snapshotContinuation.finish()
    deviceSnapshotContinuation.finish()
  }

  func start() async {
    guard !started else { return }
    started = true
    log.debug("GRID_ENGINE phase=audio_engine_start_started")
    microphonePermission = await permissionDriver.status()
    startDriverEventsIfNeeded()
    emitSnapshot()
    scheduleReconcile()
    log.debug(
      "GRID_ENGINE phase=audio_engine_start_finished permission=\(String(describing: microphonePermission))"
    )
  }

  func acquireCaptureLease(_ lease: GridAudioLease) async {
    await start()
    let wasEmpty = captureLeases.isEmpty
    guard captureLeases.insert(lease).inserted else { return }
    if !hasInputIntent {
      log.warning("GRID_ENGINE phase=audio_capture_waiting reason=input_intent_missing")
    }
    // A second lifecycle lease for the same room must not turn a suspended
    // route failure back into a retry loop. A genuinely new call (zero -> one
    // leases) may retry once; explicit UI retry remains available at any time.
    if wasEmpty, inputRouteRetrySuspended {
      inputRouteRetrySuspended = false
      lastInputRouteError = nil
      inputRoute.clearRouteFailure()
      inputRoute.assumeCurrentRouteUnknown()
    }
    if wasEmpty { recoveryDemandGeneration &+= 1 }
    cooldownGeneration &+= 1
    keepPreparedThroughCooldown = false
    engineReconcileSuspended = false
    startLifetimeHealthChecksIfNeeded()
    log.debug("GRID_ENGINE phase=audio_lease_acquired count=\(captureLeases.count)")
    emitSnapshot()
    scheduleReconcile()
    if appliedPrepared, !captureEngineHealthy {
      requestEngineRecovery(immediate: true)
    }
  }

  func releaseCaptureLease(_ lease: GridAudioLease) {
    guard captureLeases.remove(lease) != nil else { return }
    log.debug("GRID_ENGINE phase=audio_lease_released count=\(captureLeases.count)")
    guard captureLeases.isEmpty else {
      emitSnapshot()
      scheduleReconcile()
      return
    }

    lifetimeHealthTask?.cancel()
    lifetimeHealthTask = nil
    lifetimeHealthCheckCount = 0
    recoveryDemandGeneration &+= 1
    engineRecoveryTask?.cancel()
    engineRecoveryTask = nil
    engineRecoveryPending = false

    guard appliedPrepared || currentDriverOperation == "prepare" else {
      captureEngineHealthy = false
      state = .cold
      emitSnapshot()
      return
    }

    keepPreparedThroughCooldown = true
    cooldownGeneration &+= 1
    let generation = cooldownGeneration
    state = .coolingDown
    emitSnapshot()
    Task { [weak self, captureCooldown] in
      try? await Task.sleep(for: captureCooldown)
      await self?.captureCooldownFinished(generation: generation)
    }
  }

  /// Terminal process/logout path. Ordinary leave retains the short warm-audio
  /// grace period, but logout must stop capture without waiting for cooldown.
  func shutdown() async {
    reconcileTask?.cancel()
    reconcileTask = nil
    captureLeases.removeAll(keepingCapacity: true)
    keepPreparedThroughCooldown = false
    cooldownGeneration &+= 1
    recoveryDemandGeneration &+= 1
    engineHealthGeneration &+= 1
    lifetimeHealthTask?.cancel()
    lifetimeHealthTask = nil
    engineRecoveryTask?.cancel()
    engineRecoveryTask = nil
    engineHealthCheckTask?.cancel()
    engineHealthCheckTask = nil
    deviceReconcileTask?.cancel()
    deviceReconcileTask = nil
    engineRecoveryPending = false
    engineRecoveryAttempt = 0

    guard appliedPrepared else {
      captureEngineHealthy = false
      state = .cold
      emitSnapshot()
      return
    }
    guard !driverMutationInFlight else {
      // The in-flight mutation retains physical ownership. Its completion will
      // schedule the pending stop; do not overlap global Core Audio mutations.
      state = .stopping
      emitSnapshot()
      return
    }

    state = .stopping
    emitSnapshot()
    let result = await mutateDriver("shutdown") { [driver] in
      try await driver.setPrepared(false)
    }
    switch result {
    case .success:
      appliedPrepared = false
      captureEngineHealthy = false
      state = .cold
    case let .failure(error):
      state = .failed(String(describing: error))
    }
    emitSnapshot()
  }

  func setInput(_ selection: AudioInputSelection) {
    let isFirstIntent = !hasInputIntent
    hasInputIntent = true
    guard isFirstIntent || inputRoute.desiredSelection != selection else { return }
    if inputRoute.desiredSelection != selection {
      inputRoute.setSelection(selection)
    }
    inputRouteRetrySuspended = false
    lastInputRouteError = nil
    deviceRouteGeneration &+= 1
    engineReconcileSuspended = false
    emitInputDeviceSnapshot()
    scheduleReconcile()
  }

  func retryInput(_ selection: AudioInputSelection) {
    hasInputIntent = true
    inputRouteRetrySuspended = false
    lastInputRouteError = nil
    inputRoute.clearRouteFailure()
    if inputRoute.desiredSelection != selection {
      inputRoute.setSelection(selection)
    } else {
      inputRoute.assumeCurrentRouteUnknown()
    }
    deviceRouteGeneration &+= 1
    engineReconcileSuspended = false
    emitInputDeviceSnapshot()
    scheduleReconcile()
  }

  func setOutputVolume(_ volume: Float) {
    let clamped = min(max(volume, 0), 1)
    guard desiredOutputVolume != clamped else { return }
    desiredOutputVolume = clamped
    engineReconcileSuspended = false
    emitSnapshot()
    scheduleReconcile()
  }

  func deviceSnapshot() async -> AudioInputDeviceSnapshot {
    let inventory = await driver.inputDeviceInventory()
    inputRoute.observe(inventory)
    inputRoute.commitResolvedMetadataIfRouteMatches()
    let snapshot = inputRoute.snapshot ?? inventory.snapshot(resolving: inputRoute.desiredSelection)
    deviceSnapshotContinuation.yield(snapshot)
    if hasInputIntent, !inputRouteRetrySuspended, inputRoute.needsRouteTransaction {
      scheduleReconcile()
    }
    return snapshot
  }

  func currentSnapshot() -> InlineRTCAudioSnapshot {
    makeSnapshot()
  }

  func requestMicrophonePermission() async {
    let current = await permissionDriver.status()
    if current == .notDetermined {
      microphonePermission = .requesting
      emitSnapshot()
      microphonePermission = await permissionDriver.request()
    } else {
      microphonePermission = current
    }
    engineReconcileSuspended = false
    emitSnapshot()
    scheduleReconcile()
  }

  func retry() async {
    microphonePermission = await permissionDriver.status()
    engineReconcileSuspended = false
    if inputRouteRetrySuspended {
      inputRouteRetrySuspended = false
      lastInputRouteError = nil
      inputRoute.clearRouteFailure()
      inputRoute.assumeCurrentRouteUnknown()
    }
    if appliedPrepared, !captureEngineHealthy, !captureLeases.isEmpty {
      engineRecoveryAttempt = 0
      requestEngineRecovery(immediate: true)
    }
    scheduleReconcile()
  }

  /// Re-checks an established runtime after wake or network churn without
  /// clearing a quarantined route/configuration failure. External lifecycle
  /// signals are not evidence that an unavailable microphone became valid;
  /// only a device update or explicit user retry may re-run that mutation.
  func checkRuntimeHealthAfterInterruption() async {
    guard configured, appliedPrepared, !captureLeases.isEmpty else { return }
    let health = await driver.runtimeHealth()
    routeSnapshot = health.route
    guard !health.isHealthy else { return }
    captureEngineHealthy = false
    state = .warming
    emitSnapshot()
    requestEngineRecovery(immediate: true)
  }

  /// Escalates concrete PCM starvation even when Core Audio still reports a
  /// running engine and valid route. Signaling and graph flags are not proof
  /// that capture frames are reaching WebRTC.
  func captureFlowMissing() {
    mediaFlowMissing(direction: "capture")
  }

  func playoutFlowMissing() async {
    guard appliedPrepared, !captureLeases.isEmpty else { return }
    let health = await driver.runtimeHealth()
    routeSnapshot = health.route
    let physicalOutputHealthy = health.isPlaying && health.route?.isOutputRouteValid != false
    guard !physicalOutputHealthy else {
      // This signal is measured on LiveKit's decoded remote track, before the
      // Inline-owned AUHAL renderer. Missing network/decoder PCM must not
      // restart healthy physical hardware; the output callback liveness check
      // below independently recovers a genuinely stalled Audio Unit.
      log.debug(
        "GRID_ENGINE phase=audio_remote_flow_missing physical_output=healthy action=preserve_route"
      )
      emitSnapshot()
      return
    }
    mediaFlowMissing(direction: "playout")
  }

  private func mediaFlowMissing(direction: String) {
    guard appliedPrepared, !captureLeases.isEmpty else { return }
    captureEngineHealthy = false
    state = .warming
    engineRecoveryPending = true
    log.warning(
      "GRID_ENGINE phase=audio_media_flow_missing direction=\(direction) action=recover leases=\(captureLeases.count)"
    )
    emitSnapshot()
    scheduleEngineRecovery(after: .zero)
  }

  private func captureCooldownFinished(generation: Int) {
    guard generation == cooldownGeneration, captureLeases.isEmpty else { return }
    keepPreparedThroughCooldown = false
    log.debug("GRID_ENGINE phase=audio_cooldown_finished")
    scheduleReconcile()
  }

  private func scheduleReconcile() {
    guard reconcileTask == nil, !engineReconcileSuspended else { return }
    reconcileTask = Task { [weak self] in
      await self?.runReconcileLoop()
    }
  }

  private func runReconcileLoop() async {
    defer {
      reconcileTask = nil
      if needsReconcile,
         !engineReconcileSuspended,
         !driverMutationInFlight {
        scheduleReconcile()
      }
    }

    while !Task.isCancelled {
      guard !driverMutationInFlight else { return }

      if !configured {
        state = .configuring
        emitSnapshot()
        log.debug("GRID_ENGINE phase=audio_driver_configure_started")
        let result = await mutateDriver("configure") { [driver, configuration] in
          try await driver.configure(configuration)
        }
        switch result {
        case .success:
          configured = true
        case let .failure(error):
          state = .failed(error.localizedDescription)
          engineReconcileSuspended = true
          emitSnapshot()
          return
        }
        continue
      }

      if inputRoute.inventory == nil {
        let inventory = await driver.inputDeviceInventory()
        inputRoute.observe(inventory)
        inputRoute.commitResolvedMetadataIfRouteMatches()
        emitInputDeviceSnapshot()
        continue
      }

      inputRoute.commitResolvedMetadataIfRouteMatches()
      if hasInputIntent,
         !inputRouteRetrySuspended,
         inputRoute.needsRouteTransaction,
         let resolution = inputRoute.desiredResolution {
        let routeRevision = inputRoute.revision
        let restartPreparedAudio = appliedPrepared
        captureEngineHealthy = appliedPrepared ? false : captureEngineHealthy
        if appliedPrepared {
          state = .warming
          emitSnapshot()
        }
        let result = await mutateDriver("input") { [driver] in
          try await driver.applyInputRoute(
            resolution.target,
            restartPreparedAudio: restartPreparedAudio
          )
        }
        switch result {
        case .success:
          inputRoute.routeTransactionSucceeded(resolution)
          lastInputRouteError = nil
          emitInputDeviceSnapshot()
          if appliedPrepared {
            let health = await driver.runtimeHealth()
            routeSnapshot = health.route
            captureEngineHealthy = health.isHealthy
            if !health.isHealthy, !captureLeases.isEmpty {
              requestEngineRecovery(immediate: true)
            }
          }
          log.debug(
            "GRID_ENGINE phase=input_route_committed target=\(resolution.target.logDescription) requested_revision=\(routeRevision) latest_revision=\(inputRoute.revision) stale=\(routeRevision != inputRoute.revision)"
          )
        case let .failure(error):
          // A device may disappear while a transaction is in flight. Refresh
          // inventory before classifying the error: if policy now resolves to
          // another target, reconcile that latest target instead of surfacing
          // a stale failure or erasing the user's preference.
          let inventory = await driver.inputDeviceInventory()
          inputRoute.observe(inventory)
          emitInputDeviceSnapshot()
          if inputRoute.desiredResolution?.target != resolution.target {
            inputRoute.assumeCurrentRouteUnknown()
            log.debug("GRID_ENGINE phase=input_route_failure_superseded action=reconcile_latest")
            continue
          }
          inputRoute.routeTransactionFailed(resolution)
          emitInputDeviceSnapshot()
          if inputRoute.desiredResolution?.target != resolution.target {
            log.warning(
              "GRID_ENGINE phase=input_route_failure_fallback failed_target=\(resolution.target.logDescription) fallback_target=\(inputRoute.desiredResolution?.target.logDescription ?? "unknown")"
            )
            continue
          }
          inputRouteRetrySuspended = true
          lastInputRouteError = error.localizedDescription
          if appliedPrepared {
            let health = await driver.runtimeHealth()
            routeSnapshot = health.route
            captureEngineHealthy = health.isHealthy
          }
          state = .failed(error.localizedDescription)
          emitSnapshot()
          continue
        }
        continue
      }

      let shouldBePrepared = hasInputIntent && (!captureLeases.isEmpty || keepPreparedThroughCooldown)
      if shouldBePrepared, !microphonePermission.permitsCapture {
        state = switch microphonePermission {
        case .denied, .restricted: .permissionDenied
        case .notDetermined, .requesting: .waitingForPermission
        case .authorized: .warming
        }
        emitSnapshot()
        return
      }
      if appliedPrepared != shouldBePrepared {
        state = shouldBePrepared ? .warming : .stopping
        emitSnapshot()
        let result = await mutateDriver(shouldBePrepared ? "prepare" : "stop") { [driver] in
          try await driver.setPrepared(shouldBePrepared)
        }
        switch result {
        case .success:
          appliedPrepared = shouldBePrepared
          if shouldBePrepared {
            let health = await driver.runtimeHealth()
            routeSnapshot = health.route
            captureEngineHealthy = health.isHealthy
            if !captureEngineHealthy, !captureLeases.isEmpty {
              requestEngineRecovery(immediate: false)
            }
          } else {
            captureEngineHealthy = false
            engineRecoveryPending = false
            engineRecoveryAttempt = 0
            engineRecoveryTask?.cancel()
            engineRecoveryTask = nil
            engineHealthCheckTask?.cancel()
            engineHealthCheckTask = nil
          }
        case let .failure(error):
          state = .failed(error.localizedDescription)
          engineReconcileSuspended = true
          emitSnapshot()
          return
        }
        continue
      }

      updateStableState()
      emitSnapshot()
      return
    }
  }

  private var needsReconcile: Bool {
    guard configured else { return true }
    if inputRoute.inventory == nil { return true }
    if hasInputIntent, !inputRouteRetrySuspended, inputRoute.needsRouteTransaction { return true }
    let shouldBePrepared = hasInputIntent && (!captureLeases.isEmpty || keepPreparedThroughCooldown)
    if shouldBePrepared, !microphonePermission.permitsCapture { return false }
    return appliedPrepared != shouldBePrepared
  }

  private func mutateDriver<Value: Sendable>(
    _ operation: String,
    body: @escaping @Sendable () async throws -> Value
  ) async -> Result<Value, Error> {
    guard !driverMutationInFlight else {
      log.error(
        "GRID_ENGINE phase=audio_driver_operation_overlap rejected=\(operation) active=\(currentDriverOperation ?? "unknown")"
      )
      return .failure(GridAudioEngineError.driverOperationOverlap)
    }
    driverMutationInFlight = true
    currentDriverOperation = operation
    let startedAt = Date()
    defer {
      driverMutationInFlight = false
      currentDriverOperation = nil
      lastTransitionMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
      log.debug(
        "GRID_ENGINE phase=audio_driver_operation_done operation=\(operation) elapsed_ms=\(lastTransitionMilliseconds ?? 0)"
      )
      emitSnapshot()
      if engineRecoveryPending, operation != "recover" {
        scheduleEngineRecovery(after: .zero)
      }
      if needsReconcile, !engineReconcileSuspended {
        scheduleReconcile()
      }
    }
    do {
      return .success(try await body())
    } catch {
      log.error("GRID_ENGINE phase=audio_driver_operation_failed operation=\(operation)", error: error)
      return .failure(error)
    }
  }

  private func emitSnapshot() {
    snapshotContinuation.yield(makeSnapshot())
  }

  private func emitInputDeviceSnapshot() {
    guard let snapshot = inputRoute.snapshot else { return }
    deviceSnapshotContinuation.yield(snapshot)
  }

  private func deviceListChanged() {
    log.debug("GRID_ENGINE phase=audio_devices_changed")
    deviceRouteGeneration &+= 1
    let generation = deviceRouteGeneration
    deviceReconcileTask?.cancel()
    deviceReconcileTask = Task { [weak self, deviceChangeSettleDelay] in
      try? await Task.sleep(for: deviceChangeSettleDelay)
      guard !Task.isCancelled else { return }
      await self?.deviceListSettled(generation: generation)
    }
  }

  private func deviceListSettled(generation: Int) async {
    var previousInventory: AudioInputDeviceInventory?
    var previousHealth: GridAudioRuntimeHealth?
    var stableSampleCount = 0
    var finalInventory: AudioInputDeviceInventory?
    var finalHealth: GridAudioRuntimeHealth?
    for _ in 0 ..< 12 {
      let inventory = await driver.inputDeviceInventory()
      guard generation == deviceRouteGeneration, !Task.isCancelled else { return }
      let health = await driver.runtimeHealth()
      guard generation == deviceRouteGeneration, !Task.isCancelled else { return }
      finalInventory = inventory
      finalHealth = health
      if inventory == previousInventory, health == previousHealth {
        stableSampleCount += 1
      } else {
        previousInventory = inventory
        previousHealth = health
        stableSampleCount = 1
      }
      if stableSampleCount >= 3 { break }
      try? await Task.sleep(for: deviceChangeSettleDelay)
      guard !Task.isCancelled else { return }
    }
    guard generation == deviceRouteGeneration,
          let inventory = finalInventory,
          let health = finalHealth
    else { return }
    deviceReconcileTask = nil
    routeSnapshot = health.route
    inputRoute.observe(inventory)
    inputRoute.commitResolvedMetadataIfRouteMatches()
    emitInputDeviceSnapshot()
    if appliedPrepared, !health.isHealthy, !captureLeases.isEmpty {
      captureEngineHealthy = false
      state = .warming
      requestEngineRecovery(immediate: true)
    }
    log.debug(
      "GRID_ENGINE phase=audio_devices_settled samples=\(stableSampleCount) count=\(inventory.devices.count) selection=\(inputRoute.desiredSelection.logDescription) target=\(inputRoute.desiredResolution?.target.logDescription ?? "unknown") running=\(health.isEngineRunning) recording=\(health.isRecording) playing=\(health.isPlaying) input_valid=\(health.route?.isInputRouteValid ?? true) output_valid=\(health.route?.isOutputRouteValid ?? true) fallback=\(inputRoute.desiredResolution?.isFallingBackToAutomatic ?? false) route_change=\(hasInputIntent && inputRoute.needsRouteTransaction)"
    )
    scheduleReconcile()
  }

  private func audioEngineStopped(playout: Bool, recording: Bool) {
    engineHealthGeneration &+= 1
    captureEngineHealthy = false
    engineHealthCheckTask?.cancel()
    engineHealthCheckTask = nil
    guard appliedPrepared else { return }
    if let currentDriverOperation,
       ["input", "recover", "stop", "shutdown"].contains(currentDriverOperation) {
      log.debug(
        "GRID_ENGINE phase=audio_engine_stop_expected operation=\(currentDriverOperation) playout=\(playout) recording=\(recording)"
      )
      return
    }
    if engineRecoveryPending {
      log.debug(
        "GRID_ENGINE phase=audio_engine_stop_coalesced playout=\(playout) recording=\(recording)"
      )
    } else {
      log.warning(
        "GRID_ENGINE phase=audio_engine_stopped playout=\(playout) recording=\(recording) prepared=\(appliedPrepared)"
      )
    }
    guard !captureLeases.isEmpty else {
      updateStableState()
      emitSnapshot()
      return
    }
    state = .warming
    emitSnapshot()
    engineRecoveryPending = true
    if engineRecoveryInFlight {
      log.debug("GRID_ENGINE phase=audio_engine_stop_during_recovery action=coalesce")
      return
    }
    engineRecoveryTask?.cancel()
    engineRecoveryTask = nil
    scheduleEngineRecovery(after: engineRecoveryDelay)
  }

  private func recoverPreparedAudioIfNeeded(generation: Int) async {
    guard generation == recoveryDemandGeneration else {
      engineRecoveryTask = nil
      return
    }
    guard engineRecoveryPending,
          appliedPrepared,
          !captureLeases.isEmpty
    else {
      engineRecoveryPending = false
      engineRecoveryTask = nil
      return
    }
    guard !hasInputIntent || inputRouteRetrySuspended || !inputRoute.needsRouteTransaction else {
      log.debug("GRID_ENGINE phase=audio_engine_recovery_deferred reason=input_route_pending")
      engineRecoveryTask = nil
      engineReconcileSuspended = false
      scheduleReconcile()
      return
    }
    guard !driverMutationInFlight else {
      log.debug(
        "GRID_ENGINE phase=audio_engine_recovery_deferred mutation=\(currentDriverOperation ?? "none")"
      )
      engineRecoveryTask = nil
      return
    }

    engineRecoveryInFlight = true
    defer {
      engineRecoveryInFlight = false
      engineRecoveryTask = nil
      if engineRecoveryPending,
         !captureLeases.isEmpty,
         !driverMutationInFlight {
        scheduleEngineRecovery(after: Self.engineRecoveryBackoff(after: engineRecoveryAttempt))
      }
    }
    engineRecoveryAttempt += 1
    let attempt = engineRecoveryAttempt
    let preRecoveryHealth = await driver.runtimeHealth()
    routeSnapshot = preRecoveryHealth.route
    let recoveryTarget = inputRoute.desiredResolution?.target ?? inputRoute.appliedTarget
    state = .warming
    emitSnapshot()
    let result = await mutateDriver("recover") { [driver] in
      try await driver.recoverPreparedAudio(preserving: recoveryTarget)
    }
    guard generation == recoveryDemandGeneration, !captureLeases.isEmpty else {
      log.debug("GRID_ENGINE phase=audio_engine_recovery_discarded reason=stale_demand")
      return
    }
    switch result {
    case .success:
      let health = await driver.runtimeHealth()
      routeSnapshot = health.route
      captureEngineHealthy = health.isHealthy
      if captureEngineHealthy {
        engineRecoveryPending = false
        engineRecoveryAttempt = 0
        engineReconcileSuspended = false
        updateStableState()
        log.debug(
          "GRID_ENGINE phase=audio_engine_recovery_finished attempt=\(attempt) target=\(recoveryTarget?.logDescription ?? "unknown")"
        )
      } else {
        state = .failed("Audio engine did not restart")
        log.warning("GRID_ENGINE phase=audio_engine_recovery_unhealthy attempt=\(attempt)")
      }
    case let .failure(error):
      state = .failed(error.localizedDescription)
      if attempt == 3 || attempt.isMultiple(of: 10) {
        log.error(
          "GRID_ENGINE phase=audio_engine_recovery_persistently_failed attempt=\(attempt)",
          error: error
        )
      } else {
        log.warning("GRID_ENGINE phase=audio_engine_recovery_failed attempt=\(attempt)")
      }
    }
    emitSnapshot()
  }

  private func requestEngineRecovery(immediate: Bool) {
    guard appliedPrepared, !captureLeases.isEmpty, !captureEngineHealthy else { return }
    engineRecoveryPending = true
    scheduleEngineRecovery(after: immediate ? .zero : engineRecoveryDelay)
  }

  private func scheduleEngineRecovery(after delay: Duration) {
    guard engineRecoveryPending, engineRecoveryTask == nil else { return }
    let generation = recoveryDemandGeneration
    engineRecoveryTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.recoverPreparedAudioIfNeeded(generation: generation)
    }
  }

  private func scheduleEngineHealthCheck() {
    engineHealthCheckTask?.cancel()
    engineHealthGeneration &+= 1
    let generation = engineHealthGeneration
    engineHealthCheckTask = Task { [weak self, engineHealthCheckDelay] in
      try? await Task.sleep(for: engineHealthCheckDelay)
      guard !Task.isCancelled else { return }
      await self?.checkEngineHealth(generation: generation)
    }
  }

  private func checkEngineHealth(generation: Int) async {
    guard generation == engineHealthGeneration else { return }
    engineHealthCheckTask = nil
    let health = await driver.runtimeHealth()
    guard generation == engineHealthGeneration else { return }
    routeSnapshot = health.route
    captureEngineHealthy = health.isHealthy && appliedPrepared
    if captureEngineHealthy {
      engineRecoveryPending = false
      engineRecoveryAttempt = 0
      if !engineRecoveryInFlight {
        engineRecoveryTask?.cancel()
        engineRecoveryTask = nil
      }
      engineReconcileSuspended = false
      updateStableState()
      log.debug("GRID_ENGINE phase=audio_engine_health_confirmed")
    } else if appliedPrepared, !captureLeases.isEmpty {
      engineRecoveryPending = true
      state = .warming
      scheduleEngineRecovery(after: engineRecoveryDelay)
    }
    emitSnapshot()
  }

  private func startLifetimeHealthChecksIfNeeded() {
    guard lifetimeHealthTask == nil, !captureLeases.isEmpty else { return }
    lifetimeHealthTask = Task { [weak self, lifetimeHealthCheckInterval] in
      while !Task.isCancelled {
        try? await Task.sleep(for: lifetimeHealthCheckInterval)
        guard !Task.isCancelled else { return }
        guard await self?.checkLifetimeAudioHealth() == true else { return }
      }
    }
  }

  private func checkLifetimeAudioHealth() async -> Bool {
    guard !captureLeases.isEmpty else {
      lifetimeHealthTask = nil
      lifetimeHealthCheckCount = 0
      return false
    }

    let demandGeneration = recoveryDemandGeneration
    lifetimeHealthCheckCount &+= 1
    let health = await driver.runtimeHealth()
    guard demandGeneration == recoveryDemandGeneration,
          !captureLeases.isEmpty,
          !Task.isCancelled
    else {
      return false
    }
    let wasHealthy = captureEngineHealthy
    routeSnapshot = health.route
    if appliedPrepared, health.isHealthy {
      captureEngineHealthy = true
      if !wasHealthy {
        engineRecoveryPending = false
        engineRecoveryAttempt = 0
        if !engineRecoveryInFlight {
          engineRecoveryTask?.cancel()
          engineRecoveryTask = nil
        }
        engineReconcileSuspended = false
        updateStableState()
        log.debug("GRID_ENGINE phase=audio_lifetime_health_recovered")
        emitSnapshot()
      }
    } else {
      captureEngineHealthy = false
      state = .warming
      if wasHealthy || !engineRecoveryPending {
        log.warning(
          "GRID_ENGINE phase=audio_lifetime_health_degraded prepared=\(appliedPrepared) running=\(health.isEngineRunning) recording=\(health.isRecording) playing=\(health.isPlaying) input_valid=\(health.route?.isInputRouteValid ?? true) output_valid=\(health.route?.isOutputRouteValid ?? true) leases=\(captureLeases.count)"
        )
      }
      engineRecoveryPending = true
      scheduleEngineRecovery(after: .zero)
      emitSnapshot()
    }

    // Four checks per minute at the default interval gives useful call-lifetime
    // breadcrumbs without logging on every audio callback or level update.
    if lifetimeHealthCheckCount.isMultiple(of: 4) {
      log.debug(
        "GRID_ENGINE phase=audio_lifetime_health heartbeat=\(lifetimeHealthCheckCount) running=\(health.isEngineRunning) recording=\(health.isRecording) playing=\(health.isPlaying) input_valid=\(health.route?.isInputRouteValid ?? true) output_valid=\(health.route?.isOutputRouteValid ?? true) prepared=\(appliedPrepared) leases=\(captureLeases.count) recovery_attempt=\(engineRecoveryAttempt) selection=\(inputRoute.desiredSelection.logDescription) target=\(inputRoute.appliedTarget?.logDescription ?? "unknown") fallback=\(inputRoute.desiredResolution?.isFallingBackToAutomatic ?? false)"
      )
    }
    return true
  }

  private func updateStableState() {
    if let lastInputRouteError {
      state = .failed(lastInputRouteError)
      return
    }
    guard appliedPrepared else {
      state = .cold
      return
    }
    if captureLeases.isEmpty {
      state = .coolingDown
    } else {
      state = captureEngineHealthy ? .ready : .warming
    }
  }

  private func startDriverEventsIfNeeded() {
    guard driverEventsTask == nil else { return }
    driverEventsTask = Task { [weak self, events = driver.events] in
      for await event in events {
        guard !Task.isCancelled else { return }
        await self?.receive(event)
      }
    }
  }

  private func receive(_ event: GridAudioDriverEvent) {
    switch event {
    case .devicesChanged:
      deviceListChanged()
    case let .engineStarting(playout, recording):
      if !engineRecoveryInFlight {
        engineRecoveryTask?.cancel()
        engineRecoveryTask = nil
      }
      log.debug(
        "GRID_ENGINE phase=audio_engine_starting playout=\(playout) recording=\(recording)"
      )
      scheduleEngineHealthCheck()
    case let .engineStopped(playout, recording),
         let .engineDisabled(playout, recording):
      audioEngineStopped(playout: playout, recording: recording)
    case let .expectedEngineStop(playout, recording),
         let .expectedEngineDisable(playout, recording):
      log.debug(
        "GRID_ENGINE phase=audio_engine_transition_expected playout=\(playout) recording=\(recording)"
      )
    }
  }

  private func makeSnapshot() -> InlineRTCAudioSnapshot {
    InlineRTCAudioSnapshot(
      state: state,
      isPrepared: appliedPrepared && captureEngineHealthy,
      captureLeaseCount: captureLeases.count,
      input: inputRoute.snapshot?.resolvedInput,
      route: routeSnapshot,
      outputVolume: desiredOutputVolume,
      lastTransitionMilliseconds: lastTransitionMilliseconds,
      microphonePermission: microphonePermission
    )
  }

  private static func engineRecoveryBackoff(after attempt: Int) -> Duration {
    switch attempt {
    case 0, 1: .seconds(1)
    case 2: .seconds(2)
    case 3: .seconds(4)
    case 4: .seconds(8)
    case 5: .seconds(15)
    default: .seconds(30)
    }
  }
}

private enum GridAudioEngineError: Error {
  case driverOperationOverlap
}

private extension AudioInputSelection {
  var logDescription: String {
    switch self {
    case .automatic: "automatic"
    case .device: "explicit"
    }
  }
}
