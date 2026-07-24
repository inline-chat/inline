import Foundation
import Logger

protocol GridAudioDriver: Sendable {
  var events: AsyncStream<GridAudioDriverEvent> { get }
  /// The stock macOS ADM cannot enumerate, route, or record until WebRTC's
  /// real peer-connection transport initializes its media engine.
  var preparationRequiresRTCTransport: Bool { get }
  /// A custom ADM starts recording only after WebRTC attaches a microphone
  /// sender. In that mode the audio supervisor verifies physical capture but
  /// never fabricates recording demand through a parallel control path.
  var recordingStartsWithMicrophoneSender: Bool { get }

  func configure(_ configuration: InlineRTCConfiguration) async throws
  /// Opens a new media epoch after a completed terminal barrier. This is not
  /// capture demand; it only allows the next WebRTC transport to invoke the
  /// custom device lifecycle.
  func resumeAfterTerminalShutdown() async
  func setPrepared(_ prepared: Bool) async throws
  func stopForShutdown() async -> GridAudioDriverShutdownReceipt
  func recoverPreparedAudio(preserving target: AudioInputRouteTarget?) async throws
  func recoverPlayout(preserving target: AudioOutputRouteTarget?) async throws
  func isAudioEngineRunning() async -> Bool
  func runtimeHealth() async -> GridAudioRuntimeHealth
  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio: Bool
  ) async throws -> GridAudioInputRouteApplication
  func applyOutputRoute(_ target: AudioOutputRouteTarget) async throws
  func inputDeviceInventory() async -> AudioInputDeviceInventory
  func outputDeviceInventory() async -> AudioOutputDeviceInventory
}

enum GridAudioInputRouteApplication: Equatable, Sendable {
  case committed
  /// The requested route failed, but the previous physical route was fully
  /// restored and verified. This is degraded policy fulfillment, not dead
  /// capture, and must never share the fatal throw path.
  case restoredPreviousRoute(failure: String, retryable: Bool = false)
}

enum GridAudioPlayoutRecoveryDeferral: String, Equatable, Sendable {
  case driverMutation = "driver_mutation"
  case deviceSettlement = "device_settlement"
  case outputRouteTransaction = "output_route_transaction"

  static func resolve(
    driverMutationInFlight: Bool,
    deviceSettlementPending: Bool,
    hasOutputIntent: Bool,
    outputRouteRetrySuspended: Bool,
    outputRouteNeedsTransaction: Bool
  ) -> Self? {
    if driverMutationInFlight { return .driverMutation }
    if deviceSettlementPending { return .deviceSettlement }
    if hasOutputIntent,
       !outputRouteRetrySuspended,
       outputRouteNeedsTransaction {
      return .outputRouteTransaction
    }
    return nil
  }
}

extension GridAudioDriver {
  var preparationRequiresRTCTransport: Bool { false }
  var recordingStartsWithMicrophoneSender: Bool { false }

  var events: AsyncStream<GridAudioDriverEvent> {
    AsyncStream { continuation in continuation.finish() }
  }

  func resumeAfterTerminalShutdown() async {}

  func recoverPreparedAudio(preserving _: AudioInputRouteTarget?) async throws {}

  func recoverPlayout(preserving _: AudioOutputRouteTarget?) async throws {}

  func applyOutputRoute(_: AudioOutputRouteTarget) async throws {}

  func outputDeviceInventory() async -> AudioOutputDeviceInventory {
    AudioOutputDeviceInventory(
      automaticDeviceID: nil,
      automaticDeviceName: "System Default",
      devices: [],
      routeFingerprints: [:],
      routeEpoch: 0
    )
  }

  func stopForShutdown() async -> GridAudioDriverShutdownReceipt {
    var failures: [String] = []
    do {
      try await setPrepared(false)
    } catch {
      failures.append(String(describing: error))
    }
    let health = await runtimeHealth()
    return GridAudioDriverShutdownReceipt(
      recordingStopped: !health.isRecording,
      playoutStopped: !health.isPlaying,
      failures: failures
    )
  }

  func isAudioEngineRunning() async -> Bool { true }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    GridAudioRuntimeHealth(isEngineRunning: await isAudioEngineRunning(), route: nil)
  }
}

actor GridAudioEngine {
  nonisolated let snapshots: AsyncStream<InlineRTCAudioSnapshot>
  nonisolated let deviceSnapshots: AsyncStream<AudioInputDeviceSnapshot>
  nonisolated let outputDeviceSnapshots: AsyncStream<AudioOutputDeviceSnapshot>

  private let driver: any GridAudioDriver
  private let permissionDriver: any GridMicrophonePermissionDriver
  private let configuration: InlineRTCConfiguration
  private let captureCooldown: Duration
  private let deviceChangeSettleDelay: Duration
  private let engineRecoveryDelay: Duration
  private let engineHealthCheckDelay: Duration
  private let lifetimeHealthCheckInterval: Duration
  private let shutdownTimeout: Duration
  private let transientRouteRetryDelayOverride: Duration?
  private let snapshotContinuation: AsyncStream<InlineRTCAudioSnapshot>.Continuation
  private let deviceSnapshotContinuation: AsyncStream<AudioInputDeviceSnapshot>.Continuation
  private let outputDeviceSnapshotContinuation: AsyncStream<AudioOutputDeviceSnapshot>.Continuation
  private let log = Log.scoped("GridAudioEngine")

  private var state: InlineRTCAudioState = .cold
  private var started = false
  private var captureLeases = Set<GridAudioLease>()
  private var driverMutationInFlight = false
  private var currentDriverOperation: String?
  private var currentDriverOperationStartedAt: Date?
  private var configured = false
  private var rtcTransportReady: Bool
  /// Invalidates provider completions that began before a terminal logout
  /// barrier. A late, cancellation-insensitive Room.connect must not reopen
  /// capture preparation in a later authenticated session.
  private var rtcTransportGeneration: UInt64 = 0
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
  private var inputRouteRetryTask: Task<Void, Never>?
  private var outputRouteRetryTask: Task<Void, Never>?
  private var lifetimeHealthTask: Task<Void, Never>?
  private var terminalCleanupTask: Task<Void, Never>?
  private var lifetimeHealthCheckCount = 0
  private var inputRoute = AudioInputRouteState()
  private var outputRoute = AudioOutputRouteState()
  /// Inventory reads are side-effect free. A route is only applied after the
  /// product supplies input intent. A capture lease cannot invent an Auto
  /// intent because complete media demand already contains the persisted input
  /// preference. This prevents a cold Auto graph from racing the real route.
  private var hasInputIntent = false
  private var hasOutputIntent = false
  private var inputRouteRetrySuspended = false
  private var outputRouteRetrySuspended = false
  private var inputRouteRetryAttempt = 0
  private var outputRouteRetryAttempt = 0
  private var inputRouteRetryGeneration = 0
  private var outputRouteRetryGeneration = 0
  private var lastInputRouteError: String?
  private var lastOutputRouteError: String?
  private var routeSnapshot: InlineRTCAudioRoute?
  private var processingSnapshot: InlineRTCAudioProcessingState?
  private var latestRuntimeHealth: GridAudioRuntimeHealth?
  private var desiredOutputVolume: Float = 1
  private var lastTransitionMilliseconds: Int?
  private var microphonePermission: InlineRTCMicrophonePermission = .notDetermined
  /// Configuration/prepare failures require an explicit retry. Input-route
  /// failures have their own narrower suspension and never block leave/stop.
  private var engineReconcileSuspended = false
  /// A timed-out terminal caller must receive non-success immediately, but the
  /// runtime still owns an eventual local cleanup obligation. This flag keeps
  /// that obligation durable until both ADM directions are proven stopped.
  private var terminalShutdownRequested = false

  init(
    driver: any GridAudioDriver = LiveKitGridAUHALAudioDriver(),
    permissionDriver: any GridMicrophonePermissionDriver = SystemGridMicrophonePermissionDriver(),
    configuration: InlineRTCConfiguration = .voice,
    captureCooldown: Duration = .seconds(2),
    deviceChangeSettleDelay: Duration = .milliseconds(350),
    engineRecoveryDelay: Duration = .milliseconds(500),
    engineHealthCheckDelay: Duration = .milliseconds(150),
    lifetimeHealthCheckInterval: Duration = .seconds(15),
    shutdownTimeout: Duration = .seconds(3),
    transientRouteRetryDelayOverride: Duration? = nil
  ) {
    self.driver = driver
    self.permissionDriver = permissionDriver
    self.configuration = configuration
    self.captureCooldown = captureCooldown
    self.deviceChangeSettleDelay = deviceChangeSettleDelay
    self.engineRecoveryDelay = engineRecoveryDelay
    self.engineHealthCheckDelay = engineHealthCheckDelay
    self.lifetimeHealthCheckInterval = lifetimeHealthCheckInterval
    self.shutdownTimeout = shutdownTimeout
    self.transientRouteRetryDelayOverride = transientRouteRetryDelayOverride
    rtcTransportReady = !driver.preparationRequiresRTCTransport
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
    let outputDeviceStream = AsyncStream.makeStream(
      of: AudioOutputDeviceSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    outputDeviceSnapshots = outputDeviceStream.stream
    outputDeviceSnapshotContinuation = outputDeviceStream.continuation
  }

  deinit {
    reconcileTask?.cancel()
    driverEventsTask?.cancel()
    deviceReconcileTask?.cancel()
    engineRecoveryTask?.cancel()
    engineHealthCheckTask?.cancel()
    inputRouteRetryTask?.cancel()
    outputRouteRetryTask?.cancel()
    lifetimeHealthTask?.cancel()
    terminalCleanupTask?.cancel()
    snapshotContinuation.finish()
    deviceSnapshotContinuation.finish()
    outputDeviceSnapshotContinuation.finish()
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
    cancelInputRouteRetry(resetAttempt: true)

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
  func shutdown() async -> GridAudioShutdownReceipt {
    terminalShutdownRequested = true
    if driver.preparationRequiresRTCTransport {
      rtcTransportGeneration &+= 1
      rtcTransportReady = false
    }
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
    cancelInputRouteRetry(resetAttempt: true)
    cancelOutputRouteRetry(resetAttempt: true)
    deviceReconcileTask?.cancel()
    deviceReconcileTask = nil
    engineRecoveryPending = false
    engineRecoveryAttempt = 0

    state = .stopping
    emitSnapshot()

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: shutdownTimeout)
    while driverMutationInFlight, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard !driverMutationInFlight else {
      let operation = currentDriverOperation ?? "unknown"
      let failure = "Timed out waiting for audio mutation \(operation) to release ownership."
      state = .failed(failure)
      emitSnapshot()
      scheduleTerminalCleanup()
      return GridAudioShutdownReceipt(
        recordingStopped: false,
        playoutStopped: false,
        mutationReleased: false,
        failures: [failure]
      )
    }

    let receipt = await stopDriverForTerminalShutdown(operation: "shutdown")
    if !receipt.isQuiescent {
      scheduleTerminalCleanup()
    }
    return receipt
  }

  private func stopDriverForTerminalShutdown(
    operation: String
  ) async -> GridAudioShutdownReceipt {
    let result = await mutateDriver(operation) { [driver] in
      await driver.stopForShutdown()
    }
    switch result {
    case let .success(receipt):
      observeRuntimeHealth(GridAudioRuntimeHealth(
        isEngineRunning: !receipt.recordingStopped || !receipt.playoutStopped,
        isRecording: !receipt.recordingStopped,
        isPlaying: !receipt.playoutStopped,
        route: routeSnapshot,
        processing: processingSnapshot
      ))
      appliedPrepared = !receipt.recordingStopped
      captureEngineHealthy = false
      if receipt.isQuiescent {
        terminalShutdownRequested = false
        state = .cold
        if !captureLeases.isEmpty {
          engineReconcileSuspended = false
          startLifetimeHealthChecksIfNeeded()
          scheduleReconcile()
        }
      } else {
        state = .failed(receipt.failures.first ?? "Audio shutdown postconditions were not satisfied.")
      }
      emitSnapshot()
      return GridAudioShutdownReceipt(
        recordingStopped: receipt.recordingStopped,
        playoutStopped: receipt.playoutStopped,
        mutationReleased: true,
        failures: receipt.failures
      )
    case let .failure(error):
      state = .failed(String(describing: error))
      emitSnapshot()
      return GridAudioShutdownReceipt(
        recordingStopped: false,
        playoutStopped: false,
        mutationReleased: true,
        failures: [String(describing: error)]
      )
    }
  }

  private func scheduleTerminalCleanup() {
    guard terminalShutdownRequested, terminalCleanupTask == nil else { return }
    terminalCleanupTask = Task { [weak self] in
      await self?.runTerminalCleanup()
    }
  }

  private func runTerminalCleanup() async {
    defer { terminalCleanupTask = nil }
    var attempt = 0
    while terminalShutdownRequested, !Task.isCancelled {
      while driverMutationInFlight, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
      }
      guard terminalShutdownRequested, !Task.isCancelled else { return }

      attempt += 1
      let receipt = await stopDriverForTerminalShutdown(operation: "shutdown-eventual")
      if receipt.isQuiescent {
        log.info(
          "GRID_ENGINE phase=audio_shutdown_eventual_cleanup result=quiescent attempt=\(attempt)"
        )
        return
      }
      if attempt == 3 || attempt.isMultiple(of: 10) {
        log.error(
          "GRID_ENGINE phase=audio_shutdown_eventual_cleanup result=retrying attempts=\(attempt)"
        )
      }
      try? await Task.sleep(for: Self.terminalCleanupBackoff(after: attempt))
    }
  }

  func setInput(_ selection: AudioInputSelection) {
    let isFirstIntent = !hasInputIntent
    hasInputIntent = true
    guard isFirstIntent
      || inputRoute.desiredSelection != selection
      || inputRouteRetrySuspended
    else { return }
    if inputRoute.desiredSelection != selection {
      inputRoute.setSelection(selection)
    }
    cancelInputRouteRetry(resetAttempt: true)
    inputRouteRetrySuspended = false
    lastInputRouteError = nil
    deviceRouteGeneration &+= 1
    engineReconcileSuspended = false
    emitInputDeviceSnapshot()
    scheduleReconcile()
  }

  func setOutput(_ selection: AudioOutputSelection) {
    let isFirstIntent = !hasOutputIntent
    hasOutputIntent = true
    guard isFirstIntent
      || outputRoute.desiredSelection != selection
      || outputRouteRetrySuspended
    else { return }
    if outputRoute.desiredSelection != selection {
      outputRoute.setSelection(selection)
    }
    cancelOutputRouteRetry(resetAttempt: true)
    outputRouteRetrySuspended = false
    lastOutputRouteError = nil
    deviceRouteGeneration &+= 1
    engineReconcileSuspended = false
    emitOutputDeviceSnapshot()
    scheduleReconcile()
  }

  func isWaitingForRTCTransport() -> Bool {
    !rtcTransportReady
  }

  func rtcTransportPreparationGeneration() -> UInt64 {
    rtcTransportGeneration
  }

  /// Closes capture preparation while a fresh provider room is being created.
  /// A custom M144 ADM can legitimately terminate after the previous room
  /// releases its last media channel; only the matching new connect may reopen
  /// the fence after WebRTC has initialized the device again.
  func rtcTransportWillInitialize() async -> UInt64 {
    if !terminalShutdownRequested {
      await driver.resumeAfterTerminalShutdown()
    }
    guard driver.preparationRequiresRTCTransport else {
      return rtcTransportGeneration
    }
    rtcTransportGeneration &+= 1
    rtcTransportReady = false
    engineReconcileSuspended = false
    inputRoute.assumeCurrentRouteUnknown()
    log.debug(
      "GRID_ENGINE phase=audio_rtc_transport_waiting generation=\(rtcTransportGeneration)"
    )
    scheduleReconcile()
    return rtcTransportGeneration
  }

  func rtcTransportDidInitialize(generation: UInt64) {
    guard generation == rtcTransportGeneration else {
      log.warning(
        "GRID_ENGINE phase=audio_rtc_transport_ignored reason=stale_generation expected=\(rtcTransportGeneration) received=\(generation)"
      )
      return
    }
    guard !rtcTransportReady else { return }
    rtcTransportReady = true
    engineReconcileSuspended = false
    inputRoute.assumeCurrentRouteUnknown()
    log.debug("GRID_ENGINE phase=audio_rtc_transport_ready")
    scheduleReconcile()
  }

  func microphoneSenderMayStartRecording() -> Bool {
    driver.recordingStartsWithMicrophoneSender
      && configured
      && rtcTransportReady
      && !terminalShutdownRequested
      && hasInputIntent
      && !captureLeases.isEmpty
      && microphonePermission.permitsCapture
      && !inputRouteRetrySuspended
      && inputRoute.appliedTarget != nil
      && !inputRoute.needsRouteTransaction
  }

  func retryInput(_ selection: AudioInputSelection) {
    hasInputIntent = true
    cancelInputRouteRetry(resetAttempt: true)
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

  func retryOutput(_ selection: AudioOutputSelection) {
    hasOutputIntent = true
    cancelOutputRouteRetry(resetAttempt: true)
    outputRouteRetrySuspended = false
    lastOutputRouteError = nil
    outputRoute.clearRouteFailure()
    if outputRoute.desiredSelection != selection {
      outputRoute.setSelection(selection)
    } else {
      outputRoute.assumeCurrentRouteUnknown()
    }
    deviceRouteGeneration &+= 1
    engineReconcileSuspended = false
    emitOutputDeviceSnapshot()
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
    observeInputInventory(inventory)
    inputRoute.commitResolvedMetadataIfRouteMatches()
    let snapshot = inputRoute.snapshot ?? inventory.snapshot(resolving: inputRoute.desiredSelection)
    deviceSnapshotContinuation.yield(snapshot)
    if hasInputIntent, !inputRouteRetrySuspended, inputRoute.needsRouteTransaction {
      scheduleReconcile()
    }
    return snapshot
  }

  func outputDeviceSnapshot() async -> AudioOutputDeviceSnapshot {
    let inventory = await driver.outputDeviceInventory()
    outputRoute.observe(inventory)
    outputRoute.commitResolvedMetadataIfRouteMatches()
    let snapshot = outputRoute.snapshot
      ?? inventory.snapshot(resolving: outputRoute.desiredSelection)
    outputDeviceSnapshotContinuation.yield(snapshot)
    if hasOutputIntent,
       !outputRouteRetrySuspended,
       outputRoute.needsRouteTransaction {
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
    cancelInputRouteRetry(resetAttempt: true)
    cancelOutputRouteRetry(resetAttempt: true)
    if inputRouteRetrySuspended {
      inputRouteRetrySuspended = false
      lastInputRouteError = nil
      inputRoute.clearRouteFailure()
      inputRoute.assumeCurrentRouteUnknown()
    }
    if outputRouteRetrySuspended {
      outputRouteRetrySuspended = false
      lastOutputRouteError = nil
      outputRoute.clearRouteFailure()
      outputRoute.assumeCurrentRouteUnknown()
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
    guard configured, !captureLeases.isEmpty else { return }
    guard appliedPrepared || driver.recordingStartsWithMicrophoneSender else { return }
    let health = await driver.runtimeHealth()
    observeRuntimeHealth(health)
    if driver.recordingStartsWithMicrophoneSender {
      appliedPrepared = health.isRecording
    }
    guard !isCaptureRuntimeHealthy(health) else {
      markCaptureRuntimeHealthy()
      updateStableState()
      emitSnapshot()
      return
    }
    guard captureRecoveryIsDemanded(health) else {
      captureEngineHealthy = false
      state = .warming
      emitSnapshot()
      return
    }
    captureEngineHealthy = false
    state = .warming
    emitSnapshot()
    requestEngineRecovery(immediate: true)
  }

  /// Escalates concrete PCM starvation even when Core Audio still reports a
  /// running engine and valid route. Signaling and graph flags are not proof
  /// that capture frames are reaching WebRTC.
  func captureFlowMissing() async -> GridAudioCaptureFailureDisposition? {
    guard configured, !captureLeases.isEmpty, !terminalShutdownRequested else { return nil }
    guard driver.recordingStartsWithMicrophoneSender else {
      mediaFlowMissing(direction: "capture")
      return nil
    }

    let health = await driver.runtimeHealth()
    observeRuntimeHealth(health)
    appliedPrepared = health.isRecording
    captureEngineHealthy = false
    state = .warming
    emitSnapshot()

    // A healthy physical bridge plus missing outbound RTP places the fault
    // after AUHAL (APM, track, sender, or peer connection). Restarting the same
    // hardware cannot repair that ownership boundary.
    if health.isCaptureHealthy {
      log.warning(
        "GRID_ENGINE phase=audio_capture_flow_missing physical=healthy action=reconstruct_rtc_session"
      )
      return .reconstructRTCSession
    }

    // An input/terminal mutation already owns the device. Lifetime RTP checks
    // repeat, so defer instead of overlapping a route transaction.
    guard !driverMutationInFlight else {
      log.debug(
        "GRID_ENGINE phase=audio_capture_flow_missing action=defer mutation=\(currentDriverOperation ?? "unknown")"
      )
      return nil
    }

    engineRecoveryPending = false
    engineRecoveryTask?.cancel()
    engineRecoveryTask = nil
    let recoveryTarget = inputRoute.appliedTarget
      ?? inputRoute.desiredResolution?.target
    let result = await mutateDriver("recover-capture-flow") { [driver] in
      try await driver.recoverPreparedAudio(preserving: recoveryTarget)
    }
    if case .success = result {
      let recovered = await driver.runtimeHealth()
      observeRuntimeHealth(recovered)
      appliedPrepared = recovered.isRecording
      captureEngineHealthy = appliedPrepared && recovered.isCaptureHealthy
      if captureEngineHealthy {
        updateStableState()
        emitSnapshot()
        log.info(
          "GRID_ENGINE phase=audio_capture_flow_missing physical=degraded action=recovered_physical_capture"
        )
        return .recoveredPhysicalCapture
      }
    }

    log.warning(
      "GRID_ENGINE phase=audio_capture_flow_missing physical=degraded action=reconstruct_rtc_session"
    )
    emitSnapshot()
    return .reconstructRTCSession
  }

  /// Decoded remote PCM is arriving upstream of the ADM. Verify that WebRTC's
  /// physical playout direction is actually running; decoded frames alone do
  /// not prove that sound reaches the selected hardware device.
  func decodedRemoteAudioObserved() async -> GridAudioPlayoutFailureDisposition? {
    let health = await driver.runtimeHealth()
    observeRuntimeHealth(health)
    guard !health.isPlayoutHealthy else { return nil }
    // Refresh the output inventory on the uncommon unhealthy path. Core Audio
    // can expose a new Bluetooth format before its asynchronous property event
    // reaches `events`, so event delivery alone cannot own correctness.
    let previousOutputInventory = outputRoute.inventory
    let refreshedOutputInventory = await driver.outputDeviceInventory()
    let outputInventoryChanged = previousOutputInventory != refreshedOutputInventory
    if outputInventoryChanged {
      outputRoute.observe(refreshedOutputInventory)
      outputRoute.commitResolvedMetadataIfRouteMatches()
      emitOutputDeviceSnapshot()
    }
    let outputInventoryEpoch = refreshedOutputInventory.routeEpoch
    let runtimeRouteEpoch = health.route?.routeEpoch
    let outputInventoryIsStale = if let runtimeRouteEpoch {
      outputInventoryEpoch != runtimeRouteEpoch
    } else {
      false
    }
    let outputSettlementIsNeeded = outputInventoryChanged || outputInventoryIsStale
    if outputSettlementIsNeeded, deviceReconcileTask == nil {
      log.debug(
        "GRID_ENGINE phase=audio_output_inventory_changed changed=\(outputInventoryChanged) inventory_epoch=\(outputInventoryEpoch) runtime_epoch=\(runtimeRouteEpoch ?? 0) action=settle_devices"
      )
      deviceListChanged()
    }
    if hasOutputIntent,
       !outputRouteRetrySuspended,
       outputRoute.needsRouteTransaction {
      scheduleReconcile()
    }
    // A route/profile settlement or native mutation already owns physical
    // reconstruction. The decoded-frame heartbeat repeats, so defer and let
    // that transaction commit before deciding whether a real playout stall
    // remains. This prevents Bluetooth profile changes from rebuilding the
    // same output once through recovery and again through route settlement.
    let deferral = GridAudioPlayoutRecoveryDeferral.resolve(
      driverMutationInFlight: driverMutationInFlight,
      deviceSettlementPending: deviceReconcileTask != nil || outputSettlementIsNeeded,
      hasOutputIntent: hasOutputIntent,
      outputRouteRetrySuspended: outputRouteRetrySuspended,
      outputRouteNeedsTransaction: outputRoute.needsRouteTransaction
    )
    if let deferral {
      log.debug(
        "GRID_ENGINE phase=audio_physical_playout_check_deferred owner=\(deferral.rawValue) mutation=\(currentDriverOperation ?? "none")"
      )
      emitSnapshot()
      return nil
    }
    let recoveryTarget = outputRoute.appliedTarget
      ?? outputRoute.desiredResolution?.target
    let result = await mutateDriver("recover-playout") { [driver] in
      try await driver.recoverPlayout(preserving: recoveryTarget)
    }
    if case .success = result {
      let recovered = await driver.runtimeHealth()
      observeRuntimeHealth(recovered)
      if recovered.isPlayoutHealthy {
        log.info(
          "GRID_ENGINE phase=audio_physical_playout_missing result=recovered action=keep_rtc_session"
        )
        emitSnapshot()
        return .recoveredPhysicalPlayout
      }
    }
    log.warning(
      "GRID_ENGINE phase=audio_physical_playout_missing result=degraded action=reconstruct_rtc_session"
    )
    emitSnapshot()
    return .reconstructRTCSession
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
    guard reconcileTask == nil,
          !engineReconcileSuspended,
          !terminalShutdownRequested
    else { return }
    reconcileTask = Task { [weak self] in
      await self?.runReconcileLoop()
    }
  }

  private func scheduleInputRouteRetry() {
    inputRouteRetryTask?.cancel()
    inputRouteRetryAttempt += 1
    inputRouteRetryGeneration &+= 1
    let generation = inputRouteRetryGeneration
    let delay = transientRouteRetryDelayOverride
      ?? Self.transientRouteRetryBackoff(after: inputRouteRetryAttempt)
    inputRouteRetrySuspended = true
    inputRouteRetryTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.resumeInputRouteRetry(generation: generation)
    }
  }

  private func resumeInputRouteRetry(generation: Int) {
    guard generation == inputRouteRetryGeneration,
          inputRouteRetrySuspended,
          hasInputIntent,
          !captureLeases.isEmpty,
          !terminalShutdownRequested
    else { return }
    inputRouteRetryTask = nil
    inputRouteRetrySuspended = false
    lastInputRouteError = nil
    log.info(
      "GRID_ENGINE phase=input_route_transient_retry attempt=\(inputRouteRetryAttempt) selection=\(inputRoute.desiredSelection.logDescription) desired_uid=\(inputRoute.desiredResolution?.activeDeviceID ?? "none") applied_uid=\(inputRoute.appliedResolution?.activeDeviceID ?? "none")"
    )
    scheduleReconcile()
  }

  private func cancelInputRouteRetry(resetAttempt: Bool) {
    inputRouteRetryGeneration &+= 1
    inputRouteRetryTask?.cancel()
    inputRouteRetryTask = nil
    if resetAttempt { inputRouteRetryAttempt = 0 }
  }

  private func scheduleOutputRouteRetry() {
    outputRouteRetryTask?.cancel()
    outputRouteRetryAttempt += 1
    outputRouteRetryGeneration &+= 1
    let generation = outputRouteRetryGeneration
    let delay = transientRouteRetryDelayOverride
      ?? Self.transientRouteRetryBackoff(after: outputRouteRetryAttempt)
    outputRouteRetrySuspended = true
    outputRouteRetryTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.resumeOutputRouteRetry(generation: generation)
    }
  }

  private func resumeOutputRouteRetry(generation: Int) {
    guard generation == outputRouteRetryGeneration,
          outputRouteRetrySuspended,
          hasOutputIntent,
          !terminalShutdownRequested
    else { return }
    outputRouteRetryTask = nil
    outputRouteRetrySuspended = false
    lastOutputRouteError = nil
    log.info(
      "GRID_ENGINE phase=output_route_transient_retry attempt=\(outputRouteRetryAttempt) selection=\(outputRoute.desiredSelection.logDescription) desired_uid=\(outputRoute.desiredResolution?.activeDeviceID ?? "none") applied_uid=\(outputRoute.appliedResolution?.activeDeviceID ?? "none")"
    )
    scheduleReconcile()
  }

  private func cancelOutputRouteRetry(resetAttempt: Bool) {
    outputRouteRetryGeneration &+= 1
    outputRouteRetryTask?.cancel()
    outputRouteRetryTask = nil
    if resetAttempt { outputRouteRetryAttempt = 0 }
  }

  private func runReconcileLoop() async {
    defer {
      reconcileTask = nil
      if needsReconcile,
         !engineReconcileSuspended,
         !terminalShutdownRequested,
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
        observeInputInventory(inventory)
        inputRoute.commitResolvedMetadataIfRouteMatches()
        emitInputDeviceSnapshot()
        continue
      }

      if outputRoute.inventory == nil {
        let inventory = await driver.outputDeviceInventory()
        outputRoute.observe(inventory)
        outputRoute.commitResolvedMetadataIfRouteMatches()
        emitOutputDeviceSnapshot()
        continue
      }

      outputRoute.commitResolvedMetadataIfRouteMatches()
      if hasOutputIntent,
         !outputRouteRetrySuspended,
         outputRoute.needsRouteTransaction,
         let resolution = outputRoute.desiredResolution {
        let routeRevision = outputRoute.revision
        let result = await mutateDriver("output") { [driver] in
          try await driver.applyOutputRoute(resolution.target)
        }
        let postMutationHealth = await driver.runtimeHealth()
        observeRuntimeHealth(postMutationHealth)
        switch result {
        case .success:
          cancelOutputRouteRetry(resetAttempt: true)
          outputRoute.routeTransactionSucceeded(resolution)
          lastOutputRouteError = nil
          emitOutputDeviceSnapshot()
          log.debug(
            "GRID_ENGINE phase=output_route_committed target=\(resolution.target.logDescription) requested_revision=\(routeRevision) latest_revision=\(outputRoute.revision) stale=\(routeRevision != outputRoute.revision)"
          )
        case let .failure(error):
          let inventory = await driver.outputDeviceInventory()
          outputRoute.observe(inventory)
          emitOutputDeviceSnapshot()
          if routeRevision != outputRoute.revision
            || outputRoute.desiredResolution?.target != resolution.target {
            outputRoute.assumeCurrentRouteUnknown()
            log.debug(
              "GRID_ENGINE phase=output_route_failure_superseded requested_revision=\(routeRevision) latest_revision=\(outputRoute.revision) action=reconcile_latest"
            )
            continue
          }
          let restoredAppliedOutput = outputRoute.appliedResolution?.activeDeviceID
          let rollbackIsHealthy = postMutationHealth.route?.isOutputRouteValid == true
            && postMutationHealth.route?.currentOutputID == restoredAppliedOutput
          if rollbackIsHealthy {
            outputRoute.routeTransactionDeferredAfterTransientFailure(resolution)
            lastOutputRouteError = nil
            scheduleOutputRouteRetry()
            updateStableState()
            emitOutputDeviceSnapshot()
            emitSnapshot()
            log.warning(
              "GRID_ENGINE phase=output_route_restored_after_failure target=\(resolution.target.logDescription) desired_uid=\(resolution.activeDeviceID ?? "none") applied_uid=\(restoredAppliedOutput ?? "none") requested_revision=\(routeRevision) latest_revision=\(outputRoute.revision) retry_attempt=\(outputRouteRetryAttempt) failure=\(String(describing: error))"
            )
            continue
          }
          cancelOutputRouteRetry(resetAttempt: true)
          outputRoute.routeTransactionFailed(resolution)
          outputRoute.commitResolvedMetadataIfRouteMatches()
          emitOutputDeviceSnapshot()
          if outputRoute.desiredResolution?.target != resolution.target {
            log.warning(
              "GRID_ENGINE phase=output_route_failure_fallback failed_target=\(resolution.target.logDescription) fallback_target=\(outputRoute.desiredResolution?.target.logDescription ?? "unknown")"
            )
            continue
          }
          outputRouteRetrySuspended = true
          lastOutputRouteError = error.localizedDescription
          updateStableState()
          emitSnapshot()
        }
        continue
      }

      inputRoute.commitResolvedMetadataIfRouteMatches()
      if rtcTransportReady,
         hasInputIntent,
         hasNativeAudioDemand,
         microphonePermission.permitsCapture,
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
        // A macOS route transaction owns a complete recording transition: it
        // may start the ADM before the engine has committed `appliedPrepared`.
        // Preserve that physical ownership as a future stop obligation even
        // when logout timed out while the transaction was in flight. The late
        // completion will then reconcile to `setPrepared(false)` after capture
        // demand has been cleared instead of falsely settling cold.
        let postMutationHealth = await driver.runtimeHealth()
        observeRuntimeHealth(postMutationHealth)
        if postMutationHealth.isRecording {
          appliedPrepared = true
        }
        captureEngineHealthy = isCaptureRuntimeHealthy(postMutationHealth)
        switch result {
        case let .success(application):
          switch application {
          case .committed:
            cancelInputRouteRetry(resetAttempt: true)
            inputRoute.routeTransactionSucceeded(resolution)
            lastInputRouteError = nil
            emitInputDeviceSnapshot()
            if appliedPrepared,
               !captureEngineHealthy,
               !captureLeases.isEmpty {
              requestEngineRecovery(immediate: true)
            }
            log.debug(
              "GRID_ENGINE phase=input_route_committed target=\(resolution.target.logDescription) requested_revision=\(routeRevision) latest_revision=\(inputRoute.revision) stale=\(routeRevision != inputRoute.revision)"
            )
          case let .restoredPreviousRoute(failure, retryable):
            if retryable {
              inputRoute.routeTransactionDeferredAfterTransientFailure(resolution)
              scheduleInputRouteRetry()
            } else {
              cancelInputRouteRetry(resetAttempt: true)
              inputRoute.routeTransactionRestoredAfterFailure(resolution)
            }
            inputRoute.commitResolvedMetadataIfRouteMatches()
            lastInputRouteError = nil
            // A permanent Auto failure has no alternative policy target. A
            // transition-class failure instead retains the desired route and
            // is retried after capped backoff by `scheduleInputRouteRetry()`.
            if !retryable, case .automatic = resolution.target {
              inputRouteRetrySuspended = true
            }
            updateStableState()
            emitInputDeviceSnapshot()
            emitSnapshot()
            log.warning(
              "GRID_ENGINE phase=input_route_restored_after_failure target=\(resolution.target.logDescription) desired_uid=\(resolution.activeDeviceID ?? "none") applied_uid=\(inputRoute.appliedResolution?.activeDeviceID ?? "none") requested_revision=\(routeRevision) latest_revision=\(inputRoute.revision) retryable=\(retryable) retry_attempt=\(inputRouteRetryAttempt) failure=\(failure)"
            )
          }
        case let .failure(error):
          cancelInputRouteRetry(resetAttempt: true)
          // A device may disappear while a transaction is in flight. Refresh
          // inventory before classifying the error: if policy now resolves to
          // another target, reconcile that latest target instead of surfacing
          // a stale failure or erasing the user's preference.
          let inventory = await driver.inputDeviceInventory()
          observeInputInventory(inventory)
          emitInputDeviceSnapshot()
          if routeRevision != inputRoute.revision
            || inputRoute.desiredResolution?.target != resolution.target {
            inputRoute.assumeCurrentRouteUnknown()
            log.debug(
              "GRID_ENGINE phase=input_route_failure_superseded requested_revision=\(routeRevision) latest_revision=\(inputRoute.revision) action=reconcile_latest"
            )
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
          state = .failed(error.localizedDescription)
          emitSnapshot()
          continue
        }
        continue
      }

      let hasPreparedCaptureDemand = rtcTransportReady
        && hasInputIntent
        && (!captureLeases.isEmpty || keepPreparedThroughCooldown)
      let shouldBePrepared = hasPreparedCaptureDemand
        && microphonePermission.permitsCapture
      if hasPreparedCaptureDemand,
         !microphonePermission.permitsCapture,
         !appliedPrepared {
        state = switch microphonePermission {
        case .denied, .restricted: .permissionDenied
        case .notDetermined, .requesting: .waitingForPermission
        case .authorized: .warming
        }
        emitSnapshot()
        return
      }
      if appliedPrepared != shouldBePrepared {
        if driver.recordingStartsWithMicrophoneSender {
          let health = await driver.runtimeHealth()
          observeRuntimeHealth(health)
          appliedPrepared = health.isRecording
          captureEngineHealthy = isCaptureRuntimeHealthy(health)
          if appliedPrepared == shouldBePrepared {
            updateStableState()
          } else {
            state = shouldBePrepared ? .warming : .stopping
          }
          emitSnapshot()
          return
        }
        state = shouldBePrepared ? .warming : .stopping
        emitSnapshot()
        let result = await mutateDriver(shouldBePrepared ? "prepare" : "stop") { [driver] in
          try await driver.setPrepared(shouldBePrepared)
        }
        // A native mutation may throw after changing recording state. Always
        // retain the observed physical state as the next stop/recovery
        // obligation instead of projecting the requested state or the state
        // from before the mutation.
        let postMutationHealth = await driver.runtimeHealth()
        observeRuntimeHealth(postMutationHealth)
        appliedPrepared = postMutationHealth.isRecording
        captureEngineHealthy = isCaptureRuntimeHealthy(postMutationHealth)
        switch result {
        case .success:
          if shouldBePrepared {
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
    if outputRoute.inventory == nil { return true }
    if hasOutputIntent,
       !outputRouteRetrySuspended,
       outputRoute.needsRouteTransaction {
      return true
    }
    if rtcTransportReady,
       hasInputIntent,
       hasNativeAudioDemand,
       microphonePermission.permitsCapture,
       !inputRouteRetrySuspended,
       inputRoute.needsRouteTransaction {
      return true
    }
    let hasPreparedCaptureDemand = rtcTransportReady
      && hasInputIntent
      && (!captureLeases.isEmpty || keepPreparedThroughCooldown)
    let shouldBePrepared = hasPreparedCaptureDemand
      && microphonePermission.permitsCapture
    if driver.recordingStartsWithMicrophoneSender {
      // Sender attachment and detachment are the only events allowed to open
      // or close M144's native recording gate. Their driver events (plus the
      // lifetime health poll for a lost event) re-enter reconciliation. A
      // prepared-state mismatch alone must not create a busy reconcile loop.
      return false
    }
    return appliedPrepared != shouldBePrepared
  }

  private var hasNativeAudioDemand: Bool {
    !captureLeases.isEmpty || keepPreparedThroughCooldown || appliedPrepared
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
    currentDriverOperationStartedAt = startedAt
    emitSnapshot()
    defer {
      driverMutationInFlight = false
      currentDriverOperation = nil
      currentDriverOperationStartedAt = nil
      lastTransitionMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
      log.debug(
        "GRID_ENGINE phase=audio_driver_operation_done operation=\(operation) elapsed_ms=\(lastTransitionMilliseconds ?? 0)"
      )
      emitSnapshot()
      if engineRecoveryPending, operation != "recover" {
        if !terminalShutdownRequested {
          scheduleEngineRecovery(after: .zero)
        }
      }
      if terminalShutdownRequested {
        if operation != "shutdown", operation != "shutdown-eventual" {
          scheduleTerminalCleanup()
        }
      } else if needsReconcile, !engineReconcileSuspended {
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

  private func observeRuntimeHealth(_ health: GridAudioRuntimeHealth) {
    let previousProcessing = processingSnapshot
    latestRuntimeHealth = health
    routeSnapshot = health.route
    processingSnapshot = health.processing
    if let processing = health.processing,
       processing != previousProcessing {
      log.info(
        "GRID_ENGINE phase=audio_processing_state capture_compatible=\(processing.isCompatibleWithCaptureBootstrap) policy_effective=\(processing.isGridPolicyEffective) \(processing.logDescription)"
      )
    }
  }

  private func emitInputDeviceSnapshot() {
    guard let snapshot = inputRoute.snapshot else { return }
    deviceSnapshotContinuation.yield(snapshot)
  }

  private func observeInputInventory(_ inventory: AudioInputDeviceInventory) {
    let automaticInputWasQuarantined = inputRoute.isAutomaticRouteQuarantined
    inputRoute.observe(inventory)
    if automaticInputWasQuarantined,
       !inputRoute.isAutomaticRouteQuarantined {
      inputRouteRetrySuspended = false
      lastInputRouteError = nil
      log.debug(
        "GRID_ENGINE phase=input_route_quarantine_cleared reason=automatic_fingerprint_changed"
      )
    }
  }

  private func emitOutputDeviceSnapshot() {
    guard let snapshot = outputRoute.snapshot else { return }
    outputDeviceSnapshotContinuation.yield(snapshot)
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
    var previousOutputInventory: AudioOutputDeviceInventory?
    var previousHealth: GridAudioDeviceSettlementHealth?
    var stableSampleCount = 0
    var finalInventory: AudioInputDeviceInventory?
    var finalOutputInventory: AudioOutputDeviceInventory?
    var finalHealth: GridAudioRuntimeHealth?
    for _ in 0 ..< 12 {
      let inventory = await driver.inputDeviceInventory()
      guard generation == deviceRouteGeneration, !Task.isCancelled else { return }
      let outputInventory = await driver.outputDeviceInventory()
      guard generation == deviceRouteGeneration, !Task.isCancelled else { return }
      let health = await driver.runtimeHealth()
      guard generation == deviceRouteGeneration, !Task.isCancelled else { return }
      finalInventory = inventory
      finalOutputInventory = outputInventory
      finalHealth = health
      let settlementHealth = GridAudioDeviceSettlementHealth(health)
      if inventory == previousInventory,
         outputInventory == previousOutputInventory,
         settlementHealth == previousHealth {
        stableSampleCount += 1
      } else {
        previousInventory = inventory
        previousOutputInventory = outputInventory
        previousHealth = settlementHealth
        stableSampleCount = 1
      }
      if stableSampleCount >= 3 { break }
      try? await Task.sleep(for: deviceChangeSettleDelay)
      guard !Task.isCancelled else { return }
    }
    guard generation == deviceRouteGeneration,
          let inventory = finalInventory,
          let outputInventory = finalOutputInventory,
          let health = finalHealth
    else { return }
    deviceReconcileTask = nil
    observeRuntimeHealth(health)
    if driver.recordingStartsWithMicrophoneSender {
      appliedPrepared = health.isRecording
    }
    captureEngineHealthy = isCaptureRuntimeHealthy(health)
    observeInputInventory(inventory)
    inputRoute.commitResolvedMetadataIfRouteMatches()
    emitInputDeviceSnapshot()
    outputRoute.observe(outputInventory)
    outputRoute.commitResolvedMetadataIfRouteMatches()
    emitOutputDeviceSnapshot()
    if captureRecoveryIsDemanded(health), !captureEngineHealthy, !captureLeases.isEmpty {
      state = .warming
      if driverMutationInFlight {
        log.debug(
          "GRID_ENGINE phase=audio_devices_unhealthy_during_mutation operation=\(currentDriverOperation ?? "unknown") action=defer_to_operation"
        )
      } else {
        requestEngineRecovery(immediate: true)
      }
    }
    log.debug(
      "GRID_ENGINE phase=audio_devices_settled samples=\(stableSampleCount) inputs=\(inventory.devices.count) outputs=\(outputInventory.devices.count) input_selection=\(inputRoute.desiredSelection.logDescription) input_target=\(inputRoute.desiredResolution?.target.logDescription ?? "unknown") output_selection=\(outputRoute.desiredSelection.logDescription) output_target=\(outputRoute.desiredResolution?.target.logDescription ?? "unknown") running=\(health.isEngineRunning) recording=\(health.isRecording) playing=\(health.isPlaying) input_valid=\(health.route?.isInputRouteValid ?? true) output_valid=\(health.route?.isOutputRouteValid ?? true) input_fallback=\(inputRoute.desiredResolution?.isFallingBackToAutomatic ?? false) output_fallback=\(outputRoute.desiredResolution?.isFallingBackToAutomatic ?? false) input_route_change=\(hasInputIntent && inputRoute.needsRouteTransaction) output_route_change=\(hasOutputIntent && outputRoute.needsRouteTransaction)"
    )
    scheduleReconcile()
  }

  private func audioEngineStopped(playout: Bool, recording: Bool) async {
    engineHealthGeneration &+= 1
    captureEngineHealthy = false
    engineHealthCheckTask?.cancel()
    engineHealthCheckTask = nil
    if driver.recordingStartsWithMicrophoneSender, recording {
      let health = await driver.runtimeHealth()
      observeRuntimeHealth(health)
      appliedPrepared = health.isRecording
      if isCaptureRuntimeHealthy(health) {
        markCaptureRuntimeHealthy()
        updateStableState()
        emitSnapshot()
        return
      }
      guard captureRecoveryIsDemanded(health), !captureLeases.isEmpty else {
        captureEngineHealthy = false
        updateStableState()
        emitSnapshot()
        return
      }
      captureEngineHealthy = false
      state = .warming
      engineRecoveryPending = true
      emitSnapshot()
      scheduleEngineRecovery(after: engineRecoveryDelay)
      return
    }
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
          captureRecoveryIsDemanded(),
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
    observeRuntimeHealth(preRecoveryHealth)
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
      observeRuntimeHealth(health)
      if driver.recordingStartsWithMicrophoneSender {
        appliedPrepared = health.isRecording
      }
      captureEngineHealthy = isCaptureRuntimeHealthy(health)
      if captureEngineHealthy {
        markCaptureRuntimeHealthy()
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
    guard captureRecoveryIsDemanded(), !captureLeases.isEmpty, !captureEngineHealthy else { return }
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
    observeRuntimeHealth(health)
    if driver.recordingStartsWithMicrophoneSender {
      appliedPrepared = health.isRecording
    }
    captureEngineHealthy = isCaptureRuntimeHealthy(health)
    if captureEngineHealthy {
      markCaptureRuntimeHealthy()
      updateStableState()
      log.debug("GRID_ENGINE phase=audio_engine_health_confirmed")
    } else if captureRecoveryIsDemanded(health), !captureLeases.isEmpty {
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
    let runtimeHealthChanged = latestRuntimeHealth != health
    observeRuntimeHealth(health)
    if driver.recordingStartsWithMicrophoneSender {
      appliedPrepared = health.isRecording
    }
    if isCaptureIntentionallyIdle(health) {
      markCaptureRuntimeHealthy()
      updateStableState()
      if !wasHealthy || runtimeHealthChanged {
        emitSnapshot()
      }
    } else if appliedPrepared, health.isAudioDeviceHealthy {
      captureEngineHealthy = true
      if !wasHealthy {
        markCaptureRuntimeHealthy()
        updateStableState()
        log.debug("GRID_ENGINE phase=audio_lifetime_health_recovered")
        emitSnapshot()
      } else if runtimeHealthChanged {
        // Processing is track-owned and does not trigger an ADM restart, but
        // requested/effective APM changes must still reach public diagnostics.
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

  /// A sender-owned custom ADM legitimately has a capture lease while muted,
  /// but WebRTC has not requested physical recording. Treat that state as
  /// healthy only when the selected input still reads back as valid. This is
  /// deliberately distinct from `isRecordingExpected == true` with no PCM,
  /// which is a real capture failure and must remain recoverable.
  private func isCaptureIntentionallyIdle(_ health: GridAudioRuntimeHealth) -> Bool {
    driver.recordingStartsWithMicrophoneSender
      && !captureLeases.isEmpty
      && health.isRecordingExpected == false
      && health.route?.isInputRouteValid != false
  }

  private func isCaptureRuntimeHealthy(_ health: GridAudioRuntimeHealth) -> Bool {
    isCaptureIntentionallyIdle(health)
      || (appliedPrepared && health.isAudioDeviceHealthy)
  }

  private func captureRecoveryIsDemanded(_ health: GridAudioRuntimeHealth? = nil) -> Bool {
    appliedPrepared || (health ?? latestRuntimeHealth)?.isRecordingExpected == true
  }

  private func markCaptureRuntimeHealthy() {
    captureEngineHealthy = true
    engineRecoveryPending = false
    engineRecoveryAttempt = 0
    if !engineRecoveryInFlight {
      engineRecoveryTask?.cancel()
      engineRecoveryTask = nil
    }
    engineReconcileSuspended = false
  }

  private func updateStableState() {
    if let lastInputRouteError {
      state = .failed(lastInputRouteError)
      return
    }
    if let lastOutputRouteError {
      state = .failed(lastOutputRouteError)
      return
    }
    if driver.recordingStartsWithMicrophoneSender,
       latestRuntimeHealth?.isRecordingExpected == false,
       !captureLeases.isEmpty {
      state = .ready
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

  private func receive(_ event: GridAudioDriverEvent) async {
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
      await audioEngineStopped(playout: playout, recording: recording)
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
      isConfigured: configured,
      isPrepared: appliedPrepared && captureEngineHealthy,
      captureLeaseCount: captureLeases.count,
      input: inputRoute.snapshot?.resolvedInput,
      output: outputRoute.snapshot?.resolvedOutput,
      route: routeSnapshot,
      processing: processingSnapshot,
      isRecording: latestRuntimeHealth?.isRecording ?? false,
      isPlaying: latestRuntimeHealth?.isPlaying ?? false,
      isCaptureHealthy: latestRuntimeHealth?.isCaptureHealthy ?? false,
      isPlayoutHealthy: latestRuntimeHealth?.isPlayoutHealthy ?? false,
      currentMutationKind: currentDriverOperation,
      currentMutationMilliseconds: currentDriverOperationStartedAt.map {
        max(0, Int(Date().timeIntervalSince($0) * 1_000))
      },
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

  private static func transientRouteRetryBackoff(after attempt: Int) -> Duration {
    switch attempt {
    case 0, 1: .seconds(1)
    case 2: .seconds(2)
    case 3: .seconds(5)
    case 4: .seconds(10)
    default: .seconds(30)
    }
  }

  private static func terminalCleanupBackoff(after attempt: Int) -> Duration {
    switch attempt {
    case 0, 1: .milliseconds(25)
    case 2: .milliseconds(50)
    case 3: .milliseconds(100)
    case 4: .milliseconds(200)
    case 5: .milliseconds(400)
    case 6: .seconds(1)
    case 7: .seconds(2)
    default: .seconds(5)
    }
  }
}

/// Device settlement ignores realtime telemetry that is expected to change on
/// every sample. Route validity already incorporates callback freshness and
/// configured graph format, so a dead callback still resets stability without
/// a healthy callback counter making stability impossible.
private struct GridAudioDeviceSettlementHealth: Equatable {
  let isEngineRunning: Bool
  let isRecording: Bool
  let isPlaying: Bool
  let route: GridAudioDeviceSettlementRoute?

  init(_ health: GridAudioRuntimeHealth) {
    isEngineRunning = health.isEngineRunning
    isRecording = health.isRecording
    isPlaying = health.isPlaying
    route = health.route.map(GridAudioDeviceSettlementRoute.init)
  }
}

private struct GridAudioDeviceSettlementRoute: Equatable {
  let currentInputID: String?
  let defaultInputID: String?
  let currentOutputID: String?
  let defaultOutputID: String?
  let inputDeviceCount: Int
  let outputDeviceCount: Int
  let isInputRouteValid: Bool
  let isOutputRouteValid: Bool
  let routeEpoch: UInt64

  init(_ route: InlineRTCAudioRoute) {
    currentInputID = route.currentInputID
    defaultInputID = route.defaultInputID
    currentOutputID = route.currentOutputID
    defaultOutputID = route.defaultOutputID
    inputDeviceCount = route.inputDeviceCount
    outputDeviceCount = route.outputDeviceCount
    isInputRouteValid = route.isInputRouteValid
    isOutputRouteValid = route.isOutputRouteValid
    routeEpoch = route.routeEpoch
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

private extension AudioOutputSelection {
  var logDescription: String {
    switch self {
    case .automatic: "automatic"
    case .device: "explicit"
    }
  }
}
