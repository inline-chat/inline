#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation
import LiveKit
import Testing

@testable import InlineRTC

@Suite("Mac Grid custom AUHAL audio device")
struct MacGridAUHALAudioDeviceTests {
  @Test("fresh contiguous host time recovers from lifetime timestamp anomalies")
  func captureHealthUsesRollingHostTimeEvidence() {
    let device = inputDevice(uid: "input-1")
    let valid = directionHealth(device: device)
    let missing = directionHealth(
      device: device,
      hostTimestampCallbackCount: 9,
      hostTimestampMissingCount: 1
    )
    let regressing = directionHealth(
      device: device,
      hostTimestampRegressionCount: 1
    )
    let discontinuous = directionHealth(
      device: device,
      packetizerTimestampDiscontinuityCount: 1
    )
    let notYetRecovered = directionHealth(
      device: device,
      packetizerTimestampDiscontinuityCount: 1,
      packetizerContinuousFrameCount: 240
    )

    #expect(valid.hasContinuousPhysicalHostTime)
    #expect(missing.hasContinuousPhysicalHostTime)
    #expect(regressing.hasContinuousPhysicalHostTime)
    #expect(discontinuous.hasContinuousPhysicalHostTime)
    #expect(!notYetRecovered.hasContinuousPhysicalHostTime)
  }

  @Test("playout health rejects WebRTC's output-silence gate")
  func playoutHealthRejectsNativeSilenceGate() {
    let device = outputDevice(uid: "output-1")
    let active = directionHealth(
      device: device,
      latestOutputCallbackWasSilence: false
    )
    let gated = directionHealth(
      device: device,
      latestOutputCallbackWasSilence: true
    )

    #expect(active.hasActivePlayoutCallbacks)
    #expect(!gated.hasActivePlayoutCallbacks)
  }

  @Test("initial routes and WebRTC initialization are single-owner operations")
  func initialRoutesAndInitializationAreSingleOwnerOperations() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)

    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1")
    )

    #expect(device.initialize(delegate: delegate))
    #expect(!device.initialize(delegate: delegate))
    #expect(delegate.inputParameterChangeCount == 1)
    #expect(delegate.outputParameterChangeCount == 1)
    #expect(throws: MacGridAUHALAudioDeviceError.self) {
      try device.configureInitialRoutes(
        input: inputDevice(uid: "input-2"),
        output: outputDevice(uid: "output-2")
      )
    }
  }

  @Test("snapshots remain available during a slow Core Audio mutation")
  func snapshotsDoNotWaitForPhysicalStart() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1")
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializeRecording())

    let startEntered = DispatchSemaphore(value: 0)
    let allowStart = DispatchSemaphore(value: 0)
    let startFinished = DispatchSemaphore(value: 0)
    let lifecycleObserved = DispatchSemaphore(value: 0)
    harness.inputs[0].blockNextStart(
      entered: startEntered,
      release: allowStart
    )
    defer { allowStart.signal() }

    DispatchQueue.global(qos: .userInitiated).async {
      _ = device.startRecording()
      startFinished.signal()
    }
    try #require(startEntered.wait(timeout: .now() + 1) == .success)
    device.setNativeLifecycleHandler { event in
      if case .recordingStarted = event {
        lifecycleObserved.signal()
      }
    }

    let snapshotFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      _ = device.snapshot()
      snapshotFinished.signal()
    }
    try #require(snapshotFinished.wait(timeout: .now() + 0.2) == .success)

    let duringStart = device.snapshot()
    #expect(duringStart.controlMutationInFlight)
    #expect(duringStart.controlMutationGeneration > 0)
    #expect(!duringStart.isRecording)

    allowStart.signal()
    try #require(startFinished.wait(timeout: .now() + 1) == .success)
    try #require(lifecycleObserved.wait(timeout: .now() + 1) == .success)
    let settled = device.snapshot()
    #expect(!settled.controlMutationInFlight)
    #expect(settled.isRecording)
    #expect(settled.input?.isStarted == true)
  }

  @Test("route notifications expose committed physical and bridge latency")
  func routeNotificationsExposeCommittedLatency() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1", bufferFrameSize: 480)
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializeRecording())
    #expect(device.inputLatency == 0.015)
    #expect(device.initializePlayout())
    // 15 ms physical fake direction + M144-style three-packet bridge target.
    #expect(device.outputLatency == 0.045)

    let notificationObserved = DispatchSemaphore(value: 0)
    delegate.setOutputParameterChangeHandler { [weak device] in
      guard let device else { return }
      #expect(device.snapshot().selectedOutputUID == "output-2")
      // A 2,048-frame physical callback requires a 2,880-frame (60 ms)
      // bridge target, in addition to the direction's measured 15 ms.
      #expect(device.outputLatency == 0.075)
      notificationObserved.signal()
    }

    try device.applyOutputRoute(
      outputDevice(uid: "output-2", bufferFrameSize: 2_048)
    )
    try #require(notificationObserved.wait(timeout: .now() + 1) == .success)
    #expect(device.outputLatency == 0.075)
  }

  @Test("capture worker follows each selected device native sample rate")
  func captureWorkerFollowsNativeInputRate() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "airpods-input", sampleRate: 24_000),
      output: outputDevice(uid: "airpods-output")
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.snapshot().bridge?.captureNativeSampleRate == 24_000)
    #expect(device.initializeRecording())
    #expect(device.startRecording())

    try device.applyInputRoute(
      inputDevice(uid: "usb-input", sampleRate: 44_100)
    )

    let snapshot = device.snapshot()
    #expect(snapshot.selectedInputUID == "usb-input")
    #expect(snapshot.input?.isStarted == true)
    #expect(snapshot.bridge?.captureNativeSampleRate == 44_100)
  }

  @Test("overlapping route requests retain one physical mutation owner")
  func routeMutationsAreSerialized() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = try startedInputDevice(harness: harness, delegate: delegate)
    let firstStartEntered = DispatchSemaphore(value: 0)
    let allowFirstStart = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    let secondFinished = DispatchSemaphore(value: 0)
    let secondInput = inputDevice(uid: "input-2")
    let thirdInput = inputDevice(uid: "input-3")
    harness.blockNextInputStart(
      entered: firstStartEntered,
      release: allowFirstStart
    )
    defer { allowFirstStart.signal() }

    DispatchQueue.global(qos: .userInitiated).async {
      try? device.applyInputRoute(secondInput)
      firstFinished.signal()
    }
    try #require(firstStartEntered.wait(timeout: .now() + 1) == .success)

    DispatchQueue.global(qos: .userInitiated).async {
      try? device.applyInputRoute(thirdInput)
      secondFinished.signal()
    }
    #expect(secondFinished.wait(timeout: .now() + 0.1) == .timedOut)
    #expect(device.snapshot().controlMutationInFlight)

    allowFirstStart.signal()
    try #require(firstFinished.wait(timeout: .now() + 1) == .success)
    try #require(secondFinished.wait(timeout: .now() + 1) == .success)

    let settled = device.snapshot()
    #expect(!settled.controlMutationInFlight)
    #expect(settled.selectedInputUID == "input-3")
    #expect(settled.input?.device.uid == "input-3")
    #expect(harness.events.snapshot().containsSubsequence([
      "stop-input-1",
      "start-input-2",
      "stop-input-2",
      "start-input-3",
    ]))
  }

  @Test("parameter notifications run outside device ownership locks")
  func parameterNotificationsPermitSynchronousReadback() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = try startedInputDevice(harness: harness, delegate: delegate)
    let notificationFinished = DispatchSemaphore(value: 0)
    let routeFinished = DispatchSemaphore(value: 0)
    let replacement = inputDevice(uid: "input-2")
    delegate.setInputParameterChangeHandler { [weak device] in
      _ = device?.snapshot()
      notificationFinished.signal()
    }

    DispatchQueue.global(qos: .userInitiated).async {
      try? device.applyInputRoute(replacement)
      routeFinished.signal()
    }

    try #require(notificationFinished.wait(timeout: .now() + 1) == .success)
    try #require(routeFinished.wait(timeout: .now() + 1) == .success)
    #expect(device.snapshot().selectedInputUID == "input-2")
  }

  @Test("slow physical readback does not retain the device state lock")
  func physicalReadbackRunsOutsideStateLock() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1")
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializeRecording())
    let readbackEntered = DispatchSemaphore(value: 0)
    let releaseReadback = DispatchSemaphore(value: 0)
    let snapshotFinished = DispatchSemaphore(value: 0)
    harness.inputs[0].blockNextHealth(
      entered: readbackEntered,
      release: releaseReadback
    )

    DispatchQueue.global(qos: .userInitiated).async {
      _ = device.snapshot()
      snapshotFinished.signal()
    }
    try #require(readbackEntered.wait(timeout: .now() + 1) == .success)

    let handlerUpdated = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      device.setNativeLifecycleHandler { _ in }
      handlerUpdated.signal()
    }
    #expect(handlerUpdated.wait(timeout: .now() + 1) == .success)

    releaseReadback.signal()
    #expect(snapshotFinished.wait(timeout: .now() + 1) == .success)
  }

  @Test("name-only route metadata changes do not rebuild AUHAL")
  func nameOnlyRouteMetadataChangesDoNotRebuildAUHAL() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1", name: "Old microphone name"),
      output: outputDevice(uid: "output-1", name: "Old speaker name")
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializeRecording())
    #expect(device.startRecording())
    #expect(device.initializePlayout())
    #expect(device.startPlayout())
    let inputParameterChanges = delegate.inputParameterChangeCount
    let outputParameterChanges = delegate.outputParameterChangeCount

    try device.applyInputRoute(
      inputDevice(uid: "input-1", name: "Renamed microphone")
    )
    try device.applyOutputRoute(
      outputDevice(uid: "output-1", name: "Renamed speaker")
    )

    let snapshot = device.snapshot()
    #expect(snapshot.input?.device.name == "Old microphone name")
    #expect(snapshot.output?.device.name == "Old speaker name")
    #expect(snapshot.isRecording)
    #expect(snapshot.isPlaying)
    #expect(harness.inputs.count == 1)
    #expect(harness.outputs.count == 1)
    #expect(delegate.inputParameterChangeCount == inputParameterChanges)
    #expect(delegate.outputParameterChangeCount == outputParameterChanges)
  }

  @Test("failed live input replacement restarts and retains the previous route")
  func failedInputReplacementRollsBack() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = try startedInputDevice(harness: harness, delegate: delegate)
    harness.failNextInputStart()

    #expect(throws: DirectionFailure.self) {
      try device.applyInputRoute(inputDevice(uid: "input-2"))
    }

    let snapshot = device.snapshot()
    #expect(snapshot.selectedInputUID == "input-1")
    #expect(snapshot.isRecording)
    #expect(snapshot.input?.device.uid == "input-1")
    #expect(harness.inputs.count == 2)
    #expect(harness.inputs[0].isRunning)
    #expect(!harness.inputs[1].isRunning)
    #expect(harness.events.snapshot().containsSubsequence([
      "stop-input-1",
      "start-input-2-failed",
      "start-input-1",
    ]))
  }

  @Test("double failure reports route rollback failure without committing the new route")
  func doubleInputFailureIsReported() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = try startedInputDevice(harness: harness, delegate: delegate)
    harness.inputs[0].failNextStart()
    harness.failNextInputStart()

    do {
      try device.applyInputRoute(inputDevice(uid: "input-2"))
      Issue.record("Expected the input replacement and rollback to fail.")
    } catch let error as MacGridAUHALAudioDeviceError {
      guard case let .routeRollbackFailed(direction, _, _) = error else {
        Issue.record("Unexpected AUHAL error: \(error)")
        return
      }
      #expect(direction == "input")
    }

    let snapshot = device.snapshot()
    #expect(snapshot.selectedInputUID == "input-1")
    #expect(snapshot.input?.device.uid == "input-1")
    #expect(!harness.inputs[0].isRunning)
    #expect(!harness.inputs[1].isRunning)
  }

  @Test("failed replacement cleanup retains the actual input owner for terminal retry")
  func failedInputReplacementCleanupRetainsActualOwner() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = try startedInputDevice(harness: harness, delegate: delegate)
    harness.events.removeAll()
    harness.failNextInputStart(
      retainingOwnership: true,
      failCleanupStop: true
    )

    #expect(throws: MacGridAUHALAudioDeviceError.self) {
      try device.applyInputRoute(inputDevice(uid: "input-2"))
    }

    var snapshot = device.snapshot()
    #expect(snapshot.selectedInputUID == "input-2")
    #expect(snapshot.input?.device.uid == "input-2")
    #expect(!harness.inputs[0].isRunning)
    #expect(harness.inputs[1].isRunning)
    #expect(!harness.events.snapshot().contains("start-input-1"))

    var receipt = device.stopForTerminalShutdown()
    snapshot = receipt.snapshot
    #expect(!receipt.isQuiescent)
    #expect(snapshot.nativeRecordingDemanded)
    #expect(!snapshot.isRecording)
    #expect(snapshot.input == nil)
    #expect(!harness.inputs[1].isRunning)
    #expect(device.stopRecording())
    receipt = device.stopForTerminalShutdown()
    #expect(receipt.isQuiescent)
  }

  @Test("terminal shutdown drains both stable directions and gates later starts")
  func terminalShutdownIsTruthfulBarrier() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1")
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializeRecording())
    #expect(device.startRecording())
    #expect(device.initializePlayout())
    #expect(device.startPlayout())

    harness.events.removeAll()
    var receipt = device.stopForTerminalShutdown()

    #expect(!receipt.isQuiescent)
    #expect(receipt.snapshot.terminalShutdownRequested)
    #expect(!receipt.snapshot.isRecording)
    #expect(receipt.snapshot.nativeRecordingDemanded)
    #expect(!receipt.snapshot.isRecordingInitialized)
    #expect(receipt.snapshot.input == nil)
    #expect(!receipt.snapshot.isPlaying)
    #expect(!receipt.snapshot.isPlayoutInitialized)
    #expect(receipt.snapshot.output == nil)
    #expect(harness.events.snapshot().containsSubsequence([
      "stop-input-1",
      "stop-output-1",
    ]))
    // App-owned terminal stop can release physical hardware, but cannot claim
    // native quiescence while WebRTC still owns sender demand. Simulate the
    // subsequent native StopRecording acknowledgement before the final proof.
    #expect(device.stopRecording())
    receipt = device.stopForTerminalShutdown()
    #expect(receipt.isQuiescent)
    #expect(!receipt.snapshot.nativeRecordingDemanded)
    #expect(!device.initializeRecording())
    #expect(device.snapshot().lastControlFailure?.contains("terminal shutdown") == true)

    device.resumeAfterTerminalShutdown()
    #expect(device.initializeRecording())
  }

  @Test("control-plane capture cannot fabricate WebRTC sender demand")
  func controlPlaneCaptureRequiresNativeDemand() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1")
    )
    #expect(device.initialize(delegate: delegate))

    #expect(throws: MacGridAUHALAudioDeviceError.self) {
      try device.startRecordingFromControlPlane()
    }
    #expect(throws: MacGridAUHALAudioDeviceError.self) {
      try device.stopRecordingFromControlPlane()
    }

    let snapshot = device.snapshot()
    #expect(!snapshot.isRecordingInitialized)
    #expect(!snapshot.isRecording)
    #expect(snapshot.nativeRecordingStartCount == 0)
    #expect(!snapshot.nativeRecordingDemanded)
    #expect(snapshot.input == nil)
    #expect(harness.inputs.isEmpty)
  }

  @Test("control plane can restart physical capture beneath open WebRTC demand")
  func controlPlaneCaptureRestartsPhysicalDeviceUnderNativeDemand() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1")
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializeRecording())
    #expect(device.startRecording())

    var snapshot = device.snapshot()
    #expect(snapshot.nativeRecordingStartCount == 1)
    #expect(snapshot.nativeRecordingDemanded)
    #expect(harness.inputs.count == 1)

    try device.stopRecordingFromControlPlane()
    try device.stopRecordingFromControlPlane()

    snapshot = device.snapshot()
    #expect(!snapshot.isRecordingInitialized)
    #expect(snapshot.isRecording)
    #expect(snapshot.nativeRecordingStopCount == 0)
    #expect(snapshot.nativeRecordingDemanded)
    #expect(snapshot.input == nil)

    try device.startRecordingFromControlPlane()
    try device.startRecordingFromControlPlane()

    snapshot = device.snapshot()
    #expect(snapshot.isRecordingInitialized)
    #expect(snapshot.isRecording)
    #expect(snapshot.nativeRecordingStartCount == 1)
    #expect(snapshot.nativeRecordingDemanded)
    #expect(snapshot.input?.hasFreshCallbacks == true)
    #expect(harness.inputs.count == 2)

    #expect(device.stopRecording())
    snapshot = device.snapshot()
    #expect(snapshot.nativeRecordingStopCount == 1)
    #expect(!snapshot.nativeRecordingDemanded)
    #expect(!snapshot.isRecording)
    #expect(throws: MacGridAUHALAudioDeviceError.self) {
      try device.startRecordingFromControlPlane()
    }
  }

  @Test("native recording demand survives a physical start failure")
  func nativeRecordingDemandSurvivesPhysicalStartFailure() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let failedStartDevice = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try failedStartDevice.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1")
    )
    #expect(failedStartDevice.initialize(delegate: delegate))
    #expect(failedStartDevice.initializeRecording())
    harness.inputs[0].failNextStart()

    #expect(failedStartDevice.startRecording())
    var snapshot = failedStartDevice.snapshot()
    #expect(snapshot.nativeRecordingStartCount == 1)
    #expect(snapshot.nativeRecordingDemanded)
    #expect(snapshot.isRecording)
    #expect(snapshot.input?.isStarted == false)
    #expect(snapshot.bridge?.captureWorkerActive == true)

    let startedDevice = try startedInputDevice(harness: harness, delegate: delegate)
    harness.inputs.last?.failNextStop()
    #expect(!startedDevice.stopRecording())
    snapshot = startedDevice.snapshot()
    #expect(snapshot.nativeRecordingStopCount == 1)
    #expect(snapshot.nativeRecordingDemanded)
    #expect(snapshot.isRecording)
    #expect(snapshot.input?.isStarted == true)
  }

  @Test("native playout demand survives a physical start failure")
  func nativePlayoutDemandSurvivesPhysicalStartFailure() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let output = outputDevice(uid: "output-1")
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: output
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializePlayout())
    harness.outputs[0].failNextStart()

    #expect(device.startPlayout())
    var snapshot = device.snapshot()
    #expect(snapshot.isPlaying)
    #expect(snapshot.output?.isStarted == false)
    #expect(snapshot.bridge?.playoutWorkerActive == true)

    try device.applyOutputRoute(output, forceRebuild: true)
    snapshot = device.snapshot()
    #expect(snapshot.isPlaying)
    #expect(snapshot.output?.isStarted == true)
    #expect(harness.outputs.count == 2)
  }

  @Test("terminal stop failure retains physical ownership until retry succeeds")
  func terminalStopFailureRemainsRetryable() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = try startedInputDevice(harness: harness, delegate: delegate)
    harness.inputs[0].failNextStop()

    let failedReceipt = device.stopForTerminalShutdown()

    #expect(!failedReceipt.isQuiescent)
    #expect(failedReceipt.snapshot.isRecording)
    #expect(failedReceipt.snapshot.input?.isStarted == true)
    #expect(!failedReceipt.failures.isEmpty)

    var retryReceipt = device.stopForTerminalShutdown()

    #expect(!retryReceipt.isQuiescent)
    #expect(!retryReceipt.snapshot.isRecording)
    #expect(retryReceipt.snapshot.input == nil)
    #expect(retryReceipt.snapshot.nativeRecordingDemanded)
    #expect(device.stopRecording())
    retryReceipt = device.stopForTerminalShutdown()
    #expect(retryReceipt.isQuiescent)
  }

  @Test("WebRTC termination retains initialization until physical stop succeeds")
  func terminationFailureRemainsRetryable() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = try startedInputDevice(harness: harness, delegate: delegate)
    harness.inputs[0].failNextStop()

    #expect(!device.terminate())
    var snapshot = device.snapshot()
    #expect(snapshot.isInitialized)
    #expect(snapshot.isRecording)
    #expect(snapshot.input?.isStarted == true)

    #expect(device.terminate())
    snapshot = device.snapshot()
    #expect(!snapshot.isInitialized)
    #expect(!snapshot.isRecording)
    #expect(snapshot.input == nil)
    #expect(!snapshot.nativeRecordingDemanded)
    #expect(device.initialize(delegate: delegate))
  }

  @Test("output profile transition becomes silence then restarts the settled route")
  func outputTransitionQuiescesThenRestarts() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let output = outputDevice(uid: "output-1")
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: output
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializePlayout())
    #expect(device.startPlayout())

    harness.events.removeAll()
    try device.quiesceOutputForRouteTransition()
    var snapshot = device.snapshot()
    #expect(snapshot.isPlaying)
    #expect(snapshot.output?.isStarted == false)
    #expect(harness.events.snapshot().containsSubsequence([
      "stop-output-1",
    ]))

    try device.applyOutputRoute(output)
    snapshot = device.snapshot()
    #expect(snapshot.isPlaying)
    #expect(snapshot.output?.isStarted == true)
    #expect(snapshot.output?.hasFreshCallbacks == true)
    #expect(harness.outputs.count == 2)
  }

  @Test("failed settled output restart restores the quiesced route")
  func failedOutputRestartRollsBack() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let output = outputDevice(uid: "output-1")
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: output
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializePlayout())
    #expect(device.startPlayout())
    try device.quiesceOutputForRouteTransition()
    harness.failNextOutputStart()

    #expect(throws: DirectionFailure.self) {
      try device.applyOutputRoute(output)
    }

    let snapshot = device.snapshot()
    #expect(snapshot.selectedOutputUID == "output-1")
    #expect(snapshot.output?.isStarted == true)
    #expect(harness.outputs[0].isRunning)
    #expect(!harness.outputs[1].isRunning)
  }

  @Test("failed replacement cleanup retains the actual output owner for terminal retry")
  func failedOutputReplacementCleanupRetainsActualOwner() throws {
    let harness = DirectionHarness()
    let delegate = DeviceDelegate(events: harness.events)
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1")
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializePlayout())
    #expect(device.startPlayout())
    harness.events.removeAll()
    harness.failNextOutputStart(
      retainingOwnership: true,
      failCleanupStop: true
    )

    #expect(throws: MacGridAUHALAudioDeviceError.self) {
      try device.applyOutputRoute(outputDevice(uid: "output-2"))
    }

    var snapshot = device.snapshot()
    #expect(snapshot.selectedOutputUID == "output-2")
    #expect(snapshot.output?.device.uid == "output-2")
    #expect(!harness.outputs[0].isRunning)
    #expect(harness.outputs[1].isRunning)
    #expect(!harness.events.snapshot().contains("start-output-1"))

    let receipt = device.stopForTerminalShutdown()
    snapshot = receipt.snapshot
    #expect(receipt.isQuiescent)
    #expect(!snapshot.isPlaying)
    #expect(snapshot.output == nil)
    #expect(!harness.outputs[1].isRunning)
  }

  private func startedInputDevice(
    harness: DirectionHarness,
    delegate: DeviceDelegate
  ) throws -> MacGridAUHALAudioDevice {
    let device = MacGridAUHALAudioDevice(directionFactory: harness.factory)
    try device.configureInitialRoutes(
      input: inputDevice(uid: "input-1"),
      output: outputDevice(uid: "output-1")
    )
    #expect(device.initialize(delegate: delegate))
    #expect(device.initializeRecording())
    #expect(device.startRecording())
    return device
  }

  private func inputDevice(
    uid: String,
    name: String? = nil,
    sampleRate: Double = 48_000
  ) -> MacGridAudioDevice {
    device(
      uid: uid,
      name: name,
      hasInput: true,
      hasOutput: false,
      sampleRate: sampleRate
    )
  }

  private func outputDevice(
    uid: String,
    name: String? = nil,
    bufferFrameSize: UInt32 = 480
  ) -> MacGridAudioDevice {
    device(
      uid: uid,
      name: name,
      hasInput: false,
      hasOutput: true,
      bufferFrameSize: bufferFrameSize
    )
  }

  private func device(
    uid: String,
    name: String? = nil,
    hasInput: Bool,
    hasOutput: Bool,
    bufferFrameSize: UInt32 = 480,
    sampleRate: Double = 48_000
  ) -> MacGridAudioDevice {
    let description = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat,
      mBytesPerPacket: 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: 8,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    let format = MacGridAudioStreamFormat(description)
    return MacGridAudioDevice(
      id: hasInput ? 101 : 202,
      uid: uid,
      name: name ?? uid,
      hasInput: hasInput,
      hasOutput: hasOutput,
      sampleRate: sampleRate,
      bufferFrameSize: bufferFrameSize,
      transport: kAudioDeviceTransportTypeBuiltIn,
      inputStreamFormat: hasInput ? format : nil,
      outputStreamFormat: hasOutput ? format : nil
    )
  }
}

private func directionHealth(
  device: MacGridAudioDevice,
  hostTimestampCallbackCount: UInt64 = 10,
  hostTimestampMissingCount: UInt64 = 0,
  hostTimestampRegressionCount: UInt64 = 0,
  packetizerTimestampDiscontinuityCount: UInt64 = 0,
  packetizerContinuousFrameCount: UInt64 = 480,
  latestOutputCallbackWasSilence: Bool? = nil
) -> MacGridAUHALDirectionHealth {
  MacGridAUHALDirectionHealth(
    device: device,
    audioUnitDeviceID: device.id,
    isStarted: true,
    callbackCount: 10,
    frameCount: 4_800,
    lastCallbackFrameCount: 480,
    callbackAgeMilliseconds: 0,
    hostTimestampCallbackCount: hostTimestampCallbackCount,
    hostTimestampMissingCount: hostTimestampMissingCount,
    hostTimestampRegressionCount: hostTimestampRegressionCount,
    latestPhysicalHostTime: 1,
    callbackErrorCount: 0,
    cannotDoInCurrentContextCount: 0,
    parameterErrorCount: 0,
    otherCallbackErrorCount: 0,
    physicalRenderErrorCount: nil,
    physicalCannotDoCount: nil,
    bridgePublicationErrorCount: nil,
    packetizerPendingFrameCount: nil,
    packetizerTimestampDiscontinuityCount: packetizerTimestampDiscontinuityCount,
    packetizerContinuousFrameCount: packetizerContinuousFrameCount,
    outputSilenceFlagCallbackCount: latestOutputCallbackWasSilence == nil ? nil : 0,
    latestOutputCallbackWasSilence: latestOutputCallbackWasSilence,
    latencyMilliseconds: 15,
    lastStatus: noErr
  )
}

private final class DirectionHarness: @unchecked Sendable {
  let events = LockedEvents()
  private let lock = NSLock()
  private var failNextInput = false
  private var retainNextInputOnStartFailure = false
  private var failNextInputCleanupStop = false
  private var nextInputStartGate: (
    entered: DispatchSemaphore,
    release: DispatchSemaphore
  )?
  private var failNextOutput = false
  private var retainNextOutputOnStartFailure = false
  private var failNextOutputCleanupStop = false
  private(set) var inputs: [FakeDirection] = []
  private(set) var outputs: [FakeDirection] = []

  lazy var factory = MacGridAUHALDirectionFactory(
    makeInput: { [self] device, _ in
      lock.withLock {
        let direction = FakeDirection(
          device: device,
          events: events,
          failFirstStart: failNextInput,
          retainOwnershipOnFirstStartFailure: retainNextInputOnStartFailure,
          failFirstStop: failNextInputCleanupStop
        )
        failNextInput = false
        retainNextInputOnStartFailure = false
        failNextInputCleanupStop = false
        if let nextInputStartGate {
          direction.blockNextStart(
            entered: nextInputStartGate.entered,
            release: nextInputStartGate.release
          )
          self.nextInputStartGate = nil
        }
        inputs.append(direction)
        return direction
      }
    },
    makeOutput: { [self] device, _ in
      lock.withLock {
        let direction = FakeDirection(
          device: device,
          events: events,
          failFirstStart: failNextOutput,
          retainOwnershipOnFirstStartFailure: retainNextOutputOnStartFailure,
          failFirstStop: failNextOutputCleanupStop
        )
        failNextOutput = false
        retainNextOutputOnStartFailure = false
        failNextOutputCleanupStop = false
        outputs.append(direction)
        return direction
      }
    }
  )

  func failNextInputStart(
    retainingOwnership: Bool = false,
    failCleanupStop: Bool = false
  ) {
    lock.withLock {
      failNextInput = true
      retainNextInputOnStartFailure = retainingOwnership
      failNextInputCleanupStop = failCleanupStop
    }
  }

  func blockNextInputStart(
    entered: DispatchSemaphore,
    release: DispatchSemaphore
  ) {
    lock.withLock {
      nextInputStartGate = (entered, release)
    }
  }

  func failNextOutputStart(
    retainingOwnership: Bool = false,
    failCleanupStop: Bool = false
  ) {
    lock.withLock {
      failNextOutput = true
      retainNextOutputOnStartFailure = retainingOwnership
      failNextOutputCleanupStop = failCleanupStop
    }
  }
}

private final class FakeDirection: MacGridAUHALDirectionControlling, @unchecked Sendable {
  let device: MacGridAudioDevice
  let latencyNanoseconds: UInt64 = 15_000_000

  private let events: LockedEvents
  private let lock = NSLock()
  private var running = false
  private var startFailuresRemaining: Int
  private var retainOwnershipOnStartFailure: Bool
  private var stopFailuresRemaining: Int
  private var nextStartGate: (
    entered: DispatchSemaphore,
    release: DispatchSemaphore
  )?
  private var nextHealthGate: (
    entered: DispatchSemaphore,
    release: DispatchSemaphore
  )?

  init(
    device: MacGridAudioDevice,
    events: LockedEvents,
    failFirstStart: Bool = false,
    retainOwnershipOnFirstStartFailure: Bool = false,
    failFirstStop: Bool = false
  ) {
    self.device = device
    self.events = events
    startFailuresRemaining = failFirstStart ? 1 : 0
    retainOwnershipOnStartFailure = retainOwnershipOnFirstStartFailure
    stopFailuresRemaining = failFirstStop ? 1 : 0
  }

  var isRunning: Bool { lock.withLock { running } }

  func failNextStart() {
    lock.withLock { startFailuresRemaining += 1 }
  }

  func failNextStop() {
    lock.withLock { stopFailuresRemaining += 1 }
  }

  func blockNextStart(
    entered: DispatchSemaphore,
    release: DispatchSemaphore
  ) {
    lock.withLock {
      nextStartGate = (entered, release)
    }
  }

  func blockNextHealth(
    entered: DispatchSemaphore,
    release: DispatchSemaphore
  ) {
    lock.withLock {
      nextHealthGate = (entered, release)
    }
  }

  func start(operation _: String, timeout _: TimeInterval) throws {
    let gate = lock.withLock {
      let gate = nextStartGate
      nextStartGate = nil
      return gate
    }
    if let gate {
      gate.entered.signal()
      guard gate.release.wait(timeout: .now() + 2) == .success else {
        throw DirectionFailure.start(device.uid)
      }
    }
    try lock.withLock {
      if startFailuresRemaining > 0 {
        startFailuresRemaining -= 1
        if retainOwnershipOnStartFailure {
          running = true
          retainOwnershipOnStartFailure = false
        }
        events.append("start-\(device.uid)-failed")
        throw DirectionFailure.start(device.uid)
      }
      running = true
      events.append("start-\(device.uid)")
    }
  }

  func stop(operation _: String) throws {
    try lock.withLock {
      if stopFailuresRemaining > 0 {
        stopFailuresRemaining -= 1
        events.append("stop-\(device.uid)-failed")
        throw DirectionFailure.stop(device.uid)
      }
      running = false
      events.append("stop-\(device.uid)")
    }
  }

  func health() -> MacGridAUHALDirectionHealth {
    let gate = lock.withLock {
      let gate = nextHealthGate
      nextHealthGate = nil
      return gate
    }
    if let gate {
      gate.entered.signal()
      _ = gate.release.wait(timeout: .now() + 2)
    }
    return MacGridAUHALDirectionHealth(
      device: device,
      audioUnitDeviceID: device.id,
      isStarted: isRunning,
      callbackCount: isRunning ? 1 : 0,
      frameCount: isRunning ? 480 : 0,
      lastCallbackFrameCount: isRunning ? 480 : 0,
      callbackAgeMilliseconds: isRunning ? 0 : nil,
      hostTimestampCallbackCount: isRunning ? 1 : 0,
      hostTimestampMissingCount: 0,
      hostTimestampRegressionCount: 0,
      latestPhysicalHostTime: isRunning ? 1 : nil,
      callbackErrorCount: 0,
      cannotDoInCurrentContextCount: 0,
      parameterErrorCount: 0,
      otherCallbackErrorCount: 0,
      physicalRenderErrorCount: nil,
      physicalCannotDoCount: nil,
      bridgePublicationErrorCount: nil,
      packetizerPendingFrameCount: nil,
      packetizerTimestampDiscontinuityCount: nil,
      packetizerContinuousFrameCount: nil,
      outputSilenceFlagCallbackCount: nil,
      latestOutputCallbackWasSilence: nil,
      latencyMilliseconds: 15,
      lastStatus: noErr
    )
  }
}

private enum DirectionFailure: Error {
  case start(String)
  case stop(String)
}

private final class DeviceDelegate: CustomAudioDeviceDelegate, @unchecked Sendable {
  let preferredInputSampleRate = 48_000.0
  let preferredInputIOBufferDuration: TimeInterval = 0.010
  let preferredOutputSampleRate = 48_000.0
  let preferredOutputIOBufferDuration: TimeInterval = 0.010

  private let events: LockedEvents
  private let lock = NSLock()
  private(set) var inputParameterChangeCount = 0
  private(set) var outputParameterChangeCount = 0
  private var inputParameterChangeHandler: (@Sendable () -> Void)?
  private var outputParameterChangeHandler: (@Sendable () -> Void)?

  init(events: LockedEvents) {
    self.events = events
  }

  func getPlayoutData(
    _: CustomAudioDeviceIOContext,
    outputData _: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus { noErr }

  func deliverRecordedData(_: CustomAudioDeviceRecordedData) -> OSStatus { noErr }

  func notifyAudioInputParametersChange() {
    let handler = lock.withLock {
      inputParameterChangeCount += 1
      return inputParameterChangeHandler
    }
    events.append("notify-input-parameters")
    handler?()
  }

  func notifyAudioOutputParametersChange() {
    let handler = lock.withLock {
      outputParameterChangeCount += 1
      return outputParameterChangeHandler
    }
    events.append("notify-output-parameters")
    handler?()
  }

  func notifyAudioInputInterrupted() {
    events.append("notify-input-interrupted")
  }

  func notifyAudioOutputInterrupted() {
    events.append("notify-output-interrupted")
  }

  func dispatchAsync(_ block: @escaping @Sendable () -> Void) { block() }
  func dispatchSync(_ block: @escaping @Sendable () -> Void) { block() }

  func setInputParameterChangeHandler(_ handler: @escaping @Sendable () -> Void) {
    lock.withLock {
      inputParameterChangeHandler = handler
    }
  }

  func setOutputParameterChangeHandler(_ handler: @escaping @Sendable () -> Void) {
    lock.withLock {
      outputParameterChangeHandler = handler
    }
  }
}

private final class LockedEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []

  func append(_ event: String) {
    lock.withLock { events.append(event) }
  }

  func snapshot() -> [String] {
    lock.withLock { events }
  }

  func removeAll() {
    lock.withLock { events.removeAll() }
  }
}

private extension Array where Element: Equatable {
  func containsSubsequence(_ expected: [Element]) -> Bool {
    var candidate = makeIterator()
    for expectedElement in expected {
      var found = false
      while let candidateElement = candidate.next() {
        if candidateElement == expectedElement {
          found = true
          break
        }
      }
      if !found { return false }
    }
    return true
  }
}
#endif
