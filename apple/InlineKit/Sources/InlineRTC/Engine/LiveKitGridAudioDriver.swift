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
  private let catalog = MacGridAudioDeviceCatalog()
  private var catalogTask: Task<Void, Never>?
  private var deviceUpdateObserver: AudioDeviceUpdateObserverHandle?
  private var latestCatalog: MacGridAudioCatalogSnapshot?
  private var audioProcessingOptions = AudioProcessingOptions()
  private var captureState = MacGridPlatformAudioCaptureState()
  private var configured = false
  private let audioDeviceModuleBootstrapError: String?
  private let log = Log.scoped("LiveKitGridAudioDriver")

  init() {
    // Select the process-wide ADM synchronously while the session graph is
    // being constructed. Grid demand is delivered through a nonisolated
    // mailbox, so waiting until async configure() lets Room initialize the
    // peer-connection factory first.
    do {
      try AudioManager.set(audioDeviceModuleType: .platformDefault)
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
    log.debug("GRID_ENGINE phase=livekit_audio_configure_started backend=platform_default")

    // The process-wide module type was selected synchronously in init. The
    // standard macOS ADM owns capture, playout, buffering, clocking, and
    // render/capture delay reporting.
    audioProcessingOptions = configuration.makeAudioProcessingOptions()

    let initial = try await catalog.snapshot()
    guard initial.defaultInput != nil else {
      throw MacGridCoreAudioError.unavailable("No default microphone is available.")
    }
    guard initial.defaultOutput != nil else {
      throw MacGridCoreAudioError.unavailable("No default output device is available.")
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
    log.info(
      "GRID_ENGINE phase=livekit_audio_configured backend=platform_default inputs=\(initial.inputs.count) outputs=\(initial.outputs.count) software_aec=\(configuration.capture.echoCancellation) software_ns=\(configuration.capture.noiseSuppression)"
    )
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
      try startRecording()
    } else {
      guard captureState.isPrepared || AudioManager.shared.isRecording else { return }
      try stopRecording()
    }
  }

  func recoverPreparedAudio(preserving target: AudioInputRouteTarget?) async throws {
    guard configured else {
      throw LiveKitPlatformAudioDriverError.notConfigured
    }
    try switchInputRoute(
      captureState.recoveryTarget(preserving: target),
      restartRecording: true
    )
  }

  func isAudioEngineRunning() async -> Bool {
    AudioManager.shared.isRecording || AudioManager.shared.isPlaying
  }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    let manager = AudioManager.shared
    let recording = manager.isRecording
    let playing = manager.isPlaying
    guard let snapshot = latestCatalog else {
      return GridAudioRuntimeHealth(
        isEngineRunning: recording || playing,
        isRecording: recording,
        isPlaying: playing,
        route: nil
      )
    }

    // M144's current-device getters are imported as nonoptional even though
    // their Objective-C implementation can return nil during hot-plug churn.
    // Health therefore validates the selected policy against the stable Core
    // Audio catalog and the ADM's concrete recording/playing state.
    let selectedInputID: String? = switch captureState.appliedInputTarget {
    case .automatic:
      snapshot.defaultInput?.uid
    case let .device(uid, _):
      snapshot.inputs.contains(where: { $0.uid == uid }) ? uid : nil
    case nil:
      nil
    }
    let outputID = snapshot.defaultOutput?.uid
    let inputMatches = selectedInputID != nil
    let outputMatches = outputID != nil

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
        isInputRouteValid: !captureState.isPrepared || (recording && inputMatches),
        isOutputRouteValid: outputMatches,
        routeEpoch: snapshot.epoch
      )
    )
  }

  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio: Bool
  ) async throws {
    try switchInputRoute(
      target,
      restartRecording: restartPreparedAudio
        || captureState.isPrepared
        || AudioManager.shared.isRecording
    )
  }

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    let snapshot: MacGridAudioCatalogSnapshot
    if let latestCatalog {
      snapshot = latestCatalog
    } else if let current = try? await catalog.snapshot() {
      latestCatalog = current
      snapshot = current
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

  private func catalogChanged(_ snapshot: MacGridAudioCatalogSnapshot) async {
    guard snapshot != latestCatalog else { return }
    latestCatalog = snapshot
    eventContinuation.yield(.devicesChanged)
  }

  private func switchInputRoute(
    _ target: AudioInputRouteTarget,
    restartRecording: Bool
  ) throws {
    guard let snapshot = latestCatalog else {
      throw MacGridCoreAudioError.unavailable("The audio device catalog is not ready.")
    }
    let previousTarget = captureState.appliedInputTarget
    if restartRecording {
      try stopRecording()
    }

    do {
      try selectInput(target, in: snapshot)
      captureState.inputSelected(target)
      if restartRecording {
        try startRecording()
      }
    } catch let switchError {
      if let previousTarget {
        do {
          try selectInput(previousTarget, in: snapshot)
          captureState.inputSelected(previousTarget)
        } catch let rollbackError {
          captureState.inputSelectionLost()
          log.error(
            "GRID_ENGINE phase=platform_default_input_rollback_failed",
            error: rollbackError
          )
        }
      } else {
        captureState.inputSelectionLost()
      }
      if restartRecording {
        do {
          try startRecording()
        } catch let rollbackError {
          captureState.recordingStopped()
          log.error(
            "GRID_ENGINE phase=platform_default_recording_rollback_failed",
            error: rollbackError
          )
        }
      }
      throw switchError
    }
  }

  private func selectInput(
    _ target: AudioInputRouteTarget,
    in snapshot: MacGridAudioCatalogSnapshot
  ) throws {
    let manager = AudioManager.shared
    if case .automatic = target {
      // WebRTC's standard macOS ADM establishes index zero during its own
      // initialization and follows subsequent system-default changes. The
      // first Auto transaction inherits that policy; returning from an
      // explicit device must actively restore index zero.
      if captureState.appliedInputTarget != nil,
         !manager.selectDefaultInputDevice() {
        throw LiveKitPlatformAudioDriverError.inputDeviceUnavailable
      }
      log.info(
        "GRID_ENGINE phase=platform_default_input_selected route=\(target.logDescription) name=\(snapshot.defaultInput?.name ?? "System Default")"
      )
      return
    }

    let deviceID = try MacGridPlatformAudioDeviceResolver.platformInputDeviceID(
      for: target,
      in: snapshot
    )
    guard let device = manager.inputDevices.first(where: { $0.deviceId == deviceID }) else {
      throw LiveKitPlatformAudioDriverError.inputDeviceUnavailable
    }

    // M144's public property setter performs the native selection. Avoid its
    // current-device getter here: the Objective-C implementation can return
    // nil during the enumeration/getter hot-plug race despite a nonoptional
    // Swift import. Recording startup and stable-catalog health verify that
    // the selected policy remains operational.
    manager.inputDevice = device
    log.info(
      "GRID_ENGINE phase=platform_default_input_selected route=\(target.logDescription) name=\(device.name)"
    )
  }

  private func startRecording() throws {
    do {
      try AudioManager.shared.startLocalRecording(
        audioProcessingOptions: audioProcessingOptions
      )
    } catch {
      throw LiveKitPlatformAudioDriverError.recordingStartFailed(
        underlying: String(describing: error)
      )
    }
    guard AudioManager.shared.isRecording else {
      throw LiveKitPlatformAudioDriverError.recordingDidNotStart
    }
    captureState.recordingStarted()
  }

  private func stopRecording() throws {
    do {
      try AudioManager.shared.stopLocalRecording()
    } catch {
      if AudioManager.shared.isRecording {
        captureState.recordingStarted()
      } else {
        captureState.recordingStopped()
      }
      throw error
    }
    captureState.recordingStopped()
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

private enum LiveKitPlatformAudioDriverError: LocalizedError {
  case notConfigured
  case audioDeviceModuleBootstrapFailed(underlying: String)
  case platformVoiceProcessingUnsupported
  case inputRouteNotApplied
  case inputDeviceUnavailable
  case recordingStartFailed(underlying: String)
  case recordingDidNotStart

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "Platform-default audio is not configured."
    case let .audioDeviceModuleBootstrapFailed(underlying):
      "WebRTC platform-default audio could not be selected before RTC initialization. \(underlying)"
    case .platformVoiceProcessingUnsupported:
      "Grid platform-default audio requires Apple Voice Processing I/O to remain disabled."
    case .inputRouteNotApplied:
      "A microphone route must be applied before capture starts."
    case .inputDeviceUnavailable:
      "The selected microphone is not available to WebRTC."
    case let .recordingStartFailed(underlying):
      "WebRTC could not start platform-default microphone capture. \(underlying)"
    case .recordingDidNotStart:
      "WebRTC returned from microphone startup without entering the recording state."
    }
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
  ) async throws {
    guard case .automatic = target else {
      throw LiveKitGridAudioDriverError.explicitInputRoutingUnsupported
    }
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
