import Foundation
import Logger

protocol GridRTCDriver: Sendable {
  var lifecycleEvents: AsyncStream<GridRTCLifecycleEventEnvelope> { get }
  var participantSnapshots: AsyncStream<GridRTCParticipantSnapshotEnvelope> { get }

  func makeRoom(configuration: InlineRTCConfiguration) async throws -> GridRTCRoomHandle
  func connect(_ room: GridRTCRoomHandle, credentials: InlineRTCCredentials) async throws
  func publishPreparedMicrophone(_ room: GridRTCRoomHandle, initiallyMuted: Bool) async throws
  func setMicrophoneMuted(_ muted: Bool, in room: GridRTCRoomHandle) async throws
  func screenCaptureSources() async throws -> [InlineRTCScreenCaptureSource]
  func setScreenShare(
    _ source: InlineRTCScreenCaptureSource?,
    in room: GridRTCRoomHandle
  ) async throws
  func setOutputVolume(_ volume: Float, in room: GridRTCRoomHandle) async
  func quiesceLocally(_ room: GridRTCRoomHandle) async -> GridLocalRoomQuiescenceReceipt
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
  private var screenShareRepublishExpectations:
    [GridRTCRoomHandle: GridScreenShareRepublishExpectation] = [:]
  private var screenShareRepublishTimeoutTasks:
    [GridRTCRoomHandle: Task<Void, Never>] = [:]
  private var screenSharePublishConfirmationTasks:
    [GridRTCRoomHandle: Task<Void, Never>] = [:]
  private var screenShareStopConfirmationTasks:
    [GridRTCRoomHandle: Task<Void, Never>] = [:]
  private var room: GridRTCRoomHandle?
  private var roomTarget: InlineRTCSessionID?
  private var state: InlineRTCConnectionState = .idle
  private var microphonePublicationState: InlineRTCMicrophoneState = .notRequested
  private var microphonePublished = false
  private var microphoneMuted = true
  private var appliedScreenCaptureSource: InlineRTCScreenCaptureSource?
  private var screenShareState: InlineRTCScreenShareState = .off
  private var screenShares: [InlineRTCScreenShare] = []
  private var screenShareCleanupRequired = false
  private var screenShareSnapshotRevision: UInt64 = 0
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
  private var reconcileRequested = false
  private var backoffTask: Task<Void, Never>?
  private var microphoneRetryTask: Task<Void, Never>?
  private var lifecycleEventsTask: Task<Void, Never>?
  private var participantSnapshotsTask: Task<Void, Never>?
  private var retirementTasks: [GridRTCRoomHandle: Task<Void, Never>] = [:]
  private var retirementsRequiringAudioTransportFence = Set<GridRTCRoomHandle>()
  private var pendingAudioTransportGeneration: UInt64?
  private var failedLocalQuiescence: [GridRTCRoomHandle: GridLocalRoomQuiescenceReceipt] = [:]
  private var failedLocalQuiescenceTargets: [GridRTCRoomHandle: InlineRTCSessionID] = [:]
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
    screenShareRepublishTimeoutTasks.values.forEach { $0.cancel() }
    screenSharePublishConfirmationTasks.values.forEach { $0.cancel() }
    screenShareStopConfirmationTasks.values.forEach { $0.cancel() }
    retirementTasks.values.forEach { $0.cancel() }
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
    await audio.setOutput(nextDemand.output)
    await audio.setOutputVolume(nextDemand.outputVolume)
    await replaceDemandAudioLease(for: nextDemand.target)

    log.debug(
      "GRID_ENGINE phase=rtc_demand_replaced revision=\(demandRevision) room=\(nextDemand.target.map(\.rawValue) ?? "none") microphone=\(nextDemand.microphoneEnabled) screen_share=\(nextDemand.screenCaptureSource != nil)"
    )
    scheduleReconcile()
  }

  func networkBecameAvailable() {
    retryFailedLocalQuiescence()
    backoffTask?.cancel()
    backoffTask = nil
    microphoneRetryTask?.cancel()
    microphoneRetryTask = nil
    scheduleReconcile()
  }

  func applicationDidWake() {
    retryFailedLocalQuiescence()
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

  func screenCaptureSources() async throws -> [InlineRTCScreenCaptureSource] {
    try await driver.screenCaptureSources()
  }

  func currentSnapshot() -> InlineRTCConnectionSnapshot {
    makeSnapshot()
  }

  func shutdown() async -> GridRTCShutdownReceipt {
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
    retryFailedLocalQuiescence()
    await replaceDemandAudioLease(for: nil)
    let deadline = Date().addingTimeInterval(configuration.connection.providerTeardownTimeout)
    while Date() < deadline {
      if retirementTasks.isEmpty {
        guard !failedLocalQuiescence.isEmpty else { break }
        retryFailedLocalQuiescence()
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    let activeRooms = Set(retirementTasks.keys).union(failedLocalQuiescence.keys)
    let activeCount = activeRooms.count
    let localMediaMutationCount = failedLocalQuiescence.values
      .reduce(0) { $0 + $1.localMediaMutationCount }
    let microphonePublicationCount = failedLocalQuiescence.values
      .reduce(0) { $0 + $1.microphonePublicationCount }
    let screenSharePublicationCount = failedLocalQuiescence.values
      .reduce(0) { $0 + $1.screenSharePublicationCount }
    let failures = failedLocalQuiescence.values.flatMap(\.failures)
      + (failedLocalQuiescence.isEmpty
        ? []
        : ["\(failedLocalQuiescence.count) room(s) failed local media quiescence."])
      + (retirementTasks.isEmpty
        ? []
        : ["Timed out waiting for \(retirementTasks.count) room(s) to release local media."])
    state = activeCount == 0
      ? .idle
      : .failed(nil, failures.first ?? "Local room quiescence could not be proven.")
    emitSnapshot()
    return GridRTCShutdownReceipt(
      locallyActiveRoomCount: activeCount,
      localMediaMutationCount: localMediaMutationCount,
      microphonePublicationCount: microphonePublicationCount,
      screenSharePublicationCount: screenSharePublicationCount,
      failures: failures
    )
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
    guard backoffTask == nil else { return }
    guard reconcileTask == nil else {
      reconcileRequested = true
      return
    }
    reconcileRequested = false
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
        appliedScreenCaptureSource = nil
        screenShareState = .off
        screenShares = []
        screenShareCleanupRequired = false
        screenShareSnapshotRevision = 0
        localAudioFlowState = .unknown
        localAudioFlowFailureActive = false
        remoteAudioFlowStates = [:]
        emitSnapshot()
        return
      }

      if room == nil, pendingAudioTransportGeneration == nil {
        pendingAudioTransportGeneration = await audio.rtcTransportWillInitialize()
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
        if screenShareRepublishExpectations[room] == nil,
           appliedScreenCaptureSource != demand.screenCaptureSource
             || screenShareCleanupRequired {
          guard await reconcileScreenShare(in: room, target: target) else { return }
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
          let senderMayStartRecording = await audio.microphoneSenderMayStartRecording()
          guard audioSnapshot.isPrepared || senderMayStartRecording else {
            state = .connected(target)
            microphonePublicationState = .waitingForAudio
            emitSnapshot()
            if case .failed = audioSnapshot.state {
              scheduleMicrophoneRetry(for: target)
            } else {
              scheduleMicrophoneReadinessCheck(for: target)
            }
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
      guard audioSnapshot.isConfigured else {
        switch audioSnapshot.state {
        case let .failed(message):
          let failure = "Audio runtime could not initialize before RTC: \(message)"
          state = .failed(target, failure)
          lastError = failure
          emitSnapshot()
          return
        default:
          state = .preparingAudio(target)
          emitSnapshot()
          try? await Task.sleep(for: .milliseconds(25))
          continue
        }
      }
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
    appliedScreenCaptureSource = nil
    screenShareState = .off
    screenShares = []
    screenShareCleanupRequired = false
    screenShareSnapshotRevision = 0
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
    let audioTransportGeneration = await audioTransportGenerationForConnect()
    pendingAudioTransportGeneration = audioTransportGeneration
    do {
      try await driver.connect(room, credentials: credentials)
      guard demand.target == target, self.room == room else {
        detach(room)
        beginRetirement(of: room, target: target)
        return
      }
      await audio.rtcTransportDidInitialize(
        generation: audioTransportGeneration
      )
      pendingAudioTransportGeneration = nil
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

  /// Retirement and reconcile are separate tasks so a cancellation-insensitive
  /// provider teardown cannot pin the actor. Both can observe `room == nil`
  /// and open the next custom-ADM transport fence. If that happens, only the
  /// newest generation may be acknowledged after `Room.connect`; accepting a
  /// retained older value leaves the replacement sender permanently gated.
  private func audioTransportGenerationForConnect() async -> UInt64 {
    if let pendingAudioTransportGeneration {
      let currentGeneration = await audio.rtcTransportPreparationGeneration()
      guard currentGeneration != pendingAudioTransportGeneration else {
        return pendingAudioTransportGeneration
      }
      log.warning(
        "GRID_ENGINE phase=rtc_audio_transport_generation_reconciled stale=\(pendingAudioTransportGeneration) current=\(currentGeneration)"
      )
      return currentGeneration
    }
    return await audio.rtcTransportWillInitialize()
  }

  /// LiveKit room operations are process-global enough that overlapping a
  /// routine disconnect with the next connect creates avoidable signaling and
  /// audio churn. Wait for the fast path, but preserve bounded forward progress
  /// when a provider call is genuinely stuck.
  private func waitForRetirementsBeforeConnect(target: InlineRTCSessionID) async throws {
    let timeout = configuration.connection.retirementBarrierTimeout
    guard !retirementTasks.isEmpty || !failedLocalQuiescence.isEmpty else { return }
    guard timeout > 0 else {
      throw GridRTCLocalQuiescenceError.pending(
        roomCount: Set(retirementTasks.keys).union(failedLocalQuiescence.keys).count
      )
    }

    let startedAt = Date()
    while !retirementTasks.isEmpty,
          Date().timeIntervalSince(startedAt) < timeout {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(5))
    }

    let elapsed = elapsedMilliseconds(since: startedAt)
    if retirementTasks.isEmpty, failedLocalQuiescence.isEmpty {
      log.debug(
        "GRID_ENGINE phase=rtc_retirement_barrier_finished session=\(target.rawValue) elapsed_ms=\(elapsed)"
      )
    } else {
      log.error(
        "GRID_ENGINE phase=rtc_retirement_barrier_timed_out session=\(target.rawValue) elapsed_ms=\(elapsed) pending=\(retirementTasks.count) failed_local=\(failedLocalQuiescence.count)"
      )
      throw GridRTCLocalQuiescenceError.pending(
        roomCount: Set(retirementTasks.keys).union(failedLocalQuiescence.keys).count
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

  private func scheduleScreenShareOperationWatchdog(
    _ operation: GridRTCProviderOperation,
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    startedAt: Date
  ) -> Task<Void, Never>? {
    // Publication work uses the reconnect-republish bound. Terminal Stop is
    // capped by the smaller teardown bound because local capture may remain
    // active until the room becomes the isolation boundary.
    let timeout = screenShareOperationTimeout(for: operation)
    guard timeout > 0, let operationID = reconcileTaskID else { return nil }
    return Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(timeout * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.screenShareOperationTimedOut(
        operation,
        operationID: operationID,
        room: room,
        target: target,
        startedAt: startedAt
      )
    }
  }

  private func screenShareOperationTimedOut(
    _ operation: GridRTCProviderOperation,
    operationID: UUID,
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    startedAt: Date
  ) {
    guard reconcileTaskID == operationID,
          self.room == room,
          roomTarget == target,
          demand.target == target
    else { return }
    operationTimedOut(operation, room: room, target: target, startedAt: startedAt)
  }

  private func screenShareOperationTimeout(
    for operation: GridRTCProviderOperation
  ) -> TimeInterval {
    let publicationTimeout = configuration.connection.screenShareRepublishTimeout
    guard operation == .stopScreenShare else { return publicationTimeout }

    let teardownTimeout = configuration.connection.providerTeardownTimeout
    if publicationTimeout <= 0 { return teardownTimeout }
    if teardownTimeout <= 0 { return publicationTimeout }
    return min(publicationTimeout, teardownTimeout)
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

  private func reconcileScreenShare(
    in room: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) async -> Bool {
    let source = demand.screenCaptureSource
    let previousSource = appliedScreenCaptureSource
    let operation: GridRTCProviderOperation = if source == nil {
      .stopScreenShare
    } else if previousSource == nil {
      .publishScreenShare
    } else {
      .switchScreenShare
    }
    if source == nil {
      clearScreenSharePublishConfirmation(for: room)
    }
    screenShareState = source == nil ? .stopping : .publishing
    emitSnapshot()

    let startedAt = Date()
    let watchdogTask = scheduleScreenShareOperationWatchdog(
      operation,
      room: room,
      target: target,
      startedAt: startedAt
    )
    defer { watchdogTask?.cancel() }
    do {
      try await driver.setScreenShare(source, in: room)
    } catch {
      guard self.room == room, roomTarget == target else { return false }
      // Treat a failed start as requiring an explicit cleanup pass. LiveKit
      // may have created or partially published the track before surfacing
      // the error.
      appliedScreenCaptureSource = source ?? previousSource
      screenShareState = .failed(String(describing: error))
      log.error(
        "GRID_ENGINE phase=rtc_screen_share_reconcile_failed session=\(target.rawValue) requested_source=\(source?.id ?? "none") previous_source=\(previousSource?.id ?? "none") demand_revision=\(demandRevision) confirmed_publications=\(screenShares.filter(\.isLocal).map(\.publicationID).joined(separator: ","))",
        error: error
      )
      if source == nil {
        reconstructAfterScreenShareFailure(
          room: room,
          target: target,
          message: "Screen sharing did not stop",
          phase: "stop_failed"
        )
        return false
      }
      emitSnapshot()
      return false
    }

    guard self.room == room, roomTarget == target else { return false }
    // The provider operation succeeded even if product intent changed while
    // it was suspended. Record the concrete applied state first so the next
    // reconcile pass can undo a stale publication instead of assuming that
    // nothing reached LiveKit.
    appliedScreenCaptureSource = source
    screenShareCleanupRequired = false
    if source == nil {
      clearScreenShareRepublishExpectation(for: room)
      clearScreenSharePublishConfirmation(for: room)
      if screenShares.contains(where: \.isLocal) {
        screenShareState = .stopping
        scheduleScreenShareStopConfirmation(for: room, target: target)
      } else {
        clearScreenShareStopConfirmation(for: room)
        screenShareState = .off
      }
    } else {
      clearScreenShareStopConfirmation(for: room)
      if demand.screenCaptureSource == source,
         !screenShares.contains(where: \.isLocal) {
        scheduleScreenSharePublishConfirmation(for: room, target: target)
      } else {
        clearScreenSharePublishConfirmation(for: room)
      }
      screenShareState = .published
    }
    guard demand.screenCaptureSource == source else {
      emitSnapshot()
      return true
    }
    log.debug(
      "GRID_ENGINE phase=rtc_screen_share_reconciled session=\(target.rawValue) enabled=\(source != nil)"
    )
    emitSnapshot()
    return true
  }

  private func retire(_ room: GridRTCRoomHandle, target: InlineRTCSessionID) async {
    let startedAt = Date()
    let receipt = await driver.quiesceLocally(room)
    if receipt.isQuiescent {
      failedLocalQuiescence[room] = nil
      failedLocalQuiescenceTargets[room] = nil
      if let lifecycleAudioLease = lifecycleAudioLeases.removeValue(forKey: room) {
        await audio.releaseCaptureLease(lifecycleAudioLease)
      }
      if demand.target != nil, backoffTask == nil {
        scheduleReconcile()
      }
    } else {
      failedLocalQuiescence[room] = receipt
      failedLocalQuiescenceTargets[room] = target
      log.error(
        "GRID_ENGINE phase=rtc_local_quiescence_failed session=\(target.rawValue) local_media_mutations=\(receipt.localMediaMutationCount) microphone_publications=\(receipt.microphonePublicationCount) screen_publications=\(receipt.screenSharePublicationCount) failures=\(receipt.failures.joined(separator: ","))"
      )
      if demand.target == nil {
        let failure = receipt.failures.first
          ?? "Local media mutation ownership could not be released."
        state = .failed(nil, failure)
        lastError = failure
      }
    }
    lastDisconnectMilliseconds = elapsedMilliseconds(since: startedAt)
    retirementTasks[room] = nil
    log.debug(
      "GRID_ENGINE phase=rtc_retired session=\(target.rawValue) elapsed_ms=\(lastDisconnectMilliseconds ?? 0) locally_quiescent=\(receipt.isQuiescent)"
    )
    emitSnapshot()
  }

  private func detach(_ detachedRoom: GridRTCRoomHandle) {
    guard room == detachedRoom else { return }
    retirementsRequiringAudioTransportFence.insert(detachedRoom)
    pendingAudioTransportGeneration = nil
    reconnectsAwaitingMicrophonePublication.remove(detachedRoom)
    clearScreenShareRepublishExpectation(for: detachedRoom)
    clearScreenSharePublishConfirmation(for: detachedRoom)
    clearScreenShareStopConfirmation(for: detachedRoom)
    room = nil
    roomTarget = nil
    microphoneRetryTask?.cancel()
    microphoneRetryTask = nil
    microphonePublicationState = .notRequested
    microphonePublished = false
    microphoneMuted = true
    appliedScreenCaptureSource = nil
    screenShareState = .off
    screenShares = []
    screenShareCleanupRequired = false
    screenShareSnapshotRevision = 0
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
    retirementTasks[room] = Task {
      await self.fenceAudioTransportForRetirement(of: room)
      await self.retire(room, target: target)
    }
  }

  private func fenceAudioTransportForRetirement(of retiredRoom: GridRTCRoomHandle) async {
    guard retirementsRequiringAudioTransportFence.remove(retiredRoom) != nil,
          room == nil
    else { return }
    let generation = await audio.rtcTransportWillInitialize()
    if demand.target != nil, pendingAudioTransportGeneration == nil {
      pendingAudioTransportGeneration = generation
    }
  }

  private func retryFailedLocalQuiescence() {
    let obligations = failedLocalQuiescenceTargets
    for (room, target) in obligations where retirementTasks[room] == nil {
      // Keep the last concrete receipt visible until a retry proves success.
      // Otherwise shutdown can forget known retained publications while the
      // replacement local cleanup is still pending.
      beginRetirement(of: room, target: target)
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

  /// Route fencing and Room.connect complete on separate actors. A healthy
  /// custom ADM may need one short reconciliation turn after transport init;
  /// treating that coordination window as a publication failure adds a full
  /// second of silence. Persistent audio failures still use exponential retry.
  private func scheduleMicrophoneReadinessCheck(for target: InlineRTCSessionID) {
    guard demand.target == target, roomTarget == target, microphoneRetryTask == nil else { return }
    microphoneRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(25))
      await self?.microphoneRetryFinished(target: target)
    }
  }

  private func microphoneRetryFinished(target: InlineRTCSessionID) {
    microphoneRetryTask = nil
    guard demand.target == target, roomTarget == target else { return }
    scheduleReconcile()
  }

  private func receive(_ event: GridRTCLifecycleEvent, from eventRoom: GridRTCRoomHandle) async {
    if event == .retiredLocalMediaMutationReleased {
      guard let target = failedLocalQuiescenceTargets[eventRoom],
            retirementTasks[eventRoom] == nil
      else { return }
      beginRetirement(of: eventRoom, target: target)
      return
    }
    guard eventRoom == room, let target = roomTarget else { return }
    switch event {
    case let .reconnecting(mode):
      state = .reconnecting(target)
      if mode == .full, microphonePublished {
        reconnectsAwaitingMicrophonePublication.insert(eventRoom)
      }
      if mode == .full, screenShareRepublishExpectations[eventRoom] == nil {
        let localPublicationIDs = Set(
          screenShares.lazy.filter(\.isLocal).map(\.publicationID)
        )
        let hasInFlightScreenShareOperation = switch screenShareState {
        case .publishing, .stopping: true
        case .off, .published, .failed: false
        }
        // Product intent may already have changed by the time the provider's
        // reconnect callback reaches this actor. Concrete or in-flight local
        // provider state still needs a fence around LiveKit's detached
        // republish transaction.
        if !localPublicationIDs.isEmpty
          || appliedScreenCaptureSource != nil
          || hasInFlightScreenShareOperation
          || screenShareCleanupRequired {
          screenShareRepublishExpectations[eventRoom] =
            GridScreenShareRepublishExpectation(
              replacedPublicationIDs: localPublicationIDs
            )
          scheduleScreenShareRepublishTimeout(for: eventRoom, target: target)
        }
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
    case let .screenSharesChanged(revision, nextScreenShares):
      guard revision > screenShareSnapshotRevision else {
        log.debug(
          "GRID_ENGINE phase=rtc_screen_share_snapshot_ignored session=\(target.rawValue) revision=\(revision) latest_revision=\(screenShareSnapshotRevision)"
        )
        return
      }
      let hadLocalShare = screenShares.contains(where: \.isLocal)
      let hasLocalShare = nextScreenShares.contains(where: \.isLocal)
      screenShareSnapshotRevision = revision
      screenShares = nextScreenShares
      if hasLocalShare {
        clearScreenSharePublishConfirmation(for: eventRoom)
      }
      let nextLocalPublicationIDs = Set(
        nextScreenShares.lazy.filter(\.isLocal).map(\.publicationID)
      )
      if var expectation = screenShareRepublishExpectations[eventRoom] {
        if nextLocalPublicationIDs.isEmpty {
          // LiveKit full reconnect retains the local track but explicitly
          // unpublishes its old SID before publishing a replacement. Do not
          // race that SDK-owned transaction with an app-level operation,
          // including a Stop request made while the replacement is in flight.
          screenShareState = demand.screenCaptureSource == nil ? .stopping : .publishing
          expectation.sawPublicationGap = true
          screenShareRepublishExpectations[eventRoom] = expectation
          log.debug(
            "GRID_ENGINE phase=rtc_screen_share_republish_wait session=\(target.rawValue) revision=\(revision)"
          )
        } else if expectation.sawPublicationGap
          || nextLocalPublicationIDs.isDisjoint(with: expectation.replacedPublicationIDs) {
          clearScreenShareRepublishExpectation(for: eventRoom)
          screenShareState = demand.screenCaptureSource == nil ? .stopping : .published
          if demand.screenCaptureSource == nil {
            // The confirmation belonged to the pre-reconnect publication.
            // A replacement SID is fresh proof of local provider state and
            // therefore owns a new, immediate Stop operation.
            clearScreenShareStopConfirmation(for: eventRoom)
            screenShareCleanupRequired = true
          }
          scheduleReconcile()
          log.debug(
            "GRID_ENGINE phase=rtc_screen_share_republished session=\(target.rawValue) revision=\(revision) publications=\(nextLocalPublicationIDs.sorted().joined(separator: ",")) deferred_stop=\(demand.screenCaptureSource == nil)"
          )
        }
      } else if hadLocalShare, !hasLocalShare {
        if demand.screenCaptureSource == nil {
          appliedScreenCaptureSource = nil
          screenShareState = .off
        } else if case .reconnecting = state {
          appliedScreenCaptureSource = nil
          screenShareState = .publishing
          scheduleReconcile()
        } else {
          // A confirmed publication disappeared while product intent still
          // requested it. Treat the complete publication projection as the
          // authority and never republish after the macOS system stop control.
          appliedScreenCaptureSource =
            appliedScreenCaptureSource ?? demand.screenCaptureSource
          screenShareState = .failed("Screen sharing stopped")
          log.warning(
            "GRID_ENGINE phase=rtc_screen_share_interrupted session=\(target.rawValue) revision=\(revision)"
          )
        }
      }
      if screenShareRepublishExpectations[eventRoom] == nil,
         demand.screenCaptureSource == nil {
        if hasLocalShare {
          screenShareState = .stopping
          if screenShareStopConfirmationTasks[eventRoom] == nil {
            // Confirmed provider state wins over an earlier successful Stop.
            // A late SDK republish owns one more cleanup pass; a Stop already
            // awaiting confirmation is instead bounded by its watchdog.
            screenShareCleanupRequired = true
            scheduleReconcile()
          }
        } else {
          clearScreenShareStopConfirmation(for: eventRoom)
          screenShareCleanupRequired = false
          appliedScreenCaptureSource = nil
          screenShareState = .off
        }
      }
    case let .localAudioFlow(flowState):
      await receiveLocalAudioFlow(flowState, room: eventRoom, target: target)
    case let .remoteAudioFlow(identity, flowState):
      await receiveRemoteAudioFlow(
        flowState,
        identity: identity,
        room: eventRoom,
        target: target
      )
    case let .remoteAudioFramesObserved(identity):
      await verifyPhysicalPlayout(
        identity: identity,
        room: eventRoom,
        target: target
      )
    case .retiredLocalMediaMutationReleased:
      // Retired-room releases are handled before the current-room guard.
      break
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

  private func scheduleScreenShareRepublishTimeout(
    for room: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) {
    screenShareRepublishTimeoutTasks[room]?.cancel()
    let timeout = configuration.connection.screenShareRepublishTimeout
    guard timeout > 0 else { return }
    screenShareRepublishTimeoutTasks[room] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(timeout * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.screenShareRepublishTimedOut(room: room, target: target)
    }
  }

  private func screenShareRepublishTimedOut(
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) {
    screenShareRepublishTimeoutTasks[room] = nil
    guard self.room == room,
          roomTarget == target,
          demand.target == target,
          screenShareRepublishExpectations.removeValue(forKey: room) != nil
    else { return }

    // LiveKit owns full-reconnect republishing in a detached task. Once that
    // transaction exceeds our bound, an app-level publish or unpublish cannot
    // safely cancel it: the retained track could still appear afterward and
    // resurrect a stopped share (or duplicate a restarted one). Retire the
    // entire provider room so late SDK work is fenced by the room handle, then
    // reconcile the latest product intent in a fresh room.
    let requested = demand.screenCaptureSource != nil
    cancelReconcile()
    detach(room)
    beginRetirement(of: room, target: target)
    reconnectCount += 1
    state = .reconnecting(target)
    lastError = requested ? "Screen sharing is reconnecting" : nil
    log.warning(
      "GRID_ENGINE phase=rtc_screen_share_republish_timeout session=\(target.rawValue) result=reconstruct_room requested=\(requested)"
    )
    PerformanceTrace.breadcrumb(
      "Grid screen-share republish timed out",
      category: "Grid.RTC",
      level: .warning,
      data: ["requested": requested]
    )
    emitSnapshot()
    scheduleReconcile()
  }

  private func clearScreenShareRepublishExpectation(for room: GridRTCRoomHandle) {
    screenShareRepublishExpectations[room] = nil
    screenShareRepublishTimeoutTasks.removeValue(forKey: room)?.cancel()
  }

  private func scheduleScreenSharePublishConfirmation(
    for room: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) {
    clearScreenSharePublishConfirmation(for: room)
    let timeout = configuration.connection.screenShareRepublishTimeout
    guard timeout > 0 else { return }
    screenSharePublishConfirmationTasks[room] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(timeout * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.screenSharePublishConfirmationTimedOut(room: room, target: target)
    }
  }

  private func screenSharePublishConfirmationTimedOut(
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) {
    screenSharePublishConfirmationTasks[room] = nil
    guard self.room == room,
          roomTarget == target,
          demand.target == target,
          demand.screenCaptureSource != nil,
          !screenShares.contains(where: \.isLocal)
    else { return }

    let message = "Screen sharing could not be confirmed"
    screenShareState = .failed(message)
    lastError = message
    log.error(
      "GRID_ENGINE phase=rtc_screen_share_publish_confirmation_timeout session=\(target.rawValue)",
      error: GridRTCScreenShareRecoveryError.failed(message)
    )
    PerformanceTrace.breadcrumb(
      "Grid screen-share publication confirmation timed out",
      category: "Grid.RTC",
      level: .error
    )
    emitSnapshot()
  }

  private func clearScreenSharePublishConfirmation(for room: GridRTCRoomHandle) {
    screenSharePublishConfirmationTasks.removeValue(forKey: room)?.cancel()
  }

  private func scheduleScreenShareStopConfirmation(
    for room: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) {
    clearScreenShareStopConfirmation(for: room)
    let timeout = screenShareOperationTimeout(for: .stopScreenShare)
    guard timeout > 0 else { return }
    screenShareStopConfirmationTasks[room] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(timeout * 1_000)))
      guard !Task.isCancelled else { return }
      await self?.screenShareStopConfirmationTimedOut(room: room, target: target)
    }
  }

  private func screenShareStopConfirmationTimedOut(
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) {
    screenShareStopConfirmationTasks[room] = nil
    guard self.room == room,
          roomTarget == target,
          demand.target == target,
          demand.screenCaptureSource == nil,
          screenShares.contains(where: \.isLocal)
    else { return }

    reconstructAfterScreenShareFailure(
      room: room,
      target: target,
      message: "Screen sharing did not stop",
      phase: "stop_confirmation_timeout"
    )
  }

  private func clearScreenShareStopConfirmation(for room: GridRTCRoomHandle) {
    screenShareStopConfirmationTasks.removeValue(forKey: room)?.cancel()
  }

  private func reconstructAfterScreenShareFailure(
    room: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    message: String,
    phase: String
  ) {
    guard self.room == room, roomTarget == target else { return }
    cancelReconcile()
    detach(room)
    beginRetirement(of: room, target: target)
    reconnectCount += 1
    screenShareState = .failed(message)
    state = .reconnecting(target)
    lastError = message
    log.error(
      "GRID_ENGINE phase=rtc_screen_share_\(phase) session=\(target.rawValue) result=reconstruct_room",
      error: GridRTCScreenShareRecoveryError.failed(message)
    )
    PerformanceTrace.breadcrumb(
      "Grid screen-share room reconstruction",
      category: "Grid.RTC",
      level: .error,
      data: ["phase": phase]
    )
    emitSnapshot()
    scheduleReconcile()
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
      let disposition = await audio.captureFlowMissing()
      guard disposition == .reconstructRTCSession,
            self.room == eventRoom,
            roomTarget == target,
            demand.target == target
      else { return }
      reconstructForLocalAudioFailure(
        room: eventRoom,
        target: target,
        message: "Microphone capture stopped reaching outbound RTP"
      )
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
    reconstructForRemoteAudioFailure(
      identity: identity,
      room: eventRoom,
      target: target,
      message: "Remote audio stopped delivering decoded PCM"
    )
  }

  private func verifyPhysicalPlayout(
    identity: String,
    room eventRoom: GridRTCRoomHandle,
    target: InlineRTCSessionID
  ) async {
    guard let disposition = await audio.decodedRemoteAudioObserved(),
          disposition == .reconstructRTCSession,
          self.room == eventRoom,
          roomTarget == target,
          demand.target == target
    else { return }

    reconstructForRemoteAudioFailure(
      identity: identity,
      room: eventRoom,
      target: target,
      message: "Physical audio playback stopped while decoded PCM was flowing"
    )
  }

  private func reconstructForRemoteAudioFailure(
    identity: String,
    room eventRoom: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    message: String
  ) {
    guard self.room == eventRoom, roomTarget == target, demand.target == target else { return }

    cancelReconcile()
    detach(eventRoom)
    beginRetirement(of: eventRoom, target: target)
    reconnectCount += 1
    state = .reconnecting(target)
    lastError = message
    log.warning(
      "GRID_ENGINE phase=rtc_remote_audio_reconstruction_started session=\(target.rawValue) participant=\(identity)"
    )
    emitSnapshot()
    scheduleReconcile()
  }

  private func reconstructForLocalAudioFailure(
    room eventRoom: GridRTCRoomHandle,
    target: InlineRTCSessionID,
    message: String
  ) {
    guard self.room == eventRoom, roomTarget == target, demand.target == target else { return }

    cancelReconcile()
    detach(eventRoom)
    beginRetirement(of: eventRoom, target: target)
    reconnectCount += 1
    state = .reconnecting(target)
    lastError = message
    log.warning(
      "GRID_ENGINE phase=rtc_local_audio_reconstruction_started session=\(target.rawValue)"
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
    reconcileRequested = false
  }

  private func reconcileFinished(taskID: UUID) {
    if providerCircuitBreaker.contains(id: taskID) {
      retiredProviderOperationReturned(id: taskID)
    }
    guard reconcileTaskID == taskID else { return }
    reconcileTask = nil
    reconcileTaskID = nil
    guard reconcileRequested else { return }
    reconcileRequested = false
    scheduleReconcile()
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
      screenShareState: screenShareState,
      screenShares: screenShares,
      localAudioFlowState: localAudioFlowState,
      remoteAudioFlowStates: remoteAudioFlowStates,
      participants: participants,
      reconnectCount: reconnectCount,
      recoveryAttempt: recoveryAttempt,
      lastConnectMilliseconds: lastConnectMilliseconds,
      lastDisconnectMilliseconds: lastDisconnectMilliseconds,
      lastError: lastError,
      abandonedProviderOperationCount: providerCircuitBreaker.abandonedOperationCount,
      providerCircuitOpen: providerCircuitBreaker.isOpen,
      activeRoomCount: room == nil ? 0 : 1,
      retiringRoomCount: retirementTasks.count,
      failedLocalQuiescenceCount: failedLocalQuiescence.count,
      // Local transport closure is the bounded remote signal. Grid does not
      // retain a second provider-facing leave queue after local quiescence.
      pendingRemoteLeaveCount: 0
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
  case publishScreenShare = "publish_screen_share"
  case switchScreenShare = "switch_screen_share"
  case stopScreenShare = "stop_screen_share"
}

private struct GridScreenShareRepublishExpectation {
  let replacedPublicationIDs: Set<String>
  var sawPublicationGap = false
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

private enum GridRTCScreenShareRecoveryError: LocalizedError {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case let .failed(message): message
    }
  }
}

private enum GridRTCLocalQuiescenceError: LocalizedError {
  case pending(roomCount: Int)

  var errorDescription: String? {
    switch self {
    case let .pending(roomCount):
      "Grid cannot start another room while \(roomCount) previous room(s) still own local media."
    }
  }
}

private enum GridRTCLocalAudioFlowError: Error {
  case missing
}

private enum GridRTCRemoteAudioFlowError: Error {
  case missing
}
