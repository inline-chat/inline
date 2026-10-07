#if os(iOS)
import AVFoundation
import Atomics
import Foundation
import InlineAudioPlayback
import LiveKit

/// iOS uses the SDK AudioEngine ADM and its supported session observer chain.
/// Capture availability is a physical fence: retired room callbacks cannot
/// reopen the microphone after product capture intent has been withdrawn.
actor LiveKitGridIOSAudioDriver: GridAudioDriver {
  nonisolated let events: AsyncStream<GridAudioDriverEvent>
  private nonisolated let continuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private nonisolated let expectedTransition = ManagedAtomic<Bool>(false)
  private let directions = IOSGridAudioDirections()
  private let inputProbe = IOSGridAudioCallbackProbe()
  private let outputProbe = IOSGridAudioCallbackProbe()
  private var observer: IOSGridAudioEngineObserver?
  private let systemObservers = IOSGridSystemObservers()
  private var configured = false
  private var prepared = false
  private var safetyPaused = false
  private var interruptionActive = false
  private var requiresExplicitOutputResume = false
  private var requiresProcessRestart = false
  private var mediaDemandActive = false
  /// Invalidates suspended warm preparation before any safety or admission
  /// change can be undone by its completion.
  private var lifecycleEpoch: UInt64 = 0
  private var mediaDemandEpoch: UInt64 = 0
  private var expectedTransitionCount = 0
  private var warmModeMayBeEnabled = false
  private var audioProcessingOptions = AudioProcessingOptions()
  private let bootstrapError: String?
  private let backend: any IOSGridAudioBackend
  private let hasNativeEngine: Bool

  init() {
    backend = LiveKitIOSGridAudioBackend()
    hasNativeEngine = true
    // Select the process ADM before any Room can initialize its factory.
    do {
      try AudioManager.set(audioDeviceModuleType: .audioEngine)
      bootstrapError = nil
    } catch {
      bootstrapError = error.localizedDescription
    }
    let stream = AsyncStream.makeStream(of: GridAudioDriverEvent.self, bufferingPolicy: .bufferingNewest(16))
    events = stream.stream
    continuation = stream.continuation
  }

  /// Exercises the real actor lifecycle against suspended provider operations
  /// without initializing an ADM or touching the device audio session in tests.
  init(testingBackend backend: any IOSGridAudioBackend) {
    self.backend = backend
    hasNativeEngine = false
    bootstrapError = nil
    configured = true
    let stream = AsyncStream.makeStream(of: GridAudioDriverEvent.self, bufferingPolicy: .bufferingNewest(16))
    events = stream.stream
    continuation = stream.continuation
  }

  deinit {
    continuation.finish()
  }

  func configure(_ configuration: InlineRTCConfiguration) async throws {
    guard !configured else { return }
    if let bootstrapError { throw IOSGridAudioError.bootstrap(bootstrapError) }
    // The process owner supplies category and activation through its native FIFO.
    // Keep the SDK observer in the chain, without a second session writer.
    AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
    AudioManager.prepare()
    try configuration.applyVoiceProcessing()
    audioProcessingOptions = configuration.makeAudioProcessingOptions()
    let observer = IOSGridAudioEngineObserver(
      continuation: continuation,
      expectedTransition: expectedTransition,
      directions: directions
    )
    // Manual configuration retains the stock requirement/observer forwarding chain.
    AudioManager.shared.set(engineObservers: [AudioManager.shared.audioSession, observer, AudioManager.shared.mixer])
    self.observer = observer
    AudioManager.shared.add(localAudioRenderer: inputProbe)
    AudioManager.shared.add(remoteAudioRenderer: outputProbe)
    try backend.setEngineAvailability(mediaDemandActive && !safetyPaused ? Self.listenOnlyAvailability : .none)
    installSystemObservers()
    configured = true
  }

  func resumeAfterTerminalShutdown() async {
    let epoch = lifecycleEpoch
    guard !(await backend.isQuarantined()) else { return }
    guard epoch == lifecycleEpoch, mediaDemandActive, !safetyPaused, !interruptionActive else { return }
    try? backend.setEngineAvailability(Self.listenOnlyAvailability)
  }

  func setMediaDemandActive(_ active: Bool, epoch: UInt64) async throws {
    guard epoch >= mediaDemandEpoch else { return }
    if mediaDemandActive != active || epoch != mediaDemandEpoch {
      lifecycleEpoch &+= 1
      mediaDemandEpoch = epoch
      mediaDemandActive = active
      if !active {
        prepared = false
        // Withdraw physical input/output before crossing to the session owner.
        try backend.setEngineAvailability(.none)
      }
    }
    do {
      try await backend.setGridDemandActive(active, epoch: epoch)
    } catch {
      if active, epoch == mediaDemandEpoch {
        mediaDemandActive = false
        lifecycleEpoch &+= 1
        try? backend.setEngineAvailability(.none)
      }
      throw error
    }
  }

  func mediaDidQuiesce(epoch: UInt64) async {
    guard epoch == mediaDemandEpoch, !mediaDemandActive else { return }
    await backend.gridMediaDidQuiesce(epoch: epoch)
    guard epoch == mediaDemandEpoch, !mediaDemandActive else { return }
    if hasNativeEngine { _ = await runtimeHealth() }
  }

  func setPrepared(_ value: Bool) async throws {
    guard configured else { throw IOSGridAudioError.notConfigured }
    if !value {
      lifecycleEpoch &+= 1
      prepared = false
    }
    let epoch = lifecycleEpoch
    guard !(await backend.isQuarantined()) else {
      throw InlineAudioSessionError.quarantined
    }
    guard epoch == lifecycleEpoch else { throw IOSGridAudioError.superseded }
    beginExpectedTransition()
    defer { endExpectedTransition() }
    if value {
      guard !requiresProcessRestart else { throw InlineAudioSessionError.quarantined }
      guard mediaDemandActive, !safetyPaused, !interruptionActive else { throw IOSGridAudioError.safetyPaused }
      warmModeMayBeEnabled = true
      do {
        try await backend.setRecordingAlwaysPreparedMode(true, audioProcessingOptions: audioProcessingOptions)
      } catch {
        try? await stopWarmMode()
        throw error
      }
      guard epoch == lifecycleEpoch, mediaDemandActive, !safetyPaused, !interruptionActive else {
        // A cancelled SDK await may still have enabled its persistent warm
        // demand. Retire that concrete obligation before releasing the writer.
        try? await stopWarmMode()
        throw IOSGridAudioError.superseded
      }
      try backend.setEngineAvailability(.default)
    } else {
      // Highest-priority ADM gate precedes warm-mode release. A late room or
      // publication completion can express demand but cannot reopen input.
      try backend.setEngineAvailability(mediaDemandActive && !safetyPaused && !interruptionActive ? Self.listenOnlyAvailability : .none)
      try await stopWarmMode()
      guard epoch == lifecycleEpoch else { throw IOSGridAudioError.superseded }
    }
    prepared = value
  }

  func stopForShutdown() async -> GridAudioDriverShutdownReceipt {
    lifecycleEpoch &+= 1
    let epoch = lifecycleEpoch
    prepared = false
    var failures: [String] = []
    beginExpectedTransition()
    defer { endExpectedTransition() }
    do { try backend.setEngineAvailability(.none) }
    catch { failures.append("availability: \(error)") }
    do { try await stopWarmMode() }
    catch { failures.append("capture: \(error)") }
    if epoch != lifecycleEpoch { failures.append("Audio shutdown was superseded by a new lifecycle transition.") }
    let health = await runtimeHealth()
    if await backend.isQuarantined() {
      failures.append("An audio session requirement failed to release; process restart is required.")
    }
    return GridAudioDriverShutdownReceipt(
      recordingStopped: !health.isRecording,
      playoutStopped: !health.isPlaying,
      failures: failures
    )
  }

  func recoverPreparedAudio(preserving _: AudioInputRouteTarget?) async throws {
    guard prepared, mediaDemandActive, !safetyPaused, !interruptionActive else { return }
    try await setPrepared(false)
    let epoch = lifecycleEpoch
    guard mediaDemandActive, !safetyPaused, !interruptionActive else { return }
    try await setPrepared(true)
    guard epoch == lifecycleEpoch else { throw IOSGridAudioError.superseded }
  }

  func resumeListeningAfterSafetyPause() async throws {
    guard mediaDemandActive, safetyPaused else { return }
    guard !requiresProcessRestart else { throw InlineAudioSessionError.quarantined }
    guard !interruptionActive else { throw IOSGridAudioError.interrupted }
    try await resumeListening()
  }

  func isAudioEngineRunning() async -> Bool { AudioManager.shared.isEngineRunning }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    let enabled = directions.snapshot()
    let running = AudioManager.shared.isEngineRunning
    let recording = running && enabled.recording
    let playing = running && enabled.playing
    let input = inputProbe.snapshot()
    let output = outputProbe.snapshot()
    let route = AVAudioSession.sharedInstance().currentRoute
    await InlineAudioSession.shared.observeGridDirections(
      recording: recording,
      playing: playing,
      nativeOperationsQuiescent: expectedTransitionCount == 0 && !warmModeMayBeEnabled,
      epoch: mediaDemandEpoch
    )
    return GridAudioRuntimeHealth(
      isEngineRunning: running,
      isRecording: recording,
      isRecordingExpected: prepared && !safetyPaused,
      isPlaying: playing,
      route: InlineRTCAudioRoute(
        currentInputID: route.inputs.first?.uid,
        defaultInputID: route.inputs.first?.uid,
        currentOutputID: route.outputs.first?.uid,
        defaultOutputID: route.outputs.first?.uid,
        inputDeviceCount: route.inputs.count,
        outputDeviceCount: route.outputs.count,
        isInputRouteValid: !recording || (!safetyPaused && !route.inputs.isEmpty && input.isFresh),
        isOutputRouteValid: !playing || (!safetyPaused && !route.outputs.isEmpty && output.isFresh),
        inputCallbackCount: input.count,
        outputCallbackCount: output.count,
        inputCallbackAgeMilliseconds: input.ageMilliseconds,
        outputCallbackAgeMilliseconds: output.ageMilliseconds
      )
    )
  }

  func applyInputRoute(_ target: AudioInputRouteTarget, restartPreparedAudio _: Bool) async throws -> GridAudioInputRouteApplication {
    guard case .automatic = target else { throw IOSGridAudioError.explicitRoute }
    return .committed
  }

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    AudioInputDeviceInventory(automaticDeviceID: nil, automaticDeviceName: "Automatic", devices: [], routeEpoch: 0)
  }

  private static let listenOnlyAvailability = AudioEngineAvailability(isInputAvailable: false, isOutputAvailable: true)

  private func beginExpectedTransition() {
    expectedTransitionCount += 1
    expectedTransition.store(true, ordering: .releasing)
  }

  private func endExpectedTransition() {
    expectedTransitionCount -= 1
    expectedTransition.store(expectedTransitionCount > 0, ordering: .releasing)
    if expectedTransitionCount == 0, hasNativeEngine {
      Task { _ = await self.runtimeHealth() }
    }
  }

  private func stopWarmMode() async throws {
    try await backend.setRecordingAlwaysPreparedMode(false)
    warmModeMayBeEnabled = false
  }

  private func installSystemObservers() {
    let center = NotificationCenter.default
    systemObservers.tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self, continuation] notification in
      let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
      if rawReason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        Task { await self?.pauseForSafety(requiresExplicitOutputResume: true) }
      } else {
        continuation.yield(.devicesChanged)
      }
    })
    if #available(iOS 27.0, *) {
      systemObservers.tokens.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: nil) { [weak self] notification in
        guard let context = notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
              context.source == .system else { return }
        Task { await self?.interruptionBegan() }
      })
      systemObservers.tokens.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: nil) { [weak self] notification in
        guard let context = notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else { return }
        let shouldResume = context.recommendation == .shouldResume
        Task { await self?.interruptionEnded(shouldResume: shouldResume) }
      })
    } else {
      systemObservers.tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
        Task {
          if type == .began { await self?.interruptionBegan() }
          else if type == .ended { await self?.interruptionEnded(shouldResume: shouldResume) }
        }
      })
    }
    systemObservers.tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
      Task { await self?.mediaServicesWereReset() }
    })
  }

  func interruptionBegan() async {
    interruptionActive = true
    await pauseForSafety(requiresExplicitOutputResume: false)
  }

  func mediaServicesWereReset() async {
    // Fence retry synchronously, before a suspended SDK stop can delay the
    // process-owner quarantine notification.
    requiresProcessRestart = true
    await pauseForSafety(requiresExplicitOutputResume: true, quarantiningReset: true)
  }

  func interruptionEnded(shouldResume: Bool) async {
    interruptionActive = false
    guard shouldResume, !requiresExplicitOutputResume, mediaDemandActive, safetyPaused else { return }
    try? await resumeListening()
  }

  private func resumeListening() async throws {
    let epoch = lifecycleEpoch
    guard !requiresProcessRestart else { throw InlineAudioSessionError.quarantined }
    guard mediaDemandActive, !interruptionActive else { return }
    guard !(await backend.isQuarantined()) else {
      throw InlineAudioSessionError.quarantined
    }
    guard epoch == lifecycleEpoch, mediaDemandActive, !interruptionActive else { return }
    beginExpectedTransition()
    defer { endExpectedTransition() }
    // A resumed call always listens first. Neither the OS recommendation nor
    // Retry Audio restores a microphone lease withdrawn by the safety pause.
    try backend.setEngineAvailability(.none)
    try await stopWarmMode()
    guard epoch == lifecycleEpoch, mediaDemandActive, !interruptionActive else { return }
    try await backend.resumeGridSession(epoch: mediaDemandEpoch)
    guard epoch == lifecycleEpoch, mediaDemandActive, !interruptionActive else { return }
    prepared = false
    try backend.setEngineAvailability(Self.listenOnlyAvailability)
    safetyPaused = false
    requiresExplicitOutputResume = false
    continuation.yield(.listeningResumed)
  }

  func pauseForSafety(requiresExplicitOutputResume: Bool, quarantiningReset: Bool = false) async {
    lifecycleEpoch &+= 1
    let epoch = lifecycleEpoch
    safetyPaused = true
    self.requiresExplicitOutputResume = self.requiresExplicitOutputResume || requiresExplicitOutputResume
    prepared = false
    beginExpectedTransition()
    defer { endExpectedTransition() }
    try? backend.setEngineAvailability(.none)
    // Publish withdrawal before suspending, so a quick end notification cannot
    // resume output before the product has received its mute/capture fence.
    continuation.yield(.safetyPaused)
    if quarantiningReset { await backend.quarantineAfterMediaServicesReset() }
    try? await stopWarmMode()
    guard epoch == lifecycleEpoch else { return }
  }
}

/// The supported SDK calls form one narrow suspension boundary. The driver,
/// rather than this adapter, owns admission and safety epochs.
protocol IOSGridAudioBackend: Sendable {
  func setEngineAvailability(_ availability: AudioEngineAvailability) throws
  func setRecordingAlwaysPreparedMode(_ value: Bool, audioProcessingOptions: AudioProcessingOptions?) async throws
  func isQuarantined() async -> Bool
  func setGridDemandActive(_ active: Bool, epoch: UInt64) async throws
  func gridMediaDidQuiesce(epoch: UInt64) async
  func resumeGridSession(epoch: UInt64) async throws
  func quarantineAfterMediaServicesReset() async
}

extension IOSGridAudioBackend {
  func setRecordingAlwaysPreparedMode(_ value: Bool) async throws {
    try await setRecordingAlwaysPreparedMode(value, audioProcessingOptions: nil)
  }
}

private struct LiveKitIOSGridAudioBackend: IOSGridAudioBackend {
  func setEngineAvailability(_ availability: AudioEngineAvailability) throws {
    try AudioManager.shared.setEngineAvailability(availability)
  }

  func setRecordingAlwaysPreparedMode(_ value: Bool, audioProcessingOptions: AudioProcessingOptions?) async throws {
    try await AudioManager.shared.setRecordingAlwaysPreparedMode(value, audioProcessingOptions: audioProcessingOptions)
  }

  func isQuarantined() async -> Bool { await InlineAudioSession.shared.isQuarantined }

  func setGridDemandActive(_ active: Bool, epoch: UInt64) async throws {
    try await InlineAudioSession.shared.setGridDemandActive(active, epoch: epoch)
  }

  func gridMediaDidQuiesce(epoch: UInt64) async {
    await InlineAudioSession.shared.gridMediaDidQuiesce(epoch: epoch)
  }

  func resumeGridSession(epoch: UInt64) async throws {
    try await InlineAudioSession.shared.resumeGridSession(epoch: epoch)
  }

  func quarantineAfterMediaServicesReset() async {
    await InlineAudioSession.shared.quarantineAfterMediaServicesReset()
  }
}

/// Registration is driver-actor confined; destruction may happen on any thread.
private final class IOSGridSystemObservers: @unchecked Sendable {
  var tokens: [NSObjectProtocol] = []
  deinit {
    for token in tokens { NotificationCenter.default.removeObserver(token) }
  }
}

private final class IOSGridAudioDirections: @unchecked Sendable {
  private let lock = NSLock()
  private var playing = false
  private var recording = false

  func update(playing: Bool, recording: Bool) {
    lock.lock()
    self.playing = playing
    self.recording = recording
    lock.unlock()
  }

  func snapshot() -> (playing: Bool, recording: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (playing, recording)
  }
}

private final class IOSGridAudioEngineObserver: AudioEngineObserver, @unchecked Sendable {
  var next: (any AudioEngineObserver)?
  private let continuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private let expectedTransition: ManagedAtomic<Bool>
  private let directions: IOSGridAudioDirections

  init(continuation: AsyncStream<GridAudioDriverEvent>.Continuation, expectedTransition: ManagedAtomic<Bool>, directions: IOSGridAudioDirections) {
    self.continuation = continuation
    self.expectedTransition = expectedTransition
    self.directions = directions
  }

  func engineWillStart(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
    directions.update(playing: isPlayoutEnabled, recording: isRecordingEnabled)
    continuation.yield(.engineStarting(playout: isPlayoutEnabled, recording: isRecordingEnabled))
    return next?.engineWillStart(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
  }

  func engineDidStop(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
    continuation.yield(expectedTransition.load(ordering: .acquiring)
      ? .expectedEngineStop(playout: isPlayoutEnabled, recording: isRecordingEnabled)
      : .engineStopped(playout: isPlayoutEnabled, recording: isRecordingEnabled))
    return next?.engineDidStop(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
  }

  func engineDidDisable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
    directions.update(playing: isPlayoutEnabled, recording: isRecordingEnabled)
    continuation.yield(expectedTransition.load(ordering: .acquiring)
      ? .expectedEngineDisable(playout: isPlayoutEnabled, recording: isRecordingEnabled)
      : .engineDisabled(playout: isPlayoutEnabled, recording: isRecordingEnabled))
    return next?.engineDidDisable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
  }
}

private final class IOSGridAudioCallbackProbe: NSObject, AudioRenderer, @unchecked Sendable {
  struct Snapshot {
    let count: UInt64
    let ageMilliseconds: UInt64?
    var isFresh: Bool { ageMilliseconds.map { $0 < 1_000 } ?? false }
  }
  private let count = ManagedAtomic<UInt64>(0)
  private let lastCallback = ManagedAtomic<UInt64>(0)

  func render(pcmBuffer _: AVAudioPCMBuffer) {
    count.wrappingIncrement(ordering: .relaxed)
    lastCallback.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
  }

  func snapshot() -> Snapshot {
    let last = lastCallback.load(ordering: .relaxed)
    let now = DispatchTime.now().uptimeNanoseconds
    return Snapshot(count: count.load(ordering: .relaxed), ageMilliseconds: last > 0 && now >= last ? (now - last) / 1_000_000 : nil)
  }
}

private enum IOSGridAudioError: LocalizedError {
  case bootstrap(String)
  case notConfigured
  case explicitRoute
  case superseded
  case safetyPaused
  case interrupted
  var errorDescription: String? {
    switch self {
    case let .bootstrap(message): "Audio could not initialize. \(message)"
    case .notConfigured: "Audio is not configured."
    case .explicitRoute: "Choose the audio route using the system audio control."
    case .superseded: "Audio preparation was superseded by a safety or call change."
    case .safetyPaused: "Resume audio before unmuting."
    case .interrupted: "Audio is interrupted. Try again when the interruption ends."
    }
  }
}
#endif
