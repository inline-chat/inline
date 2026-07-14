import AVFoundation
import Atomics
import Foundation
import LiveKit
import Logger

#if os(macOS)
actor LiveKitGridAudioDriver: GridAudioDriver {
  nonisolated let events: AsyncStream<GridAudioDriverEvent>

  private nonisolated let eventContinuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private let catalog = MacGridAudioDeviceCatalog()
  private let io = MacGridAudioIOController()
  private var catalogTask: Task<Void, Never>?
  private var latestCatalog: MacGridAudioCatalogSnapshot?
  private var configured = false
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
    catalogTask?.cancel()
    catalog.stop()
    eventContinuation.finish()
  }

  func configure(_ configuration: InlineRTCConfiguration) async throws {
    guard !configured else { return }
    log.debug("GRID_ENGINE phase=manual_audio_configure_started")
    try AudioManager.set(audioDeviceModuleType: .audioEngine)
    try AudioManager.shared.setManualRenderingMode(true)
    try configuration.applyVoiceProcessing()

    let initial = try await catalog.snapshot()
    latestCatalog = initial
    await io.updateCatalog(initial)
    catalog.start()
    catalogTask = Task { [weak self, updates = catalog.updates] in
      for await snapshot in updates {
        guard !Task.isCancelled else { return }
        await self?.catalogChanged(snapshot)
      }
    }
    configured = true
    log.info(
      "GRID_ENGINE phase=manual_audio_configured inputs=\(initial.inputs.count) outputs=\(initial.outputs.count)"
    )
  }

  func setPrepared(_ prepared: Bool) async throws {
    try await io.setPrepared(prepared)
  }

  func recoverPreparedAudio(preserving target: AudioInputRouteTarget?) async throws {
    if let target { try await io.applyInput(target) }
    try await io.recover()
  }

  func isAudioEngineRunning() async -> Bool {
    await io.health().isEngineRunning
  }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    await io.health()
  }

  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio _: Bool
  ) async throws {
    try await io.applyInput(target)
  }

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    let snapshot: MacGridAudioCatalogSnapshot
    if let latestCatalog {
      snapshot = latestCatalog
    } else if let current = try? await catalog.snapshot() {
      latestCatalog = current
      await io.updateCatalog(current)
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
    await io.updateCatalog(snapshot)
    eventContinuation.yield(.devicesChanged)
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
