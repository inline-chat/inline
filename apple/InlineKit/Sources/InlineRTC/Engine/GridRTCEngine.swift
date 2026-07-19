import Foundation
import Logger

protocol GridRTCDriver: Sendable {
  var lifecycleEvents: AsyncStream<GridRTCLifecycleEventEnvelope> { get }
  var participantSnapshots: AsyncStream<GridRTCParticipantSnapshotEnvelope> { get }

  func makeRoom(configuration: InlineRTCConfiguration) async throws -> GridRTCRoomHandle
  func connect(_ room: GridRTCRoomHandle, credentials: InlineRTCCredentials) async throws
  func publishPreparedMicrophone(_ room: GridRTCRoomHandle, initiallyMuted: Bool) async throws
  func setMicrophoneMuted(_ muted: Bool, in room: GridRTCRoomHandle) async throws
  func setOutputVolume(_ volume: Float, in room: GridRTCRoomHandle) async
  func silence(_ room: GridRTCRoomHandle) async
  func disconnect(_ room: GridRTCRoomHandle) async
}

extension GridRTCDriver {
  var lifecycleEvents: AsyncStream<GridRTCLifecycleEventEnvelope> {
    AsyncStream { continuation in continuation.finish() }
  }

  var participantSnapshots: AsyncStream<GridRTCParticipantSnapshotEnvelope> {
    AsyncStream { continuation in continuation.finish() }
  }

  func setOutputVolume(_: Float, in _: GridRTCRoomHandle) async {}
}

actor GridRTCEngine {
  nonisolated let snapshots: AsyncStream<InlineRTCConnectionSnapshot>

  private let audio: GridAudioEngine
  private let driver: any GridRTCDriver
  private let configuration: InlineRTCConfiguration
  private let snapshotContinuation: AsyncStream<InlineRTCConnectionSnapshot>.Continuation
  private let log = Log.scoped("GridRTCEngine")

  private var demand = InlineRTCDemand()
  private var demandRevision = 0
  private var demandAudioLease: GridAudioLease?
  private var lifecycleAudioLeases: [GridRTCRoomHandle: GridAudioLease] = [:]
  private var reconnectsAwaitingMicrophonePublication = Set<GridRTCRoomHandle>()
  private var room: GridRTCRoomHandle?
  private var roomTarget: InlineRTCSessionID?
  private var state: InlineRTCConnectionState = .idle
  private var microphonePublicationState: InlineRTCMicrophoneState = .notRequested
  private var microphonePublished = false
  private var microphoneMuted = true
  private var appliedOutputVolume: Float?
  private var localAudioFlowState: InlineRTCAudioFlowState = .unknown
  private var localAudioFlowFailureActive = false
  private var remoteAudioFlowStates: [String: InlineRTCAudioFlowState] = [:]
  private var microphonePublishAttempt = 0
  private var microphoneReconcileFailures = 0
  private var participants: [InlineRTCParticipant] = []
  private var reconnectCount = 0
  private var recoveryAttempt = 0
  private var lastConnectMilliseconds: Int?
  private var lastDisconnectMilliseconds: Int?
  private var lastError: String?
  private var reconcileTask: Task<Void, Never>?
  private var reconcileTaskID: UUID?
  private var backoffTask: Task<Void, Never>?
  private var microphoneRetryTask: Task<Void, Never>?
  private var lifecycleEventsTask: Task<Void, Never>?
  private var participantSnapshotsTask: Task<Void, Never>?
  private var retirementTasks: [GridRTCRoomHandle: Task<Void, Never>] = [:]
  private var providerDisconnectTasks: [GridRTCRoomHandle: Task<Void, Never>] = [:]
  private var providerDisconnectOperationIDs: [GridRTCRoomHandle: UUID] = [:]
  private var completedProviderDisconnects = Set<GridRTCRoomHandle>()
  private var activeSilenceOperations = Set<UUID>()
  private var completedSilenceOperations = Set<UUID>()
  private var audioPreparationTarget: InlineRTCSessionID?
  private var audioPreparationStartedAt: Date?
  private var audioPreparationBypassLogged = false
  private var providerCircuitBreaker: GridOperationCircuitBreaker

  init(
    audio: GridAudioEngine,
    driver: any GridRTCDriver = LiveKitGridRTCDriver(),
    configuration: InlineRTCConfiguration = .voice
  ) {
    self.audio = audio
    self.driver = driver
    self.configuration = configuration
    providerCircuitBreaker = GridOperationCircuitBreaker(
      limit: configuration.connection.maxAbandonedProviderOperations
    )
    let stream = AsyncStream.makeStream(
      of: InlineRTCConnectionSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    snapshots = stream.stream
    snapshotContinuation = stream.continuation
  }

  deinit {
    reconcileTask?.cancel()
    backoffTask?.cancel()
    microphoneRetryTask?.cancel()
    lifecycleEventsTask?.cancel()
    participantSnapshotsTask?.cancel()
    retirementTasks.values.forEach { $0.cancel() }
    providerDisconnectTasks.values.forEach { $0.cancel() }
    snapshotContinuation.finish()
  }

  func setDemand(_ nextDemand: InlineRTCDemand) async {
    startDriverEventsIfNeeded()
    var nextDemand = nextDemand
    if nextDemand.credentials?.target != nextDemand.target {
      nextDemand.credentials = nil
    }
    guard nextDemand != demand else { return }
    let previousTarget = demand.target
    demandRevision &+= 1
    demand = nextDemand
    backoffTask?.cancel()
    backoffTask = nil
    microphoneRetryTask?.cancel()
    microphoneRetryTask = nil

    if previousTarget != nextDemand.target, let room, let roomTarget {
      detach(room)
      beginRetirement(of: room, target: roomTarget)
      cancelReconcile()
    }
    if previousTarget != nextDemand.target {
      startAudioPreparationWait(for: nextDemand.target)
    }

    await audio.setInput(nextDemand.input)
    await audio.setOutputVolume(nextDemand.outputVolume)
    await replaceDemandAudioLease(for: nextDemand.target)

    log.debug(
      "GRID_ENGINE phase=rtc_demand_replaced revision=\(demandRevision) room=\(nextDemand.target.map(\.rawValue) ?? "none") microphone=\(nextDemand.microphoneEnabled)"
    )
    scheduleReconcile()
  }

  func networkBecameAvailable() {
    backoffTask?.cancel()
    backoffTask = nil
    microphoneRetryTask?.cancel()
    microphoneRetryTask = nil
    scheduleReconcile()
  }

  func applicationDidWake() {
    backoffTask?.cancel()
    backoffTask = nil
    microphoneRetryTask?.cancel()
    microphoneRetryTask = nil
    scheduleReconcile()
  }

  func audioAvailabilityChanged() {
    microphoneRetryTask?.cancel()
    microphoneRetryTask = nil
    scheduleReconcile()
  }

  func currentSnapshot() -> InlineRTCConnectionSnapshot {
    makeSnapshot()
  }

  func shutdown() async {
    demandRevision &+= 1
    demand = InlineRTCDemand()
    backoffTask?.cancel()
    backoffTask = nil
    microphoneRetryTask?.cancel()
    microphoneRetryTask = nil
    cancelReconcile()
    if let room, let roomTarget {
      detach(room)
      beginRetirement(of: room, target: roomTarget)
    }
    await replaceDemandAudioLease(for: nil)
    let retirements = Array(retirementTasks.values)
    for retirement in retirements {
      await retirement.value
    }
    state = .idle
    emitSnapshot()
  }

  private func replaceDemandAudioLease(for target: InlineRTCSessionID?) async {
    let nextLease = target.map(GridAudioLease.connectionDemand)
    guard nextLease != demandAudioLease else { return }
    if let nextLease {
      await audio.acquireCaptureLease(nextLease)
    }
    if let demandAudioLease {
      await audio.releaseCaptureLease(demandAudioLease)
    }
    demandAudioLease = nextLease
  }

  private func scheduleReconcile() {
    guard reconcileTask == nil, backoffTask == nil else { return }
    if providerCircuitBreaker.isOpen, let target = demand.target {
      let error = GridRTCProviderCircuitError.open(
        abandonedOperations: providerCircuitBreaker.abandonedOperationCount
      )
      lastError = error.localizedDescription
      state = .failed(target, error.localizedDescription)
      emitSnapshot()
      return
    }
    let taskID = UUID()
    reconcileTaskID = taskID
    reconcileTask = Task { [weak self] in
      await self?.runReconcileLoop()
      await self?.reconcileFinished(taskID: taskID)
    }
  }

  private func runReconcileLoop() async {
    while !Task.isCancelled {
      // A watchdog may have detached a stuck LiveKit room and installed a
      // recovery delay while the original connect call is still unwinding.
      // Do not let that stale call bypass the delay by falling through into a
      // fresh room attempt.
      guard backoffTask == nil else { return }
      let desiredTarget = demand.target

      if let room, let roomTarget, roomTarget != desiredTarget {
        if let desiredTarget {
          state = .switching(from: roomTarget, to: desiredTarget)
        } else {
          state = .disconnecting(roomTarget)
        }
        emitSnapshot()
        detach(room)
        beginRetirement(of: room, target: roomTarget)
        continue
      }

      guard let target = desiredTarget else {
        state = .idle
        participants = []
        recoveryAttempt = 0
        microphonePublishAttempt = 0
        microphonePublicationState = .notRequested
        localAudioFlowState = .unknown
        localAudioFlowFailureActive = false
        remoteAudioFlowStates = [:]
        emitSnapshot()
        return
      }

      if let room, roomTarget == target {
        if case .reconnecting = state {
          emitSnapshot()
          return
        }

        state = .connected(target)
        if appliedOutputVolume != demand.outputVolume {
          let volume = demand.outputVolume
          await driver.setOutputVolume(volume, in: room)
          guard self.room == room, roomTarget == target else { continue }
          appliedOutputVolume = volume
          log.debug(
            "GRID_ENGINE phase=rtc_output_volume_applied session=\(target.rawValue) volume=\(volume)"
          )
          continue
        }
        if !microphonePublished {
          guard microphoneRetryTask == nil else {
            emitSnapshot()
            return
          }
          let audioSnapshot = await audio.currentSnapshot()
          guard audioSnapshot.microphonePermission.permitsCapture else {
            microphonePublicationState = .waitingForPermission
            emitSnapshot()
            return
          }
          guard audioSnapshot.isPrepared else {
            state = .connected(target)
            microphonePublicationState = .waitingForAudio
            emitSnapshot()
            scheduleMicrophoneRetry(for: target)
            return
          }
          guard await publishMicrophone(in: room, target: target) else { return }
          continue
        }

        let desiredMuted = !demand.microphoneEnabled
        if microphoneMuted != desiredMuted {
          let startedAt = Date()
          let watchdogTask = scheduleMicrophoneMuteWatchdog(
            for: room,
            target: target,
            desiredMuted: desiredMuted,
            startedAt: startedAt
          )
          defer { watchdogTask?.cancel() }
          do {
            try await driver.setMicrophoneMuted(desiredMuted, in: room)
            if self.room == room, roomTarget == target {
              microphoneMuted = desiredMuted
              microphoneReconcileFailures = 0
              lastError = nil
              log.debug(
                "GRID_ENGINE phase=rtc_microphone_reconciled session=\(target.rawValue) muted=\(desiredMuted)"
              )
            }
          } catch {
            lastError = String(describing: error)
            microphoneReconcileFailures += 1
            if microphoneReconcileFailures == 3 {
              log.error(
                "GRID_ENGINE phase=rtc_microphone_reconcile_persistently_failed failures=3",
                error: error
              )
            } else {
              log.warning(
                "GRID_ENGINE phase=rtc_microphone_reconcile_failed failures=\(microphoneReconcileFailures)"
              )
            }
            scheduleMicrophoneRetry(for: target)
          }
          emitSnapshot()
          if microphoneMuted != desiredMuted { return }
          continue
        }
        state = .connected(target)
        emitSnapshot()
        return
      }

      guard let credentials = validCredentials(for: target) else {
        state = .waitingForCredentials(target)
        emitSnapshot()
        return
      }

      let audioSnapshot = await audio.currentSnapshot()
      let audioWaitsForRTCTransport = await audio.isWaitingForRTCTransport()
      if !audioWaitsForRTCTransport,
         !audioSnapshot.isPrepared,
         audioSnapshot.microphonePermission.permitsCapture {
        if shouldWaitForAudioPreparation(target: target) {
          state = .preparingAudio(target)
          emitSnapshot()
          try? await Task.sleep(for: .milliseconds(25))
          continue
        }
        logAudioPreparationBypassIfNeeded(target: target)
      } else {
        clearAudioPreparationWait(for: target)
      }

      do {
        try await connect(target: target, credentials: credentials)
      } catch {
        guard demand.target == target else { continue }
        guard backoffTask == nil else { return }
        lastError = String(describing: error)
        state = .failed(target, String(describing: error))
        emitSnapshot()
        recordConnectFailure(error, attempt: recoveryAttempt)
        scheduleBackoff(for: target)
        return
      }
    }
  }

  private func connect(
    target: InlineRTCSessionID,
    credentials: InlineRTCCredentials
  ) async throws {
    recoveryAttempt += 1
    state = .connecting(target, attempt: recoveryAttempt)
    emitSnapshot()
    try await waitForRetirementsBeforeConnect(target: target)

    let attemptID = UUID()
    let lifecycleLease = GridAudioLease.rtcLifecycle(attemptID)
    await audio.acquireCaptureLease(lifecycleLease)
    let room: GridRTCRoomHandle
    do {
      room = try await driver.makeRoom(configuration: configuration)
    } catch {
      await audio.releaseCaptureLease(lifecycleLease)
      throw error
    }
    lifecycleAudioLeases[room] = lifecycleLease

    guard demand.target == target, !Task.isCancelled else {
      beginRetirement(of: room, target: target)
      return
    }
    self.room = room
    roomTarget = target
    microphonePublicationState = .notRequested
    microphonePublished = false
    microphoneMuted = true
    appliedOutputVolume = nil
    localAudioFlowState = .unknown
    localAudioFlowFailureActive = false
    remoteAudioFlowStates = [:]
    microphonePublishAttempt = 0
    participants = []

    state = .connecting(target, attempt: recoveryAttempt)
    emitSnapshot()
    let connectStartedAt = Date()
    let slowWarningTask = scheduleInitialConnectSlowWarning(
      for: room,
      target: target,
      startedAt: connectStartedAt
    )
    let watchdogTask = scheduleInitialConnectWatchdog(
      for: room,
      target: target,
      startedAt: connectStartedAt
    )
    defer {
      slowWarningTask?.cancel()
      watchdogTask?.cancel()
    }
    do {
      try await driver.connect(room, credentials: credentials)
      await audio.rtcTransportDidInitialize()
    } catch {
      let wasCurrentAttempt = self.room == room && roomTarget == target
      detach(room)
      beginRetirement(of: room, target: target)
      // A watchdog, room switch, or leave already owns the transition. The
      // eventual provider error from that stale call must not install another
      // failure/backoff path over the current desired state.
      guard wasCurrentAttempt else { return }
      throw error
    }
    lastConnectMilliseconds = elapsedMilliseconds(since: connectStartedAt)

    guard demand.target == target, self.room == room else {
      detach(room)
      beginRetirement(of: room, target: target)
      return
    }

    recoveryAttempt = 0
    lastError = nil
    state = .connected(target)
    log.debug(
      "GRID_ENGINE phase=rtc_room_connected session=\(target.rawValue) connect_ms=\(lastConnectMilliseconds ?? 0)"
    )
    PerformanceTrace.breadcrumb(
      "Grid RTC connected",
      category: "Grid.RTC",
      data: [
        "connect_ms": lastConnectMilliseconds ?? -1,
        "reconnect_count": reconnectCount,
      ]
    )
    emitSnapshot()
  }

  /// LiveKit room operations are process-global enough that overlapping a
  /// routine disconnect with the next connect creates avoidable signaling and
  /// audio churn. Wait for the fast path, but preserve bounded forward progress
  /// when a provider call is genuinely stuck.
  private func waitForRetirementsBeforeConnect(target: InlineRTCSessionID) async throws {
    let timeout = configuration.connection.retirementBarrierTimeout
    guard timeout > 0, !retirementTasks.isEmpty else { return }

    let startedAt = Date()
    while !retirementTasks.isEmpty,
          Date().timeIntervalSince(startedAt) < timeout {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(5))
    }

    let elapsed = elapsedMilliseconds(since: startedAt)
    if retirementTasks.isEmpty {
      log.debug(
        "GRID_ENGINE phase=rtc_retirement_barrier_finished session=\(target.rawValue) elapsed_ms=\(elapsed)"
      )
    } else {
      log.warning(
        "GRID_ENGINE phase=rtc_retirement_barrier_timed_out session=\(target.rawValue) elapsed_ms=\(elapsed) pending=\(retirementTasks.count)"
      )
    }
  }

  private func scheduleInitialConnectSlowWarning(
    for room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    startedAt: Date
  ) -> Task<Void, Never>? {
    let delay = configuration.connection.initialConnectSlowWarningDelay
    guard delay > 0 else { return nil }
    return Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.initialConnectIsSlow(room: room, target: target, startedAt: startedAt)
    }
  }

  private func scheduleInitialConnectWatchdog(
    for room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    startedAt: Date
  ) -> Task<Void, Never>? {
    let timeout = configuration.connection.initialConnectWatchdogTimeout
    guard timeout > 0 else { return nil }
    let remaining = max(timeout - Date().timeIntervalSince(startedAt), 0)
    return Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(remaining * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.initialConnectTimedOut(
        room: room,
        target: target,
        startedAt: startedAt
      )
    }
  }

  private func initialConnectIsSlow(
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    startedAt: Date
  ) {
    guard self.room == room, roomTarget == target, demand.target == target,
          case .connecting = state
    else { return }
    let elapsed = elapsedMilliseconds(since: startedAt)
    log.warning(
      "GRID_ENGINE phase=rtc_initial_connect_slow session=\(target.rawValue) elapsed_ms=\(elapsed)"
    )
    PerformanceTrace.breadcrumb(
      "Grid RTC initial connection is slow",
      category: "Grid.RTC",
      level: .warning,
      data: ["elapsed_ms": elapsed, "attempt": recoveryAttempt]
    )
  }

  private func initialConnectTimedOut(
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    startedAt: Date
  ) {
    guard self.room == room, roomTarget == target, demand.target == target,
          case .connecting = state
    else { return }
    let elapsed = elapsedMilliseconds(since: startedAt)
    let error = GridRTCInitialConnectError.timedOut(milliseconds: elapsed)
    lastError = error.localizedDescription
    log.error(
      "GRID_ENGINE phase=rtc_initial_connect_watchdog session=\(target.rawValue) elapsed_ms=\(elapsed)",
      error: error
    )
    PerformanceTrace.breadcrumb(
      "Grid RTC initial connection watchdog fired",
      category: "Grid.RTC",
      level: .error,
      data: ["elapsed_ms": elapsed, "attempt": recoveryAttempt]
    )
    recordAbandonedProviderOperation(
      id: reconcileTaskID,
      operation: "connect",
      target: target
    )
    // Cancellation is advisory for provider code, so detach logical ownership
    // of this reconcile task before starting recovery. A fresh attempt must be
    // able to begin even if the old Room.connect call never returns. Its task
    // ID prevents a late completion from clearing the replacement worker.
    cancelReconcile()
    detach(room)
    beginRetirement(of: room, target: target)
    state = .failed(target, error.localizedDescription)
    emitSnapshot()
    scheduleBackoff(for: target)
  }

  private func scheduleMicrophonePublishWatchdog(
    for room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    startedAt: Date
  ) -> Task<Void, Never>? {
    let timeout = configuration.connection.microphonePublishWatchdogTimeout
    guard timeout > 0 else { return nil }
    return Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(timeout * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.microphonePublishTimedOut(
        room: room,
        target: target,
        startedAt: startedAt
      )
    }
  }

  private func microphonePublishTimedOut(
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    startedAt: Date
  ) {
    guard self.room == room,
          roomTarget == target,
          demand.target == target,
          !microphonePublished,
          case .publishing = microphonePublicationState
    else { return }
    operationTimedOut(
      .publishMicrophone,
      room: room,
      target: target,
      startedAt: startedAt
    )
  }

  private func scheduleMicrophoneMuteWatchdog(
    for room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    desiredMuted: Bool,
    startedAt: Date
  ) -> Task<Void, Never>? {
    let timeout = configuration.connection.microphoneMuteWatchdogTimeout
    guard timeout > 0 else { return nil }
    return Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(timeout * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.microphoneMuteTimedOut(
        room: room,
        target: target,
        desiredMuted: desiredMuted,
        startedAt: startedAt
      )
    }
  }

  private func microphoneMuteTimedOut(
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    desiredMuted: Bool,
    startedAt: Date
  ) {
    guard self.room == room, roomTarget == target, demand.target == target else { return }
    log.warning(
      "GRID_ENGINE phase=rtc_microphone_mute_stuck session=\(target.rawValue) desired_muted=\(desiredMuted)"
    )
    operationTimedOut(
      .muteMicrophone,
      room: room,
      target: target,
      startedAt: startedAt
    )
  }

  private func operationTimedOut(
    _ operation: GridRTCProviderOperation,
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    startedAt: Date
  ) {
    let elapsed = elapsedMilliseconds(since: startedAt)
    let error = GridRTCProviderOperationError.timedOut(
      operation: operation,
      milliseconds: elapsed
    )
    lastError = error.localizedDescription
    log.error(
      "GRID_ENGINE phase=rtc_provider_operation_watchdog operation=\(operation.rawValue) session=\(target.rawValue) elapsed_ms=\(elapsed)",
      error: error
    )
    PerformanceTrace.breadcrumb(
      "Grid RTC provider operation watchdog fired",
      category: "Grid.RTC",
      level: .error,
      data: ["operation": operation.rawValue, "elapsed_ms": elapsed]
    )
    recordAbandonedProviderOperation(
      id: reconcileTaskID,
      operation: operation.rawValue,
      target: target
    )
    cancelReconcile()
    detach(room)
    beginRetirement(of: room, target: target)
    state = .failed(target, error.localizedDescription)
    emitSnapshot()
    scheduleBackoff(for: target)
  }

  /// Publishes every new microphone track muted first. Inline's mic intent is
  /// reconciled only after the server acknowledges that safe initial state.
  /// Publication failure is a media substate and never destroys a healthy RTC
  /// room or prevents the participant from receiving remote audio.
  private func publishMicrophone(
    in room: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) async -> Bool {
    microphonePublishAttempt += 1
    let attempt = microphonePublishAttempt
    microphonePublicationState = .publishing(attempt: attempt)
    emitSnapshot()

    let startedAt = Date()
    let watchdogTask = scheduleMicrophonePublishWatchdog(
      for: room,
      target: target,
      startedAt: startedAt
    )
    defer { watchdogTask?.cancel() }
    do {
      try await driver.publishPreparedMicrophone(room, initiallyMuted: true)
    } catch {
      guard self.room == room, roomTarget == target else { return false }
      let message = String(describing: error)
      microphonePublicationState = .failed(message: message, attempt: attempt)
      lastError = message
      let elapsed = elapsedMilliseconds(since: startedAt)
      if attempt == 3 {
        log.error(
          "GRID_ENGINE phase=rtc_microphone_publish_persistently_failed attempt=3 elapsed_ms=\(elapsed)",
          error: error
        )
      } else {
        log.warning(
          "GRID_ENGINE phase=rtc_microphone_publish_failed attempt=\(attempt) elapsed_ms=\(elapsed)"
        )
      }
      if attempt == 1 || attempt == 3 || attempt.isMultiple(of: 10) {
        PerformanceTrace.breadcrumb(
          "Grid microphone publication failed",
          category: "Grid.RTC",
          level: .warning,
          data: ["attempt": attempt, "elapsed_ms": elapsed]
        )
      }
      scheduleMicrophoneRetry(for: target)
      emitSnapshot()
      return false
    }

    guard demand.target == target, self.room == room, roomTarget == target else { return false }
    microphonePublished = true
    microphoneMuted = true
    microphonePublishAttempt = 0
    microphoneReconcileFailures = 0
    microphonePublicationState = .published
    localAudioFlowState = .unknown
    localAudioFlowFailureActive = false
    remoteAudioFlowStates = [:]
    lastError = nil
    log.debug(
      "GRID_ENGINE phase=rtc_microphone_published session=\(target.rawValue) elapsed_ms=\(elapsedMilliseconds(since: startedAt)) muted=true"
    )
    emitSnapshot()
    return true
  }

  private func retire(_ room: GridRTCRoomHandle, target: InlineRTCSessionID) async {
    let startedAt = Date()
    await silenceWithDeadline(room, target: target)
    var providerCompleted = false
    if providerCircuitBreaker.isOpen {
      log.error(
        "GRID_ENGINE phase=rtc_provider_teardown_skipped_circuit_open session=\(target.rawValue) abandoned=\(providerCircuitBreaker.abandonedOperationCount)"
      )
    } else {
      let operationID = UUID()
      let providerTask = Task { [weak self, driver] in
        await driver.disconnect(room)
        await self?.providerDisconnectFinished(room, operationID: operationID)
      }
      providerDisconnectTasks[room] = providerTask
      providerDisconnectOperationIDs[room] = operationID
      let teardownTimeout = configuration.connection.providerTeardownTimeout
      while !completedProviderDisconnects.contains(room),
            Date().timeIntervalSince(startedAt) < teardownTimeout,
            !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
      }
      providerCompleted = completedProviderDisconnects.remove(room) != nil
      if !providerCompleted {
        providerDisconnectTasks[room] = nil
        providerDisconnectOperationIDs[room] = nil
        recordAbandonedProviderOperation(
          id: operationID,
          operation: "disconnect",
          target: target
        )
        providerTask.cancel()
        log.warning(
          "GRID_ENGINE phase=rtc_provider_teardown_timed_out session=\(target.rawValue) elapsed_ms=\(elapsedMilliseconds(since: startedAt))"
        )
        PerformanceTrace.breadcrumb(
          "Grid RTC provider teardown timed out",
          category: "Grid.RTC",
          level: .warning,
          data: ["elapsed_ms": elapsedMilliseconds(since: startedAt)]
        )
      }
    }
    if let lifecycleAudioLease = lifecycleAudioLeases.removeValue(forKey: room) {
      await audio.releaseCaptureLease(lifecycleAudioLease)
    }
    lastDisconnectMilliseconds = elapsedMilliseconds(since: startedAt)
    retirementTasks[room] = nil
    log.debug(
      "GRID_ENGINE phase=rtc_disconnected session=\(target.rawValue) elapsed_ms=\(lastDisconnectMilliseconds ?? 0) provider_completed=\(providerCompleted)"
    )
    emitSnapshot()
  }

  private func silenceWithDeadline(
    _ room: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) async {
    let timeout = configuration.connection.roomSilenceTimeout
    guard timeout > 0 else {
      log.debug(
        "GRID_ENGINE phase=rtc_silence_skipped_disabled session=\(target.rawValue)"
      )
      return
    }
    guard !providerCircuitBreaker.isOpen else {
      log.error(
        "GRID_ENGINE phase=rtc_silence_skipped_circuit_open session=\(target.rawValue) abandoned=\(providerCircuitBreaker.abandonedOperationCount)"
      )
      return
    }

    let operationID = UUID()
    activeSilenceOperations.insert(operationID)
    let startedAt = Date()
    let providerTask = Task { [weak self, driver] in
      await driver.silence(room)
      await self?.silenceFinished(operationID)
    }
    while activeSilenceOperations.contains(operationID),
          !completedSilenceOperations.contains(operationID),
          Date().timeIntervalSince(startedAt) < timeout,
          !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(10))
    }

    let completed = completedSilenceOperations.remove(operationID) != nil
    activeSilenceOperations.remove(operationID)
    guard !completed else { return }
    recordAbandonedProviderOperation(
      id: operationID,
      operation: "silence",
      target: target
    )
    providerTask.cancel()
    let elapsed = elapsedMilliseconds(since: startedAt)
    log.warning(
      "GRID_ENGINE phase=rtc_silence_timed_out session=\(target.rawValue) elapsed_ms=\(elapsed)"
    )
    PerformanceTrace.breadcrumb(
      "Grid RTC silence timed out",
      category: "Grid.RTC",
      level: .warning,
      data: ["elapsed_ms": elapsed]
    )
  }

  private func silenceFinished(_ operationID: UUID) {
    if providerCircuitBreaker.contains(id: operationID) {
      retiredProviderOperationReturned(id: operationID)
    }
    guard activeSilenceOperations.contains(operationID) else { return }
    completedSilenceOperations.insert(operationID)
  }

  private func providerDisconnectFinished(
    _ room: GridRTCRoomHandle,
    operationID: UUID
  ) {
    if providerCircuitBreaker.contains(id: operationID) {
      retiredProviderOperationReturned(id: operationID)
    }
    guard providerDisconnectOperationIDs[room] == operationID else { return }
    providerDisconnectOperationIDs[room] = nil
    providerDisconnectTasks[room] = nil
    completedProviderDisconnects.insert(room)
  }

  private func detach(_ detachedRoom: GridRTCRoomHandle) {
    guard room == detachedRoom else { return }
    reconnectsAwaitingMicrophonePublication.remove(detachedRoom)
    room = nil
    roomTarget = nil
    microphoneRetryTask?.cancel()
    microphoneRetryTask = nil
    microphonePublicationState = .notRequested
    microphonePublished = false
    microphoneMuted = true
    appliedOutputVolume = nil
    localAudioFlowState = .unknown
    localAudioFlowFailureActive = false
    remoteAudioFlowStates = [:]
    microphonePublishAttempt = 0
    participants = []
    startAudioPreparationWait(for: demand.target)
    emitSnapshot()
  }

  private func beginRetirement(of room: GridRTCRoomHandle, target: InlineRTCSessionID) {
    guard retirementTasks[room] == nil else { return }
    retirementTasks[room] = Task { [weak self] in
      await self?.retire(room, target: target)
    }
  }

  private func validCredentials(for target: InlineRTCSessionID) -> InlineRTCCredentials? {
    guard let credentials = demand.credentials,
          credentials.target == target,
          credentials.expiresAt.timeIntervalSinceNow > 5
    else { return nil }
    return credentials
  }

  private func scheduleBackoff(for target: InlineRTCSessionID) {
    guard demand.target == target else { return }
    guard !providerCircuitBreaker.isOpen else {
      let error = GridRTCProviderCircuitError.open(
        abandonedOperations: providerCircuitBreaker.abandonedOperationCount
      )
      lastError = error.localizedDescription
      state = .failed(target, error.localizedDescription)
      emitSnapshot()
      return
    }
    let attempt = max(recoveryAttempt, 1)
    let delay = Self.recoveryDelay(attempt: attempt)
    state = .backingOff(target, attempt: attempt, delaySeconds: delay)
    emitSnapshot()
    backoffTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      await self?.backoffFinished(target: target)
    }
  }

  private func backoffFinished(target: InlineRTCSessionID) {
    backoffTask = nil
    guard demand.target == target else { return }
    scheduleReconcile()
  }

  private func scheduleMicrophoneRetry(for target: InlineRTCSessionID) {
    guard demand.target == target, roomTarget == target, microphoneRetryTask == nil else { return }
    let attempt = max(microphonePublishAttempt, 1)
    let delay = Self.recoveryDelay(attempt: attempt)
    log.debug(
      "GRID_ENGINE phase=rtc_microphone_retry_scheduled session=\(target.rawValue) attempt=\(attempt) delay_s=\(delay)"
    )
    microphoneRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      await self?.microphoneRetryFinished(target: target)
    }
  }

  private func microphoneRetryFinished(target: InlineRTCSessionID) {
    microphoneRetryTask = nil
    guard demand.target == target, roomTarget == target else { return }
    scheduleReconcile()
  }

  private func receive(_ event: GridRTCLifecycleEvent, from eventRoom: GridRTCRoomHandle) async {
    guard eventRoom == room, let target = roomTarget else { return }
    switch event {
    case let .reconnecting(mode):
      state = .reconnecting(target)
      if mode == .full, microphonePublished {
        reconnectsAwaitingMicrophonePublication.insert(eventRoom)
      }
      emitSnapshot()
      log.warning(
        "GRID_ENGINE phase=rtc_reconnecting session=\(target.rawValue) mode=\(mode.rawValue)"
      )
    case let .reconnected(mode):
      if case .reconnecting = state {
        reconnectCount += 1
      }
      state = .connected(target)
      lastError = nil
      log.info(
        "GRID_ENGINE phase=rtc_reconnected session=\(target.rawValue) mode=\(mode.rawValue) reconnect_count=\(reconnectCount)"
      )
      if mode == .full, reconnectsAwaitingMicrophonePublication.contains(eventRoom) {
        microphonePublished = false
        microphonePublicationState = .publishing(attempt: max(microphonePublishAttempt, 1))
        scheduleMicrophoneRetry(for: target)
      }
      scheduleReconcile()
    case let .localMicrophonePublished(muted):
      microphoneRetryTask?.cancel()
      microphoneRetryTask = nil
      microphonePublished = true
      microphoneMuted = muted
      microphonePublishAttempt = 0
      microphoneReconcileFailures = 0
      microphonePublicationState = .published
      lastError = nil
      log.debug(
        "GRID_ENGINE phase=rtc_microphone_publication_observed session=\(target.rawValue) muted=\(muted)"
      )
      reconnectsAwaitingMicrophonePublication.remove(eventRoom)
      scheduleReconcile()
    case .localMicrophoneUnpublished:
      microphonePublished = false
      microphonePublicationState = .publishing(attempt: max(microphonePublishAttempt, 1))
      log.warning(
        "GRID_ENGINE phase=rtc_microphone_unpublished session=\(target.rawValue) action=await_republish"
      )
      scheduleMicrophoneRetry(for: target)
    case let .localAudioFlow(flowState):
      await receiveLocalAudioFlow(flowState, room: eventRoom, target: target)
    case let .remoteAudioFlow(identity, flowState):
      await receiveRemoteAudioFlow(
        flowState,
        identity: identity,
        room: eventRoom,
        target: target
      )
    case let .disconnected(error):
      lastError = error
      log.warning(
        "GRID_ENGINE phase=rtc_terminal_disconnect session=\(target.rawValue)"
      )
      detach(eventRoom)
      beginRetirement(of: eventRoom, target: target)
      if demand.target == target {
        recoveryAttempt += 1
        scheduleBackoff(for: target)
      } else {
        scheduleReconcile()
      }
    }
    emitSnapshot()
  }

  private func receiveLocalAudioFlow(
    _ flowState: InlineRTCAudioFlowState,
    room eventRoom: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) async {
    localAudioFlowState = flowState
    switch flowState {
    case .unknown:
      if localAudioFlowFailureActive {
        localAudioFlowFailureActive = false
        if microphonePublished {
          microphonePublicationState = .published
        }
        lastError = nil
      }
    case .flowing:
      if localAudioFlowFailureActive {
        log.info(
          "GRID_ENGINE phase=rtc_local_audio_flow_recovered session=\(target.rawValue)"
        )
      }
      localAudioFlowFailureActive = false
      if microphonePublished {
        microphonePublicationState = .published
      }
      lastError = nil
    case .missing:
      guard microphonePublished,
            !microphoneMuted,
            demand.microphoneEnabled,
            self.room == eventRoom
      else { return }
      let wasMissing = localAudioFlowFailureActive
      localAudioFlowFailureActive = true
      let message = "Microphone capture is not delivering audio"
      microphonePublicationState = .failed(
        message: message,
        attempt: max(microphonePublishAttempt, 1)
      )
      lastError = message
      if !wasMissing {
        log.error(
          "GRID_ENGINE phase=rtc_local_audio_flow_missing session=\(target.rawValue)",
          error: GridRTCLocalAudioFlowError.missing
        )
        PerformanceTrace.breadcrumb(
          "Grid local microphone PCM is missing",
          category: "Grid.RTC",
          level: .error
        )
      }
      await audio.captureFlowMissing()
    }
  }

  private func receiveRemoteAudioFlow(
    _ flowState: InlineRTCAudioFlowState,
    identity: String,
    room eventRoom: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) async {
    let previous = remoteAudioFlowStates[identity]
    if flowState == .unknown {
      remoteAudioFlowStates[identity] = nil
    } else {
      remoteAudioFlowStates[identity] = flowState
    }
    guard flowState == .missing else {
      if previous == .missing, flowState == .flowing {
        log.info(
          "GRID_ENGINE phase=rtc_remote_audio_flow_recovered session=\(target.rawValue) participant=\(identity)"
        )
      }
      return
    }
    if previous != .missing {
      log.error(
        "GRID_ENGINE phase=rtc_remote_audio_flow_missing session=\(target.rawValue) participant=\(identity)",
        error: GridRTCRemoteAudioFlowError.missing
      )
      PerformanceTrace.breadcrumb(
        "Grid remote audio PCM is missing",
        category: "Grid.RTC",
        level: .error
      )
    }
    let disposition = await audio.playoutFlowMissing()
    guard disposition == .reconstructRTCSession,
          self.room == eventRoom,
          roomTarget == target,
          demand.target == target
    else { return }

    cancelReconcile()
    detach(eventRoom)
    beginRetirement(of: eventRoom, target: target)
    reconnectCount += 1
    state = .reconnecting(target)
    lastError = "Remote audio stopped delivering decoded PCM"
    log.warning(
      "GRID_ENGINE phase=rtc_remote_audio_reconstruction_started session=\(target.rawValue) participant=\(identity)"
    )
    emitSnapshot()
    scheduleReconcile()
  }

  private func shouldWaitForAudioPreparation(target: InlineRTCSessionID) -> Bool {
    if audioPreparationTarget != target || audioPreparationStartedAt == nil {
      startAudioPreparationWait(for: target)
    }
    guard let startedAt = audioPreparationStartedAt else { return false }
    return Date().timeIntervalSince(startedAt)
      < configuration.connection.audioPreparationConnectWaitTimeout
  }

  private func startAudioPreparationWait(for target: InlineRTCSessionID?) {
    audioPreparationTarget = target
    audioPreparationStartedAt = target == nil ? nil : Date()
    audioPreparationBypassLogged = false
  }

  private func clearAudioPreparationWait(for target: InlineRTCSessionID) {
    audioPreparationTarget = target
    audioPreparationStartedAt = nil
    audioPreparationBypassLogged = false
  }

  private func logAudioPreparationBypassIfNeeded(target: InlineRTCSessionID) {
    guard !audioPreparationBypassLogged else { return }
    audioPreparationBypassLogged = true
    let elapsed = audioPreparationStartedAt.map(elapsedMilliseconds) ?? 0
    log.warning(
      "GRID_ENGINE phase=rtc_audio_preparation_bypassed session=\(target.rawValue) elapsed_ms=\(elapsed) mode=listen_only"
    )
    PerformanceTrace.breadcrumb(
      "Grid joined listen-only after audio preparation delay",
      category: "Grid.RTC",
      level: .warning,
      data: ["elapsed_ms": elapsed]
    )
  }

  private func receiveParticipants(
    _ nextParticipants: [InlineRTCParticipant],
    from eventRoom: GridRTCRoomHandle
  ) {
    guard eventRoom == room else { return }
    participants = nextParticipants
    let currentIdentities = Set(nextParticipants.map(\.identity))
    remoteAudioFlowStates = remoteAudioFlowStates.filter { currentIdentities.contains($0.key) }
    emitSnapshot()
  }

  private func cancelReconcile() {
    reconcileTask?.cancel()
    reconcileTask = nil
    reconcileTaskID = nil
  }

  private func reconcileFinished(taskID: UUID) {
    if providerCircuitBreaker.contains(id: taskID) {
      retiredProviderOperationReturned(id: taskID)
    }
    guard reconcileTaskID == taskID else { return }
    reconcileTask = nil
    reconcileTaskID = nil
  }

  private func startDriverEventsIfNeeded() {
    if lifecycleEventsTask == nil {
      lifecycleEventsTask = Task { [weak self, events = driver.lifecycleEvents] in
        for await envelope in events {
          guard !Task.isCancelled else { return }
          await self?.receive(envelope.event, from: envelope.room)
        }
      }
    }
    if participantSnapshotsTask == nil {
      participantSnapshotsTask = Task { [weak self, snapshots = driver.participantSnapshots] in
        for await envelope in snapshots {
          guard !Task.isCancelled else { return }
          await self?.receiveParticipants(envelope.participants, from: envelope.room)
        }
      }
    }
  }

  private func emitSnapshot() {
    snapshotContinuation.yield(makeSnapshot())
  }

  private func makeSnapshot() -> InlineRTCConnectionSnapshot {
    InlineRTCConnectionSnapshot(
      state: state,
      target: roomTarget ?? demand.target,
      microphonePublicationState: microphonePublicationState,
      microphonePublished: microphonePublished,
      microphoneMuted: microphoneMuted,
      localAudioFlowState: localAudioFlowState,
      remoteAudioFlowStates: remoteAudioFlowStates,
      participants: participants,
      reconnectCount: reconnectCount,
      recoveryAttempt: recoveryAttempt,
      lastConnectMilliseconds: lastConnectMilliseconds,
      lastDisconnectMilliseconds: lastDisconnectMilliseconds,
      lastError: lastError,
      abandonedProviderOperationCount: providerCircuitBreaker.abandonedOperationCount,
      providerCircuitOpen: providerCircuitBreaker.isOpen
    )
  }

  private func recordAbandonedProviderOperation(
    id: UUID?,
    operation: String,
    target: InlineRTCSessionID
  ) {
    guard let id else { return }
    let wasOpen = providerCircuitBreaker.isOpen
    guard providerCircuitBreaker.abandon(id: id, operation: operation) else { return }
    let isOpen = providerCircuitBreaker.isOpen
    log.warning(
      "GRID_ENGINE phase=rtc_provider_operation_abandoned operation=\(operation) session=\(target.rawValue) abandoned=\(providerCircuitBreaker.abandonedOperationCount) circuit_open=\(isOpen)"
    )
    if !wasOpen, isOpen {
      PerformanceTrace.breadcrumb(
        "Grid RTC provider circuit opened",
        category: "Grid.RTC",
        level: .error,
        data: ["abandoned_operations": providerCircuitBreaker.abandonedOperationCount]
      )
    }
    emitSnapshot()
  }

  private func retiredProviderOperationReturned(id: UUID) {
    let wasOpen = providerCircuitBreaker.isOpen
    guard providerCircuitBreaker.retiredOperationReturned(id: id) else { return }
    let isOpen = providerCircuitBreaker.isOpen
    log.info(
      "GRID_ENGINE phase=rtc_provider_retired_operation_returned abandoned=\(providerCircuitBreaker.abandonedOperationCount) circuit_open=\(isOpen)"
    )
    if wasOpen, !isOpen {
      PerformanceTrace.breadcrumb(
        "Grid RTC provider circuit closed",
        category: "Grid.RTC",
        data: ["abandoned_operations": providerCircuitBreaker.abandonedOperationCount]
      )
      backoffTask?.cancel()
      backoffTask = nil
      scheduleReconcile()
    }
    emitSnapshot()
  }

  private static func recoveryDelay(attempt: Int) -> Int {
    switch attempt {
    case 1: 1
    case 2: 2
    case 3: 4
    case 4: 8
    case 5: 15
    default: 30
    }
  }

  private func recordConnectFailure(_ error: Error, attempt: Int) {
    if attempt == 5 {
      log.error("GRID_ENGINE phase=rtc_connect_persistently_failed attempt=5", error: error)
    } else {
      log.warning("GRID_ENGINE phase=rtc_connect_attempt_failed attempt=\(attempt)")
    }
    if attempt == 1 || attempt == 5 || attempt.isMultiple(of: 10) {
      PerformanceTrace.breadcrumb(
        "Grid RTC connection failed",
        category: "Grid.RTC",
        level: .warning,
        data: ["attempt": attempt]
      )
    }
  }

  private func elapsedMilliseconds(since startedAt: Date) -> Int {
    Int(Date().timeIntervalSince(startedAt) * 1_000)
  }
}

private enum GridRTCInitialConnectError: LocalizedError {
  case timedOut(milliseconds: Int)

  var errorDescription: String? {
    switch self {
    case let .timedOut(milliseconds):
      "Initial Grid connection timed out after \(milliseconds) ms"
    }
  }
}

private enum GridRTCProviderOperation: String {
  case publishMicrophone = "publish_microphone"
  case muteMicrophone = "mute_microphone"
}

private enum GridRTCProviderOperationError: LocalizedError {
  case timedOut(operation: GridRTCProviderOperation, milliseconds: Int)

  var errorDescription: String? {
    switch self {
    case let .timedOut(operation, milliseconds):
      "Grid provider operation \(operation.rawValue) timed out after \(milliseconds) ms"
    }
  }
}

private enum GridRTCProviderCircuitError: LocalizedError {
  case open(abandonedOperations: Int)

  var errorDescription: String? {
    switch self {
    case let .open(abandonedOperations):
      "Grid media provider paused after \(abandonedOperations) operations stopped responding"
    }
  }
}

private enum GridRTCLocalAudioFlowError: Error {
  case missing
}

private enum GridRTCRemoteAudioFlowError: Error {
  case missing
}
