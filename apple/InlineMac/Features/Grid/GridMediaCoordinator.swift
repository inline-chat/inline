import Foundation
import InlineKit
import InlineRTC

enum GridMediaCoordinatorEvent: Sendable {
  case credentialsNeeded(GridMediaTarget)
  case connected(GridMediaTarget, rtcConnectMilliseconds: Int?)
  case screenShareContextChanged
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
  private let outputPreferences: AudioOutputPreferenceStore
  private let defaults: UserDefaults
  private var microphoneEnabled: Bool
  private var inputSelection: AudioInputSelection
  private var outputSelection: AudioOutputSelection
  private var outputVolume: Float = 1
  private var screenCaptureSource: InlineRTCScreenCaptureSource?
  private var screenCaptureSourceRefresh: GridScreenCaptureSourceRefresh?
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
    inputPreferences: AudioInputPreferenceStore,
    outputPreferences: AudioOutputPreferenceStore
  ) {
    self.engine = engine
    self.defaults = defaults
    self.inputPreferences = inputPreferences
    self.outputPreferences = outputPreferences
    inputSelection = inputPreferences.selection
    outputSelection = outputPreferences.selection
    microphoneEnabled = defaults.bool(forKey: Self.microphoneEnabledKey)
    let controller = GridMediaPresentationController(
      microphoneEnabled: microphoneEnabled,
      inputSelection: inputSelection,
      outputSelection: outputSelection
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
    screenCaptureSource = nil
    presentationController.setSelectedScreenCaptureSource(nil)
    presentationController.clearScreenCaptureError()
    GridScreenShareOutlineCoordinator.shared.hide()
    GridScreenShareWindowCoordinator.shared.closeAll()
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

  func setOutput(_ selection: AudioOutputSelection) {
    if outputSelection == selection {
      if presentation.isFallingBackToAutomaticOutput || presentation.audioState.isFailed {
        engine.retryOutput(selection)
      }
      return
    }
    outputSelection = selection
    outputPreferences.setSelection(selection)
    presentationController.setDesiredOutputSelection(selection)
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

  func refreshOutputDevices() {
    engine.refreshDevices()
  }

  @discardableResult
  func refreshScreenCaptureSources() async -> [InlineRTCScreenCaptureSource] {
    if let refresh = screenCaptureSourceRefresh {
      return finishScreenCaptureSourceRefresh(
        await refresh.task.value,
        id: refresh.id
      )
    }

    let refresh = GridScreenCaptureSourceRefresh(
      id: UUID(),
      task: Task { [engine] in
        do {
          let sources = try await engine.screenCaptureSources()
          guard !sources.isEmpty else {
            return .failure("No displays are available")
          }
          return .success(sources)
        } catch {
          return .failure(error.localizedDescription)
        }
      }
    )
    screenCaptureSourceRefresh = refresh
    presentationController.setRefreshingScreenCaptureSources(true)
    return finishScreenCaptureSourceRefresh(
      await refresh.task.value,
      id: refresh.id
    )
  }

  func startScreenSharing(displayID: UInt32?) async {
    guard let expectedTarget = target else { return }
    let sources = await refreshScreenCaptureSources()
    guard target == expectedTarget else { return }
    let source = displayID.flatMap { displayID in
      sources.first { $0.displayID == displayID }
    } ?? sources.first
    guard let source else { return }
    startScreenSharing(source)
  }

  func startScreenSharing(_ source: InlineRTCScreenCaptureSource) {
    guard target != nil else { return }
    screenCaptureSource = source
    presentationController.setSelectedScreenCaptureSource(source)
    presentationController.clearScreenCaptureError()
    submitDemand()
  }

  func stopScreenSharing() {
    screenCaptureSource = nil
    presentationController.setSelectedScreenCaptureSource(nil)
    presentationController.clearScreenCaptureError()
    GridScreenShareOutlineCoordinator.shared.hide()
    submitDemand()
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
    screenCaptureSource = nil
    screenCaptureSourceRefresh?.task.cancel()
    screenCaptureSourceRefresh = nil
    presentationController.setRefreshingScreenCaptureSources(false)
    presentationController.setSelectedScreenCaptureSource(nil)
    presentationController.clearScreenCaptureError()
    GridScreenShareOutlineCoordinator.shared.hide()
    GridScreenShareWindowCoordinator.shared.closeAll()
    lastDemand = nil
    engine.setDemand(InlineRTCDemand())
    _ = await engine.shutdown()
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
      screenCaptureSource: screenCaptureSource,
      input: inputSelection,
      output: outputSelection,
      outputVolume: outputVolume
    )
    guard demand != lastDemand else { return }
    lastDemand = demand
    engine.setDemand(demand)
  }

  private func finishScreenCaptureSourceRefresh(
    _ result: GridScreenCaptureSourceRefreshResult,
    id: UUID
  ) -> [InlineRTCScreenCaptureSource] {
    let sources = result.sources
    guard screenCaptureSourceRefresh?.id == id else { return sources }
    screenCaptureSourceRefresh = nil
    presentationController.setRefreshingScreenCaptureSources(false)
    switch result {
    case let .success(sources):
      presentationController.applyScreenCaptureSources(.success(sources))
    case let .failure(message):
      presentationController.applyScreenCaptureSources(
        .failure(GridScreenCaptureSourceRefreshError(message: message))
      )
    }
    reconcileScreenShareOutline()
    return sources
  }

  private func apply(_ snapshot: InlineRTCState) {
    presentationController.apply(audio: snapshot.audio)
    if let devices = snapshot.devices {
      presentationController.apply(devices: devices)
    }
    if let outputDevices = snapshot.outputDevices {
      presentationController.apply(outputDevices: outputDevices)
    }

    let wasConnected = presentation.connectionState == .connected
    presentationController.apply(rtc: snapshot.rtc)
    reconcileScreenShareOutline()
    broadcast(.screenShareContextChanged)
    if case .failed = snapshot.rtc.screenShareState, screenCaptureSource != nil {
      screenCaptureSource = nil
      presentationController.setSelectedScreenCaptureSource(nil)
      submitDemand()
    }
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

  private func reconcileScreenShareOutline() {
    guard let localShare = presentation.screenShares.first(where: \.isLocal),
          let sourceID = localShare.captureSourceID
    else {
      GridScreenShareOutlineCoordinator.shared.hide()
      return
    }
    let sources = presentation.screenCaptureSources
      + [presentation.selectedScreenCaptureSource].compactMap { $0 }
    guard let source = sources.first(where: { $0.id == sourceID }) else {
      GridScreenShareOutlineCoordinator.shared.hide()
      return
    }
    GridScreenShareOutlineCoordinator.shared.show(for: source)
  }
}

private struct GridScreenCaptureSourceRefresh {
  let id: UUID
  let task: Task<GridScreenCaptureSourceRefreshResult, Never>
}

private enum GridScreenCaptureSourceRefreshResult: Sendable {
  case success([InlineRTCScreenCaptureSource])
  case failure(String)

  var sources: [InlineRTCScreenCaptureSource] {
    switch self {
    case let .success(sources): sources
    case .failure: []
    }
  }
}

private struct GridScreenCaptureSourceRefreshError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private extension InlineRTCAudioState {
  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}
