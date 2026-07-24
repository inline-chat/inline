import Foundation
import Testing

@testable import InlineRTC

@Suite("Grid audio engine", .serialized)
struct GridAudioEngineTests {
  @Test("permission gates the physical input transaction")
  func permissionGatesInputRoute() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(
        current: .notDetermined,
        requested: .authorized
      )
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually {
      await engine.currentSnapshot().state == .waitingForPermission
    }
    var operations = await driver.operations()
    #expect(!operations.contains("input:automatic"))
    #expect(!operations.contains("prepared:true"))

    await engine.requestMicrophonePermission()
    try await eventually { await engine.currentSnapshot().state == .ready }
    operations = await driver.operations()
    #expect(operations.filter { $0 == "input:automatic" }.count == 1)
    #expect(operations.filter { $0 == "prepared:true" }.count == 1)
  }

  @Test("denied permission never opens the physical microphone route")
  func deniedPermissionDoesNotTouchInputRoute() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(
        current: .denied,
        requested: .denied
      )
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .permissionDenied }

    let operations = await driver.operations()
    #expect(!operations.contains("input:automatic"))
    #expect(!operations.contains("prepared:true"))
    #expect(!(await driver.runtimeHealth()).isRecording)
  }

  @Test("permission revocation actively releases prepared capture")
  func revokedPermissionStopsPreparedCapture() async throws {
    let permission = BlockingGridMicrophonePermissionDriver()
    await permission.resolve(.authorized)
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: permission
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }

    await permission.resolve(.denied)
    await engine.retry()

    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .permissionDenied && !snapshot.isPrepared
    }
    #expect(await driver.operations().contains("prepared:false"))
    #expect(!(await driver.runtimeHealth()).isRecording)
  }

  @Test("capture remains warm through grace and then stops")
  func captureCooldown() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(60)
    )
    let target = InlineRTCSessionID("grid-test:1:2:3")
    let lease = GridAudioLease.connectionDemand(target)

    await engine.start()
    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .ready && snapshot.isPrepared
    }

    await engine.releaseCaptureLease(lease)
    let coolingSnapshot = await engine.currentSnapshot()
    #expect(coolingSnapshot.state == .coolingDown)
    #expect(coolingSnapshot.isPrepared)

    try await Task.sleep(for: .milliseconds(25))
    #expect(await engine.currentSnapshot().isPrepared)

    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .cold && snapshot.isPrepared == false
    }
    #expect(await driver.operations().filter { $0 == "prepared:true" }.count == 1)
    #expect(await driver.operations().filter { $0 == "prepared:false" }.count == 1)
  }

  @Test("terminal shutdown bypasses capture cooldown")
  func shutdownBypassesCooldown() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .seconds(30)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    let receipt = await engine.shutdown()

    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.state == .cold)
    #expect(snapshot.isPrepared == false)
    #expect(snapshot.captureLeaseCount == 0)
    #expect(receipt.isQuiescent)
    #expect(await driver.operations().filter { $0 == "prepared:false" }.count == 1)
  }

  @Test("a throwing prepare that started capture retains a shutdown obligation")
  func partialPrepareFailureUsesObservedCaptureState() async throws {
    let driver = FakeGridAudioDriver(prepareFailuresAfterMutation: [true: 1])
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .failed("prepare failed") }

    let failedSnapshot = await engine.currentSnapshot()
    #expect(failedSnapshot.isRecording)
    #expect(failedSnapshot.isPrepared)

    let receipt = await engine.shutdown()
    #expect(receipt.isQuiescent)
    let shutdownHealth = await driver.runtimeHealth()
    #expect(!shutdownHealth.isRecording)
  }

  @Test("a throwing stop that released capture clears stale prepared state")
  func partialStopFailureUsesObservedCaptureState() async throws {
    let driver = FakeGridAudioDriver(prepareFailuresAfterMutation: [false: 1])
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .zero
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await engine.releaseCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .failed("prepare failed") }

    let failedSnapshot = await engine.currentSnapshot()
    #expect(!failedSnapshot.isRecording)
    #expect(!failedSnapshot.isPrepared)
  }

  @Test("terminal shutdown waits for an in-flight native mutation")
  func shutdownWaitsForMutationOwnership() async throws {
    let driver = FakeGridAudioDriver(blockConfigure: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      shutdownTimeout: .seconds(1)
    )

    await engine.start()
    try await eventually { await driver.operations().contains("configure") }
    let shutdown = Task { await engine.shutdown() }
    try await Task.sleep(for: .milliseconds(30))
    let mutationSnapshot = await engine.currentSnapshot()
    #expect(mutationSnapshot.state == .stopping)
    #expect(mutationSnapshot.currentMutationKind == "configure")
    #expect((mutationSnapshot.currentMutationMilliseconds ?? -1) >= 0)

    await driver.releaseConfigure()
    let receipt = await shutdown.value
    #expect(receipt.isQuiescent)
    #expect(receipt.mutationReleased)
  }

  @Test("terminal shutdown waits for an in-flight input route mutation")
  func shutdownWaitsForInputMutationOwnership() async throws {
    let driver = FakeGridAudioDriver(blockInputDeviceID: "usb")
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      shutdownTimeout: .seconds(1)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))
    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().contains("input:usb") }
    let shutdown = Task { await engine.shutdown() }
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .stopping && snapshot.currentMutationKind == "input"
    }

    await driver.releaseInput()
    let receipt = await shutdown.value
    #expect(receipt.isQuiescent)
    #expect(receipt.mutationReleased)
  }

  @Test("terminal shutdown waits for in-flight capture preparation")
  func shutdownWaitsForPrepareMutationOwnership() async throws {
    let driver = FakeGridAudioDriver(blockPrepare: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      shutdownTimeout: .seconds(1)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().contains("prepared:true") }
    let shutdown = Task { await engine.shutdown() }
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .stopping && snapshot.currentMutationKind == "prepare"
    }

    await driver.releasePrepare()
    let receipt = await shutdown.value
    #expect(receipt.isQuiescent)
    #expect(receipt.mutationReleased)
  }

  @Test("terminal shutdown waits for in-flight capture recovery")
  func shutdownWaitsForRecoveryMutationOwnership() async throws {
    let driver = FakeGridAudioDriver(blockRecovery: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .zero,
      shutdownTimeout: .seconds(1)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }
    await driver.emit(.engineStopped(playout: true, recording: true))
    try await eventually { await driver.operations().contains("recover") }
    let shutdown = Task { await engine.shutdown() }
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .stopping && snapshot.currentMutationKind == "recover"
    }

    await driver.releaseRecovery()
    let receipt = await shutdown.value
    #expect(receipt.isQuiescent)
    #expect(receipt.mutationReleased)
  }

  @Test("terminal shutdown waits for in-flight directional playout recovery")
  func shutdownWaitsForPlayoutRecoveryMutationOwnership() async throws {
    let driver = FakeGridAudioDriver(blockPlayoutRecovery: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      shutdownTimeout: .seconds(1)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }
    await driver.setPlayingActive(false)
    let playoutRecovery = Task { await engine.decodedRemoteAudioObserved() }
    try await eventually { await driver.operations().contains("recover-playout") }
    let shutdown = Task { await engine.shutdown() }
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .stopping && snapshot.currentMutationKind == "recover-playout"
    }

    await driver.releasePlayoutRecovery()
    _ = await playoutRecovery.value
    let receipt = await shutdown.value
    #expect(receipt.isQuiescent)
    #expect(receipt.mutationReleased)
  }

  @Test("terminal shutdown returns typed failure when mutation ownership does not release")
  func shutdownMutationTimeoutIsNotSuccess() async throws {
    let driver = FakeGridAudioDriver(blockConfigure: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      shutdownTimeout: .milliseconds(40)
    )

    await engine.start()
    try await eventually { await driver.operations().contains("configure") }
    let receipt = await engine.shutdown()
    #expect(!receipt.isQuiescent)
    #expect(!receipt.mutationReleased)
    #expect(!receipt.failures.isEmpty)
    let mutationSnapshot = await engine.currentSnapshot()
    #expect(mutationSnapshot.currentMutationKind == "configure")
    #expect(mutationSnapshot.currentMutationMilliseconds != nil)
    await driver.releaseConfigure()
  }

  @Test("a timed-out shutdown eventually stops capture started by a late route mutation")
  func shutdownTimeoutRetainsLateRouteStopObligation() async throws {
    let driver = FakeGridAudioDriver(
      blockInputDeviceID: "usb",
      inputMutationStartsRecording: true
    )
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      shutdownTimeout: .milliseconds(40)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))
    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().contains("input:usb") }

    let timedOutReceipt = await engine.shutdown()
    #expect(!timedOutReceipt.isQuiescent)
    #expect(!timedOutReceipt.mutationReleased)

    await driver.releaseInput()
    try await eventually {
      let health = await driver.runtimeHealth()
      let operations = await driver.operations()
      return operations.contains("prepared:false")
        && !health.isRecording
        && !health.isPlaying
    }
    let eventualSnapshot = await engine.currentSnapshot()
    #expect(eventualSnapshot.state == .cold)
    #expect(!eventualSnapshot.isPrepared)

    let confirmedReceipt = await engine.shutdown()
    #expect(confirmedReceipt.isQuiescent)
    #expect(confirmedReceipt.mutationReleased)
  }

  @Test("new capture demand resumes after timed-out shutdown cleanup")
  func newDemandResumesAfterEventualShutdownCleanup() async throws {
    let driver = FakeGridAudioDriver(blockConfigure: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      shutdownTimeout: .milliseconds(40)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:2"))

    await engine.start()
    try await eventually { await driver.operations().contains("configure") }
    let timedOutReceipt = await engine.shutdown()
    #expect(!timedOutReceipt.isQuiescent)

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    await driver.releaseConfigure()

    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.captureLeaseCount == 1
        && snapshot.state == .ready
        && snapshot.isPrepared
    }
    let operations = await driver.operations()
    #expect(operations.contains("prepared:false"))
    #expect(operations.contains("input:automatic"))
    #expect(operations.contains("prepared:true"))
  }

  @Test("a timed-out shutdown eventually stops late playout without capture demand")
  func shutdownTimeoutRetainsLatePlayoutStopObligation() async throws {
    let driver = FakeGridAudioDriver(blockPlayoutRecovery: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      shutdownTimeout: .milliseconds(40)
    )

    await engine.start()
    try await eventually { await driver.operations().contains("configure") }
    await driver.setEngineRunning(false)
    let playoutRecovery = Task { await engine.decodedRemoteAudioObserved() }
    try await eventually { await driver.operations().contains("recover-playout") }

    let timedOutReceipt = await engine.shutdown()
    #expect(!timedOutReceipt.isQuiescent)
    #expect(!timedOutReceipt.mutationReleased)

    await driver.releasePlayoutRecovery()
    _ = await playoutRecovery.value
    try await eventually {
      let health = await driver.runtimeHealth()
      let operations = await driver.operations()
      return operations.contains("prepared:false")
        && !health.isRecording
        && !health.isPlaying
    }
    let eventualSnapshot = await engine.currentSnapshot()
    #expect(eventualSnapshot.state == .cold)
    #expect(!eventualSnapshot.isPrepared)
  }

  @Test("a failed terminal stop remains durable beyond the initial retry window")
  func shutdownStopFailureRetainsCleanupObligation() async throws {
    let driver = FakeGridAudioDriver(shutdownFailures: 4)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }

    let failedReceipt = await engine.shutdown()
    #expect(!failedReceipt.isQuiescent)
    #expect(failedReceipt.mutationReleased)

    try await eventually {
      let attempts = await driver.operations().filter { $0 == "shutdown-attempt" }.count
      let snapshot = await engine.currentSnapshot()
      return attempts == 5 && snapshot.state == .cold && !snapshot.isPrepared
    }
  }

  @Test("capture and physical playout health are independent")
  func stoppedPlayoutIsDirectionallyUnhealthy() {
    let health = GridAudioRuntimeHealth(
      isEngineRunning: true,
      isRecording: true,
      isPlaying: false,
      route: InlineRTCAudioRoute(
        currentInputID: "input",
        defaultInputID: "input",
        currentOutputID: "output",
        defaultOutputID: "output",
        inputDeviceCount: 1,
        outputDeviceCount: 1,
        isInputRouteValid: true,
        isOutputRouteValid: true
      )
    )
    #expect(health.isCaptureHealthy)
    #expect(!health.isPlayoutHealthy)
  }

  @Test("requested software processing is unhealthy when VPIO becomes active")
  func effectiveProcessingRejectsVPIO() {
    let processing = InlineRTCAudioProcessingState(
      echoCancellationRequested: true,
      echoCancellationEffective: .software,
      noiseSuppressionRequested: true,
      noiseSuppressionEffective: .software,
      automaticGainControlRequested: true,
      automaticGainControlEffective: .software,
      platformVoiceProcessingAllowed: false,
      platformVoiceProcessingRequested: false,
      platformVoiceProcessingActive: true
    )

    #expect(!processing.isGridPolicyEffective)
  }

  @Test("capture preparation waits for the first track request without deadlocking")
  func processingRequestIsDeferredUntilTrackPublication() {
    let processing = InlineRTCAudioProcessingState(
      echoCancellationRequested: nil,
      echoCancellationEffective: .disabled,
      noiseSuppressionRequested: nil,
      noiseSuppressionEffective: .disabled,
      automaticGainControlRequested: nil,
      automaticGainControlEffective: .disabled,
      platformVoiceProcessingAllowed: false,
      platformVoiceProcessingRequested: false,
      platformVoiceProcessingActive: false
    )
    let health = GridAudioRuntimeHealth(
      isEngineRunning: true,
      isRecording: true,
      isPlaying: false,
      route: nil,
      processing: processing
    )

    #expect(!processing.isGridPolicyEffective)
    #expect(processing.isCompatibleWithCaptureBootstrap)
    #expect(health.isAudioDeviceHealthy)
    #expect(health.isCaptureHealthy)
  }

  @Test("APM failure is capture-unhealthy without poisoning ADM recovery")
  func processingFailureDoesNotMisclassifyDeviceHealth() {
    let processing = InlineRTCAudioProcessingState(
      echoCancellationRequested: true,
      echoCancellationEffective: .disabled,
      noiseSuppressionRequested: true,
      noiseSuppressionEffective: .software,
      automaticGainControlRequested: true,
      automaticGainControlEffective: .software,
      platformVoiceProcessingAllowed: false,
      platformVoiceProcessingRequested: false,
      platformVoiceProcessingActive: false
    )
    let health = GridAudioRuntimeHealth(
      isEngineRunning: true,
      isRecording: true,
      isPlaying: false,
      route: nil,
      processing: processing
    )

    #expect(health.isAudioDeviceHealthy)
    #expect(!health.isCaptureHealthy)
  }

  @Test("an APM policy failure is surfaced without restarting Core Audio")
  func processingFailureDoesNotStartDeviceRecovery() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }
    await driver.setProcessing(
      InlineRTCAudioProcessingState(
        echoCancellationRequested: true,
        echoCancellationEffective: .disabled,
        noiseSuppressionRequested: true,
        noiseSuppressionEffective: .software,
        automaticGainControlRequested: true,
        automaticGainControlEffective: .software,
        platformVoiceProcessingAllowed: false,
        platformVoiceProcessingRequested: false,
        platformVoiceProcessingActive: false
      )
    )

    await engine.checkRuntimeHealthAfterInterruption()

    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.isPrepared)
    #expect(!snapshot.isCaptureHealthy)
    #expect(await driver.operations().filter { $0 == "recover" }.isEmpty)
    await engine.releaseCaptureLease(lease)
  }

  @Test("rejoin during grace never stops capture")
  func rejoinDuringCooldown() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(80)
    )
    let first = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))
    let second = GridAudioLease.connectionDemand(.init("grid-test:1:4:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(first)
    try await eventually { await engine.currentSnapshot().state == .ready }
    await engine.releaseCaptureLease(first)
    try await Task.sleep(for: .milliseconds(20))
    await engine.acquireCaptureLease(second)
    try await Task.sleep(for: .milliseconds(100))

    #expect(await engine.currentSnapshot().state == .ready)
    #expect(await driver.operations().contains("prepared:false") == false)
  }

  @Test("leave before warm-up begins never starts capture")
  func leaveBeforeWarmup() async throws {
    let driver = FakeGridAudioDriver(blockConfigure: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(40)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:8:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().contains("configure") }
    await engine.releaseCaptureLease(lease)
    await driver.releaseConfigure()
    try await Task.sleep(for: .milliseconds(80))

    #expect(await driver.operations().contains("prepared:true") == false)
    #expect(await engine.currentSnapshot().state == .cold)
  }

  @Test("latest selection reconciles after a slow stale mutation without overlap")
  func latestInputWinsAfterSlowMutation() async throws {
    let driver = FakeGridAudioDriver(blockInputDeviceID: "usb")
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(20)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))
    await engine.start()
    try await eventually { await driver.operations().contains("configure") }

    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))
    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().contains("input:usb") }
    await engine.setInput(.automatic)
    try await Task.sleep(for: .milliseconds(40))
    #expect(await driver.operations().contains("input:automatic") == false)

    await driver.releaseInput()
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      let didApplyAutomatic = await driver.operations().contains("input:automatic")
      return snapshot.input?.selection == .automatic
        && didApplyAutomatic
    }
    #expect(await driver.operations().filter { $0 == "input:usb" }.count == 1)
    #expect(await driver.operations().filter { $0 == "input:automatic" }.count == 1)
  }

  @Test("first explicit intent never clears the route to automatic first")
  func firstExplicitIntentDoesNotWriteAutomatic() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.start()
    try await eventually { await driver.operations().contains("configure") }
    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))
    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().contains("input:usb") }

    #expect(await driver.operations().filter { $0 == "input:automatic" }.isEmpty)
  }

  @Test("input preference alone never opens a physical capture route")
  func inputPreferenceWithoutCaptureDemandStaysDesiredOnly() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let preference = AudioInputSelection.device(
      id: "usb",
      rememberedName: "USB Microphone"
    )

    await engine.start()
    await engine.setInput(preference)
    try await eventually { await driver.operations().contains("configure") }
    try await Task.sleep(for: .milliseconds(40))

    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.state == .cold)
    #expect(snapshot.input?.selection == preference)
    #expect(await driver.operations().filter { $0.hasPrefix("input:") }.isEmpty)
    #expect(await driver.operations().contains("prepared:true") == false)
  }

  @Test("capture waits for the complete input intent instead of inventing Auto")
  func captureWaitsForInputIntent() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().contains("configure") }
    try await Task.sleep(for: .milliseconds(40))
    #expect(await driver.operations().contains("prepared:true") == false)
    #expect(await driver.operations().contains("input:automatic") == false)

    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))
    try await eventually { await engine.currentSnapshot().state == .ready }

    let operations = await driver.operations()
    let inputIndex = try #require(operations.firstIndex(of: "input:usb"))
    let prepareIndex = try #require(operations.firstIndex(of: "prepared:true"))
    #expect(inputIndex < prepareIndex)
    #expect(operations.contains("input:automatic") == false)
  }

  @Test("WebRTC ADM routing and capture wait for RTC transport initialization")
  func webRTCADMWaitsForRTCTransport() async throws {
    let driver = FakeGridAudioDriver(preparationRequiresRTCTransport: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().contains("configure") }
    try await Task.sleep(for: .milliseconds(40))

    var operations = await driver.operations()
    #expect(operations.contains("input:automatic") == false)
    #expect(operations.contains("prepared:true") == false)
    #expect(await engine.isWaitingForRTCTransport())

    let generation = await engine.rtcTransportPreparationGeneration()
    await engine.rtcTransportDidInitialize(generation: generation)
    try await eventually { await engine.currentSnapshot().state == .ready }

    operations = await driver.operations()
    let inputIndex = try #require(operations.firstIndex(of: "input:automatic"))
    let prepareIndex = try #require(operations.firstIndex(of: "prepared:true"))
    #expect(inputIndex < prepareIndex)
    #expect(await engine.isWaitingForRTCTransport() == false)
  }

  @Test("custom ADM waits for sender attachment instead of prestarting recording")
  func customADMRecordingIsSenderOwned() async throws {
    let driver = FakeGridAudioDriver(
      preparationRequiresRTCTransport: true,
      recordingStartsWithMicrophoneSender: true
    )
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineHealthCheckDelay: .milliseconds(5)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    let generation = await engine.rtcTransportPreparationGeneration()
    await engine.rtcTransportDidInitialize(generation: generation)

    try await eventually {
      let operations = await driver.operations()
      let senderMayStartRecording = await engine.microphoneSenderMayStartRecording()
      return operations.contains("input:automatic") && senderMayStartRecording
    }
    var operations = await driver.operations()
    #expect(!operations.contains("prepared:true"))
    #expect(!(await engine.currentSnapshot()).isPrepared)

    await driver.setEngineRunning(true)
    await driver.setRecordingExpected(true)
    await driver.setRecordingActive(true)
    await driver.emit(.engineStarting(playout: false, recording: true))

    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .ready && snapshot.isPrepared && snapshot.isRecording
    }
    operations = await driver.operations()
    #expect(!operations.contains("prepared:true"))
  }

  @Test("a new custom ADM transport explicitly rearms the terminal device gate")
  func customADMTransportRearmsTerminalGate() async {
    let driver = FakeGridAudioDriver(
      preparationRequiresRTCTransport: true,
      recordingStartsWithMicrophoneSender: true
    )
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )

    let receipt = await engine.shutdown()
    #expect(receipt.isQuiescent)
    _ = await engine.rtcTransportWillInitialize()

    #expect(await driver.operations().contains("resume-terminal-gate"))
  }

  @Test("terminal shutdown invalidates older RTC transport completions")
  func shutdownInvalidatesOlderRTCTransportCompletions() async throws {
    let driver = FakeGridAudioDriver(preparationRequiresRTCTransport: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let staleGeneration = await engine.rtcTransportPreparationGeneration()

    let receipt = await engine.shutdown()
    #expect(receipt.isQuiescent)
    #expect(await engine.isWaitingForRTCTransport())

    await engine.rtcTransportDidInitialize(generation: staleGeneration)
    #expect(await engine.isWaitingForRTCTransport())

    let currentGeneration = await engine.rtcTransportPreparationGeneration()
    #expect(currentGeneration != staleGeneration)
    await engine.rtcTransportDidInitialize(generation: currentGeneration)
    #expect(await engine.isWaitingForRTCTransport() == false)
  }

  @Test("a replacement RTC transport closes capture until its own initialization")
  func replacementRTCTransportRearmsCaptureFence() async throws {
    let driver = FakeGridAudioDriver(preparationRequiresRTCTransport: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    let firstGeneration = await engine.rtcTransportWillInitialize()
    await engine.rtcTransportDidInitialize(generation: firstGeneration)
    try await eventually { await engine.currentSnapshot().isPrepared }

    let replacementGeneration = await engine.rtcTransportWillInitialize()
    #expect(replacementGeneration != firstGeneration)
    #expect(await engine.isWaitingForRTCTransport())
    try await eventually { await engine.currentSnapshot().isPrepared == false }

    await engine.rtcTransportDidInitialize(generation: firstGeneration)
    #expect(await engine.isWaitingForRTCTransport())
    await engine.rtcTransportDidInitialize(generation: replacementGeneration)
    try await eventually { await engine.currentSnapshot().isPrepared }
  }

  @Test("automatic and explicit fallback stay distinct")
  func explicitFallback() async throws {
    let driver = FakeGridAudioDriver(availableDeviceIDs: ["built-in"])
    let engine = GridAudioEngine(driver: driver, permissionDriver: TestGridMicrophonePermissionDriver())
    await engine.setInput(.device(id: "missing", rememberedName: "Desk Mic"))

    try await eventually {
      await engine.currentSnapshot().input?.isFallingBackToAutomatic == true
    }
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.input?.selection == .device(id: "missing", rememberedName: "Desk Mic"))
    #expect(snapshot.input?.activeDeviceID == "built-in")
  }

  @Test("rejected explicit input falls back once, preserves preference, and retries on demand")
  func rejectedExplicitInputFallsBackAndRetries() async throws {
    let preferred = AudioInputSelection.device(id: "usb", rememberedName: "USB Microphone")
    let driver = FakeGridAudioDriver(inputFailures: ["usb": 1])
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(preferred)
    await engine.acquireCaptureLease(lease)
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      let operations = await driver.operations()
      return operations.filter { $0 == "input:usb" }.count == 1
        && operations.filter { $0 == "input:automatic" }.count == 1
        && snapshot.input?.selection == preferred
        && snapshot.input?.isFallingBackToAutomatic == true
    }

    await driver.emit(.devicesChanged)
    try await Task.sleep(for: .milliseconds(80))
    #expect(await driver.operations().filter { $0 == "input:usb" }.count == 1)

    await engine.retryInput(preferred)
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      let explicitAttempts = await driver.operations().filter { $0 == "input:usb" }.count
      return explicitAttempts == 2 && snapshot.input?.isFallingBackToAutomatic == false
    }
  }

  @Test("an explicit failure plus failed Auto fallback suspends without oscillating")
  func explicitAndAutomaticFailureSuspendOnce() async throws {
    let preferred = AudioInputSelection.device(id: "usb", rememberedName: "USB Microphone")
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(10)
    )
    let demandLease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))
    let lifecycleLease = GridAudioLease.rtcLifecycle(UUID())

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(demandLease)
    try await eventually { await engine.currentSnapshot().state == .ready }
    await driver.failNextInput("usb")
    await driver.failNextInput("automatic")

    await engine.setInput(preferred)
    try await eventually {
      if case .failed = await engine.currentSnapshot().state { return true }
      return false
    }
    await engine.acquireCaptureLease(lifecycleLease)
    try await Task.sleep(for: .milliseconds(80))

    #expect(await driver.operations().filter { $0 == "input:usb" }.count == 1)
    #expect(await driver.operations().filter { $0 == "input:automatic" }.count == 2)

    await engine.releaseCaptureLease(lifecycleLease)
    await engine.releaseCaptureLease(demandLease)
    try await eventually { await driver.operations().contains("prepared:false") }
  }

  @Test("an Auto route error cannot prevent leave from stopping capture")
  func automaticInputFailureDoesNotBlockStop() async throws {
    let driver = FakeGridAudioDriver(inputFailures: ["automatic": 1])
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(10)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await engine.releaseCaptureLease(lease)

    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return !snapshot.isPrepared && snapshot.state == .failed("device unavailable")
    }
    #expect(await driver.operations().filter { $0 == "input:automatic" }.count == 1)
    #expect(await driver.operations().filter { $0 == "prepared:false" }.count == 1)
  }

  @Test("persistent audio failure waits for an explicit retry signal")
  func failureSuspendsReconcile() async throws {
    let driver = FakeGridAudioDriver(configureFailures: 1)
    let engine = GridAudioEngine(driver: driver, permissionDriver: TestGridMicrophonePermissionDriver())

    await engine.start()
    try await eventually {
      if case .failed = await engine.currentSnapshot().state { return true }
      return false
    }
    try await Task.sleep(for: .milliseconds(40))
    #expect(await driver.operations().filter { $0 == "configure" }.count == 1)

    await engine.retry()
    try await eventually { await engine.currentSnapshot().state == .cold }
    #expect(await driver.operations().filter { $0 == "configure" }.count == 2)
  }

  @Test("network and wake health checks do not repeat a quarantined route failure")
  func interruptionHealthChecksPreserveRouteQuarantine() async throws {
    let driver = FakeGridAudioDriver(inputFailures: ["automatic": 1])
    let engine = GridAudioEngine(driver: driver, permissionDriver: TestGridMicrophonePermissionDriver())
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually {
      if case .failed = await engine.currentSnapshot().state { return true }
      return false
    }

    for _ in 0 ..< 20 {
      await engine.checkRuntimeHealthAfterInterruption()
    }
    try await Task.sleep(for: .milliseconds(40))

    #expect(await driver.operations().filter { $0 == "input:automatic" }.count == 1)
  }

  @Test("device update bursts refresh inventory without rewriting an unchanged route")
  func deviceUpdatesAreDebounced() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      deviceChangeSettleDelay: .milliseconds(40)
    )

    await engine.start()
    try await eventually { await driver.operations().contains("configure") }

    await driver.emit(.devicesChanged)
    try await Task.sleep(for: .milliseconds(10))
    await driver.emit(.devicesChanged)
    try await Task.sleep(for: .milliseconds(10))
    await driver.emit(.devicesChanged)
    try await Task.sleep(for: .milliseconds(20))
    try await Task.sleep(for: .milliseconds(180))
    #expect(await driver.operations().filter { $0 == "input:automatic" }.isEmpty)
  }

  @Test("volatile callback telemetry does not extend device settlement")
  func volatileTelemetryDoesNotDelayDeviceSettlement() async throws {
    let driver = FakeGridAudioDriver(volatileRuntimeDiagnostics: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      deviceChangeSettleDelay: .zero
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }
    let baseline = await driver.inventoryReadCount()

    await driver.emit(.devicesChanged)
    try await eventually { await driver.inventoryReadCount() >= baseline + 3 }
    try await Task.sleep(for: .milliseconds(20))

    #expect(await driver.inventoryReadCount() == baseline + 3)
  }

  @Test("a stopped prepared engine requests recovery after device churn settles")
  func stoppedPreparedEngineRecovers() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(25)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.emit(.engineStopped(playout: true, recording: true))

    try await eventually { await driver.operations().contains("recover") }
  }

  @Test("a stopped engine exposes warming until recovery finishes")
  func stoppedEngineExposesRecoveryState() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(20)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.emit(.engineStopped(playout: true, recording: true))

    try await eventually { await engine.currentSnapshot().isPrepared == false }
    let degraded = await engine.currentSnapshot()
    #expect(degraded.isPrepared == false)
    #expect(degraded.state == .warming)
    try await eventually { await driver.operations().contains("recover") }

    try await eventually { await engine.currentSnapshot().isPrepared }
  }

  @Test("duplicate engine-stop callbacks coalesce into one recovery")
  func duplicateStopsCoalesce() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(30)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.emit(.engineStopped(playout: true, recording: true))
    try await Task.sleep(for: .milliseconds(10))
    await driver.emit(.engineStopped(playout: true, recording: true))
    try await Task.sleep(for: .milliseconds(10))
    await driver.emit(.engineDisabled(playout: true, recording: true))

    try await eventually { await driver.operations().contains("recover") }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await driver.operations().filter { $0 == "recover" }.count == 1)
  }

  @Test("a route transaction stop callback never starts competing recovery")
  func expectedRouteStopDoesNotRecover() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(10)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.emit(.expectedEngineStop(playout: true, recording: true))
    try await Task.sleep(for: .milliseconds(50))

    #expect(await driver.operations().contains("recover") == false)
  }

  @Test("transient device health during a route mutation defers to that mutation")
  func transientDeviceHealthDuringRouteMutationDoesNotRecover() async throws {
    let driver = FakeGridAudioDriver(blockInputDeviceID: "usb")
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      deviceChangeSettleDelay: .milliseconds(10),
      engineRecoveryDelay: .milliseconds(5)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }

    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))
    try await eventually { await driver.operations().contains("input:usb") }
    await driver.setOutputRouteValid(false)
    await driver.emit(.devicesChanged)
    try await Task.sleep(for: .milliseconds(60))

    await driver.setOutputRouteValid(true)
    await driver.releaseInput()
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .ready && snapshot.input?.activeDeviceID == "usb"
    }
    try await Task.sleep(for: .milliseconds(40))

    #expect(await driver.operations().filter { $0 == "recover" }.isEmpty)
  }

  @Test("an unhealthy recovery is retried until the engine actually runs")
  func unhealthyRecoveryRetries() async throws {
    let driver = FakeGridAudioDriver(recoveryRunningResults: [false, true])
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(10)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.emit(.engineStopped(playout: true, recording: true))

    try await eventually(timeout: .seconds(2)) {
      let recoveryCount = await driver.operations().filter { $0 == "recover" }.count
      let isPrepared = await engine.currentSnapshot().isPrepared
      return recoveryCount == 2 && isPrepared
    }
    #expect(await engine.currentSnapshot().state == .ready)
  }

  @Test("an audio engine restart cancels a pending recovery request")
  func engineRestartCancelsRecovery() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(60),
      engineHealthCheckDelay: .milliseconds(10)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.emit(.engineStopped(playout: true, recording: true))
    try await eventually { await engine.currentSnapshot().state == .warming }
    await driver.emit(.engineStarting(playout: true, recording: true))
    await driver.setRecordingActive(true)
    try await eventually { await engine.currentSnapshot().state == .ready }
    try await Task.sleep(for: .milliseconds(80))

    #expect(await driver.operations().contains("recover") == false)
  }

  @Test("lifetime health checks recover a stopped engine even when its callback is lost")
  func lifetimeHealthDetectsMissedStop() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(10),
      lifetimeHealthCheckInterval: .milliseconds(20)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.setEngineRunning(false)

    try await eventually {
      let recovered = await driver.operations().contains("recover")
      let isPrepared = await engine.currentSnapshot().isPrepared
      return recovered && isPrepared
    }
  }

  @Test("invalid output health stays directional and never restarts healthy capture")
  func invalidOutputHealthDoesNotRestartCapture() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(5),
      lifetimeHealthCheckInterval: .milliseconds(20)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.setOutputRouteValid(false)

    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.route?.isOutputRouteValid == false && snapshot.isPrepared
    }
    #expect(await driver.operations().contains("recover") == false)

    let disposition = await engine.decodedRemoteAudioObserved()

    #expect(disposition == .reconstructRTCSession)
    #expect(await driver.operations().contains("recover-playout"))
    #expect(await driver.operations().contains("recover") == false)
  }

  @Test("lifetime health recovers stopped ADM recording even while the engine is running")
  func lifetimeHealthDetectsStoppedRecording() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(5),
      lifetimeHealthCheckInterval: .milliseconds(20)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.setRecordingActive(false)

    try await eventually {
      let recovered = await driver.operations().contains("recover")
      let snapshot = await engine.currentSnapshot()
      return recovered && snapshot.isPrepared && snapshot.state == .ready
    }
  }

  @Test("verified input rollback remains healthy and falls back without a fatal error")
  func verifiedInputRollbackIsNonfatal() async throws {
    let driver = FakeGridAudioDriver(inputRestorations: ["usb": 1])
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }

    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))

    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return await driver.operations().filter { $0 == "input:usb" }.count == 1
        && snapshot.state == .ready
        && snapshot.input?.selection == .device(
          id: "usb",
          rememberedName: "USB Microphone"
        )
        && snapshot.input?.isFallingBackToAutomatic == true
        && snapshot.input?.activeDeviceID == "built-in"
    }
    #expect(await driver.operations().filter { $0 == "input:usb" }.count == 1)
  }

  @Test("transient input rollback retains the chosen route and retries it")
  func transientInputRollbackRetriesChosenRoute() async throws {
    let preferred = AudioInputSelection.device(
      id: "usb",
      rememberedName: "USB Microphone"
    )
    let driver = FakeGridAudioDriver(inputTransientRestorations: ["usb": 1])
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      transientRouteRetryDelayOverride: .milliseconds(10)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }

    await engine.setInput(preferred)
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return await driver.operations().filter { $0 == "input:usb" }.count == 1
        && snapshot.input?.selection == preferred
        && snapshot.input?.activeDeviceID == "built-in"
        && snapshot.input?.isFallingBackToAutomatic == true
    }
    try await eventually {
      await driver.operations().filter { $0 == "input:usb" }.count == 2
    }
    let recovered = await engine.currentSnapshot()
    #expect(recovered.input?.selection == preferred)
    #expect(recovered.input?.isFallingBackToAutomatic == false)
  }

  @Test("muted sender-owned capture is healthy idle and does not recover")
  func mutedSenderOwnedCaptureIsHealthyIdle() async throws {
    let driver = FakeGridAudioDriver(
      preparationRequiresRTCTransport: true,
      recordingStartsWithMicrophoneSender: true
    )
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(5),
      lifetimeHealthCheckInterval: .milliseconds(20)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    let generation = await engine.rtcTransportPreparationGeneration()
    await engine.rtcTransportDidInitialize(generation: generation)

    try await eventually { await engine.currentSnapshot().state == .ready }
    await engine.checkRuntimeHealthAfterInterruption()
    await driver.emit(.devicesChanged)
    await driver.emit(.engineStopped(playout: false, recording: true))
    try await Task.sleep(for: .milliseconds(80))

    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.state == .ready)
    #expect(!snapshot.isRecording)
    #expect(!snapshot.isPrepared)
    #expect(await driver.operations().contains("recover") == false)
  }

  @Test("sender recording demand without physical capture recovers instead of looking muted")
  func demandedSenderCaptureRecovers() async throws {
    let driver = FakeGridAudioDriver(
      preparationRequiresRTCTransport: true,
      recordingStartsWithMicrophoneSender: true
    )
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      engineRecoveryDelay: .milliseconds(5)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    let generation = await engine.rtcTransportPreparationGeneration()
    await engine.rtcTransportDidInitialize(generation: generation)
    try await eventually { await engine.microphoneSenderMayStartRecording() }

    await driver.setRecordingExpected(true)
    await engine.checkRuntimeHealthAfterInterruption()

    try await eventually { await driver.operations().contains("recover") }
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.state == .ready && snapshot.isPrepared
    }
  }

  @Test("remote playout failure escalates without restarting microphone capture")
  func remotePlayoutFailureEscalatesToRTC() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }
    await driver.setOutputRouteValid(false)

    let disposition = await engine.decodedRemoteAudioObserved()

    #expect(disposition == .reconstructRTCSession)
    #expect(await driver.operations().contains("recover") == false)
  }

  @Test("sender-owned capture reconstructs RTC when physical delivery is healthy")
  func senderOwnedDownstreamCaptureFailureReconstructsRTC() async throws {
    let driver = FakeGridAudioDriver(recordingStartsWithMicrophoneSender: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.microphoneSenderMayStartRecording() }
    await driver.setEngineRunning(true)
    await driver.setRecordingExpected(true)
    await driver.setRecordingActive(true)
    await driver.emit(.engineStarting(playout: false, recording: true))
    try await eventually { await engine.currentSnapshot().state == .ready }

    let disposition = await engine.captureFlowMissing()

    #expect(disposition == .reconstructRTCSession)
    #expect(await driver.operations().contains("recover") == false)
  }

  @Test("sender-owned capture repairs a degraded physical direction first")
  func senderOwnedPhysicalCaptureFailureRecoversDirectionally() async throws {
    let driver = FakeGridAudioDriver(recordingStartsWithMicrophoneSender: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.microphoneSenderMayStartRecording() }
    await driver.setEngineRunning(true)
    await driver.setRecordingExpected(true)
    await driver.setRecordingActive(true)
    await driver.emit(.engineStarting(playout: false, recording: true))
    try await eventually { await engine.currentSnapshot().state == .ready }
    await driver.setInputRouteValid(false)

    let disposition = await engine.captureFlowMissing()

    #expect(disposition == .recoveredPhysicalCapture)
    #expect(await driver.operations().contains("recover"))
  }

  @Test("decoded remote PCM triggers stopped physical playout recovery")
  func stoppedPhysicalPlayoutRecoversDirectionally() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }
    await driver.setPlayingActive(false)

    let disposition = await engine.decodedRemoteAudioObserved()

    #expect(disposition == .recoveredPhysicalPlayout)
    #expect(await driver.operations().contains("recover-playout"))
  }

  @Test("playout recovery defers to each active route transition owner")
  func playoutRecoveryDefersToRouteOwners() {
    #expect(GridAudioPlayoutRecoveryDeferral.resolve(
      driverMutationInFlight: true,
      deviceSettlementPending: false,
      hasOutputIntent: true,
      outputRouteRetrySuspended: false,
      outputRouteNeedsTransaction: true
    ) == .driverMutation)
    #expect(GridAudioPlayoutRecoveryDeferral.resolve(
      driverMutationInFlight: false,
      deviceSettlementPending: true,
      hasOutputIntent: true,
      outputRouteRetrySuspended: false,
      outputRouteNeedsTransaction: true
    ) == .deviceSettlement)
    #expect(GridAudioPlayoutRecoveryDeferral.resolve(
      driverMutationInFlight: false,
      deviceSettlementPending: false,
      hasOutputIntent: true,
      outputRouteRetrySuspended: false,
      outputRouteNeedsTransaction: true
    ) == .outputRouteTransaction)
  }

  @Test("runtime route epoch drift starts settlement before playout recovery")
  func routeEpochDriftDefersPlayoutRecovery() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      deviceChangeSettleDelay: .milliseconds(10)
    )

    await engine.start()
    await engine.setOutput(.automatic)
    try await eventually {
      await driver.operations().contains("output:automatic")
    }
    await driver.setPlayingActive(false)
    await driver.setRouteEpoch(1)

    let disposition = await engine.decodedRemoteAudioObserved()

    #expect(disposition == nil)
    #expect(await driver.operations().contains("recover-playout") == false)
  }

  @Test("physical playout refresh catches a profile change before its event")
  func playoutRefreshCatchesProfileChangeBeforeEvent() async throws {
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      deviceChangeSettleDelay: .milliseconds(10)
    )

    await engine.start()
    await engine.setOutput(.automatic)
    try await eventually {
      await driver.operations().filter { $0 == "output:automatic" }.count == 1
    }
    await driver.setPlayingActive(false)
    await driver.setOutputSampleRate(24_000)

    let disposition = await engine.decodedRemoteAudioObserved()

    #expect(disposition == nil)
    #expect(await driver.operations().contains("recover-playout") == false)
    try await eventually {
      await driver.operations().filter { $0 == "output:automatic" }.count == 2
    }
  }

  @Test("settled or suspended routes leave persistent playout recovery enabled")
  func persistentPlayoutFailureRetainsRecoveryOwnership() {
    #expect(GridAudioPlayoutRecoveryDeferral.resolve(
      driverMutationInFlight: false,
      deviceSettlementPending: false,
      hasOutputIntent: true,
      outputRouteRetrySuspended: false,
      outputRouteNeedsTransaction: false
    ) == nil)
    #expect(GridAudioPlayoutRecoveryDeferral.resolve(
      driverMutationInFlight: false,
      deviceSettlementPending: false,
      hasOutputIntent: true,
      outputRouteRetrySuspended: true,
      outputRouteNeedsTransaction: true
    ) == nil)
  }

  @Test("physical playout checks defer while a native route mutation owns the ADM")
  func physicalPlayoutCheckDefersDuringRouteMutation() async throws {
    let driver = FakeGridAudioDriver(blockInputDeviceID: "usb")
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().state == .ready }
    await driver.setPlayingActive(false)
    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))
    try await eventually { await engine.currentSnapshot().currentMutationKind == "input" }

    let disposition = await engine.decodedRemoteAudioObserved()

    #expect(disposition == nil)
    #expect(await driver.operations().contains("recover-playout") == false)
    await driver.releaseInput()
  }

  @Test("removing a preferred input applies automatic once and preserves preference")
  func removedPreferenceFallsBackOnce() async throws {
    let preferred = AudioInputSelection.device(id: "usb", rememberedName: "usb")
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      deviceChangeSettleDelay: .milliseconds(10)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.start()
    await engine.setInput(preferred)
    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().filter { $0 == "input:usb" }.count == 1 }
    await driver.setAvailableDeviceIDs(["built-in"])
    await driver.emit(.devicesChanged)

    try await eventually {
      let snapshot = await engine.currentSnapshot()
      let automaticAssignments = await driver.operations().filter { $0 == "input:automatic" }.count
      return snapshot.input?.selection == preferred
        && snapshot.input?.isFallingBackToAutomatic == true
        && automaticAssignments == 1
    }
    await driver.emit(.devicesChanged)
    try await Task.sleep(for: .milliseconds(80))

    #expect(await driver.operations().filter { $0 == "input:automatic" }.count == 1)
  }

  @Test("returning preferred input restores it once")
  func returningPreferenceRestoresOnce() async throws {
    let preferred = AudioInputSelection.device(id: "usb", rememberedName: "USB Microphone")
    let driver = FakeGridAudioDriver(availableDeviceIDs: ["built-in"])
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      deviceChangeSettleDelay: .milliseconds(10)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.start()
    await engine.setInput(preferred)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().input?.isFallingBackToAutomatic == true }
    #expect(await driver.operations().filter { $0 == "input:automatic" }.count == 1)

    await driver.setAvailableDeviceIDs(["built-in", "usb"])
    await driver.emit(.devicesChanged)

    try await eventually {
      let inputs = await driver.operations().filter { $0 == "input:usb" }.count
      let snapshot = await engine.currentSnapshot()
      return inputs == 1 && snapshot.input?.isFallingBackToAutomatic == false
    }
    await driver.emit(.devicesChanged)
    try await Task.sleep(for: .milliseconds(80))
    #expect(await driver.operations().filter { $0 == "input:usb" }.count == 1)
  }

  @Test("manual inventory refresh repairs a missed removal event")
  func manualRefreshRepairsMissedRemovalEvent() async throws {
    let preferred = AudioInputSelection.device(id: "usb", rememberedName: "USB Microphone")
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(preferred)
    await engine.acquireCaptureLease(lease)
    try await eventually { await driver.operations().filter { $0 == "input:usb" }.count == 1 }
    await driver.setAvailableDeviceIDs(["built-in"])

    _ = await engine.deviceSnapshot()

    try await eventually {
      let snapshot = await engine.currentSnapshot()
      let automaticAssignments = await driver.operations().filter { $0 == "input:automatic" }.count
      return automaticAssignments == 1
        && snapshot.input?.selection == preferred
        && snapshot.input?.isFallingBackToAutomatic == true
    }
  }

  @Test("removing a preferred output applies Auto and restores the preference once")
  func outputRemovalFallsBackAndRestores() async throws {
    let preferred = AudioOutputSelection.device(id: "airpods", rememberedName: "airpods")
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      deviceChangeSettleDelay: .milliseconds(1)
    )

    await engine.start()
    await engine.setOutput(preferred)
    try await eventually {
      await driver.operations().filter { $0 == "output:airpods" }.count == 1
    }

    await driver.setAvailableOutputDeviceIDs(["built-in-output"])
    await driver.emit(.devicesChanged)
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return await driver.operations().filter { $0 == "output:automatic" }.count >= 1
        && snapshot.output?.selection == preferred
        && snapshot.output?.isFallingBackToAutomatic == true
    }

    await driver.setAvailableOutputDeviceIDs(["built-in-output", "airpods"])
    await driver.emit(.devicesChanged)
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return await driver.operations().filter { $0 == "output:airpods" }.count == 2
        && snapshot.output?.isFallingBackToAutomatic == false
    }
    await driver.emit(.devicesChanged)
    try await Task.sleep(for: .milliseconds(40))
    #expect(await driver.operations().filter { $0 == "output:airpods" }.count == 2)
  }

  @Test("rejected explicit output falls back without erasing user intent")
  func rejectedOutputFallsBack() async throws {
    let preferred = AudioOutputSelection.device(id: "airpods", rememberedName: "airpods")
    let driver = FakeGridAudioDriver(outputFailures: ["airpods": 1])
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )

    await engine.start()
    await engine.setOutput(.automatic)
    try await eventually {
      await driver.operations().filter { $0 == "output:automatic" }.count == 1
    }
    await engine.setOutput(preferred)
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return await driver.operations().filter { $0 == "output:airpods" }.count == 1
        && snapshot.output?.selection == preferred
        && snapshot.output?.isFallingBackToAutomatic == true
    }
    #expect(await driver.operations().filter { $0 == "output:airpods" }.count == 1)
  }

  @Test("healthy output rollback retains the chosen route and retries it")
  func restoredOutputRetriesChosenRoute() async throws {
    let preferred = AudioOutputSelection.device(id: "airpods", rememberedName: "airpods")
    let driver = FakeGridAudioDriver(
      outputFailures: ["airpods": 1],
      outputFailuresRestorePrevious: true
    )
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      transientRouteRetryDelayOverride: .milliseconds(10)
    )

    await engine.start()
    await engine.setOutput(.automatic)
    try await eventually {
      await driver.operations().filter { $0 == "output:automatic" }.count == 1
    }
    await engine.setOutput(preferred)
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return await driver.operations().filter { $0 == "output:airpods" }.count == 1
        && snapshot.output?.selection == preferred
        && snapshot.output?.activeDeviceID == "built-in-output"
        && snapshot.output?.isFallingBackToAutomatic == true
    }
    try await eventually {
      await driver.operations().filter { $0 == "output:airpods" }.count == 2
    }
    let recovered = await engine.currentSnapshot()
    #expect(recovered.output?.selection == preferred)
    #expect(recovered.output?.activeDeviceID == "airpods")
    #expect(recovered.output?.isFallingBackToAutomatic == false)
  }

  @Test("leaving cancels in-flight audio recovery and stale work cannot resume")
  func leaveCancelsInFlightRecovery() async throws {
    let driver = FakeGridAudioDriver(waitForRecoveryCancellation: true)
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(10),
      engineRecoveryDelay: .milliseconds(5)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.emit(.engineStopped(playout: true, recording: true))
    try await eventually { await driver.operations().contains("recover") }
    await engine.releaseCaptureLease(lease)

    try await eventually {
      await driver.didObserveRecoveryCancellation()
    }
    try await eventually {
      let snapshot = await engine.currentSnapshot()
      return snapshot.captureLeaseCount == 0 && snapshot.state == .cold
    }
    #expect(await driver.operations().filter { $0 == "recover" }.count == 1)
  }
}

private actor FakeGridAudioDriver: GridAudioDriver {
  nonisolated let events: AsyncStream<GridAudioDriverEvent>
  nonisolated let preparationRequiresRTCTransport: Bool
  nonisolated let recordingStartsWithMicrophoneSender: Bool
  private nonisolated let eventContinuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private var log: [String] = []
  private var availableDeviceIDs: Set<String>
  private var availableOutputDeviceIDs: Set<String>
  private let blockConfigure: Bool
  private let blockPrepare: Bool
  private var configureFailuresRemaining: Int
  private var recoveryRunningResults: [Bool]
  private let blockRecovery: Bool
  private let blockPlayoutRecovery: Bool
  private let waitForRecoveryCancellation: Bool
  private let blockInputDeviceID: String?
  private let inputMutationStartsRecording: Bool
  private var shutdownFailuresRemaining: Int?
  private var prepareFailuresAfterMutation: [Bool: Int]
  private var configureBlocksRemaining: Int
  private var inputBlocksRemaining: Int
  private var inputFailuresRemaining: [String: Int]
  private var inputRestorationsRemaining: [String: Int]
  private var inputTransientRestorationsRemaining: [String: Int]
  private var outputFailuresRemaining: [String: Int]
  private let outputFailuresRestorePrevious: Bool
  private let volatileRuntimeDiagnostics: Bool
  private var engineRunning = false
  private var recordingActive = false
  private var recordingExpected = false
  private var playingActive = false
  private var inputRouteValid = true
  private var outputRouteValid = true
  private var currentOutputDeviceID = "built-in-output"
  private var processing: InlineRTCAudioProcessingState?
  private var configureContinuation: CheckedContinuation<Void, Never>?
  private var prepareContinuation: CheckedContinuation<Void, Never>?
  private var recoveryContinuation: CheckedContinuation<Void, Never>?
  private var playoutRecoveryContinuation: CheckedContinuation<Void, Never>?
  private var recoveryCancellationObserved = false
  private var inputContinuations: [CheckedContinuation<Void, Never>] = []
  private var runtimeHealthReads = 0
  private var inventoryReads = 0
  private var routeEpoch: UInt64 = 0
  private var outputSampleRate = 48_000.0

  init(
    availableDeviceIDs: Set<String> = ["built-in", "usb"],
    availableOutputDeviceIDs: Set<String> = ["built-in-output", "airpods"],
    blockConfigure: Bool = false,
    blockPrepare: Bool = false,
    configureFailures: Int = 0,
    recoveryRunningResults: [Bool] = [],
    blockRecovery: Bool = false,
    blockPlayoutRecovery: Bool = false,
    waitForRecoveryCancellation: Bool = false,
    blockInputDeviceID: String? = nil,
    blockedInputCalls: Int = 1,
    inputMutationStartsRecording: Bool = false,
    shutdownFailures: Int? = nil,
    prepareFailuresAfterMutation: [Bool: Int] = [:],
    inputFailures: [String: Int] = [:],
    inputRestorations: [String: Int] = [:],
    inputTransientRestorations: [String: Int] = [:],
    outputFailures: [String: Int] = [:],
    outputFailuresRestorePrevious: Bool = false,
    volatileRuntimeDiagnostics: Bool = false,
    preparationRequiresRTCTransport: Bool = false,
    recordingStartsWithMicrophoneSender: Bool = false,
    recoveredInput _: ResolvedAudioInput? = nil
  ) {
    let stream = AsyncStream.makeStream(
      of: GridAudioDriverEvent.self,
      bufferingPolicy: .bufferingNewest(16)
    )
    events = stream.stream
    eventContinuation = stream.continuation
    self.availableDeviceIDs = availableDeviceIDs
    self.availableOutputDeviceIDs = availableOutputDeviceIDs
    self.blockConfigure = blockConfigure
    self.blockPrepare = blockPrepare
    configureBlocksRemaining = blockConfigure ? 1 : 0
    configureFailuresRemaining = configureFailures
    self.recoveryRunningResults = recoveryRunningResults
    self.blockRecovery = blockRecovery
    self.blockPlayoutRecovery = blockPlayoutRecovery
    self.waitForRecoveryCancellation = waitForRecoveryCancellation
    self.blockInputDeviceID = blockInputDeviceID
    self.inputMutationStartsRecording = inputMutationStartsRecording
    shutdownFailuresRemaining = shutdownFailures.map { max($0, 0) }
    self.prepareFailuresAfterMutation = prepareFailuresAfterMutation
    inputBlocksRemaining = blockInputDeviceID == nil ? 0 : max(blockedInputCalls, 0)
    inputFailuresRemaining = inputFailures
    inputRestorationsRemaining = inputRestorations
    inputTransientRestorationsRemaining = inputTransientRestorations
    outputFailuresRemaining = outputFailures
    self.outputFailuresRestorePrevious = outputFailuresRestorePrevious
    self.volatileRuntimeDiagnostics = volatileRuntimeDiagnostics
    self.preparationRequiresRTCTransport = preparationRequiresRTCTransport
    self.recordingStartsWithMicrophoneSender = recordingStartsWithMicrophoneSender
  }

  func configure(_: InlineRTCConfiguration) async throws {
    log.append("configure")
    if configureFailuresRemaining > 0 {
      configureFailuresRemaining -= 1
      throw FakeGridAudioDriverError.configureFailed
    }
    if blockConfigure, configureBlocksRemaining > 0 {
      configureBlocksRemaining -= 1
      await withCheckedContinuation { continuation in
        configureContinuation = continuation
      }
    }
  }

  func resumeAfterTerminalShutdown() async {
    log.append("resume-terminal-gate")
  }

  func setPrepared(_ prepared: Bool) async throws {
    log.append("prepared:\(prepared)")
    if prepared, blockPrepare {
      await withCheckedContinuation { continuation in
        prepareContinuation = continuation
      }
    }
    engineRunning = prepared
    recordingActive = prepared
    playingActive = prepared
    if let failuresRemaining = prepareFailuresAfterMutation[prepared],
       failuresRemaining > 0 {
      prepareFailuresAfterMutation[prepared] = failuresRemaining - 1
      throw FakeGridAudioDriverError.prepareFailed
    }
  }

  func stopForShutdown() async -> GridAudioDriverShutdownReceipt {
    if let failuresRemaining = shutdownFailuresRemaining {
      log.append("shutdown-attempt")
      if failuresRemaining > 0 {
        shutdownFailuresRemaining = failuresRemaining - 1
        return GridAudioDriverShutdownReceipt(
          recordingStopped: false,
          playoutStopped: false,
          failures: ["injected terminal stop failure"]
        )
      }
    }

    do {
      try await setPrepared(false)
    } catch {
      return GridAudioDriverShutdownReceipt(
        recordingStopped: false,
        playoutStopped: false,
        failures: [String(describing: error)]
      )
    }
    return GridAudioDriverShutdownReceipt(
      recordingStopped: !recordingActive,
      playoutStopped: !playingActive,
      failures: []
    )
  }

  func recoverPreparedAudio(preserving target: AudioInputRouteTarget?) async throws {
    log.append("recover")
    log.append("recover-target:\(target?.logDescription ?? "unknown")")
    if waitForRecoveryCancellation {
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        recoveryCancellationObserved = true
        throw error
      }
    }
    if blockRecovery {
      await withCheckedContinuation { continuation in
        recoveryContinuation = continuation
      }
    }
    engineRunning = recoveryRunningResults.isEmpty ? true : recoveryRunningResults.removeFirst()
    recordingActive = engineRunning
    playingActive = engineRunning
    inputRouteValid = true
    outputRouteValid = true
  }

  func recoverPlayout(preserving _: AudioOutputRouteTarget?) async throws {
    log.append("recover-playout")
    if blockPlayoutRecovery {
      await withCheckedContinuation { continuation in
        playoutRecoveryContinuation = continuation
      }
    }
    engineRunning = true
    playingActive = true
  }

  func isAudioEngineRunning() async -> Bool {
    engineRunning
  }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    runtimeHealthReads += 1
    return GridAudioRuntimeHealth(
      isEngineRunning: engineRunning,
      isRecording: recordingActive,
      isRecordingExpected: recordingStartsWithMicrophoneSender ? recordingExpected : nil,
      isPlaying: playingActive,
      route: InlineRTCAudioRoute(
        currentInputID: "built-in",
        defaultInputID: "built-in",
        currentOutputID: outputRouteValid ? currentOutputDeviceID : "missing-output",
        defaultOutputID: "built-in-output",
        inputDeviceCount: availableDeviceIDs.count,
        outputDeviceCount: 1,
        isInputRouteValid: inputRouteValid,
        isOutputRouteValid: outputRouteValid,
        routeEpoch: routeEpoch,
        inputCallbackCount: volatileRuntimeDiagnostics ? UInt64(runtimeHealthReads) : nil,
        outputCallbackCount: volatileRuntimeDiagnostics ? UInt64(runtimeHealthReads) : nil,
        inputCallbackAgeMilliseconds: volatileRuntimeDiagnostics
          ? UInt64(runtimeHealthReads % 3)
          : nil,
        outputCallbackAgeMilliseconds: volatileRuntimeDiagnostics
          ? UInt64(runtimeHealthReads % 3)
          : nil,
        measuredInputDelayMilliseconds: volatileRuntimeDiagnostics
          ? UInt16(runtimeHealthReads % 20)
          : nil,
        measuredOutputDelayMilliseconds: volatileRuntimeDiagnostics
          ? UInt16(runtimeHealthReads % 20)
          : nil
      ),
      processing: processing
    )
  }

  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio: Bool
  ) async throws -> GridAudioInputRouteApplication {
    let failureKey: String
    switch target {
    case .automatic:
      log.append("input:automatic")
      failureKey = "automatic"
    case let .device(id, _):
      log.append("input:\(id)")
      failureKey = id
      if blockInputDeviceID == id, inputBlocksRemaining > 0 {
        inputBlocksRemaining -= 1
        await withCheckedContinuation { continuation in
          inputContinuations.append(continuation)
        }
      }
      guard availableDeviceIDs.contains(id) else { throw FakeGridAudioDriverError.deviceUnavailable }
    }
    if let failures = inputFailuresRemaining[failureKey], failures > 0 {
      inputFailuresRemaining[failureKey] = failures - 1
      throw FakeGridAudioDriverError.deviceUnavailable
    }
    if let restorations = inputRestorationsRemaining[failureKey], restorations > 0 {
      inputRestorationsRemaining[failureKey] = restorations - 1
      return .restoredPreviousRoute(failure: "injected route start failure")
    }
    if let restorations = inputTransientRestorationsRemaining[failureKey], restorations > 0 {
      inputTransientRestorationsRemaining[failureKey] = restorations - 1
      return .restoredPreviousRoute(
        failure: "injected transient route start failure",
        retryable: true
      )
    }
    if restartPreparedAudio || inputMutationStartsRecording {
      engineRunning = true
      recordingActive = true
      playingActive = true
    }
    return .committed
  }

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    inventoryReads += 1
    return AudioInputDeviceInventory(
      automaticDeviceID: "built-in",
      automaticDeviceName: "Built-in Microphone",
      devices: availableDeviceIDs.sorted().map {
        AudioInputDeviceDescriptor(id: $0, name: $0, isSystemDefault: $0 == "built-in", systemImage: "mic.fill")
      },
      routeEpoch: routeEpoch
    )
  }

  func applyOutputRoute(_ target: AudioOutputRouteTarget) async throws {
    let failureKey: String
    let selectedID: String
    switch target {
    case .automatic:
      log.append("output:automatic")
      failureKey = "automatic"
      selectedID = "built-in-output"
    case let .device(id, _):
      log.append("output:\(id)")
      failureKey = id
      selectedID = id
      guard availableOutputDeviceIDs.contains(id) else {
        throw FakeGridAudioDriverError.deviceUnavailable
      }
    }
    if let failures = outputFailuresRemaining[failureKey], failures > 0 {
      outputFailuresRemaining[failureKey] = failures - 1
      outputRouteValid = outputFailuresRestorePrevious
      throw FakeGridAudioDriverError.deviceUnavailable
    }
    currentOutputDeviceID = selectedID
    outputRouteValid = true
  }

  func outputDeviceInventory() async -> AudioOutputDeviceInventory {
    let devices = availableOutputDeviceIDs.sorted().map {
      AudioOutputDeviceDescriptor(
        id: $0,
        name: $0,
        isSystemDefault: $0 == "built-in-output",
        systemImage: "speaker.wave.2"
      )
    }
    let fingerprint = AudioOutputRouteFingerprint(
      sampleRate: outputSampleRate,
      channelCount: 2,
      bytesPerPacket: 4,
      framesPerPacket: 1,
      bytesPerFrame: 4,
      bitsPerChannel: 16,
      formatID: 1,
      formatFlags: 0,
      bufferFrameSize: 512,
      transport: 0,
      isAlive: true
    )
    return AudioOutputDeviceInventory(
      automaticDeviceID: "built-in-output",
      automaticDeviceName: "Built-in Output",
      devices: devices,
      routeFingerprints: Dictionary(
        uniqueKeysWithValues: devices.map { ($0.id, fingerprint) }
      ),
      routeEpoch: routeEpoch
    )
  }

  func operations() -> [String] {
    log
  }

  func inventoryReadCount() -> Int {
    inventoryReads
  }

  func failNextInput(_ key: String) {
    inputFailuresRemaining[key, default: 0] += 1
  }

  func emit(_ event: GridAudioDriverEvent) {
    switch event {
    case .engineStarting:
      engineRunning = true
      playingActive = true
    case .engineStopped, .engineDisabled, .expectedEngineStop, .expectedEngineDisable:
      engineRunning = false
      recordingActive = false
      playingActive = false
    case .devicesChanged:
      break
    }
    eventContinuation.yield(event)
  }

  func releaseConfigure() {
    configureContinuation?.resume()
    configureContinuation = nil
  }

  func releasePrepare() {
    prepareContinuation?.resume()
    prepareContinuation = nil
  }

  func setEngineRunning(_ running: Bool) {
    engineRunning = running
    if !running {
      recordingActive = false
      playingActive = false
    }
  }

  func setRecordingActive(_ active: Bool) {
    recordingActive = active
  }

  func setRecordingExpected(_ expected: Bool) {
    recordingExpected = expected
  }

  func setPlayingActive(_ active: Bool) {
    playingActive = active
  }

  func setOutputRouteValid(_ valid: Bool) {
    outputRouteValid = valid
  }

  func setInputRouteValid(_ valid: Bool) {
    inputRouteValid = valid
  }

  func setProcessing(_ processing: InlineRTCAudioProcessingState?) {
    self.processing = processing
  }

  func setAvailableDeviceIDs(_ ids: Set<String>) {
    availableDeviceIDs = ids
  }

  func setAvailableOutputDeviceIDs(_ ids: Set<String>) {
    availableOutputDeviceIDs = ids
  }

  func setRouteEpoch(_ epoch: UInt64) {
    routeEpoch = epoch
  }

  func setOutputSampleRate(_ sampleRate: Double) {
    outputSampleRate = sampleRate
  }

  func releaseRecovery() {
    recoveryContinuation?.resume()
    recoveryContinuation = nil
  }

  func releasePlayoutRecovery() {
    playoutRecoveryContinuation?.resume()
    playoutRecoveryContinuation = nil
  }

  func didObserveRecoveryCancellation() -> Bool {
    recoveryCancellationObserved
  }

  func releaseInput() {
    let continuations = inputContinuations
    inputContinuations.removeAll()
    continuations.forEach { $0.resume() }
  }

}

private enum FakeGridAudioDriverError: LocalizedError {
  case configureFailed
  case deviceUnavailable
  case prepareFailed

  var errorDescription: String? {
    switch self {
    case .configureFailed: "configure failed"
    case .deviceUnavailable: "device unavailable"
    case .prepareFailed: "prepare failed"
    }
  }
}

private enum EventuallyError: Error {
  case timedOut
}

private func eventually(
  timeout: Duration = .seconds(1),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw EventuallyError.timedOut
}
