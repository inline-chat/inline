#if os(macOS)
import Atomics
import Foundation
import LiveKit

struct MacGridAUHALAudioDeviceSnapshot: Equatable, Sendable {
  let isInitialized: Bool
  let isRecordingInitialized: Bool
  let isRecording: Bool
  /// Number of `startRecording` calls received through WebRTC's custom-device
  /// contract. Control-plane prewarm deliberately does not increment this;
  /// the count therefore proves whether native ADM opened its recording gate.
  let nativeRecordingStartCount: UInt64
  let nativeRecordingStopCount: UInt64
  let nativeRecordingDemanded: Bool
  let isPlayoutInitialized: Bool
  let isPlaying: Bool
  let selectedInputUID: String?
  let selectedOutputUID: String?
  let input: MacGridAUHALDirectionHealth?
  let output: MacGridAUHALDirectionHealth?
  let bridge: MacGridWebRTCAudioBridgeSnapshot?
  let reportedInputLatencyMilliseconds: UInt16
  let reportedOutputLatencyMilliseconds: UInt16
  let controlMutationInFlight: Bool
  let controlMutationGeneration: UInt64
  let terminalShutdownRequested: Bool
  let lastControlFailure: String?
}

enum MacGridAUHALNativeLifecycleEvent: Sendable {
  case recordingStarted
  case recordingStopped
  case playoutStarted
  case playoutStopped
}

struct MacGridAUHALTerminalShutdownReceipt: Equatable, Sendable {
  let snapshot: MacGridAUHALAudioDeviceSnapshot
  let failures: [String]

  var isQuiescent: Bool {
    !snapshot.isRecording
      && !snapshot.nativeRecordingDemanded
      && !snapshot.isRecordingInitialized
      && snapshot.input == nil
      && !snapshot.isPlaying
      && !snapshot.isPlayoutInitialized
      && snapshot.output == nil
      && failures.isEmpty
  }
}

/// Process-wide WebRTC physical device. WebRTC remains the ADM owner; this
/// object owns only the directional AUHAL units and their route transactions.
final class MacGridAUHALAudioDevice: CustomAudioDevice, @unchecked Sendable {
  private struct State {
    var delegate: (any CustomAudioDeviceDelegate)?
    var selectedInput: MacGridAudioDevice?
    var selectedOutput: MacGridAudioDevice?
    var input: (any MacGridAUHALDirectionControlling)?
    var output: (any MacGridAUHALDirectionControlling)?
    var lastControlFailure: String?
    var nativeLifecycleHandler: (@Sendable (MacGridAUHALNativeLifecycleEvent) -> Void)?
  }

  private struct MutationNotifications {
    var inputParametersChanged = false
    var outputParametersChanged = false

    func deliver(to delegate: (any CustomAudioDeviceDelegate)?) {
      guard let delegate else { return }
      if inputParametersChanged {
        delegate.notifyAudioInputParametersChange()
      }
      if outputParametersChanged {
        delegate.notifyAudioOutputParametersChange()
      }
    }
  }

  private let directionFactory: MacGridAUHALDirectionFactory
  /// Serializes native lifecycle and physical route ownership changes. Slow
  /// Core Audio work happens under this lock, never `stateLock`, so snapshots
  /// and health observers stay responsive during a bounded hardware wait.
  private let mutationLock = NSLock()
  private let stateLock = NSLock()
  private var state = State()
  private let initialized = ManagedAtomic(false)
  private let recordingInitialized = ManagedAtomic(false)
  private let recording = ManagedAtomic(false)
  private let nativeRecordingStartCount = ManagedAtomic<UInt64>(0)
  private let nativeRecordingStopCount = ManagedAtomic<UInt64>(0)
  private let nativeRecordingDemanded = ManagedAtomic(false)
  private let playoutInitialized = ManagedAtomic(false)
  private let playing = ManagedAtomic(false)
  private let controlMutationInFlight = ManagedAtomic(false)
  private let controlMutationGeneration = ManagedAtomic<UInt64>(0)
  private let terminalShutdown = ManagedAtomic(false)
  private let inputLatencyNanoseconds = ManagedAtomic<UInt64>(10_000_000)
  private let outputLatencyNanoseconds = ManagedAtomic<UInt64>(10_000_000)

  let deviceInputSampleRate = MacGridAUHALFormat.sampleRate
  let inputIOBufferDuration: TimeInterval = 0.010
  let inputNumberOfChannels = Int(MacGridAUHALFormat.inputChannels)
  var inputLatency: TimeInterval {
    TimeInterval(inputLatencyNanoseconds.load(ordering: .relaxed)) / 1_000_000_000
  }

  let deviceOutputSampleRate = MacGridAUHALFormat.sampleRate
  let outputIOBufferDuration: TimeInterval = 0.010
  let outputNumberOfChannels = Int(MacGridAUHALFormat.outputChannels)
  var outputLatency: TimeInterval {
    TimeInterval(outputLatencyNanoseconds.load(ordering: .relaxed)) / 1_000_000_000
  }

  var isInitialized: Bool { initialized.load(ordering: .acquiring) }
  var isRecordingInitialized: Bool { recordingInitialized.load(ordering: .acquiring) }
  var isRecording: Bool { recording.load(ordering: .acquiring) }
  var isPlayoutInitialized: Bool { playoutInitialized.load(ordering: .acquiring) }
  var isPlaying: Bool { playing.load(ordering: .acquiring) }

  init(directionFactory: MacGridAUHALDirectionFactory = .live) {
    self.directionFactory = directionFactory
  }

  func setNativeLifecycleHandler(
    _ handler: (@Sendable (MacGridAUHALNativeLifecycleEvent) -> Void)?
  ) {
    withState { $0.nativeLifecycleHandler = handler }
  }

  func initialize(delegate: any CustomAudioDeviceDelegate) -> Bool {
    guard withState({ $0.delegate == nil }) else { return false }
    let bridge: MacGridWebRTCAudioBridge
    do {
      bridge = try MacGridWebRTCAudioBridge(upstream: delegate)
    } catch {
      recordControlFailure(String(describing: error))
      return false
    }
    if let input = withState({ $0.selectedInput }),
       !Self.configureCaptureBridge(bridge, for: input) {
      bridge.shutdown()
      recordControlFailure(
        "The stable capture worker rejected the initial native input format."
      )
      return false
    }
    let accepted = withStateMutation { state, _ in
      guard state.delegate == nil else { return false }
      state.delegate = bridge
      state.lastControlFailure = nil
      return true
    }
    guard accepted else {
      bridge.shutdown()
      return false
    }
    if let output = withState({ $0.selectedOutput }) {
      Self.configurePlayoutBridge(bridge, for: output)
    }
    initialized.store(true, ordering: .releasing)
    // Init does not cache custom-device latency itself in M144. We are already
    // on the ADM thread, so seed both delay values before the first IO start.
    bridge.notifyAudioInputParametersChange()
    bridge.notifyAudioOutputParametersChange()
    return true
  }

  func terminate() -> Bool {
    var failures: [String] = []
    var bridgeToShutdown: MacGridWebRTCAudioBridge?
    withStateMutation { state, _ in
      stopInputLocked(state: &state, failures: &failures, clearNativeState: true)
      stopOutputLocked(state: &state, failures: &failures)
      if failures.isEmpty {
        bridgeToShutdown = state.delegate as? MacGridWebRTCAudioBridge
        state.delegate = nil
      }
      state.lastControlFailure = failures.first
    }
    if failures.isEmpty {
      bridgeToShutdown?.shutdown()
      initialized.store(false, ordering: .releasing)
      nativeRecordingDemanded.store(false, ordering: .releasing)
    }
    return failures.isEmpty
  }

  func initializeRecording() -> Bool {
    guard !terminalShutdown.load(ordering: .acquiring) else {
      recordControlFailure("Recording initialization was rejected during terminal shutdown.")
      return false
    }
    do {
      let delegate = try withStateMutation { state, _ -> any CustomAudioDeviceDelegate in
        guard let delegate = state.delegate else {
          throw MacGridAUHALAudioDeviceError.notInitialized
        }
        guard let device = state.selectedInput else {
          throw MacGridAUHALAudioDeviceError.inputRouteUnavailable
        }
        if let bridge = delegate as? MacGridWebRTCAudioBridge,
           !Self.configureCaptureBridge(bridge, for: device) {
          throw MacGridAUHALAudioDeviceError.captureFormatUnavailable(
            Self.inputSampleRate(for: device)
          )
        }
        if let input = state.input {
          inputLatencyNanoseconds.store(input.latencyNanoseconds, ordering: .relaxed)
          return delegate
        }
        let input = try directionFactory.makeInput(device, delegate)
        state.input = input
        state.lastControlFailure = nil
        inputLatencyNanoseconds.store(input.latencyNanoseconds, ordering: .relaxed)
        return delegate
      }
      recordingInitialized.store(true, ordering: .releasing)
      delegate.notifyAudioInputParametersChange()
      return true
    } catch {
      recordControlFailure(String(describing: error))
      recordingInitialized.store(false, ordering: .releasing)
      return false
    }
  }

  func startRecording() -> Bool {
    nativeRecordingStartCount.wrappingIncrement(ordering: .relaxed)
    guard !terminalShutdown.load(ordering: .acquiring) else {
      recordControlFailure("Recording start was rejected during terminal shutdown.")
      return false
    }
    let physicalStarted = startRecordingPhysical()
    if !physicalStarted {
      // WebRTC may not call StartRecording again after a physical failure. Keep
      // its native gate open whenever the stable worker can still honor the ADM
      // contract; Grid then repairs AUHAL beneath persistent sender demand.
      let bridgeReady = withState { state in
        (state.delegate as? MacGridWebRTCAudioBridge)?.setRecordingActive(true) == true
      }
      guard bridgeReady else { return false }
    }
    nativeRecordingDemanded.store(true, ordering: .releasing)
    recording.store(true, ordering: .releasing)
    withState { $0.nativeLifecycleHandler }?(.recordingStarted)
    return true
  }

  private func startRecordingPhysical() -> Bool {
    guard !terminalShutdown.load(ordering: .acquiring) else {
      recordControlFailure("Recording start was rejected during terminal shutdown.")
      return false
    }
    do {
      try withStateMutation { state, _ in
        guard let input = state.input else {
          throw MacGridAUHALAudioDeviceError.recordingNotInitialized
        }
        guard let bridge = state.delegate as? MacGridWebRTCAudioBridge else {
          throw MacGridAUHALAudioDeviceError.stableWorkerUnavailable("capture")
        }
        guard Self.configureCaptureBridge(bridge, for: input.device) else {
          throw MacGridAUHALAudioDeviceError.captureFormatUnavailable(
            Self.inputSampleRate(for: input.device)
          )
        }
        guard bridge.setRecordingActive(true) else {
          throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
            direction: "capture",
            active: true
          )
        }
        do {
          try input.start(operation: "start AUHAL microphone", timeout: 2)
        } catch {
          if !input.isRunning {
            _ = bridge.setRecordingActive(false)
          }
          throw error
        }
        state.lastControlFailure = nil
      }
      return true
    } catch {
      recordControlFailure(String(describing: error))
      return false
    }
  }

  func stopRecording() -> Bool {
    nativeRecordingStopCount.wrappingIncrement(ordering: .relaxed)
    let stopped = stopRecordingPhysical(clearNativeState: true)
    if stopped {
      // M144 clears its native `recording_` gate only after this method
      // acknowledges success. A failure must retain the previous demand fact.
      nativeRecordingDemanded.store(false, ordering: .releasing)
      recording.store(false, ordering: .releasing)
      withState { $0.nativeLifecycleHandler }?(.recordingStopped)
    }
    return stopped
  }

  private func stopRecordingPhysical(clearNativeState: Bool) -> Bool {
    var failures: [String] = []
    withStateMutation { state, _ in
      stopInputLocked(
        state: &state,
        failures: &failures,
        clearNativeState: clearNativeState
      )
      state.lastControlFailure = failures.first
    }
    return failures.isEmpty
  }

  /// Restarts physical capture while M144 already owns microphone-sender
  /// demand. Route recovery may rebuild AUHAL beneath the open native gate, but
  /// this control path can never fabricate that gate before sender attachment.
  func startRecordingFromControlPlane() throws {
    try performOnADMThread { [self] in
      guard isInitialized else {
        throw MacGridAUHALAudioDeviceError.notInitialized
      }
      guard nativeRecordingDemanded.load(ordering: .acquiring) else {
        throw MacGridAUHALAudioDeviceError.nativeRecordingDemandUnavailable
      }
      let physicalInputExists = snapshot().input != nil
      if !isRecordingInitialized || !physicalInputExists, !initializeRecording() {
        throw MacGridAUHALAudioDeviceError.controlPlaneRecordingFailed(
          snapshot().lastControlFailure ?? "recording initialization returned false"
        )
      }
      if snapshot().input?.isStarted != true, !startRecordingPhysical() {
        throw MacGridAUHALAudioDeviceError.controlPlaneRecordingFailed(
          snapshot().lastControlFailure ?? "recording start returned false"
        )
      }
    }
  }

  /// Quiesces physical capture for a route transaction while retaining M144's
  /// native microphone-sender demand.
  func stopRecordingFromControlPlane() throws {
    try performOnADMThread { [self] in
      guard nativeRecordingDemanded.load(ordering: .acquiring) else {
        throw MacGridAUHALAudioDeviceError.nativeRecordingDemandUnavailable
      }
      guard snapshot().input?.isStarted != true
        || stopRecordingPhysical(clearNativeState: false)
      else {
        throw MacGridAUHALAudioDeviceError.controlPlaneRecordingFailed(
          snapshot().lastControlFailure ?? "recording stop returned false"
        )
      }
    }
  }

  func initializePlayout() -> Bool {
    guard !terminalShutdown.load(ordering: .acquiring) else {
      recordControlFailure("Playout initialization was rejected during terminal shutdown.")
      return false
    }
    do {
      let delegate = try withStateMutation { state, _ -> any CustomAudioDeviceDelegate in
        guard let delegate = state.delegate else {
          throw MacGridAUHALAudioDeviceError.notInitialized
        }
        guard let device = state.selectedOutput else {
          throw MacGridAUHALAudioDeviceError.outputRouteUnavailable
        }
        if let bridge = delegate as? MacGridWebRTCAudioBridge {
          Self.configurePlayoutBridge(bridge, for: device)
        }
        if let output = state.output {
          outputLatencyNanoseconds.store(
            Self.outputLatencyNanoseconds(
              physicalLatencyNanoseconds: output.latencyNanoseconds,
              device: device
            ),
            ordering: .relaxed
          )
          return delegate
        }
        let output = try directionFactory.makeOutput(device, delegate)
        state.output = output
        state.lastControlFailure = nil
        outputLatencyNanoseconds.store(
          Self.outputLatencyNanoseconds(
            physicalLatencyNanoseconds: output.latencyNanoseconds,
            device: device
          ),
          ordering: .relaxed
        )
        return delegate
      }
      playoutInitialized.store(true, ordering: .releasing)
      delegate.notifyAudioOutputParametersChange()
      return true
    } catch {
      recordControlFailure(String(describing: error))
      playoutInitialized.store(false, ordering: .releasing)
      return false
    }
  }

  func startPlayout() -> Bool {
    guard !terminalShutdown.load(ordering: .acquiring) else {
      recordControlFailure("Playout start was rejected during terminal shutdown.")
      return false
    }
    let physicalStarted: Bool
    do {
      try withStateMutation { state, _ in
        guard let output = state.output else {
          throw MacGridAUHALAudioDeviceError.playoutNotInitialized
        }
        guard let bridge = state.delegate as? MacGridWebRTCAudioBridge else {
          throw MacGridAUHALAudioDeviceError.stableWorkerUnavailable("playout")
        }
        guard bridge.setPlayoutActive(true) else {
          throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
            direction: "playout",
            active: true
          )
        }
        do {
          try output.start(operation: "start AUHAL output", timeout: 2)
        } catch {
          if !output.isRunning {
            _ = bridge.setPlayoutActive(false)
          }
          throw error
        }
        state.lastControlFailure = nil
      }
      physicalStarted = true
    } catch {
      recordControlFailure(String(describing: error))
      physicalStarted = false
    }
    if !physicalStarted {
      let bridgeReady = withState { state in
        (state.delegate as? MacGridWebRTCAudioBridge)?.setPlayoutActive(true) == true
      }
      guard bridgeReady else { return false }
    }
    // As with recording, native demand is durable while a physical output is
    // repaired. Returning false here can permanently strand an existing remote
    // stream because WebRTC is not required to retry StartPlayout.
    playing.store(true, ordering: .releasing)
    withState { $0.nativeLifecycleHandler }?(.playoutStarted)
    return true
  }

  func stopPlayout() -> Bool {
    var failures: [String] = []
    withStateMutation { state, _ in
      stopOutputLocked(state: &state, failures: &failures)
      state.lastControlFailure = failures.first
    }
    if failures.isEmpty {
      withState { $0.nativeLifecycleHandler }?(.playoutStopped)
    }
    return failures.isEmpty
  }

  func configureInitialRoutes(
    input: MacGridAudioDevice,
    output: MacGridAudioDevice
  ) throws {
    try Self.validate(input: input, output: output)
    try performOnADMThread { [self] in
      try withStateMutation { state, _ in
        guard state.delegate == nil,
              state.input == nil,
              state.output == nil
        else {
          throw MacGridAUHALAudioDeviceError.initialRoutesAlreadyActive
        }
        state.selectedInput = input
        state.selectedOutput = output
        inputLatencyNanoseconds.store(
          Self.estimatedLatencyNanoseconds(
            device: input,
            direction: .input,
            packetizationLatency: 0.010
          ),
          ordering: .relaxed
        )
        outputLatencyNanoseconds.store(
          Self.estimatedLatencyNanoseconds(
            device: output,
            direction: .output,
            packetizationLatency: Self.playoutBridgeLatency(for: output)
          ),
          ordering: .relaxed
        )
        state.lastControlFailure = nil
      }
    }
  }

  func applyInputRoute(
    _ input: MacGridAudioDevice,
    forceRebuild: Bool = false
  ) throws {
    guard MacGridAudioRouteTransitionPolicy.inputIsUsable(input) else {
      throw MacGridAUHALAudioDeviceError.inputRouteUnavailable
    }
    try performOnADMThread { [self] in
      try withStateMutation { state, notifications in
        try replaceInputLocked(
          with: input,
          force: forceRebuild,
          state: &state,
          notifications: &notifications
        )
        state.lastControlFailure = nil
      }
    }
  }

  func applyOutputRoute(
    _ output: MacGridAudioDevice,
    forceRebuild: Bool = false
  ) throws {
    guard output.hasOutput,
          output.isAlive,
          output.bufferFrameSize > 0,
          let format = output.outputStreamFormat,
          format.sampleRate > 0,
          format.channelCount > 0
    else {
      throw MacGridAUHALAudioDeviceError.outputRouteUnavailable
    }
    try performOnADMThread { [self] in
      try withStateMutation { state, notifications in
        try replaceOutputLocked(
          with: output,
          force: forceRebuild,
          state: &state,
          notifications: &notifications
        )
        state.lastControlFailure = nil
      }
    }
  }

  /// Stops physical playout without clearing WebRTC's playout demand. A later
  /// output-route commit rebuilds and restarts the AUHAL before it can report
  /// healthy again. This turns unstable Bluetooth profile audio into bounded
  /// silence instead of rendering malformed PCM through a changing device.
  func quiesceOutputForRouteTransition() throws {
    try performOnADMThread { [self] in
      try withStateMutation { state, _ in
        do {
          guard let bridge = state.delegate as? MacGridWebRTCAudioBridge else {
            throw MacGridAUHALAudioDeviceError.stableWorkerUnavailable("playout")
          }
          if let output = state.output, output.isRunning {
            try output.stop(operation: "quiesce AUHAL output for route transition")
          }
          guard !bridge.snapshot().playoutWorkerActive
            || bridge.setPlayoutActive(false)
          else {
            throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
              direction: "playout",
              active: false
            )
          }
          state.lastControlFailure = nil
        } catch {
          state.lastControlFailure = String(describing: error)
          throw error
        }
      }
    }
  }

  func resumeAfterTerminalShutdown() {
    terminalShutdown.store(false, ordering: .releasing)
  }

  func stopForTerminalShutdown() -> MacGridAUHALTerminalShutdownReceipt {
    terminalShutdown.store(true, ordering: .releasing)
    let box = MacGridSynchronousResultBox<Void>()
    do {
      try performOnADMThread { [self] in
        var failures: [String] = []
        withStateMutation { state, _ in
          stopInputLocked(state: &state, failures: &failures, clearNativeState: true)
          stopOutputLocked(state: &state, failures: &failures)
          state.lastControlFailure = failures.first
        }
        if failures.isEmpty {
          box.result = .success(())
        } else {
          box.result = .failure(
            MacGridAUHALAudioDeviceError.terminalStopFailed(failures)
          )
        }
      }
    } catch {
      box.result = .failure(error)
    }
    let failures: [String]
    switch box.result {
    case .success:
      failures = []
    case let .failure(error):
      failures = [String(describing: error)]
    case nil:
      failures = ["The terminal AUHAL stop returned no result."]
    }
    return MacGridAUHALTerminalShutdownReceipt(
      snapshot: snapshot(),
      failures: failures
    )
  }

  func snapshot() -> MacGridAUHALAudioDeviceSnapshot {
    let values = withState { state in
      (
        state.selectedInput?.uid,
        state.selectedOutput?.uid,
        state.input,
        state.output,
        state.delegate as? MacGridWebRTCAudioBridge,
        state.lastControlFailure
      )
    }
    // Retain the shallow owners under `stateLock`, then perform Core Audio
    // property readback and bridge telemetry outside it. A slow HAL read must
    // never block a route mutation from committing its ownership ledger.
    let inputHealth = values.2?.health()
    let outputHealth = values.3?.health()
    let bridgeSnapshot = values.4?.snapshot()
    return MacGridAUHALAudioDeviceSnapshot(
      isInitialized: isInitialized,
      isRecordingInitialized: isRecordingInitialized,
      isRecording: isRecording,
      nativeRecordingStartCount: nativeRecordingStartCount.load(ordering: .relaxed),
      nativeRecordingStopCount: nativeRecordingStopCount.load(ordering: .relaxed),
      nativeRecordingDemanded: nativeRecordingDemanded.load(ordering: .acquiring),
      isPlayoutInitialized: isPlayoutInitialized,
      isPlaying: isPlaying,
      selectedInputUID: values.0,
      selectedOutputUID: values.1,
      input: inputHealth,
      output: outputHealth,
      bridge: bridgeSnapshot,
      reportedInputLatencyMilliseconds: UInt16(
        min(
          inputLatencyNanoseconds.load(ordering: .relaxed) / 1_000_000,
          UInt64(UInt16.max)
        )
      ),
      reportedOutputLatencyMilliseconds: UInt16(
        min(
          outputLatencyNanoseconds.load(ordering: .relaxed) / 1_000_000,
          UInt64(UInt16.max)
        )
      ),
      controlMutationInFlight: controlMutationInFlight.load(ordering: .acquiring),
      controlMutationGeneration: controlMutationGeneration.load(ordering: .acquiring),
      terminalShutdownRequested: terminalShutdown.load(ordering: .acquiring),
      lastControlFailure: values.5
    )
  }
}

private extension MacGridAUHALAudioDevice {
  private func replaceInputLocked(
    with device: MacGridAudioDevice,
    force: Bool,
    state: inout State,
    notifications: inout MutationNotifications
  ) throws {
    if !force,
       let selectedSignature = state.selectedInput?.inputRouteSignature,
       selectedSignature == device.inputRouteSignature {
      // Core Audio may update presentation metadata without changing the
      // physical route. Keep the latest catalog record, but do not interrupt
      // a healthy callback thread merely because the display name changed.
      state.selectedInput = device
      return
    }
    guard let previous = state.input, let delegate = state.delegate else {
      state.selectedInput = device
      if let bridge = state.delegate as? MacGridWebRTCAudioBridge,
         !Self.configureCaptureBridge(bridge, for: device) {
        throw MacGridAUHALAudioDeviceError.captureFormatUnavailable(
          Self.inputSampleRate(for: device)
        )
      }
      inputLatencyNanoseconds.store(
        UInt64(
          MacGridAUHALLatency.measure(
            device: device,
            direction: .input,
            packetizationLatency: 0.010
          ) * 1_000_000_000
        ),
        ordering: .relaxed
      )
      return
    }

    let replacement = try directionFactory.makeInput(device, delegate)
    let wasRunning = previous.isRunning
    guard let bridge = state.delegate as? MacGridWebRTCAudioBridge else {
      throw MacGridAUHALAudioDeviceError.stableWorkerUnavailable("capture")
    }
    if wasRunning {
      try previous.stop(operation: "stop previous AUHAL microphone")
      if !bridge.setRecordingActive(false) {
        let primaryError = MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
          direction: "capture",
          active: false
        )
        do {
          guard bridge.setRecordingActive(true, forceTransition: true) else {
            throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
              direction: "capture rollback",
              active: true
            )
          }
          try previous.start(operation: "restart previous AUHAL microphone", timeout: 2)
        } catch let rollbackError {
          throw MacGridAUHALAudioDeviceError.routeRollbackFailed(
            direction: "input",
            primary: String(describing: primaryError),
            rollback: String(describing: rollbackError)
          )
        }
        throw primaryError
      }
      do {
        guard Self.configureCaptureBridge(bridge, for: device) else {
          throw MacGridAUHALAudioDeviceError.captureFormatUnavailable(
            Self.inputSampleRate(for: device)
          )
        }
        guard bridge.setRecordingActive(true) else {
          throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
            direction: "capture",
            active: true
          )
        }
        try replacement.start(operation: "start replacement AUHAL microphone", timeout: 2)
      } catch let primaryError {
        if replacement.isRunning {
          do {
            try replacement.stop(operation: "stop failed replacement AUHAL microphone")
          } catch let cleanupError {
            // The new direction still owns hardware. Preserve that physical
            // fact so a higher-level forced rollback or terminal shutdown can
            // retry cleanup; starting the old unit concurrently would create
            // split capture ownership.
            state.input = replacement
            state.selectedInput = device
            inputLatencyNanoseconds.store(
              replacement.latencyNanoseconds,
              ordering: .relaxed
            )
            notifications.inputParametersChanged = true
            throw MacGridAUHALAudioDeviceError.routeRollbackFailed(
              direction: "input",
              primary: String(describing: primaryError),
              rollback: "replacement cleanup: \(String(describing: cleanupError))"
            )
          }
        }
        do {
          guard Self.configureCaptureBridge(bridge, for: previous.device) else {
            throw MacGridAUHALAudioDeviceError.captureFormatUnavailable(
              Self.inputSampleRate(for: previous.device)
            )
          }
          guard bridge.setRecordingActive(true, forceTransition: true) else {
            throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
              direction: "capture rollback",
              active: true
            )
          }
          try previous.start(operation: "restart previous AUHAL microphone", timeout: 2)
        } catch let rollbackError {
          throw MacGridAUHALAudioDeviceError.routeRollbackFailed(
            direction: "input",
            primary: String(describing: primaryError),
            rollback: String(describing: rollbackError)
          )
        }
        throw primaryError
      }
    } else if !Self.configureCaptureBridge(bridge, for: device) {
      throw MacGridAUHALAudioDeviceError.captureFormatUnavailable(
        Self.inputSampleRate(for: device)
      )
    }
    state.input = replacement
    state.selectedInput = device
    inputLatencyNanoseconds.store(replacement.latencyNanoseconds, ordering: .relaxed)
    notifications.inputParametersChanged = true
  }

  private func replaceOutputLocked(
    with device: MacGridAudioDevice,
    force: Bool,
    state: inout State,
    notifications: inout MutationNotifications
  ) throws {
    let playoutDemanded = playing.load(ordering: .acquiring)
    if !force,
       state.output?.isRunning != false || !playoutDemanded,
       let selectedSignature = state.selectedOutput?.outputRouteSignature,
       selectedSignature == device.outputRouteSignature {
      // A name-only catalog refresh is metadata, not a new echo path.
      state.selectedOutput = device
      return
    }
    guard let previous = state.output, let delegate = state.delegate else {
      state.selectedOutput = device
      if let bridge = state.delegate as? MacGridWebRTCAudioBridge {
        Self.configurePlayoutBridge(bridge, for: device)
      }
      outputLatencyNanoseconds.store(
        UInt64(
          MacGridAUHALLatency.measure(
            device: device,
            direction: .output,
            packetizationLatency: Self.playoutBridgeLatency(for: device)
          ) * 1_000_000_000
        ),
        ordering: .relaxed
      )
      return
    }

    let replacement = try directionFactory.makeOutput(device, delegate)
    let wasRunning = previous.isRunning
    let shouldStartReplacement = wasRunning || playoutDemanded
    guard let bridge = state.delegate as? MacGridWebRTCAudioBridge else {
      throw MacGridAUHALAudioDeviceError.stableWorkerUnavailable("playout")
    }
    if wasRunning {
      try previous.stop(operation: "stop previous AUHAL output")
      if !bridge.setPlayoutActive(false) {
        let primaryError = MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
          direction: "playout",
          active: false
        )
        do {
          guard bridge.setPlayoutActive(true, forceTransition: true) else {
            throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
              direction: "playout rollback",
              active: true
            )
          }
          try previous.start(operation: "restart previous AUHAL output", timeout: 2)
        } catch let rollbackError {
          throw MacGridAUHALAudioDeviceError.routeRollbackFailed(
            direction: "output",
            primary: String(describing: primaryError),
            rollback: String(describing: rollbackError)
          )
        }
        throw primaryError
      }
    }
    Self.configurePlayoutBridge(bridge, for: device)
    if shouldStartReplacement {
      do {
        guard bridge.setPlayoutActive(true, forceTransition: !wasRunning) else {
          throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
            direction: "playout",
            active: true
          )
        }
        try replacement.start(operation: "start replacement AUHAL output", timeout: 2)
      } catch let primaryError {
        if replacement.isRunning {
          do {
            try replacement.stop(operation: "stop failed replacement AUHAL output")
          } catch let cleanupError {
            state.output = replacement
            state.selectedOutput = device
            outputLatencyNanoseconds.store(
              Self.outputLatencyNanoseconds(
                physicalLatencyNanoseconds: replacement.latencyNanoseconds,
                device: device
              ),
              ordering: .relaxed
            )
            notifications.outputParametersChanged = true
            throw MacGridAUHALAudioDeviceError.routeRollbackFailed(
              direction: "output",
              primary: String(describing: primaryError),
              rollback: "replacement cleanup: \(String(describing: cleanupError))"
            )
          }
        }
        do {
          Self.configurePlayoutBridge(bridge, for: previous.device)
          guard bridge.setPlayoutActive(true, forceTransition: true) else {
            throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
              direction: "playout rollback",
              active: true
            )
          }
          try previous.start(operation: "restart previous AUHAL output", timeout: 2)
        } catch let rollbackError {
          throw MacGridAUHALAudioDeviceError.routeRollbackFailed(
            direction: "output",
            primary: String(describing: primaryError),
            rollback: String(describing: rollbackError)
          )
        }
        throw primaryError
      }
    }
    state.output = replacement
    state.selectedOutput = device
    outputLatencyNanoseconds.store(
      Self.outputLatencyNanoseconds(
        physicalLatencyNanoseconds: replacement.latencyNanoseconds,
        device: device
      ),
      ordering: .relaxed
    )
    notifications.outputParametersChanged = true
  }

  private func stopInputLocked(
    state: inout State,
    failures: inout [String],
    clearNativeState: Bool
  ) {
    guard let input = state.input else {
      if clearNativeState {
        recording.store(false, ordering: .releasing)
      }
      recordingInitialized.store(false, ordering: .releasing)
      return
    }
    do {
      try input.stop(operation: "stop AUHAL microphone")
      if let bridge = state.delegate as? MacGridWebRTCAudioBridge,
         !bridge.setRecordingActive(false) {
        throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
          direction: "capture",
          active: false
        )
      }
      state.input = nil
      if clearNativeState {
        recording.store(false, ordering: .releasing)
      }
      recordingInitialized.store(false, ordering: .releasing)
    } catch {
      failures.append("recording: \(String(describing: error))")
      // The direction reports running until Core Audio acknowledges its stop.
      // Retain it and every ownership flag so cleanup remains retryable.
      recording.store(
        nativeRecordingDemanded.load(ordering: .acquiring),
        ordering: .releasing
      )
      recordingInitialized.store(true, ordering: .releasing)
    }
  }

  private func stopOutputLocked(state: inout State, failures: inout [String]) {
    guard let output = state.output else {
      playing.store(false, ordering: .releasing)
      playoutInitialized.store(false, ordering: .releasing)
      return
    }
    do {
      try output.stop(operation: "stop AUHAL output")
      if let bridge = state.delegate as? MacGridWebRTCAudioBridge,
         !bridge.setPlayoutActive(false) {
        throw MacGridAUHALAudioDeviceError.stableWorkerTransitionTimedOut(
          direction: "playout",
          active: false
        )
      }
      state.output = nil
      playing.store(false, ordering: .releasing)
      playoutInitialized.store(false, ordering: .releasing)
    } catch {
      failures.append("playout: \(String(describing: error))")
      playing.store(true, ordering: .releasing)
      playoutInitialized.store(true, ordering: .releasing)
    }
  }

  private func performOnADMThread(_ body: @escaping @Sendable () throws -> Void) throws {
    mutationLock.lock()
    let delegate = withState { $0.delegate }
    mutationLock.unlock()
    guard let delegate else {
      try body()
      return
    }
    let box = MacGridSynchronousResultBox<Void>()
    delegate.dispatchSync {
      do {
        try body()
        box.result = .success(())
      } catch {
        box.result = .failure(error)
      }
    }
    guard let result = box.result else {
      throw MacGridAUHALAudioDeviceError.admDispatchReturnedNoResult
    }
    try result.get()
  }

  private func recordControlFailure(_ failure: String) {
    withStateMutation { state, _ in
      state.lastControlFailure = failure
    }
  }

  /// Runs one lifecycle/route transaction at a time while keeping `stateLock`
  /// available to snapshots. `State` is a shallow ownership ledger: the local
  /// copy continues to reference the live directions while Core Audio waits,
  /// then commits the truthful resulting owner on either success or failure.
  /// The lifecycle handler is independently replaceable and therefore merged
  /// from the latest committed state. Delegate notifications run only after
  /// both locks are released so synchronous readback cannot deadlock.
  private func withStateMutation<Value>(
    _ body: (
      inout State,
      inout MutationNotifications
    ) throws -> Value
  ) rethrows -> Value {
    mutationLock.lock()
    let generation = controlMutationGeneration.load(ordering: .relaxed) &+ 1
    controlMutationGeneration.store(generation, ordering: .releasing)
    controlMutationInFlight.store(true, ordering: .releasing)

    var workingState = withState { $0 }
    var notifications = MutationNotifications()
    do {
      let value = try body(&workingState, &notifications)
      commitMutationState(&workingState)
      controlMutationInFlight.store(false, ordering: .releasing)
      mutationLock.unlock()
      notifications.deliver(to: workingState.delegate)
      return value
    } catch {
      // Route rollback failures deliberately mutate the ownership ledger. The
      // failed transaction must publish that retained owner before propagating.
      commitMutationState(&workingState)
      controlMutationInFlight.store(false, ordering: .releasing)
      mutationLock.unlock()
      notifications.deliver(to: workingState.delegate)
      throw error
    }
  }

  private func commitMutationState(_ workingState: inout State) {
    withState { currentState in
      workingState.nativeLifecycleHandler = currentState.nativeLifecycleHandler
      currentState = workingState
    }
  }

  private func withState<Value>(_ body: (inout State) throws -> Value) rethrows -> Value {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try body(&state)
  }

  static func validate(
    input: MacGridAudioDevice,
    output: MacGridAudioDevice
  ) throws {
    guard MacGridAudioRouteTransitionPolicy.inputIsUsable(input) else {
      throw MacGridAUHALAudioDeviceError.inputRouteUnavailable
    }
    guard output.hasOutput,
          output.isAlive,
          output.bufferFrameSize > 0,
          let format = output.outputStreamFormat,
          format.sampleRate > 0,
          format.channelCount > 0
    else {
      throw MacGridAUHALAudioDeviceError.outputRouteUnavailable
    }
  }

  static func estimatedLatencyNanoseconds(
    device: MacGridAudioDevice,
    direction: MacGridAUHALLatency.Direction,
    packetizationLatency: TimeInterval
  ) -> UInt64 {
    UInt64(
      max(
        MacGridAUHALLatency.measure(
          device: device,
          direction: direction,
          packetizationLatency: packetizationLatency
        ),
        0
      ) * 1_000_000_000
    )
  }

  static func configurePlayoutBridge(
    _ bridge: MacGridWebRTCAudioBridge,
    for device: MacGridAudioDevice
  ) {
    bridge.configurePlayoutTarget(
      deviceBufferFrames: device.bufferFrameSize,
      deviceSampleRate: outputSampleRate(for: device)
    )
  }

  static func configureCaptureBridge(
    _ bridge: MacGridWebRTCAudioBridge,
    for device: MacGridAudioDevice
  ) -> Bool {
    bridge.configureCaptureFormat(
      nativeSampleRate: inputSampleRate(for: device)
    )
  }

  static func playoutBridgeLatency(for device: MacGridAudioDevice) -> TimeInterval {
    TimeInterval(
      MacGridWebRTCAudioBridge.playoutQueueLatencyNanoseconds(
        deviceBufferFrames: device.bufferFrameSize,
        deviceSampleRate: outputSampleRate(for: device)
      )
    ) / 1_000_000_000
  }

  static func outputLatencyNanoseconds(
    physicalLatencyNanoseconds: UInt64,
    device: MacGridAudioDevice
  ) -> UInt64 {
    physicalLatencyNanoseconds &+ MacGridWebRTCAudioBridge.playoutQueueLatencyNanoseconds(
      deviceBufferFrames: device.bufferFrameSize,
      deviceSampleRate: outputSampleRate(for: device)
    )
  }

  static func outputSampleRate(for device: MacGridAudioDevice) -> Double {
    device.outputStreamFormat?.sampleRate ?? device.sampleRate
  }

  static func inputSampleRate(for device: MacGridAudioDevice) -> Double {
    device.inputStreamFormat?.sampleRate ?? device.sampleRate
  }
}

private final class MacGridSynchronousResultBox<Value>: @unchecked Sendable {
  var result: Result<Value, Error>?
}

enum MacGridAUHALAudioDeviceError: LocalizedError, Sendable {
  case notInitialized
  case initialRoutesAlreadyActive
  case inputRouteUnavailable
  case outputRouteUnavailable
  case captureFormatUnavailable(Double)
  case recordingNotInitialized
  case playoutNotInitialized
  case controlPlaneRecordingFailed(String)
  case nativeRecordingDemandUnavailable
  case stableWorkerUnavailable(String)
  case stableWorkerTransitionTimedOut(direction: String, active: Bool)
  case admDispatchReturnedNoResult
  case routeRollbackFailed(direction: String, primary: String, rollback: String)
  case terminalStopFailed([String])

  var errorDescription: String? {
    switch self {
    case .notInitialized:
      "The custom WebRTC audio device is not initialized."
    case .initialRoutesAlreadyActive:
      "Initial AUHAL routes must be configured before WebRTC initializes the device."
    case .inputRouteUnavailable:
      "No usable AUHAL microphone route is available."
    case .outputRouteUnavailable:
      "No usable AUHAL output route is available."
    case let .captureFormatUnavailable(sampleRate):
      "The stable capture worker rejected the native input rate \(sampleRate)."
    case .recordingNotInitialized:
      "The AUHAL microphone was not initialized before start."
    case .playoutNotInitialized:
      "The AUHAL output was not initialized before start."
    case let .controlPlaneRecordingFailed(failure):
      "The AUHAL control-plane recording mutation failed: \(failure)"
    case .nativeRecordingDemandUnavailable:
      "Physical AUHAL recording cannot be controlled without WebRTC microphone-sender demand."
    case let .stableWorkerUnavailable(direction):
      "The stable WebRTC \(direction) worker is unavailable."
    case let .stableWorkerTransitionTimedOut(direction, active):
      "The stable WebRTC \(direction) worker timed out while setting active=\(active)."
    case .admDispatchReturnedNoResult:
      "The WebRTC audio-device thread returned without completing the AUHAL mutation."
    case let .routeRollbackFailed(direction, primary, rollback):
      "The \(direction) route failed (\(primary)) and rollback failed (\(rollback))."
    case let .terminalStopFailed(failures):
      "Terminal AUHAL shutdown failed: \(failures.joined(separator: ", "))"
    }
  }
}
#endif
