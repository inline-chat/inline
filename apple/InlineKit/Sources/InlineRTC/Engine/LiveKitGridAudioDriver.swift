import AVFoundation
import Atomics
import Foundation
import LiveKit
import Logger

#if os(macOS)
actor LiveKitGridAudioDriver: GridAudioDriver {
  nonisolated let events: AsyncStream<GridAudioDriverEvent>
  nonisolated let preparationRequiresRTCTransport = true

  private nonisolated let eventContinuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private let catalog: MacGridAudioDeviceCatalog
  private let outputSettler: MacGridAudioOutputRouteSettler
  private var catalogTask: Task<Void, Never>?
  private var deviceUpdateObserver: AudioDeviceUpdateObserverHandle?
  private var latestCatalog: MacGridAudioCatalogSnapshot?
  private var audioProcessingOptions = AudioProcessingOptions()
  private var captureState = MacGridPlatformAudioCaptureState()
  private var configured = false
  private let audioDeviceModuleBootstrapError: String?
  private let inputDevices: MacGridWebRTCInputDeviceController
  private let audioLifecycle: MacGridWebRTCAudioLifecycleController
  private let log = Log.scoped("LiveKitGridAudioDriver")

  init(
    inputDevices: MacGridWebRTCInputDeviceController = MacGridWebRTCInputDeviceController(),
    audioLifecycle: MacGridWebRTCAudioLifecycleController =
      MacGridWebRTCAudioLifecycleController(),
    catalog: MacGridAudioDeviceCatalog = MacGridAudioDeviceCatalog()
  ) {
    self.inputDevices = inputDevices
    self.audioLifecycle = audioLifecycle
    self.catalog = catalog
    outputSettler = MacGridAudioOutputRouteSettler(catalog: catalog)
    // Select the process-wide ADM synchronously while the session graph is
    // being constructed. Grid demand is delivered through a nonisolated
    // mailbox, so waiting until async configure() lets Room initialize the
    // peer-connection factory first.
    do {
      try AudioManager.set(audioDeviceModuleType: .audioEngine)
      audioDeviceModuleBootstrapError = nil
    } catch {
      audioDeviceModuleBootstrapError = error.localizedDescription
    }
    let stream = AsyncStream.makeStream(
      of: GridAudioDriverEvent.self,
      bufferingPolicy: .bufferingNewest(16)
    )
    events = stream.stream
    eventContinuation = stream.continuation
  }

  deinit {
    catalogTask?.cancel()
    catalog.stop()
    eventContinuation.finish()
  }

  func configure(_ configuration: InlineRTCConfiguration) async throws {
    guard !configured else { return }
    guard !configuration.voiceProcessing.platformVoiceProcessingAllowed else {
      throw LiveKitPlatformAudioDriverError.platformVoiceProcessingUnsupported
    }
    if let audioDeviceModuleBootstrapError {
      throw LiveKitPlatformAudioDriverError.audioDeviceModuleBootstrapFailed(
        underlying: audioDeviceModuleBootstrapError
      )
    }
    log.debug("GRID_ENGINE phase=livekit_audio_configure_started backend=audio_engine_aggregate")

    // The process-wide module type was selected synchronously in init. Apply
    // and verify the no-VPIO policy before the first recording or playout
    // transaction can construct an AVAudioEngine graph.
    AudioManager.prepare()
    try configuration.applyVoiceProcessing()
    let initialProcessing = MacGridLiveKitAudioProcessingPolicy.snapshot()
    guard !initialProcessing.platformVoiceProcessingAllowed,
          !initialProcessing.platformVoiceProcessingActive
    else {
      throw LiveKitPlatformAudioDriverError.platformVoiceProcessingPolicyNotEnforced
    }
    audioProcessingOptions = configuration.makeAudioProcessingOptions()

    let initial = try await catalog.snapshot()
    guard let initialInput = initial.defaultInput,
          MacGridAudioRouteTransitionPolicy.inputIsUsable(initialInput)
    else {
      throw MacGridCoreAudioError.unavailable(
        "No default microphone with a readable live format is available."
      )
    }
    guard MacGridAudioRouteTransitionPolicy.outputIsUsable(in: initial) else {
      throw MacGridCoreAudioError.unavailable(
        "No default output device with a readable live format is available."
      )
    }
    latestCatalog = initial

    let eventContinuation = eventContinuation
    deviceUpdateObserver = AudioManager.shared.observeDeviceUpdates { _ in
      eventContinuation.yield(.devicesChanged)
    }
    catalog.start()
    catalogTask = Task { [weak self, updates = catalog.updates] in
      for await snapshot in updates {
        guard !Task.isCancelled else { return }
        await self?.catalogChanged(snapshot)
      }
    }
    configured = true
    let configurationFields = [
      "backend=audio_engine_aggregate",
      "inputs=\(initial.inputs.count)",
      "outputs=\(initial.outputs.count)",
      "software_aec=\(configuration.capture.echoCancellation)",
      "software_ns=\(configuration.capture.noiseSuppression)",
    ].joined(separator: " ")
    log.info("GRID_ENGINE phase=livekit_audio_configured \(configurationFields)")
  }

  func setPrepared(_ value: Bool) async throws {
    guard configured else {
      throw LiveKitPlatformAudioDriverError.notConfigured
    }
    if value {
      guard !captureState.isPrepared else { return }
      guard captureState.appliedInputTarget != nil else {
        throw LiveKitPlatformAudioDriverError.inputRouteNotApplied
      }
      try await setRecordingPrepared(true)
    } else {
      guard captureState.isPrepared || audioLifecycle.isRecording else { return }
      try await setRecordingPrepared(false)
    }
  }

  func stopForShutdown() async -> GridAudioDriverShutdownReceipt {
    var failures: [String] = []
    do {
      try audioLifecycle.stopPlayout()
    } catch {
      failures.append("playout: \(String(describing: error))")
    }
    do {
      // Capture stop changes the shared VPIO-off HAL topology. Quiesce
      // playout first, but always attempt microphone release even when the
      // playout stop reported failure.
      try audioLifecycle.stopRecording()
    } catch {
      failures.append("recording: \(String(describing: error))")
    }
    if audioLifecycle.isRecording {
      captureState.recordingStarted()
    } else {
      captureState.recordingStopped()
    }
    return GridAudioDriverShutdownReceipt(
      recordingStopped: !audioLifecycle.isRecording,
      playoutStopped: !audioLifecycle.isPlaying,
      failures: failures
    )
  }

  func recoverPreparedAudio(preserving target: AudioInputRouteTarget?) async throws {
    guard configured else {
      throw LiveKitPlatformAudioDriverError.notConfigured
    }
    try await switchInputRoute(
      captureState.recoveryTarget(preserving: target),
      restartRecording: true,
      forcePlayoutTransition: audioLifecycle.isPlaying
    )
  }

  func recoverPlayout() async throws {
    let wasPlaying = try audioLifecycle.beginPlayoutTransition()
    do {
      let expectedOutputUID = try await settleOutput()
      if wasPlaying {
        try audioLifecycle.finishPlayoutTransition(wasPlaying: true)
      } else {
        try audioLifecycle.ensurePlayoutStarted()
      }
      try await waitForDeviceReadback(
        expectedUID: expectedOutputUID,
        direction: .output
      )
    } catch let recoveryError {
      let rollbackFailures = await restorePlayoutAfterFailedTransition(
        wasPlaying: wasPlaying,
        phase: "audio_engine_directional_playout_rollback_failed"
      )
      if !rollbackFailures.isEmpty {
        throw LiveKitPlatformAudioDriverError.routeTransitionFailed(
          primary: String(describing: recoveryError),
          rollbackFailures: rollbackFailures
        )
      }
      throw recoveryError
    }
  }

  func isAudioEngineRunning() async -> Bool {
    audioLifecycle.isRecording || audioLifecycle.isPlaying
  }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    let recording = audioLifecycle.isRecording
    let playing = audioLifecycle.isPlaying
    let manager = AudioManager.shared
    let processing = MacGridLiveKitAudioProcessingPolicy.snapshot(manager: manager)
    let ioDiagnostics = manager.audioEngineRuntimeDiagnostics
    guard let snapshot = try? await catalog.snapshot() else {
      return GridAudioRuntimeHealth(
        isEngineRunning: recording || playing,
        isRecording: recording,
        isPlaying: playing,
        route: InlineRTCAudioRoute(
          currentInputID: nil,
          defaultInputID: nil,
          currentOutputID: nil,
          defaultOutputID: nil,
          inputDeviceCount: 0,
          outputDeviceCount: 0,
          isInputRouteValid: false,
          isOutputRouteValid: false
        ),
        processing: processing
      )
    }
    latestCatalog = snapshot
    let processRoute = try? await catalog.processRouteSnapshot()
    let inputUIDs = MacGridADMDeviceReadbackMonitor.stableUIDs(
      forCoreAudioDeviceIDs: processRoute?.inputDeviceIDs ?? [],
      direction: .input,
      snapshot: snapshot
    )
    let outputUIDs = MacGridADMDeviceReadbackMonitor.stableUIDs(
      forCoreAudioDeviceIDs: processRoute?.outputDeviceIDs ?? [],
      direction: .output,
      snapshot: snapshot
    )
    let expectedInputID = captureState.appliedInputDeviceUID
    let selectedInputID = expectedInputID.flatMap { inputUIDs.contains($0) ? $0 : nil }
      ?? inputUIDs.first
    let expectedOutputID = snapshot.defaultOutput?.uid
    let outputID = expectedOutputID.flatMap { outputUIDs.contains($0) ? $0 : nil }
      ?? outputUIDs.first
    let expectedOutputSampleRate = snapshot.defaultOutputRouteSignature?.sampleRate
    let expectedInputSampleRate = expectedInputID
      .flatMap { expectedUID in snapshot.inputs.first { $0.uid == expectedUID } }
      .map { $0.inputStreamFormat?.sampleRate ?? $0.sampleRate }
    // When both directions are enabled with distinct endpoints, the private
    // aggregate is clocked by the physical output. Its capture graph therefore
    // runs at the output rate while Core Audio drift-compensates the input.
    let expectedRecordingSampleRate = MacGridAudioGraphFormatHealth.expectedRecordingSampleRate(
      inputSampleRate: expectedInputSampleRate,
      outputSampleRate: expectedOutputSampleRate,
      isPlaying: playing
    )
    let inputGraphFormatMatches = MacGridAudioGraphFormatHealth.matches(
      configuredSampleRate: ioDiagnostics.configuredRecordingSampleRate,
      configuredChannels: ioDiagnostics.configuredRecordingChannels,
      expectedSampleRate: expectedRecordingSampleRate,
      isActive: recording
    )
    let outputGraphFormatMatches = MacGridAudioGraphFormatHealth.matches(
      configuredSampleRate: ioDiagnostics.configuredPlayoutSampleRate,
      configuredChannels: ioDiagnostics.configuredPlayoutChannels,
      expectedSampleRate: expectedOutputSampleRate,
      isActive: playing
    )
    let inputMatches = if recording {
      processRoute?.isRunningInput == true
        && expectedInputID.map(inputUIDs.contains) == true
        && inputGraphFormatMatches
        && MacGridAudioCallbackHealth.isFresh(
          seen: ioDiagnostics.recordingCallbackSeen,
          ageMilliseconds: ioDiagnostics.recordingCallbackAgeMilliseconds
        )
    } else {
      !captureState.isPrepared
    }
    let outputMatches = if playing {
      processRoute?.isRunningOutput == true
        && expectedOutputID.map(outputUIDs.contains) == true
        && outputGraphFormatMatches
        && MacGridAudioCallbackHealth.isFresh(
          seen: ioDiagnostics.playoutCallbackSeen,
          ageMilliseconds: ioDiagnostics.playoutCallbackAgeMilliseconds
        )
    } else {
      true
    }
    let outputFormatMatches = MacGridAudioRouteTransitionPolicy.outputIsUsable(in: snapshot)
    if recording, !inputGraphFormatMatches {
      log.warning(
        "GRID_ENGINE phase=audio_engine_graph_format_mismatch direction=input configured_rate=\(ioDiagnostics.configuredRecordingSampleRate) expected_rate=\(expectedRecordingSampleRate ?? 0) configured_channels=\(ioDiagnostics.configuredRecordingChannels)"
      )
    }
    if playing, !outputGraphFormatMatches {
      log.warning(
        "GRID_ENGINE phase=audio_engine_graph_format_mismatch direction=output configured_rate=\(ioDiagnostics.configuredPlayoutSampleRate) expected_rate=\(expectedOutputSampleRate ?? 0) configured_channels=\(ioDiagnostics.configuredPlayoutChannels)"
      )
    }

    return GridAudioRuntimeHealth(
      isEngineRunning: recording || playing,
      isRecording: recording,
      isPlaying: playing,
      route: InlineRTCAudioRoute(
        currentInputID: selectedInputID,
        defaultInputID: snapshot.defaultInput?.uid,
        currentOutputID: outputID,
        defaultOutputID: snapshot.defaultOutput?.uid,
        inputDeviceCount: snapshot.inputs.count,
        outputDeviceCount: snapshot.outputs.count,
        isInputRouteValid: inputMatches,
        isOutputRouteValid: outputMatches && (!playing || outputFormatMatches),
        routeEpoch: snapshot.epoch,
        inputCallbackCount: ioDiagnostics.recordingCallbackCount,
        outputCallbackCount: ioDiagnostics.playoutCallbackCount,
        inputCallbackAgeMilliseconds: ioDiagnostics.recordingCallbackSeen
          ? ioDiagnostics.recordingCallbackAgeMilliseconds
          : nil,
        outputCallbackAgeMilliseconds: ioDiagnostics.playoutCallbackSeen
          ? ioDiagnostics.playoutCallbackAgeMilliseconds
          : nil,
        measuredInputDelayMilliseconds: ioDiagnostics.measuredRecordingDelayMilliseconds,
        measuredOutputDelayMilliseconds: ioDiagnostics.measuredPlayoutDelayMilliseconds
      ),
      processing: processing
    )
  }

  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio _: Bool
  ) async throws -> GridAudioInputRouteApplication {
    try await switchInputRoute(
      target,
      restartRecording: true
    )
    let health = await runtimeHealth()
    guard health.route?.isInputRouteValid == true else {
      throw LiveKitPlatformAudioDriverError.inputRouteReadbackMismatch
    }
    return .committed
  }

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    let snapshot: MacGridAudioCatalogSnapshot
    if let current = try? await catalog.snapshot() {
      latestCatalog = current
      snapshot = current
    } else if let latestCatalog {
      // Inventory is presentation and route-policy input rather than physical
      // health proof. Retain the last complete catalog across a transient
      // enumeration race; runtimeHealth() independently fails closed when its
      // current readback cannot be obtained.
      snapshot = latestCatalog
    } else {
      return AudioInputDeviceInventory(
        automaticDeviceID: nil,
        automaticDeviceName: "System Default",
        devices: [],
        routeEpoch: 0
      )
    }
    return AudioInputDeviceInventory(
      automaticDeviceID: snapshot.defaultInput?.uid,
      automaticDeviceName: snapshot.defaultInput?.name ?? "System Default",
      devices: snapshot.inputs.map { device in
        AudioInputDeviceDescriptor(
          id: device.uid,
          name: device.name,
          isSystemDefault: device.id == snapshot.defaultInputID,
          systemImage: Self.systemImage(for: device)
        )
      },
      routeEpoch: snapshot.epoch
    )
  }
}

extension LiveKitGridAudioDriver {
  private func catalogChanged(_ snapshot: MacGridAudioCatalogSnapshot) async {
    guard snapshot != latestCatalog else { return }
    latestCatalog = snapshot
    eventContinuation.yield(.devicesChanged)
  }

  // Keep native commit and rollback branches co-located so the ownership
  // transaction remains auditable as one state machine.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func switchInputRoute(
    _ target: AudioInputRouteTarget,
    restartRecording: Bool,
    forcePlayoutTransition: Bool = false
  ) async throws {
    let snapshot = try await catalog.snapshot()
    latestCatalog = snapshot
    let previousTarget = captureState.appliedInputTarget
    let previousInputUID = captureState.appliedInputDeviceUID
    let nextInput = try MacGridPlatformAudioDeviceResolver.inputDevice(
      for: target,
      in: snapshot
    )
    var coordinatePlayout = restartRecording && (
      forcePlayoutTransition
        || MacGridAudioRouteTransitionPolicy.requiresCoordinatedPlayout(
          previousInputUID: previousInputUID,
          nextInputUID: nextInput.uid,
          in: snapshot
        )
    )
    var wasPlaying = coordinatePlayout
      ? try audioLifecycle.beginPlayoutTransition()
      : false

    do {
      if restartRecording {
        try stopRecording()
      }
      let selectedInput = try await selectInput(target)
      if restartRecording,
         !coordinatePlayout,
         let selectedCatalog = latestCatalog,
         MacGridAudioRouteTransitionPolicy.requiresCoordinatedPlayout(
           previousInputUID: previousInputUID,
           nextInputUID: selectedInput.uid,
           in: selectedCatalog
         ) {
        coordinatePlayout = true
        wasPlaying = try audioLifecycle.beginPlayoutTransition()
      }
      captureState.inputSelected(target, deviceUID: selectedInput.uid)
      if restartRecording {
        try await startRecordingVerified(inputUID: selectedInput.uid)
      }
      if coordinatePlayout {
        let expectedOutputUID = try await settleOutput()
        try audioLifecycle.finishPlayoutTransition(wasPlaying: wasPlaying)
        if audioLifecycle.isPlaying {
          try await waitForDeviceReadback(
            expectedUID: expectedOutputUID,
            direction: .output
          )
        }
      }
    } catch let switchError {
      let inventoryError = switchError as? MacGridWebRTCInputDeviceError
      var rollbackFailures: [String] = []
      var rollbackInputUID = captureState.appliedInputDeviceUID
      var routeReadyForRecording = captureState.appliedInputTarget != nil
      var recordingRestored = !restartRecording
      if let inventoryError {
        // No setter ran when the requested device was absent from WebRTC's
        // inventory, so the previously selected native route is still the
        // safest rollback. Preserve its durable metadata while Core Audio and
        // the ADM converge instead of cascading into "route not applied".
        let route = inventoryError.requestedID
          == MacGridPlatformAudioDeviceResolver.defaultDeviceID
          ? "automatic"
          : "explicit"
        let inventoryFields = [
          "route=\(route)",
          "available_count=\(inventoryError.availableIDs.count)",
          "attempts=\(inventoryError.attempts)",
          "preserving_route=\(captureState.appliedInputTarget?.logDescription ?? "none")",
        ].joined(separator: " ")
        log.warning(
          "GRID_ENGINE phase=audio_engine_input_inventory_unsettled \(inventoryFields)"
        )
      } else if let previousTarget {
        // Output settlement can fail after the requested route restarted
        // capture. Re-enter the stopped-recording boundary before selecting
        // the previous device; native input selection must never be rolled back
        // underneath active recording.
        if restartRecording, audioLifecycle.isRecording {
          do {
            try stopRecording()
          } catch let rollbackError {
            rollbackFailures.append(
              "stop recording before input rollback: \(String(describing: rollbackError))"
            )
            log.error(
              "GRID_ENGINE phase=audio_engine_input_rollback_stop_failed",
              error: rollbackError
            )
          }
        }
        if !audioLifecycle.isRecording {
          do {
            let rollbackInput = try await selectInput(previousTarget)
            rollbackInputUID = rollbackInput.uid
            captureState.inputSelected(previousTarget, deviceUID: rollbackInput.uid)
            routeReadyForRecording = true
          } catch let rollbackError {
            // Readback failure leaves the native selector unknown. Projecting
            // the old route as applied could restart capture on the wrong mic.
            captureState.inputSelectionLost()
            rollbackInputUID = nil
            routeReadyForRecording = false
            rollbackFailures.append(
              "restore previous input: \(String(describing: rollbackError))"
            )
            log.error(
              "GRID_ENGINE phase=audio_engine_input_rollback_failed",
              error: rollbackError
            )
          }
        } else {
          routeReadyForRecording = false
          rollbackFailures.append(
            "restore previous input: recording did not stop before rollback"
          )
        }
      } else if captureState.appliedInputTarget == nil {
        captureState.inputSelectionLost()
      } else {
        // A first applied route has no previous selector to restore. Keep its
        // verified identity for explicit retry, but stop capture so a partial
        // transaction cannot be mistaken for a committed route.
        if restartRecording, audioLifecycle.isRecording {
          do {
            try stopRecording()
          } catch let rollbackError {
            rollbackFailures.append(
              "stop recording after first-route failure: \(String(describing: rollbackError))"
            )
          }
        }
        routeReadyForRecording = false
      }
      if restartRecording {
        if routeReadyForRecording {
          do {
            guard let rollbackInputUID else {
              throw LiveKitPlatformAudioDriverError.inputRouteNotApplied
            }
            try await startRecordingVerified(inputUID: rollbackInputUID)
            recordingRestored = true
          } catch let rollbackError {
            captureState.recordingStopped()
            rollbackFailures.append(
              "restart recording after input rollback: \(String(describing: rollbackError))"
            )
            log.error(
              "GRID_ENGINE phase=audio_engine_recording_rollback_failed",
              error: rollbackError
            )
          }
        } else {
          captureState.recordingStopped()
        }
      }
      if coordinatePlayout {
        rollbackFailures += await restorePlayoutAfterFailedTransition(
          wasPlaying: wasPlaying,
          phase: "audio_engine_playout_rollback_failed"
        )
      }
      if rollbackFailures.isEmpty,
         captureState.canCommitUnchangedAutomaticRoute(
        requesting: target,
        selectionWasAttempted: inventoryError == nil,
        recordingRestored: recordingRestored
      ) {
        // Index zero is WebRTC's durable system-default policy. If its
        // temporary inventory gap did not run a setter and the existing route
        // restarted successfully, the requested Auto transaction is already
        // satisfied; surfacing a failure would only quarantine a healthy mic.
        log.info(
          "GRID_ENGINE phase=audio_engine_input_inventory_recovered route=automatic"
        )
        return
      }
      if !rollbackFailures.isEmpty {
        throw LiveKitPlatformAudioDriverError.routeTransitionFailed(
          primary: String(describing: switchError),
          rollbackFailures: rollbackFailures
        )
      }
      throw switchError
    }
  }

  private func selectInput(_ target: AudioInputRouteTarget) async throws -> MacGridAudioDevice {
    // Auto is an active route transaction too: after the RTC transport has
    // initialized the ADM, resolve it to WebRTC's enumerated `default` device
    // and use the same setter as explicit routes. This restores index zero
    // both on first preparation and after an explicit-device override.
    let selection = try await inputDevices.select(target) { [catalog] in
      try await catalog.snapshot()
    }
    latestCatalog = selection.catalog
    let inputFields = [
      "route=\(target.logDescription)",
      "sample_rate=\(selection.physicalDevice.inputStreamFormat?.sampleRate ?? selection.physicalDevice.sampleRate)",
      "channels=\(selection.physicalDevice.inputStreamFormat?.channelCount ?? 0)",
      "buffer_frames=\(selection.physicalDevice.bufferFrameSize)",
      "bluetooth=\(selection.physicalDevice.isBluetooth)",
    ].joined(separator: " ")
    log.info(
      "GRID_ENGINE phase=audio_engine_input_selector_applied \(inputFields)"
    )
    return selection.physicalDevice
  }

  private func startRecording() throws {
    do {
      try audioLifecycle.startRecording(
        audioProcessingOptions: audioProcessingOptions
      )
    } catch {
      throw LiveKitPlatformAudioDriverError.recordingStartFailed(
        underlying: String(describing: error)
      )
    }
    captureState.recordingStarted()
  }

  private func startRecordingVerified(inputUID: String) async throws {
    try startRecording()
    do {
      try await waitForDeviceReadback(
        expectedUID: inputUID,
        direction: .input
      )
    } catch let readbackError {
      do {
        try stopRecording()
      } catch let rollbackError {
        throw LiveKitPlatformAudioDriverError.routeTransitionFailed(
          primary: String(describing: readbackError),
          rollbackFailures: [
            "stop recording after unverified readback: \(String(describing: rollbackError))",
          ]
        )
      }
      throw readbackError
    }
  }

  private func stopRecording() throws {
    do {
      try audioLifecycle.stopRecording()
    } catch {
      if audioLifecycle.isRecording {
        captureState.recordingStarted()
      } else {
        captureState.recordingStopped()
      }
      throw error
    }
    captureState.recordingStopped()
  }

  private func setRecordingPrepared(_ prepared: Bool) async throws {
    guard let inputUID = captureState.appliedInputDeviceUID,
          latestCatalog != nil
    else {
      throw LiveKitPlatformAudioDriverError.inputRouteNotApplied
    }
    // Capture enable/disable changes the shared HAL unit between a physical
    // output and a split aggregate. Quiesce playout for every such topology
    // change; transport type does not alter that ownership rule.
    let wasRecording = audioLifecycle.isRecording
    let coordinatePlayout = audioLifecycle.isPlaying
    let wasPlaying = coordinatePlayout
      ? try audioLifecycle.beginPlayoutTransition()
      : false

    do {
      if prepared {
        try await startRecordingVerified(inputUID: inputUID)
      } else {
        try stopRecording()
      }
      if coordinatePlayout {
        let expectedOutputUID = try await settleOutput()
        try audioLifecycle.finishPlayoutTransition(wasPlaying: wasPlaying)
        if audioLifecycle.isPlaying {
          try await waitForDeviceReadback(
            expectedUID: expectedOutputUID,
            direction: .output
          )
        }
      }
    } catch let transitionError {
      var rollbackFailures: [String] = []
      var rollbackWasPlaying = wasPlaying
      var recordingCanBeRestored = true

      // A failed output settle/readback can occur after playout has already
      // restarted. Stop it again before reversing the capture topology: the
      // VPIO-off AudioEngine path owns one shared HAL unit and cannot safely
      // change physical<->aggregate mode under active playout.
      if audioLifecycle.isRecording != wasRecording,
         audioLifecycle.isPlaying {
        do {
          rollbackWasPlaying = try audioLifecycle.beginPlayoutTransition()
            || rollbackWasPlaying
        } catch {
          recordingCanBeRestored = false
          rollbackFailures.append(
            "stop playout before recording rollback: \(String(describing: error))"
          )
        }
      }

      if audioLifecycle.isRecording != wasRecording,
         recordingCanBeRestored {
        do {
          if wasRecording {
            try await startRecordingVerified(inputUID: inputUID)
          } else {
            try stopRecording()
          }
        } catch {
          rollbackFailures.append(
            "restore recording after prepared transition: \(String(describing: error))"
          )
        }
      }

      if coordinatePlayout || rollbackWasPlaying || audioLifecycle.isPlaying {
        rollbackFailures += await restorePlayoutAfterFailedTransition(
          wasPlaying: rollbackWasPlaying,
          phase: "audio_engine_playout_resume_failed"
        )
      }
      if !rollbackFailures.isEmpty {
        throw LiveKitPlatformAudioDriverError.routeTransitionFailed(
          primary: String(describing: transitionError),
          rollbackFailures: rollbackFailures
        )
      }
      throw transitionError
    }
  }

  private func restorePlayoutAfterFailedTransition(
    wasPlaying: Bool,
    phase: String
  ) async -> [String] {
    var failures: [String] = []
    var expectedOutputUID: String?
    do {
      expectedOutputUID = try await settleOutput()
    } catch {
      failures.append("settle output during rollback: \(String(describing: error))")
      log.warning(
        "GRID_ENGINE phase=\(phase) step=output_settle_skipped cancelled=\(error is CancellationError)"
      )
    }
    do {
      try audioLifecycle.finishPlayoutTransition(wasPlaying: wasPlaying)
      if audioLifecycle.isPlaying, let expectedOutputUID {
        try await waitForDeviceReadback(
          expectedUID: expectedOutputUID,
          direction: .output
        )
      }
    } catch {
      failures.append("restart playout during rollback: \(String(describing: error))")
      log.error(
        "GRID_ENGINE phase=\(phase) step=playout_restart",
        error: error
      )
    }
    return failures
  }

  private func settleOutput() async throws -> String {
    let result = try await outputSettler.waitForCompatibleOutput()
    latestCatalog = result.snapshot
    let output = result.snapshot.defaultOutputRouteSignature
    let fields = [
      "output_present=\(output != nil)",
      "sample_rate=\(output?.sampleRate ?? 0)",
      "channels=\(output?.channelCount ?? 0)",
      "buffer_frames=\(output?.bufferFrameSize ?? 0)",
      "bluetooth=\(result.snapshot.defaultOutput?.isBluetooth ?? false)",
    ].joined(separator: " ")
    if result.timedOut {
      log.warning(
        "GRID_ENGINE phase=audio_engine_output_settle_timeout \(fields)"
      )
    }
    let settledSnapshot = try result.requireCompatibleOutput()
    guard let expectedOutputUID = settledSnapshot.defaultOutput?.uid else {
      throw MacGridCoreAudioError.unavailable("No default output device is available after route settlement.")
    }
    log.info(
      "GRID_ENGINE phase=audio_engine_output_format_settled \(fields)"
    )
    return expectedOutputUID
  }

  private func waitForDeviceReadback(
    expectedUID: String,
    direction: MacGridADMDeviceDirection
  ) async throws {
    for attempt in 1 ... 36 {
      try Task.checkCancellation()
      let snapshot = try await catalog.snapshot()
      latestCatalog = snapshot
      let processRoute = try await catalog.processRouteSnapshot()
      let recording = audioLifecycle.isRecording
      let playing = audioLifecycle.isPlaying
      let expectedInputUID = direction == .input
        ? expectedUID
        : captureState.appliedInputDeviceUID
      let expectedOutputUID = direction == .output
        ? expectedUID
        : snapshot.defaultOutput?.uid
      let inputUIDs = MacGridADMDeviceReadbackMonitor.stableUIDs(
        forCoreAudioDeviceIDs: processRoute.inputDeviceIDs,
        direction: .input,
        snapshot: snapshot
      )
      let outputUIDs = MacGridADMDeviceReadbackMonitor.stableUIDs(
        forCoreAudioDeviceIDs: processRoute.outputDeviceIDs,
        direction: .output,
        snapshot: snapshot
      )
      let diagnostics = AudioManager.shared.audioEngineRuntimeDiagnostics
      let inputRouteMatches = !recording
        || (
          processRoute.isRunningInput
            && expectedInputUID.map(inputUIDs.contains) == true
        )
      let outputRouteMatches = !playing
        || (
          processRoute.isRunningOutput
            && expectedOutputUID.map(outputUIDs.contains) == true
        )
      let inputCallbackFresh = !recording || MacGridAudioCallbackHealth.isFresh(
        seen: diagnostics.recordingCallbackSeen,
        ageMilliseconds: diagnostics.recordingCallbackAgeMilliseconds
      )
      let outputCallbackFresh = !playing || MacGridAudioCallbackHealth.isFresh(
        seen: diagnostics.playoutCallbackSeen,
        ageMilliseconds: diagnostics.playoutCallbackAgeMilliseconds
      )
      let expectedInputSampleRate = expectedInputUID
        .flatMap { uid in snapshot.inputs.first { $0.uid == uid } }
        .map { $0.inputStreamFormat?.sampleRate ?? $0.sampleRate }
      let expectedOutputSampleRate = expectedOutputUID
        .flatMap { uid in snapshot.outputs.first { $0.uid == uid } }
        .map { $0.outputStreamFormat?.sampleRate ?? $0.sampleRate }
      let expectedRecordingSampleRate = MacGridAudioGraphFormatHealth.expectedRecordingSampleRate(
        inputSampleRate: expectedInputSampleRate,
        outputSampleRate: expectedOutputSampleRate,
        isPlaying: playing
      )
      let inputGraphMatches = MacGridAudioGraphFormatHealth.matches(
        configuredSampleRate: diagnostics.configuredRecordingSampleRate,
        configuredChannels: diagnostics.configuredRecordingChannels,
        expectedSampleRate: expectedRecordingSampleRate,
        isActive: recording
      )
      let outputGraphMatches = MacGridAudioGraphFormatHealth.matches(
        configuredSampleRate: diagnostics.configuredPlayoutSampleRate,
        configuredChannels: diagnostics.configuredPlayoutChannels,
        expectedSampleRate: expectedOutputSampleRate,
        isActive: playing
      )
      if inputRouteMatches,
         outputRouteMatches,
         inputCallbackFresh,
         outputCallbackFresh,
         inputGraphMatches,
         outputGraphMatches {
        let readbackFields = [
          "direction=\(direction.rawValue)",
          "matched=true",
          "input_devices=\(processRoute.inputDeviceIDs.count)",
          "output_devices=\(processRoute.outputDeviceIDs.count)",
          "recording_callback_age_ms=\(diagnostics.recordingCallbackAgeMilliseconds)",
          "playout_callback_age_ms=\(diagnostics.playoutCallbackAgeMilliseconds)",
        ].joined(separator: " ")
        log.info(
          "GRID_ENGINE phase=audio_engine_physical_route_verified \(readbackFields)"
        )
        return
      }
      guard attempt < 36 else {
        if recording, !inputRouteMatches {
          throw LiveKitPlatformAudioDriverError.routeReadbackDidNotConverge(
            direction: MacGridADMDeviceDirection.input.rawValue,
            expectedUID: expectedInputUID ?? "",
            observedUID: inputUIDs.count == 1 ? inputUIDs[0] : nil
          )
        }
        if playing, !outputRouteMatches {
          throw LiveKitPlatformAudioDriverError.routeReadbackDidNotConverge(
            direction: MacGridADMDeviceDirection.output.rawValue,
            expectedUID: expectedOutputUID ?? "",
            observedUID: outputUIDs.count == 1 ? outputUIDs[0] : nil
          )
        }
        if recording, !inputCallbackFresh {
          throw LiveKitPlatformAudioDriverError.callbackReadbackDidNotConverge(
            direction: MacGridADMDeviceDirection.input.rawValue,
            callbackSeen: diagnostics.recordingCallbackSeen,
            callbackAgeMilliseconds: diagnostics.recordingCallbackAgeMilliseconds
          )
        }
        if playing, !outputCallbackFresh {
          throw LiveKitPlatformAudioDriverError.callbackReadbackDidNotConverge(
            direction: MacGridADMDeviceDirection.output.rawValue,
            callbackSeen: diagnostics.playoutCallbackSeen,
            callbackAgeMilliseconds: diagnostics.playoutCallbackAgeMilliseconds
          )
        }
        if recording, !inputGraphMatches {
          throw LiveKitPlatformAudioDriverError.graphFormatReadbackDidNotConverge(
            direction: MacGridADMDeviceDirection.input.rawValue,
            configuredSampleRate: diagnostics.configuredRecordingSampleRate,
            expectedSampleRate: expectedRecordingSampleRate,
            configuredChannels: diagnostics.configuredRecordingChannels
          )
        }
        throw LiveKitPlatformAudioDriverError.graphFormatReadbackDidNotConverge(
          direction: MacGridADMDeviceDirection.output.rawValue,
          configuredSampleRate: diagnostics.configuredPlayoutSampleRate,
          expectedSampleRate: expectedOutputSampleRate,
          configuredChannels: diagnostics.configuredPlayoutChannels
        )
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private static func systemImage(for device: MacGridAudioDevice) -> String {
    let name = device.name.localizedLowercase
    if name.contains("airpods") { return "airpods" }
    if name.contains("iphone") { return "iphone" }
    if name.contains("bluetooth") || name.contains("headset") { return "headphones" }
    if name.contains("usb") { return "cable.connector" }
    if name.contains("built-in") || name.contains("macbook") { return "macbook" }
    return "mic.fill"
  }
}

private enum LiveKitPlatformAudioDriverError: LocalizedError, CustomStringConvertible {
  case notConfigured
  case audioDeviceModuleBootstrapFailed(underlying: String)
  case platformVoiceProcessingUnsupported
  case platformVoiceProcessingPolicyNotEnforced
  case inputRouteNotApplied
  case inputRouteReadbackMismatch
  case routeReadbackDidNotConverge(direction: String, expectedUID: String, observedUID: String?)
  case callbackReadbackDidNotConverge(
    direction: String,
    callbackSeen: Bool,
    callbackAgeMilliseconds: UInt64?
  )
  case graphFormatReadbackDidNotConverge(
    direction: String,
    configuredSampleRate: Double,
    expectedSampleRate: Double?,
    configuredChannels: UInt32
  )
  case routeTransitionFailed(primary: String, rollbackFailures: [String])
  case recordingStartFailed(underlying: String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "AudioEngine audio is not configured."
    case let .audioDeviceModuleBootstrapFailed(underlying):
      "WebRTC AudioEngine audio could not be selected before RTC initialization. \(underlying)"
    case .platformVoiceProcessingUnsupported:
      "Grid AudioEngine audio requires Apple Voice Processing I/O to remain disabled."
    case .platformVoiceProcessingPolicyNotEnforced:
      "WebRTC did not enforce Grid's process-wide no-VPIO policy before audio startup."
    case .inputRouteNotApplied:
      "A microphone route must be applied before capture starts."
    case .inputRouteReadbackMismatch:
      "WebRTC's observed microphone route did not match the requested Core Audio device."
    case let .routeReadbackDidNotConverge(direction, _, observedUID):
      "WebRTC's \(direction) physical route did not converge (observed_route=\(observedUID != nil))."
    case let .callbackReadbackDidNotConverge(direction, callbackSeen, callbackAgeMilliseconds):
      "WebRTC's \(direction) physical route was selected, but its realtime callback did not converge (seen=\(callbackSeen), age_ms=\(callbackAgeMilliseconds.map(String.init) ?? "none"))."
    case let .graphFormatReadbackDidNotConverge(
      direction,
      configuredSampleRate,
      expectedSampleRate,
      configuredChannels
    ):
      "WebRTC's \(direction) graph format did not converge (configured_rate=\(configuredSampleRate), expected_rate=\(expectedSampleRate.map { String($0) } ?? "none"), configured_channels=\(configuredChannels))."
    case let .routeTransitionFailed(primary, rollbackFailures):
      "The audio route transaction failed (\(primary)); rollback was incomplete: \(rollbackFailures.joined(separator: "; "))"
    case let .recordingStartFailed(underlying):
      "WebRTC could not start AudioEngine microphone capture. \(underlying)"
    }
  }

  var description: String {
    errorDescription ?? "Grid AudioEngine audio failed."
  }
}
#else
/// The mobile driver deliberately leaves physical route policy to the system.
/// InlineRTC owns lifecycle and health while LiveKit's stock AudioEngine ADM
/// owns AVAudioSession and the currently active input/output route.
actor LiveKitGridAudioDriver: GridAudioDriver {
  nonisolated let events: AsyncStream<GridAudioDriverEvent>

  private nonisolated let eventContinuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private nonisolated let expectedEngineTransition = ManagedAtomic<Bool>(false)
  private var engineObserver: GridLiveKitAudioEngineObserver?
  private var configured = false
  private var prepared = false
  private let log = Log.scoped("LiveKitGridAudioDriver")

  init() {
    let stream = AsyncStream.makeStream(
      of: GridAudioDriverEvent.self,
      bufferingPolicy: .bufferingNewest(16)
    )
    events = stream.stream
    eventContinuation = stream.continuation
  }

  deinit {
    eventContinuation.finish()
  }

  func configure(_ configuration: InlineRTCConfiguration) async throws {
    guard !configured else { return }
    log.debug("GRID_ENGINE phase=livekit_audio_configure_started backend=av_audio_engine")
    try AudioManager.set(audioDeviceModuleType: .audioEngine)
    AudioManager.prepare()
    try configuration.applyVoiceProcessing()

    let engineObserver = GridLiveKitAudioEngineObserver(
      eventContinuation: eventContinuation,
      expectedEngineTransition: expectedEngineTransition
    )
    AudioManager.shared.set(engineObservers: [engineObserver, AudioManager.shared.mixer])
    self.engineObserver = engineObserver

    let eventContinuation = eventContinuation
    AudioManager.shared.onDeviceUpdate = { _ in
      eventContinuation.yield(.devicesChanged)
    }
    configured = true
    log.info("GRID_ENGINE phase=livekit_audio_configured backend=av_audio_engine")
  }

  func setPrepared(_ prepared: Bool) async throws {
    guard self.prepared != prepared else { return }
    log.debug("GRID_ENGINE phase=livekit_audio_prepared_set requested=\(prepared)")
    expectedEngineTransition.store(true, ordering: .releasing)
    defer { expectedEngineTransition.store(false, ordering: .releasing) }
    try await AudioManager.shared.setRecordingAlwaysPreparedMode(prepared)
    self.prepared = prepared
  }

  func recoverPreparedAudio(preserving _: AudioInputRouteTarget?) async throws {
    guard prepared else { return }
    expectedEngineTransition.store(true, ordering: .releasing)
    defer { expectedEngineTransition.store(false, ordering: .releasing) }
    try await AudioManager.shared.setRecordingAlwaysPreparedMode(false)
    try await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
  }

  func isAudioEngineRunning() async -> Bool {
    AudioManager.shared.isEngineRunning
  }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    let isRunning = AudioManager.shared.isEngineRunning
    return GridAudioRuntimeHealth(
      isEngineRunning: isRunning,
      isRecording: isRunning,
      isPlaying: isRunning,
      route: nil
    )
  }

  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio _: Bool
  ) async throws -> GridAudioInputRouteApplication {
    guard case .automatic = target else {
      throw LiveKitGridAudioDriverError.explicitInputRoutingUnsupported
    }
    return .committed
  }

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    AudioInputDeviceInventory(
      automaticDeviceID: nil,
      automaticDeviceName: "System Default",
      devices: [],
      routeEpoch: 0
    )
  }
}

private enum LiveKitGridAudioDriverError: LocalizedError {
  case explicitInputRoutingUnsupported

  var errorDescription: String? {
    "Explicit microphone selection is not supported on this platform."
  }
}
#endif

private final class GridLiveKitAudioEngineObserver: AudioEngineObserver, @unchecked Sendable {
  var next: (any AudioEngineObserver)?

  private let eventContinuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private let expectedEngineTransition: ManagedAtomic<Bool>

  init(
    eventContinuation: AsyncStream<GridAudioDriverEvent>.Continuation,
    expectedEngineTransition: ManagedAtomic<Bool>
  ) {
    self.eventContinuation = eventContinuation
    self.expectedEngineTransition = expectedEngineTransition
  }

  func engineWillStart(
    _ engine: AVAudioEngine,
    isPlayoutEnabled: Bool,
    isRecordingEnabled: Bool
  ) -> Int {
    eventContinuation.yield(
      .engineStarting(playout: isPlayoutEnabled, recording: isRecordingEnabled)
    )
    return next?.engineWillStart(
      engine,
      isPlayoutEnabled: isPlayoutEnabled,
      isRecordingEnabled: isRecordingEnabled
    ) ?? 0
  }

  func engineDidStop(
    _ engine: AVAudioEngine,
    isPlayoutEnabled: Bool,
    isRecordingEnabled: Bool
  ) -> Int {
    let event: GridAudioDriverEvent = expectedEngineTransition.load(ordering: .acquiring)
      ? .expectedEngineStop(playout: isPlayoutEnabled, recording: isRecordingEnabled)
      : .engineStopped(playout: isPlayoutEnabled, recording: isRecordingEnabled)
    eventContinuation.yield(event)
    return next?.engineDidStop(
      engine,
      isPlayoutEnabled: isPlayoutEnabled,
      isRecordingEnabled: isRecordingEnabled
    ) ?? 0
  }

  func engineDidDisable(
    _ engine: AVAudioEngine,
    isPlayoutEnabled: Bool,
    isRecordingEnabled: Bool
  ) -> Int {
    let event: GridAudioDriverEvent = expectedEngineTransition.load(ordering: .acquiring)
      ? .expectedEngineDisable(playout: isPlayoutEnabled, recording: isRecordingEnabled)
      : .engineDisabled(playout: isPlayoutEnabled, recording: isRecordingEnabled)
    eventContinuation.yield(event)
    return next?.engineDidDisable(
      engine,
      isPlayoutEnabled: isPlayoutEnabled,
      isRecordingEnabled: isRecordingEnabled
    ) ?? 0
  }
}
