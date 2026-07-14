import Foundation
import Testing

@testable import InlineRTC

@Suite("Grid audio engine", .serialized)
struct GridAudioEngineTests {
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
    await engine.shutdown()

    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.state == .cold)
    #expect(snapshot.isPrepared == false)
    #expect(snapshot.captureLeaseCount == 0)
    #expect(await driver.operations().filter { $0 == "prepared:false" }.count == 1)
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
    await engine.start()
    try await eventually { await driver.operations().contains("configure") }

    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))
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

    await engine.start()
    try await eventually { await driver.operations().contains("configure") }
    await engine.setInput(.device(id: "usb", rememberedName: "USB Microphone"))
    try await eventually { await driver.operations().contains("input:usb") }

    #expect(await driver.operations().filter { $0 == "input:automatic" }.isEmpty)
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

    await engine.setInput(preferred)
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
      engineRecoveryDelay: .milliseconds(60)
    )
    let lease = GridAudioLease.connectionDemand(.init("grid-test:1:2:1"))

    await engine.setInput(.automatic)
    await engine.acquireCaptureLease(lease)
    try await eventually { await engine.currentSnapshot().isPrepared }
    await driver.emit(.engineStopped(playout: true, recording: true))
    try await Task.sleep(for: .milliseconds(15))
    await driver.emit(.engineStarting(playout: true, recording: true))
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

  @Test("lifetime health recovers an invalid output route even while engine is running")
  func lifetimeHealthDetectsInvalidOutputRoute() async throws {
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
      let recovered = await driver.operations().contains("recover")
      let snapshot = await engine.currentSnapshot()
      return recovered && snapshot.route?.isOutputRouteValid == true && snapshot.isPrepared
    }
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

  @Test("removing a preferred input applies automatic once and preserves preference")
  func removedPreferenceFallsBackOnce() async throws {
    let preferred = AudioInputSelection.device(id: "usb", rememberedName: "usb")
    let driver = FakeGridAudioDriver()
    let engine = GridAudioEngine(
      driver: driver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      deviceChangeSettleDelay: .milliseconds(10)
    )

    await engine.start()
    await engine.setInput(preferred)
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

    await engine.start()
    await engine.setInput(preferred)
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

    await engine.setInput(preferred)
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
  private nonisolated let eventContinuation: AsyncStream<GridAudioDriverEvent>.Continuation
  private var log: [String] = []
  private var availableDeviceIDs: Set<String>
  private let blockConfigure: Bool
  private var configureFailuresRemaining: Int
  private var recoveryRunningResults: [Bool]
  private let blockRecovery: Bool
  private let waitForRecoveryCancellation: Bool
  private let blockInputDeviceID: String?
  private var configureBlocksRemaining: Int
  private var inputBlocksRemaining: Int
  private var inputFailuresRemaining: [String: Int]
  private var engineRunning = false
  private var recordingActive = false
  private var inputRouteValid = true
  private var outputRouteValid = true
  private var configureContinuation: CheckedContinuation<Void, Never>?
  private var recoveryContinuation: CheckedContinuation<Void, Never>?
  private var recoveryCancellationObserved = false
  private var inputContinuations: [CheckedContinuation<Void, Never>] = []

  init(
    availableDeviceIDs: Set<String> = ["built-in", "usb"],
    blockConfigure: Bool = false,
    configureFailures: Int = 0,
    recoveryRunningResults: [Bool] = [],
    blockRecovery: Bool = false,
    waitForRecoveryCancellation: Bool = false,
    blockInputDeviceID: String? = nil,
    blockedInputCalls: Int = 1,
    inputFailures: [String: Int] = [:],
    recoveredInput _: ResolvedAudioInput? = nil
  ) {
    let stream = AsyncStream.makeStream(
      of: GridAudioDriverEvent.self,
      bufferingPolicy: .bufferingNewest(16)
    )
    events = stream.stream
    eventContinuation = stream.continuation
    self.availableDeviceIDs = availableDeviceIDs
    self.blockConfigure = blockConfigure
    configureBlocksRemaining = blockConfigure ? 1 : 0
    configureFailuresRemaining = configureFailures
    self.recoveryRunningResults = recoveryRunningResults
    self.blockRecovery = blockRecovery
    self.waitForRecoveryCancellation = waitForRecoveryCancellation
    self.blockInputDeviceID = blockInputDeviceID
    inputBlocksRemaining = blockInputDeviceID == nil ? 0 : max(blockedInputCalls, 0)
    inputFailuresRemaining = inputFailures
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

  func setPrepared(_ prepared: Bool) async throws {
    log.append("prepared:\(prepared)")
    engineRunning = prepared
    recordingActive = prepared
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
    outputRouteValid = true
  }

  func isAudioEngineRunning() async -> Bool {
    engineRunning
  }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    GridAudioRuntimeHealth(
      isEngineRunning: engineRunning,
      isRecording: recordingActive,
      isPlaying: engineRunning,
      route: InlineRTCAudioRoute(
        currentInputID: "built-in",
        defaultInputID: "built-in",
        currentOutputID: outputRouteValid ? "built-in-output" : "missing-output",
        defaultOutputID: "built-in-output",
        inputDeviceCount: availableDeviceIDs.count,
        outputDeviceCount: 1,
        isInputRouteValid: inputRouteValid,
        isOutputRouteValid: outputRouteValid
      )
    )
  }

  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio: Bool
  ) async throws {
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
    if restartPreparedAudio { engineRunning = true }
  }

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    AudioInputDeviceInventory(
      automaticDeviceID: "built-in",
      automaticDeviceName: "Built-in Microphone",
      devices: availableDeviceIDs.sorted().map {
        AudioInputDeviceDescriptor(id: $0, name: $0, isSystemDefault: $0 == "built-in", systemImage: "mic.fill")
      },
      routeEpoch: 0
    )
  }

  func operations() -> [String] {
    log
  }

  func failNextInput(_ key: String) {
    inputFailuresRemaining[key, default: 0] += 1
  }

  func emit(_ event: GridAudioDriverEvent) {
    switch event {
    case .engineStarting:
      engineRunning = true
    case .engineStopped, .engineDisabled, .expectedEngineStop, .expectedEngineDisable:
      engineRunning = false
      recordingActive = false
    case .devicesChanged:
      break
    }
    eventContinuation.yield(event)
  }

  func releaseConfigure() {
    configureContinuation?.resume()
    configureContinuation = nil
  }

  func setEngineRunning(_ running: Bool) {
    engineRunning = running
    if !running { recordingActive = false }
  }

  func setRecordingActive(_ active: Bool) {
    recordingActive = active
  }

  func setOutputRouteValid(_ valid: Bool) {
    outputRouteValid = valid
  }

  func setInputRouteValid(_ valid: Bool) {
    inputRouteValid = valid
  }

  func setAvailableDeviceIDs(_ ids: Set<String>) {
    availableDeviceIDs = ids
  }

  func releaseRecovery() {
    recoveryContinuation?.resume()
    recoveryContinuation = nil
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

  var errorDescription: String? {
    switch self {
    case .configureFailed: "configure failed"
    case .deviceUnavailable: "device unavailable"
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
