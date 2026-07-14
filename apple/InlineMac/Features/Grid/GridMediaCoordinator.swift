import Foundation
import InlineKit
import InlineRTC

enum GridMediaCoordinatorEvent: Sendable {
  case credentialsNeeded(GridMediaTarget)
  case connected(GridMediaTarget, rtcConnectMilliseconds: Int?)
}

/// Main-actor bridge between room product state and the process-wide media
/// engine. This owns media intent, preference persistence, credentials, and
/// snapshot projection; `GridRoomService` never reaches into audio or RTC.
@MainActor
final class GridMediaCoordinator {
  let presentation: GridMediaPresentation

  private let engine: InlineRTCSession
  private let presentationController: GridMediaPresentationController
  private let inputPreferences: AudioInputPreferenceStore
  private let defaults: UserDefaults
  private var microphoneEnabled: Bool
  private var inputSelection: AudioInputSelection
  private var outputVolume: Float = 1
  private var target: GridMediaTarget?
  private var connectedTarget: GridMediaTarget?
  private var credentials: InlineRTCCredentials?
  private var lastDemand: InlineRTCDemand?
  private var playedConnectionSoundKeys = Set<String>()
  private var engineTask: Task<Void, Never>?
  private var subscribers: [UUID: AsyncStream<GridMediaCoordinatorEvent>.Continuation] = [:]

  private static let microphoneEnabledKey = "grid.microphoneEnabled"

  init(
    engine: InlineRTCSession,
    defaults: UserDefaults,
    inputPreferences: AudioInputPreferenceStore
  ) {
    self.engine = engine
    self.defaults = defaults
    self.inputPreferences = inputPreferences
    inputSelection = inputPreferences.selection
    microphoneEnabled = defaults.bool(forKey: Self.microphoneEnabledKey)
    let controller = GridMediaPresentationController(
      microphoneEnabled: microphoneEnabled,
      inputSelection: inputSelection
    )
    presentationController = controller
    presentation = controller.presentation

    engineTask = Task { [weak self, engine] in
      await engine.start()
      guard !Task.isCancelled else { return }
      engine.refreshDevices()
      self?.submitDemand()
      let snapshots = await engine.subscribe()
      for await snapshot in snapshots {
        guard !Task.isCancelled else { return }
        self?.apply(snapshot)
      }
    }
  }

  deinit {
    engineTask?.cancel()
    subscribers.values.forEach { $0.finish() }
    engine.requestShutdown()
  }

  func subscribe() -> AsyncStream<GridMediaCoordinatorEvent> {
    let id = UUID()
    let stream = AsyncStream.makeStream(
      of: GridMediaCoordinatorEvent.self,
      // These are edge notifications backed by complete engine snapshots and
      // target-scoped credential retry. A stalled observer must stay bounded.
      bufferingPolicy: .bufferingNewest(16)
    )
    stream.continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
    }
    subscribers[id] = stream.continuation
    return stream.stream
  }

  func setTarget(_ target: GridMediaTarget?) {
    guard self.target != target else {
      submitDemand()
      return
    }
    self.target = target
    if credentials?.target != target?.rtcSessionID {
      credentials = nil
    }
    submitDemand()
  }

  func accept(_ credentials: InlineRTCCredentials) -> Bool {
    guard credentials.target == target?.rtcSessionID else { return false }
    self.credentials = credentials
    submitDemand()
    return true
  }

  func hasUsableCredentials(for target: GridMediaTarget) -> Bool {
    credentials?.target == target.rtcSessionID
      && (credentials?.expiresAt.timeIntervalSinceNow ?? 0) > 5
  }

  func isConnected(to target: GridMediaTarget) -> Bool {
    connectedTarget == target
  }

  func invalidateCredentials(for target: GridMediaTarget) {
    guard credentials?.target == target.rtcSessionID else { return }
    credentials = nil
    submitDemand()
  }

  func clearCredentials() {
    guard credentials != nil else { return }
    credentials = nil
    submitDemand()
  }

  func toggleMicrophone() -> Bool {
    let enabled = !microphoneEnabled
    if enabled, presentation.microphonePermission != .authorized {
      engine.requestMicrophonePermission()
    }
    microphoneEnabled = enabled
    presentationController.setMicrophoneEnabled(enabled)
    defaults.set(enabled, forKey: Self.microphoneEnabledKey)
    submitDemand()
    return enabled
  }

  func requestMicrophonePermission() {
    engine.requestMicrophonePermission()
  }

  func setInput(_ selection: AudioInputSelection) {
    if inputSelection == selection {
      if presentation.isFallingBackToAutomaticInput || presentation.audioState.isFailed {
        engine.retryInput(selection)
      }
      return
    }
    inputSelection = selection
    inputPreferences.setSelection(selection)
    presentationController.setDesiredInputSelection(selection)
    submitDemand()
  }

  func setOutputVolume(_ volume: Float) {
    outputVolume = min(max(volume, 0), 1)
    presentationController.setDesiredOutputVolume(outputVolume)
    submitDemand()
  }

  func refreshInputDevices() {
    engine.refreshDevices()
  }

  func retryAudio() {
    engine.retryAudio()
  }

  func networkBecameAvailable() {
    engine.networkBecameAvailable()
  }

  func applicationDidWake() {
    engine.applicationDidWake()
  }

  func shutdown() async {
    target = nil
    connectedTarget = nil
    credentials = nil
    lastDemand = nil
    engine.setDemand(InlineRTCDemand())
    await engine.shutdown()
  }

  var isMicrophoneEnabled: Bool { microphoneEnabled }

  private func submitDemand() {
    let rtcTarget = target?.rtcSessionID
    if credentials?.target != rtcTarget {
      credentials = nil
    }
    let demand = InlineRTCDemand(
      target: rtcTarget,
      credentials: credentials,
      microphoneEnabled: microphoneEnabled,
      input: inputSelection,
      outputVolume: outputVolume
    )
    guard demand != lastDemand else { return }
    lastDemand = demand
    engine.setDemand(demand)
  }

  private func apply(_ snapshot: InlineRTCState) {
    presentationController.apply(audio: snapshot.audio)
    if let devices = snapshot.devices {
      presentationController.apply(devices: devices)
    }

    let wasConnected = presentation.connectionState == .connected
    presentationController.apply(rtc: snapshot.rtc)
    if case let .connected(sessionID) = snapshot.rtc.state,
       let target,
       target.rtcSessionID == sessionID {
      connectedTarget = target
    } else {
      connectedTarget = nil
    }
    if !wasConnected,
       presentation.connectionState == .connected,
       let sessionID = snapshot.rtc.target,
       let target,
       target.rtcSessionID == sessionID {
      let soundKey = sessionID.rawValue
      if playedConnectionSoundKeys.count >= 128 {
        playedConnectionSoundKeys.removeAll(keepingCapacity: true)
      }
      if playedConnectionSoundKeys.insert(soundKey).inserted {
        GridSoundEffects.shared.play(.connected)
      }
      broadcast(.connected(target, rtcConnectMilliseconds: snapshot.rtc.lastConnectMilliseconds))
    }
    if case let .waitingForCredentials(sessionID) = snapshot.rtc.state,
       let target,
       target.rtcSessionID == sessionID {
      broadcast(.credentialsNeeded(target))
    }
  }

  private func broadcast(_ event: GridMediaCoordinatorEvent) {
    subscribers.values.forEach { $0.yield(event) }
  }
}

private extension InlineRTCAudioState {
  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}
