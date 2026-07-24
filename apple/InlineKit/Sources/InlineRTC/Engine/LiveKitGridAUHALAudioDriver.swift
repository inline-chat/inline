import AVFoundation
import Atomics
import Foundation
import LiveKit
import Logger

#if os(macOS)
protocol MacGridCustomAudioDeviceInstalling: Sendable {
  func install(_ device: any CustomAudioDevice) throws
}

struct LiveKitMacGridCustomAudioDeviceInstaller: MacGridCustomAudioDeviceInstalling {
  func install(_ device: any CustomAudioDevice) throws {
    try AudioManager.set(customAudioDevice: device)
  }
}

actor LiveKitGridAUHALAudioDriver: GridAudioDriver {
  nonisolated let events: AsyncStream<GridAudioDriverEvent>
  nonisolated let preparationRequiresRTCTransport = true
  nonisolated let recordingStartsWithMicrophoneSender = true

  private nonisolated let eventContinuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private let audioDevice: MacGridAUHALAudioDevice
  private let catalog: MacGridAudioDeviceCatalog
  private let outputSettler: MacGridAudioOutputRouteSettler
  private var catalogTask: Task<Void, Never>?
  private var latestCatalog: MacGridAudioCatalogSnapshot?
  private var lastCatalogEventEpoch: UInt64?
  private var appliedInputTarget: AudioInputRouteTarget?
  private var appliedInputDeviceUID: String?
  private var configured = false
  private var terminalShutdownRequested = false
  private let bootstrapError: String?
  private let log = Log.scoped("LiveKitGridAudioDriver")

  init(
    audioDevice: MacGridAUHALAudioDevice = MacGridAUHALAudioDevice(),
    installer: any MacGridCustomAudioDeviceInstalling =
      LiveKitMacGridCustomAudioDeviceInstaller(),
    catalog: MacGridAudioDeviceCatalog = MacGridAudioDeviceCatalog()
  ) {
    self.audioDevice = audioDevice
    self.catalog = catalog
    outputSettler = MacGridAudioOutputRouteSettler(catalog: catalog)
    do {
      try installer.install(audioDevice)
      bootstrapError = nil
    } catch {
      bootstrapError = error.localizedDescription
    }
    let stream = AsyncStream.makeStream(
      of: GridAudioDriverEvent.self,
      bufferingPolicy: .bufferingNewest(16)
    )
    events = stream.stream
    eventContinuation = stream.continuation
    audioDevice.setNativeLifecycleHandler { event in
      switch event {
      case .recordingStarted:
        stream.continuation.yield(.engineStarting(playout: false, recording: true))
      case .recordingStopped:
        stream.continuation.yield(.engineStopped(playout: false, recording: true))
      case .playoutStarted:
        stream.continuation.yield(.engineStarting(playout: true, recording: false))
      case .playoutStopped:
        stream.continuation.yield(.engineStopped(playout: true, recording: false))
      }
    }
  }

  deinit {
    catalogTask?.cancel()
    catalog.stop()
    eventContinuation.finish()
  }

  func configure(_ configuration: InlineRTCConfiguration) async throws {
    guard !configured else { return }
    guard !configuration.voiceProcessing.platformVoiceProcessingAllowed else {
      throw LiveKitGridAUHALDriverError.platformVoiceProcessingUnsupported
    }
    if let bootstrapError {
      throw LiveKitGridAUHALDriverError.customDeviceInstallFailed(bootstrapError)
    }
    log.debug("GRID_ENGINE phase=livekit_audio_configure_started backend=custom_auhal")

    let initialSettle = try await outputSettler.waitForCompatibleOutput()
    let initial = try initialSettle.requireCompatibleOutput()
    guard let input = initial.defaultInput,
          MacGridAudioRouteTransitionPolicy.inputIsUsable(input)
    else {
      throw MacGridAUHALAudioDeviceError.inputRouteUnavailable
    }
    guard let output = initial.defaultOutput,
          MacGridAudioRouteTransitionPolicy.outputIsUsable(in: initial)
    else {
      throw MacGridAUHALAudioDeviceError.outputRouteUnavailable
    }
    try audioDevice.configureInitialRoutes(input: input, output: output)
    appliedInputTarget = .automatic
    appliedInputDeviceUID = input.uid
    latestCatalog = initial
    lastCatalogEventEpoch = initial.epoch

    // The custom device must be selected before this line. `prepare` creates
    // the official M144 peer-connection factory and initializes its ObjC ADM.
    AudioManager.prepare()

    configured = true
    terminalShutdownRequested = false
    catalog.start()
    catalogTask = Task { [weak self, updates = catalog.updates] in
      for await snapshot in updates {
        guard !Task.isCancelled else { return }
        await self?.catalogChanged(snapshot)
      }
    }
    log.info(
      "GRID_ENGINE phase=livekit_audio_configured backend=custom_auhal inputs=\(initial.inputs.count) outputs=\(initial.outputs.count) software_aec=\(configuration.capture.echoCancellation) software_ns=\(configuration.capture.noiseSuppression)"
    )
  }

  func setPrepared(_ prepared: Bool) async throws {
    guard configured else { throw LiveKitGridAUHALDriverError.notConfigured }
    if prepared {
      guard appliedInputTarget != nil,
            let expectedInputUID = appliedInputDeviceUID
      else {
        throw LiveKitGridAUHALDriverError.inputRouteNotApplied
      }
      terminalShutdownRequested = false
      audioDevice.resumeAfterTerminalShutdown()
      let snapshot = audioDevice.snapshot()
      guard snapshot.nativeRecordingDemanded, snapshot.isRecording else {
        throw LiveKitGridAUHALDriverError.recordingDidNotStart(
          Self.recordingReadbackDescription(snapshot)
        )
      }
      do {
        try await waitForInputRouteReadback(expectedUID: expectedInputUID)
      } catch {
        let failedSnapshot = audioDevice.snapshot()
        throw LiveKitGridAUHALDriverError.recordingDidNotStart(
          Self.recordingReadbackDescription(
            failedSnapshot,
            readbackFailure: error
          )
        )
      }
    } else {
      let snapshot = audioDevice.snapshot()
      guard !snapshot.nativeRecordingDemanded, !snapshot.isRecording else {
        throw LiveKitGridAUHALDriverError.recordingStopFailed(
          "WebRTC still owns microphone sender demand."
        )
      }
    }
  }

  func resumeAfterTerminalShutdown() async {
    guard terminalShutdownRequested else { return }
    terminalShutdownRequested = false
    audioDevice.resumeAfterTerminalShutdown()
    log.debug("GRID_ENGINE phase=custom_auhal_terminal_gate_rearmed")
  }

  func stopForShutdown() async -> GridAudioDriverShutdownReceipt {
    terminalShutdownRequested = true
    var failures: [String] = []
    let terminalReceipt = audioDevice.stopForTerminalShutdown()
    failures += terminalReceipt.failures
    return GridAudioDriverShutdownReceipt(
      recordingStopped: !terminalReceipt.snapshot.isRecording
        && !terminalReceipt.snapshot.nativeRecordingDemanded
        && !terminalReceipt.snapshot.isRecordingInitialized
        && terminalReceipt.snapshot.input == nil,
      playoutStopped: !terminalReceipt.snapshot.isPlaying
        && !terminalReceipt.snapshot.isPlayoutInitialized
        && terminalReceipt.snapshot.output == nil,
      failures: failures
    )
  }

  func recoverPreparedAudio(preserving target: AudioInputRouteTarget?) async throws {
    guard configured else { throw LiveKitGridAUHALDriverError.notConfigured }
    let target = target ?? appliedInputTarget ?? .automatic
    terminalShutdownRequested = false
    audioDevice.resumeAfterTerminalShutdown()
    let application = try await switchInputRoute(
      target,
      forceRebuild: true,
      ensureRecording: true
    )
    guard case .committed = application else {
      throw LiveKitGridAUHALDriverError.routeReadbackMismatch("input recovery target")
    }
    let health = await runtimeHealth()
    guard health.isAudioDeviceHealthy else {
      throw LiveKitGridAUHALDriverError.routeReadbackMismatch("input recovery")
    }
  }

  func recoverPlayout(preserving target: AudioOutputRouteTarget?) async throws {
    guard configured else { throw LiveKitGridAUHALDriverError.notConfigured }
    let target = target ?? .automatic
    let result = try await outputSettler.waitForCompatibleOutput(target: target)
    let snapshot = try result.requireCompatibleOutput()
    let output = try MacGridPlatformAudioDeviceResolver.outputDevice(
      for: target,
      in: snapshot
    )
    try audioDevice.applyOutputRoute(output, forceRebuild: true)
    if audioDevice.isPlaying {
      try await waitForOutputRouteReadback(expectedUID: output.uid)
    }
    log.info(
      "GRID_ENGINE phase=custom_auhal_output_recovery_reconciled target=\(target.logDescription) \(await outputReadbackDescription(expectedUID: output.uid))"
    )
  }

  func isAudioEngineRunning() async -> Bool {
    audioDevice.isRecording || audioDevice.isPlaying
  }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    let deviceSnapshot = audioDevice.snapshot()
    guard let catalogSnapshot = try? await catalog.snapshot() else {
      return GridAudioRuntimeHealth(
        isEngineRunning: deviceSnapshot.isRecording || deviceSnapshot.isPlaying,
        isRecording: deviceSnapshot.isRecording,
        isRecordingExpected: deviceSnapshot.nativeRecordingDemanded,
        isPlaying: deviceSnapshot.isPlaying,
        route: InlineRTCAudioRoute(
          currentInputID: deviceSnapshot.input?.device.uid,
          defaultInputID: nil,
          currentOutputID: deviceSnapshot.output?.device.uid,
          defaultOutputID: nil,
          inputDeviceCount: 0,
          outputDeviceCount: 0,
          isInputRouteValid: false,
          isOutputRouteValid: false
        ),
        processing: configured ? MacGridLiveKitAudioProcessingPolicy.snapshot() : nil
      )
    }
    latestCatalog = catalogSnapshot
    let expectedInputUID = appliedInputDeviceUID
      ?? deviceSnapshot.selectedInputUID
    let expectedOutputUID = deviceSnapshot.selectedOutputUID
    let currentInputUID = deviceSnapshot.input?.device.uid
      ?? deviceSnapshot.selectedInputUID
    let currentOutputUID = deviceSnapshot.output?.device.uid
      ?? deviceSnapshot.selectedOutputUID
    let activeInputSignature = deviceSnapshot.input?.device.inputRouteSignature
    let catalogInputSignature = catalogSnapshot.inputRouteSignature(forUID: expectedInputUID)
    let activeOutputSignature = deviceSnapshot.output?.device.outputRouteSignature
    let catalogOutputSignature = catalogSnapshot.outputRouteSignature(forUID: expectedOutputUID)
    let inputRouteValid: Bool
    if deviceSnapshot.isRecording {
      inputRouteValid = currentInputUID == expectedInputUID
        && activeInputSignature == catalogInputSignature
        && deviceSnapshot.input?.hasFreshCallbacks == true
        && deviceSnapshot.input?.hasContinuousPhysicalHostTime == true
        && deviceSnapshot.input?.hasVerifiedDeviceReadback == true
        && deviceSnapshot.bridge?.captureWorkerActive == true
        && deviceSnapshot.bridge?.captureHasDeliveredForCurrentActivation == true
        && deviceSnapshot.bridge?.lastCaptureDeliveryStatus == noErr
        && deviceSnapshot.bridge?.lastCaptureConversionStatus == noErr
        && deviceSnapshot.bridge?.lastCapturePacketizationStatus == noErr
    } else {
      inputRouteValid = MacGridAUHALIdleInputRouteHealthPolicy.isValid(
        MacGridAUHALIdleInputRouteHealthState(
          nativeRecordingDemanded: deviceSnapshot.nativeRecordingDemanded,
          isRecording: deviceSnapshot.isRecording,
          expectedUID: expectedInputUID,
          selectedUID: deviceSnapshot.selectedInputUID,
          activeUID: deviceSnapshot.input?.device.uid,
          activeSignature: activeInputSignature,
          activeDeviceReadbackVerified: deviceSnapshot.input?.hasVerifiedDeviceReadback,
          lastControlFailure: deviceSnapshot.lastControlFailure
        ),
        catalogInput: expectedInputUID.flatMap { expectedUID in
          catalogSnapshot.inputs.first { $0.uid == expectedUID }
        }
      )
    }

    let outputRouteValid: Bool
    if deviceSnapshot.isPlaying {
      outputRouteValid = currentOutputUID == expectedOutputUID
        && activeOutputSignature == catalogOutputSignature
        && deviceSnapshot.output?.hasFreshCallbacks == true
        && deviceSnapshot.output?.hasVerifiedDeviceReadback == true
        && deviceSnapshot.bridge?.playoutWorkerActive == true
        && deviceSnapshot.bridge?.playoutHasPulledForCurrentActivation == true
        && deviceSnapshot.bridge?.lastPlayoutPullStatus == noErr
        && (deviceSnapshot.bridge?.consecutivePlayoutMissingFrames
          ?? MacGridWebRTCAudioBridge.sustainedPlayoutUnderrunFrames)
          < MacGridWebRTCAudioBridge.sustainedPlayoutUnderrunFrames
    } else {
      outputRouteValid = currentOutputUID == expectedOutputUID
        && expectedOutputUID.flatMap { expectedUID in
          catalogSnapshot.outputs.first { $0.uid == expectedUID }
        }.map(MacGridAudioRouteTransitionPolicy.outputIsUsable) == true
    }

    return GridAudioRuntimeHealth(
      isEngineRunning: deviceSnapshot.isRecording || deviceSnapshot.isPlaying,
      isRecording: deviceSnapshot.isRecording,
      isRecordingExpected: deviceSnapshot.nativeRecordingDemanded,
      isPlaying: deviceSnapshot.isPlaying,
      route: InlineRTCAudioRoute(
        currentInputID: currentInputUID,
        defaultInputID: catalogSnapshot.defaultInput?.uid,
        currentOutputID: currentOutputUID,
        defaultOutputID: catalogSnapshot.defaultOutput?.uid,
        inputDeviceCount: catalogSnapshot.inputs.count,
        outputDeviceCount: catalogSnapshot.outputs.count,
        isInputRouteValid: inputRouteValid,
        isOutputRouteValid: outputRouteValid,
        routeEpoch: catalogSnapshot.epoch,
        inputCallbackCount: deviceSnapshot.input?.callbackCount,
        outputCallbackCount: deviceSnapshot.output?.callbackCount,
        inputCallbackAgeMilliseconds: deviceSnapshot.input?.callbackAgeMilliseconds,
        outputCallbackAgeMilliseconds: deviceSnapshot.output?.callbackAgeMilliseconds,
        measuredInputDelayMilliseconds: deviceSnapshot.reportedInputLatencyMilliseconds,
        measuredOutputDelayMilliseconds: deviceSnapshot.reportedOutputLatencyMilliseconds
      ),
      processing: MacGridLiveKitAudioProcessingPolicy.snapshot()
    )
  }

  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio: Bool
  ) async throws -> GridAudioInputRouteApplication {
    guard configured else { throw LiveKitGridAUHALDriverError.notConfigured }
    return try await switchInputRoute(
      target,
      forceRebuild: false,
      ensureRecording: restartPreparedAudio
    )
  }

  func applyOutputRoute(_ target: AudioOutputRouteTarget) async throws {
    guard configured else { throw LiveKitGridAUHALDriverError.notConfigured }
    let result = try await outputSettler.waitForCompatibleOutput(target: target)
    let snapshot = try result.requireCompatibleOutput()
    latestCatalog = snapshot
    let output = try MacGridPlatformAudioDeviceResolver.outputDevice(
      for: target,
      in: snapshot
    )
    try audioDevice.applyOutputRoute(output)
    if audioDevice.isPlaying {
      try await waitForOutputRouteReadback(expectedUID: output.uid)
    }
    log.info(
      "GRID_ENGINE phase=custom_auhal_output_route_committed target=\(target.logDescription) \(await outputReadbackDescription(expectedUID: output.uid))"
    )
  }

  private func switchInputRoute(
    _ target: AudioInputRouteTarget,
    forceRebuild: Bool,
    ensureRecording: Bool
  ) async throws -> GridAudioInputRouteApplication {
    let snapshot = try await catalog.snapshot()
    latestCatalog = snapshot
    let input = try MacGridPlatformAudioDeviceResolver.inputDevice(
      for: target,
      in: snapshot
    )
    let previousTarget = appliedInputTarget
    let previousUID = audioDevice.snapshot().selectedInputUID
      ?? appliedInputDeviceUID
    let previousInput = previousUID.flatMap { uid in
      snapshot.inputs.first { $0.uid == uid }
    }
    let shouldRestart = audioDevice.snapshot().nativeRecordingDemanded || ensureRecording

    if audioDevice.snapshot().input?.isStarted == true {
      do {
        try quiesceRecordingForRouteTransition()
      } catch {
        guard audioDevice.snapshot().input?.isStarted != true else {
          throw LiveKitGridAUHALDriverError.recordingStopFailed(
            String(describing: error)
          )
        }
      }
    }

    do {
      try await commitInputRoute(
        input,
        target: target,
        forceRebuild: forceRebuild,
        shouldRestart: shouldRestart
      )
      return .committed
    } catch {
      let primaryError: any Error = error
      let failedAttempt = audioDevice.snapshot().input
      let retryableTransitionFailure = if let failedAttempt {
        MacGridAUHALInputStartFailurePolicy.isRetryableTransitionFailure(
           callbackCount: failedAttempt.callbackCount,
           frameCount: failedAttempt.frameCount,
           physicalRenderErrorCount: failedAttempt.physicalRenderErrorCount ?? 0,
           physicalCannotDoCount: failedAttempt.physicalCannotDoCount ?? 0,
           lastStatus: failedAttempt.lastStatus
         )
      } else {
        false
      }
      if retryableTransitionFailure, let failedAttempt {
        log.warning(
          "GRID_ENGINE phase=custom_auhal_input_transient_start target=\(target.logDescription) uid=\(input.uid) callbacks=\(failedAttempt.callbackCount) frames=\(failedAttempt.frameCount) physical_render_errors=\(failedAttempt.physicalRenderErrorCount ?? 0) physical_render_cannot_do_in_context=\(failedAttempt.physicalCannotDoCount ?? 0) bridge_publication_errors=\(failedAttempt.bridgePublicationErrorCount ?? 0) callback_cannot_do_in_context=\(failedAttempt.cannotDoInCurrentContextCount) parameter_errors=\(failedAttempt.parameterErrorCount) other_errors=\(failedAttempt.otherCallbackErrorCount) status=\(failedAttempt.lastStatus) action=rollback_and_defer_to_supervisor"
        )
      }
      var rollbackFailures: [String] = []
      var restoredInputUID: String?
      let latestRollbackInput = if let previousUID,
                                   let currentCatalog = try? await catalog.snapshot() {
        currentCatalog.inputs.first { $0.uid == previousUID } ?? previousInput
      } else {
        previousInput
      }
      if let previousInput = latestRollbackInput, let previousTarget {
        do {
          try audioDevice.applyInputRoute(previousInput, forceRebuild: true)
          appliedInputTarget = previousTarget
          appliedInputDeviceUID = previousInput.uid
          restoredInputUID = previousInput.uid
        } catch {
          rollbackFailures.append("restore input route: \(String(describing: error))")
          appliedInputTarget = nil
          appliedInputDeviceUID = nil
        }
      } else {
        rollbackFailures.append("the previous microphone was unavailable for rollback")
        appliedInputTarget = nil
        appliedInputDeviceUID = nil
      }
      if let restoredInputUID {
        do {
          let restarted = try resumeRecordingIfNativeDemanded()
          if restarted {
            try await waitForInputRouteReadback(expectedUID: restoredInputUID)
          }
        } catch {
          rollbackFailures.append("restart previous microphone: \(String(describing: error))")
        }
      }
      if !rollbackFailures.isEmpty {
        throw LiveKitGridAUHALDriverError.routeTransactionFailed(
          primary: String(describing: primaryError),
          rollback: rollbackFailures
        )
      }
      log.warning(
        "GRID_ENGINE phase=custom_auhal_input_route_restored failed_target=\(target.logDescription) restored_uid=\(restoredInputUID ?? "none") failure=\(String(describing: primaryError))"
      )
      return .restoredPreviousRoute(
        failure: String(describing: primaryError),
        retryable: retryableTransitionFailure
      )
    }
  }

  private func commitInputRoute(
    _ input: MacGridAudioDevice,
    target: AudioInputRouteTarget,
    forceRebuild: Bool,
    shouldRestart: Bool
  ) async throws {
    try audioDevice.applyInputRoute(input, forceRebuild: forceRebuild)
    appliedInputTarget = target
    appliedInputDeviceUID = input.uid
    let restarted = try resumeRecordingIfNativeDemanded()
    if !restarted, shouldRestart {
      log.info(
        "GRID_ENGINE phase=custom_auhal_input_restart_skipped reason=native_sender_demand_ended uid=\(input.uid)"
      )
    }
    let readback = audioDevice.snapshot()
    guard readback.selectedInputUID == input.uid else {
      throw LiveKitGridAUHALDriverError.routeReadbackMismatch("input")
    }
    if restarted, readback.isRecording {
      try await waitForInputRouteReadback(expectedUID: input.uid)
    }
  }

  private func waitForInputRouteReadback(expectedUID: String) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    var progress = MacGridAudioCallbackProgressMonitor(
      baselineCallbackCount: audioDevice.snapshot().input?.callbackCount
    )
    while clock.now < deadline {
      try Task.checkCancellation()
      if !audioDevice.snapshot().nativeRecordingDemanded {
        log.info(
          "GRID_ENGINE phase=custom_auhal_input_settle_quiesced reason=native_sender_demand_ended expected_uid=\(expectedUID)"
        )
        return
      }
      let health = await runtimeHealth()
      let routeIsValid = health.isRecording
        && health.route?.currentInputID == expectedUID
        && health.route?.isInputRouteValid == true
      if progress.observe(
        callbackCount: health.route?.inputCallbackCount,
        isRouteValid: routeIsValid
      ) {
        log.info(
          "GRID_ENGINE phase=custom_auhal_input_reconciled \(await inputReadbackDescription(expectedUID: expectedUID))"
        )
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let detail = await inputReadbackDescription(expectedUID: expectedUID)
    let error = LiveKitGridAUHALDriverError.routeReadbackMismatch("physical input")
    log.error(
      "GRID_ENGINE phase=custom_auhal_input_readback_failed \(detail)",
      error: error
    )
    throw error
  }

  private func resumeRecordingIfNativeDemanded() throws -> Bool {
    let beforeRestart = audioDevice.snapshot()
    guard beforeRestart.nativeRecordingDemanded else { return false }
    guard beforeRestart.input?.isStarted != true else { return true }
    do {
      try audioDevice.startRecordingFromControlPlane()
    } catch {
      // Mute/sender teardown can race an asynchronous route settle. The latest
      // native gate is authoritative: a selected, intentionally stopped route
      // is a successful quiescent commit, not a rollback failure.
      guard audioDevice.snapshot().nativeRecordingDemanded else { return false }
      throw LiveKitGridAUHALDriverError.recordingStartFailed(
        "custom_device=\(String(describing: error))"
      )
    }
    return audioDevice.snapshot().nativeRecordingDemanded
  }

  private func quiesceRecordingForRouteTransition() throws {
    guard audioDevice.snapshot().input?.isStarted == true else { return }
    do {
      try audioDevice.stopRecordingFromControlPlane()
    } catch {
      throw LiveKitGridAUHALDriverError.recordingStopFailed(
        "custom_device=\(String(describing: error))"
      )
    }
  }

  private func waitForOutputRouteReadback(expectedUID: String) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    var progress = MacGridAudioCallbackProgressMonitor(
      baselineCallbackCount: audioDevice.snapshot().output?.callbackCount
    )
    while clock.now < deadline {
      try Task.checkCancellation()
      let health = await runtimeHealth()
      let routeIsValid = health.isPlaying
        && health.route?.currentOutputID == expectedUID
        && health.route?.isOutputRouteValid == true
      if progress.observe(
        callbackCount: health.route?.outputCallbackCount,
        isRouteValid: routeIsValid
      ) {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let detail = await outputReadbackDescription(expectedUID: expectedUID)
    let error = LiveKitGridAUHALDriverError.routeReadbackMismatch("physical output")
    log.error(
      "GRID_ENGINE phase=custom_auhal_output_readback_failed \(detail)",
      error: error
    )
    throw error
  }

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    let snapshot: MacGridAudioCatalogSnapshot
    if let current = try? await catalog.snapshot() {
      latestCatalog = current
      snapshot = current
    } else if let latestCatalog {
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
      routeFingerprints: Dictionary(
        uniqueKeysWithValues: snapshot.inputs.compactMap { device in
          device.inputRouteSignature.map { signature in
            (device.uid, Self.inputFingerprint(signature))
          }
        }
      ),
      routeEpoch: snapshot.epoch
    )
  }

  func outputDeviceInventory() async -> AudioOutputDeviceInventory {
    let snapshot: MacGridAudioCatalogSnapshot
    if let current = try? await catalog.snapshot() {
      latestCatalog = current
      snapshot = current
    } else if let latestCatalog {
      snapshot = latestCatalog
    } else {
      return AudioOutputDeviceInventory(
        automaticDeviceID: nil,
        automaticDeviceName: "System Default",
        devices: [],
        routeFingerprints: [:],
        routeEpoch: 0
      )
    }
    return AudioOutputDeviceInventory(
      automaticDeviceID: snapshot.defaultOutput?.uid,
      automaticDeviceName: snapshot.defaultOutput?.name ?? "System Default",
      devices: snapshot.outputs.map { device in
        AudioOutputDeviceDescriptor(
          id: device.uid,
          name: device.name,
          isSystemDefault: device.id == snapshot.defaultOutputID,
          systemImage: Self.outputSystemImage(for: device)
        )
      },
      routeFingerprints: Dictionary(
        uniqueKeysWithValues: snapshot.outputs.compactMap { device in
          device.outputRouteSignature.map { signature in
            (device.uid, Self.outputFingerprint(signature))
          }
        }
      ),
      routeEpoch: snapshot.epoch
    )
  }

  private func catalogChanged(_ snapshot: MacGridAudioCatalogSnapshot) async {
    guard snapshot.epoch != lastCatalogEventEpoch else { return }
    lastCatalogEventEpoch = snapshot.epoch
    latestCatalog = snapshot
    // Catalog callbacks publish facts only. GridAudioEngine is the sole route
    // transaction owner for both persisted explicit choices and Auto fallback.
    // Mutating output here would race user selection with a second default-only
    // state machine.
    eventContinuation.yield(.devicesChanged)
  }

  private static func outputFingerprint(
    _ signature: MacGridAudioOutputRouteSignature
  ) -> AudioOutputRouteFingerprint {
    AudioOutputRouteFingerprint(
      sampleRate: signature.sampleRate,
      channelCount: signature.channelCount,
      bytesPerPacket: signature.bytesPerPacket,
      framesPerPacket: signature.framesPerPacket,
      bytesPerFrame: signature.bytesPerFrame,
      bitsPerChannel: signature.bitsPerChannel,
      formatID: signature.formatID,
      formatFlags: signature.formatFlags,
      bufferFrameSize: signature.bufferFrameSize,
      transport: signature.transport,
      isAlive: signature.isAlive
    )
  }

  private static func inputFingerprint(
    _ signature: MacGridAudioInputRouteSignature
  ) -> AudioInputRouteFingerprint {
    AudioInputRouteFingerprint(
      sampleRate: signature.sampleRate,
      channelCount: signature.channelCount,
      bytesPerPacket: signature.bytesPerPacket,
      framesPerPacket: signature.framesPerPacket,
      bytesPerFrame: signature.bytesPerFrame,
      bitsPerChannel: signature.bitsPerChannel,
      formatID: signature.formatID,
      formatFlags: signature.formatFlags,
      bufferFrameSize: signature.bufferFrameSize,
      transport: signature.transport,
      isAlive: signature.isAlive
    )
  }

  private static func systemImage(for device: MacGridAudioDevice) -> String {
    if device.isBluetooth { return "airpodspro" }
    let name = device.name.localizedLowercase
    if name.contains("display") || name.contains("hdmi") { return "display" }
    if name.contains("headphone") || name.contains("headset") {
      return "headphones"
    }
    return "mic"
  }

  private static func outputSystemImage(for device: MacGridAudioDevice) -> String {
    if device.isBluetooth { return "airpodspro" }
    let name = device.name.localizedLowercase
    if name.contains("display") || name.contains("hdmi") { return "display" }
    if name.contains("headphone") || name.contains("headset") {
      return "headphones"
    }
    return "speaker.wave.2"
  }

  private static func recordingReadbackDescription(
    _ snapshot: MacGridAUHALAudioDeviceSnapshot,
    readbackFailure: (any Error)? = nil,
    cleanupFailure: String? = nil
  ) -> String {
    let input = snapshot.input
    var fields = [
      "initialized=\(snapshot.isInitialized)",
      "recording=\(snapshot.isRecording)",
      "native_starts=\(snapshot.nativeRecordingStartCount)",
      "native_stops=\(snapshot.nativeRecordingStopCount)",
      "native_demand=\(snapshot.nativeRecordingDemanded)",
      "control_mutation=\(snapshot.controlMutationInFlight)",
      "control_generation=\(snapshot.controlMutationGeneration)",
      "selected_uid=\(snapshot.selectedInputUID ?? "none")",
      "active_uid=\(input?.device.uid ?? "none")",
      "configured_device_id=\(input?.device.id.description ?? "none")",
      "auhal_device_id=\(input?.audioUnitDeviceID?.description ?? "none")",
      "started=\(input?.isStarted ?? false)",
      "callbacks=\(input?.callbackCount ?? 0)",
      "frames=\(input?.frameCount ?? 0)",
      "callback_frames=\(input?.lastCallbackFrameCount ?? 0)",
      "callback_age_ms=\(input?.callbackAgeMilliseconds?.description ?? "none")",
      "host_time_callbacks=\(input?.hostTimestampCallbackCount ?? 0)",
      "host_time_missing=\(input?.hostTimestampMissingCount ?? 0)",
      "host_time_regressions=\(input?.hostTimestampRegressionCount ?? 0)",
      "callback_errors=\(input?.callbackErrorCount ?? 0)",
      "callback_cannot_do_in_context=\(input?.cannotDoInCurrentContextCount ?? 0)",
      "callback_parameter_errors=\(input?.parameterErrorCount ?? 0)",
      "callback_other_errors=\(input?.otherCallbackErrorCount ?? 0)",
      "physical_render_errors=\(input?.physicalRenderErrorCount ?? 0)",
      "physical_render_cannot_do_in_context=\(input?.physicalCannotDoCount ?? 0)",
      "bridge_publication_errors=\(input?.bridgePublicationErrorCount ?? 0)",
      "packet_pending_frames=\(input?.packetizerPendingFrameCount?.description ?? "none")",
      "packet_timestamp_discontinuities=\(input?.packetizerTimestampDiscontinuityCount?.description ?? "none")",
      "packet_continuous_frames=\(input?.packetizerContinuousFrameCount?.description ?? "none")",
      "bridge_active=\(snapshot.bridge?.captureWorkerActive ?? false)",
      "bridge_delivered=\(snapshot.bridge?.captureHasDeliveredForCurrentActivation ?? false)",
      "bridge_queued_frames=\(snapshot.bridge?.captureQueuedFrames ?? 0)",
      "bridge_overflows=\(snapshot.bridge?.captureOverflowCount ?? 0)",
      "bridge_delivery_errors=\(snapshot.bridge?.captureDeliveryErrorCount ?? 0)",
      "bridge_delivery_status=\(snapshot.bridge?.lastCaptureDeliveryStatus ?? noErr)",
      "bridge_conversion_errors=\(snapshot.bridge?.captureConversionErrorCount ?? 0)",
      "bridge_conversion_status=\(snapshot.bridge?.lastCaptureConversionStatus ?? noErr)",
      "bridge_packetization_errors=\(snapshot.bridge?.capturePacketizationErrorCount ?? 0)",
      "bridge_packetization_status=\(snapshot.bridge?.lastCapturePacketizationStatus ?? noErr)",
      "bridge_native_rate=\(snapshot.bridge?.captureNativeSampleRate ?? 0)",
      "delay_ms=\(snapshot.reportedInputLatencyMilliseconds)",
      "status=\(input?.lastStatus ?? noErr)",
    ]
    if let controlFailure = snapshot.lastControlFailure {
      fields.append("control_failure=\(controlFailure)")
    }
    if let readbackFailure {
      fields.append("readback_failure=\(String(describing: readbackFailure))")
    }
    if let cleanupFailure {
      fields.append("cleanup_failure=\(cleanupFailure)")
    }
    return fields.joined(separator: " ")
  }

  private func inputReadbackDescription(expectedUID: String) async -> String {
    let snapshot = audioDevice.snapshot()
    let input = snapshot.input
    let processRoute = try? await catalog.processRouteSnapshot()
    let catalogSnapshot = try? await catalog.snapshot()
    return [
      "expected_uid=\(expectedUID)",
      "selected_uid=\(snapshot.selectedInputUID ?? "none")",
      "active_uid=\(input?.device.uid ?? "none")",
      "configured_device_id=\(input?.device.id.description ?? "none")",
      "auhal_device_id=\(input?.audioUnitDeviceID?.description ?? "none")",
      "auhal_device_match=\(input?.hasVerifiedDeviceReadback ?? false)",
      "recording=\(snapshot.isRecording)",
      "started=\(input?.isStarted ?? false)",
      "callbacks=\(input?.callbackCount ?? 0)",
      "frames=\(input?.frameCount ?? 0)",
      "callback_frames=\(input?.lastCallbackFrameCount ?? 0)",
      "callback_age_ms=\(input?.callbackAgeMilliseconds?.description ?? "none")",
      "host_time_callbacks=\(input?.hostTimestampCallbackCount ?? 0)",
      "host_time_missing=\(input?.hostTimestampMissingCount ?? 0)",
      "host_time_regressions=\(input?.hostTimestampRegressionCount ?? 0)",
      "callback_errors=\(input?.callbackErrorCount ?? 0)",
      "callback_cannot_do_in_context=\(input?.cannotDoInCurrentContextCount ?? 0)",
      "callback_parameter_errors=\(input?.parameterErrorCount ?? 0)",
      "callback_other_errors=\(input?.otherCallbackErrorCount ?? 0)",
      "physical_render_errors=\(input?.physicalRenderErrorCount ?? 0)",
      "physical_render_cannot_do_in_context=\(input?.physicalCannotDoCount ?? 0)",
      "bridge_publication_errors=\(input?.bridgePublicationErrorCount ?? 0)",
      "packet_pending_frames=\(input?.packetizerPendingFrameCount?.description ?? "none")",
      "packet_timestamp_discontinuities=\(input?.packetizerTimestampDiscontinuityCount?.description ?? "none")",
      "packet_continuous_frames=\(input?.packetizerContinuousFrameCount?.description ?? "none")",
      "bridge_active=\(snapshot.bridge?.captureWorkerActive ?? false)",
      "bridge_delivered=\(snapshot.bridge?.captureHasDeliveredForCurrentActivation ?? false)",
      "bridge_queued_frames=\(snapshot.bridge?.captureQueuedFrames ?? 0)",
      "bridge_overflows=\(snapshot.bridge?.captureOverflowCount ?? 0)",
      "bridge_delivery_errors=\(snapshot.bridge?.captureDeliveryErrorCount ?? 0)",
      "bridge_delivery_status=\(snapshot.bridge?.lastCaptureDeliveryStatus ?? noErr)",
      "bridge_conversion_errors=\(snapshot.bridge?.captureConversionErrorCount ?? 0)",
      "bridge_conversion_status=\(snapshot.bridge?.lastCaptureConversionStatus ?? noErr)",
      "bridge_packetization_errors=\(snapshot.bridge?.capturePacketizationErrorCount ?? 0)",
      "bridge_packetization_status=\(snapshot.bridge?.lastCapturePacketizationStatus ?? noErr)",
      "bridge_native_rate=\(snapshot.bridge?.captureNativeSampleRate ?? 0)",
      "delay_ms=\(snapshot.reportedInputLatencyMilliseconds)",
      "status=\(input?.lastStatus ?? noErr)",
      "native_starts=\(snapshot.nativeRecordingStartCount)",
      "native_stops=\(snapshot.nativeRecordingStopCount)",
      "native_demand=\(snapshot.nativeRecordingDemanded)",
      "control_mutation=\(snapshot.controlMutationInFlight)",
      "control_generation=\(snapshot.controlMutationGeneration)",
      "process_running_input=\(processRoute?.isRunningInput ?? false)",
      "process_input_ids=\(processRoute?.inputDeviceIDs.map(String.init).joined(separator: ",") ?? "none")",
      "default_uid=\(catalogSnapshot?.defaultInput?.uid ?? "none")",
      "default_device_id=\(catalogSnapshot?.defaultInputID?.description ?? "none")",
      "hardware_rate=\(input?.device.inputStreamFormat?.sampleRate ?? input?.device.sampleRate ?? 0)",
      "hardware_channels=\(input?.device.inputStreamFormat?.channelCount ?? 0)",
      "hardware_buffer_frames=\(input?.device.bufferFrameSize ?? 0)",
    ].joined(separator: " ")
  }

  private func outputReadbackDescription(expectedUID: String) async -> String {
    let snapshot = audioDevice.snapshot()
    let output = snapshot.output
    let processRoute = try? await catalog.processRouteSnapshot()
    let catalogSnapshot = try? await catalog.snapshot()
    let defaultOutput = catalogSnapshot?.defaultOutput
    return [
      "expected_uid=\(expectedUID)",
      "selected_uid=\(snapshot.selectedOutputUID ?? "none")",
      "active_uid=\(output?.device.uid ?? "none")",
      "configured_device_id=\(output?.device.id.description ?? "none")",
      "auhal_device_id=\(output?.audioUnitDeviceID?.description ?? "none")",
      "auhal_device_match=\(output?.hasVerifiedDeviceReadback ?? false)",
      "playing=\(snapshot.isPlaying)",
      "control_mutation=\(snapshot.controlMutationInFlight)",
      "control_generation=\(snapshot.controlMutationGeneration)",
      "started=\(output?.isStarted ?? false)",
      "callbacks=\(output?.callbackCount ?? 0)",
      "frames=\(output?.frameCount ?? 0)",
      "callback_frames=\(output?.lastCallbackFrameCount ?? 0)",
      "callback_age_ms=\(output?.callbackAgeMilliseconds?.description ?? "none")",
      "host_time_callbacks=\(output?.hostTimestampCallbackCount ?? 0)",
      "host_time_missing=\(output?.hostTimestampMissingCount ?? 0)",
      "host_time_regressions=\(output?.hostTimestampRegressionCount ?? 0)",
      "callback_errors=\(output?.callbackErrorCount ?? 0)",
      "callback_cannot_do_in_context=\(output?.cannotDoInCurrentContextCount ?? 0)",
      "callback_parameter_errors=\(output?.parameterErrorCount ?? 0)",
      "callback_other_errors=\(output?.otherCallbackErrorCount ?? 0)",
      "silence_flag_callbacks=\(output?.outputSilenceFlagCallbackCount?.description ?? "none")",
      "latest_callback_silence=\(output?.latestOutputCallbackWasSilence?.description ?? "none")",
      "bridge_active=\(snapshot.bridge?.playoutWorkerActive ?? false)",
      "bridge_pulled=\(snapshot.bridge?.playoutHasPulledForCurrentActivation ?? false)",
      "bridge_queued_frames=\(snapshot.bridge?.playoutQueuedFrames ?? 0)",
      "bridge_underruns=\(snapshot.bridge?.playoutUnderrunCount ?? 0)",
      "bridge_latest_requested_frames=\(snapshot.bridge?.latestPlayoutRequestedFrames ?? 0)",
      "bridge_latest_copied_frames=\(snapshot.bridge?.latestPlayoutCopiedFrames ?? 0)",
      "bridge_latest_underrun=\(snapshot.bridge?.latestPlayoutCallbackHadUnderrun ?? false)",
      "bridge_consecutive_missing_frames=\(snapshot.bridge?.consecutivePlayoutMissingFrames ?? 0)",
      "bridge_target_frames=\(snapshot.bridge?.playoutTargetFrames ?? 0)",
      "bridge_pull_errors=\(snapshot.bridge?.playoutPullErrorCount ?? 0)",
      "bridge_pull_status=\(snapshot.bridge?.lastPlayoutPullStatus ?? noErr)",
      "delay_ms=\(snapshot.reportedOutputLatencyMilliseconds)",
      "status=\(output?.lastStatus ?? noErr)",
      "process_running_output=\(processRoute?.isRunningOutput ?? false)",
      "process_output_ids=\(processRoute?.outputDeviceIDs.map(String.init).joined(separator: ",") ?? "none")",
      "default_uid=\(defaultOutput?.uid ?? "none")",
      "default_device_id=\(catalogSnapshot?.defaultOutputID?.description ?? "none")",
      "hardware_rate=\(output?.device.outputStreamFormat?.sampleRate ?? output?.device.sampleRate ?? 0)",
      "hardware_channels=\(output?.device.outputStreamFormat?.channelCount ?? 0)",
      "hardware_buffer_frames=\(output?.device.bufferFrameSize ?? 0)",
      "default_rate=\(defaultOutput?.outputStreamFormat?.sampleRate ?? defaultOutput?.sampleRate ?? 0)",
      "default_channels=\(defaultOutput?.outputStreamFormat?.channelCount ?? 0)",
      "default_buffer_frames=\(defaultOutput?.bufferFrameSize ?? 0)",
    ].joined(separator: " ")
  }
}

private enum LiveKitGridAUHALDriverError: LocalizedError {
  case notConfigured
  case customDeviceInstallFailed(String)
  case platformVoiceProcessingUnsupported
  case inputRouteNotApplied
  case recordingStartFailed(String)
  case recordingDidNotStart(String)
  case recordingStopFailed(String)
  case routeReadbackMismatch(String)
  case routeTransactionFailed(primary: String, rollback: [String])

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "The custom AUHAL audio driver is not configured."
    case let .customDeviceInstallFailed(error):
      "WebRTC rejected the custom AUHAL device before initialization: \(error)"
    case .platformVoiceProcessingUnsupported:
      "The custom AUHAL path requires Apple platform voice processing to remain disabled."
    case .inputRouteNotApplied:
      "No microphone route was applied before capture preparation."
    case let .recordingStartFailed(error):
      "WebRTC failed to start AUHAL recording: \(error)"
    case let .recordingDidNotStart(detail):
      "AUHAL recording did not reach stable physical readback: \(detail)"
    case let .recordingStopFailed(error):
      "WebRTC failed to stop AUHAL recording: \(error)"
    case let .routeReadbackMismatch(direction):
      "The \(direction) AUHAL route did not match physical readback."
    case let .routeTransactionFailed(primary, rollback):
      "The AUHAL route failed (\(primary)); rollback failures: \(rollback.joined(separator: ", "))"
    }
  }
}
#else
actor LiveKitGridAUHALAudioDriver: GridAudioDriver {
  nonisolated let events: AsyncStream<GridAudioDriverEvent>

  private nonisolated let eventContinuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private nonisolated let expectedEngineTransition = ManagedAtomic<Bool>(false)
  private var engineObserver: GridLiveKitAudioEngineObserver?
  private var configured = false
  private var prepared = false

  init() {
    let stream = AsyncStream.makeStream(
      of: GridAudioDriverEvent.self,
      bufferingPolicy: .bufferingNewest(16)
    )
    events = stream.stream
    eventContinuation = stream.continuation
  }

  deinit { eventContinuation.finish() }

  func configure(_ configuration: InlineRTCConfiguration) async throws {
    guard !configured else { return }
    try AudioManager.set(audioDeviceModuleType: .audioEngine)
    AudioManager.prepare()
    try configuration.applyVoiceProcessing()
    let observer = GridLiveKitAudioEngineObserver(
      eventContinuation: eventContinuation,
      expectedEngineTransition: expectedEngineTransition
    )
    AudioManager.shared.set(engineObservers: [observer, AudioManager.shared.mixer])
    engineObserver = observer
    let eventContinuation = eventContinuation
    AudioManager.shared.onDeviceUpdate = { _ in
      eventContinuation.yield(.devicesChanged)
    }
    configured = true
  }

  func setPrepared(_ prepared: Bool) async throws {
    guard self.prepared != prepared else { return }
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

  func isAudioEngineRunning() async -> Bool { AudioManager.shared.isEngineRunning }

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
#endif
