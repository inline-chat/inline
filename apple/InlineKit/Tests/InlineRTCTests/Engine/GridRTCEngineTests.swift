import Foundation
import Testing

@testable import InlineRTC

@Suite("Grid RTC engine", .serialized)
struct GridRTCEngineTests {
  @Test("process mailbox coalesces replaceable work without dropping shutdown")
  func processMailboxCoalescing() throws {
    let mailbox = GridEngineCommandMailbox()
    let target = InlineRTCSessionID("grid-test:1:9:1")
    for index in 0 ..< 1_000 {
      mailbox.enqueue(.setDemand(demand(
        target: target,
        microphoneEnabled: index.isMultiple(of: 2)
      )))
    }
    #expect(mailbox.pendingCount == 1)

    for _ in 0 ..< 1_000 {
      mailbox.enqueue(.networkBecameAvailable)
      mailbox.enqueue(.requestMicrophonePermission)
    }
    #expect(mailbox.pendingCount == 3)

    let firstShutdownID = UUID()
    let secondShutdownID = UUID()
    mailbox.enqueue(.shutdown(requestID: firstShutdownID))
    mailbox.enqueue(.shutdown(requestID: secondShutdownID))
    #expect(mailbox.pendingCount == 5)

    let commands = try (0 ..< 5).map { _ in try #require(mailbox.dequeue()) }
    guard case let .setDemand(latestDemand) = commands[0] else {
      Issue.record("Expected the coalesced demand first")
      return
    }
    #expect(latestDemand.target == target)
    #expect(latestDemand.microphoneEnabled == false)
    #expect(commands[1] == .networkBecameAvailable)
    #expect(commands[2] == .requestMicrophonePermission)
    #expect(commands[3] == .shutdown(requestID: firstShutdownID))
    #expect(commands[4] == .shutdown(requestID: secondShutdownID))
    mailbox.finish()
  }

  @Test("connect publishes one already-muted microphone track")
  func mutedPublicationOrder() async throws {
    let audioDriver = RTCFakeAudioDriver()
    let audio = GridAudioEngine(
      driver: audioDriver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(20)
    )
    let rtcDriver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: rtcDriver)
    let target = InlineRTCSessionID("grid-test:1:10:2")

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.state == .connected(target) && snapshot.microphonePublicationState == .published
    }

    let operations = await rtcDriver.operations()
    let connectIndex = try #require(operations.firstIndex(of: "connect:10"))
    let publishIndex = try #require(operations.firstIndex(of: "publish:10:muted=true"))
    #expect(connectIndex < publishIndex)
    #expect(await rtc.currentSnapshot().microphonePublished)
    #expect(await rtc.currentSnapshot().microphoneMuted)
  }

  @Test("remote output gain follows demand independently of the audio device backend")
  func outputVolumeFollowsDemand() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:12:1")

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      outputVolume: 0.4
    ))
    try await eventuallyRTC {
      await driver.operations().contains("volume:12:0.4")
    }

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      outputVolume: 0.7
    ))
    try await eventuallyRTC {
      await driver.operations().contains("volume:12:0.7")
    }
  }

  @Test("microphone intent coalesces to the latest value")
  func microphoneIntentCoalesces() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:11:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC { await rtc.currentSnapshot().microphoneMuted }

    #expect(await rtc.currentSnapshot().state == .connected(target))
    #expect(await driver.currentMutedState(roomID: 11) == true)
  }

  @Test("stale generation cannot win after a suspended connect")
  func staleConnectCannotWin() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(blockedRoomID: 20)
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let first = InlineRTCSessionID("grid-test:1:20:1")
    let latest = InlineRTCSessionID("grid-test:1:21:2")

    await rtc.setDemand(demand(target: first, microphoneEnabled: true))
    try await eventuallyRTC { await driver.operations().contains("connect:20") }
    await rtc.setDemand(demand(target: latest, microphoneEnabled: true))

    try await eventuallyRTC(timeout: .seconds(2)) {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.state == .connected(latest) && snapshot.microphonePublicationState == .published
    }
    await driver.releaseBlockedConnect()
    try await Task.sleep(for: .milliseconds(20))
    let operations = await driver.operations()
    #expect(operations.contains("disconnect:20"))
    #expect(operations.contains("publish:20:muted=false") == false)
    #expect(operations.contains("connect:21"))
  }

  @Test("initial connect watchdog starts a replacement while the old provider remains stuck")
  func initialConnectWatchdog() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(blockedRoomID: 22)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.initialConnectSlowWarningDelay = 0.01
    configuration.connection.initialConnectWatchdogTimeout = 0.03
    configuration.connection.audioPreparationConnectWaitTimeout = 0
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:22:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC {
      guard case let .backingOff(backoffTarget, attempt, _) = await rtc.currentSnapshot().state else {
        return false
      }
      return backoffTarget == target && attempt == 1
    }
    try await eventuallyRTC {
      await driver.operations().contains("disconnect:22")
    }

    let operations = await driver.operations()
    #expect(operations.contains("silence:22"))
    #expect(operations.contains("disconnect:22"))
    #expect(operations.contains("publish:22:muted=true") == false)

    // The first provider call deliberately remains suspended and ignores the
    // watchdog's cancellation. Logical worker ownership must still be free for
    // the backoff to start a second concrete room attempt.
    try await eventuallyRTC(timeout: .seconds(2)) {
      await driver.operations().filter { $0 == "connect:22" }.count >= 2
    }

    // Let the intentionally suspended fake provider calls unwind. Their stale
    // completions must not publish from both the retired and current handles.
    await driver.releaseBlockedConnect()
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.state == .connected(target)
        && snapshot.microphonePublicationState == .published
    }
    #expect(await driver.operations().filter { $0 == "publish:22:muted=true" }.count == 1)
  }

  @Test("repeated stuck connects open a bounded circuit until retired calls return")
  func connectCircuitBreaker() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(blockedRoomID: 25, blockedConnectCalls: 2)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.initialConnectSlowWarningDelay = 0.01
    configuration.connection.initialConnectWatchdogTimeout = 0.03
    configuration.connection.providerTeardownTimeout = 0.05
    configuration.connection.maxAbandonedProviderOperations = 2
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:25:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC(timeout: .seconds(3)) {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.providerCircuitOpen
        && snapshot.abandonedProviderOperationCount == 2
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await driver.operations().filter { $0 == "connect:25" }.count == 2)

    await driver.releaseBlockedConnect()
    try await eventuallyRTC(timeout: .seconds(2)) {
      let snapshot = await rtc.currentSnapshot()
      return !snapshot.providerCircuitOpen
        && snapshot.abandonedProviderOperationCount == 0
        && snapshot.state == .connected(target)
        && snapshot.microphonePublicationState == .published
    }
    #expect(await driver.operations().filter { $0 == "connect:25" }.count == 3)
  }

  @Test("a hung microphone publication is retired and replaced")
  func microphonePublicationWatchdog() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(blockedPublishRoomID: 23)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.microphonePublishWatchdogTimeout = 0.03
    configuration.connection.roomSilenceTimeout = 0.02
    configuration.connection.providerTeardownTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:23:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC { await driver.operations().contains("publish:23:muted=true") }
    try await eventuallyRTC(timeout: .seconds(2)) {
      let snapshot = await rtc.currentSnapshot()
      let connectCount = await driver.operations().filter { $0 == "connect:23" }.count
      return connectCount >= 2
        && snapshot.state == .connected(target)
        && snapshot.microphonePublicationState == .published
        && !snapshot.microphoneMuted
    }

    await driver.releaseBlockedPublish()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await driver.operations().filter { $0 == "publish:23:muted=true" }.count == 2)
    #expect(await rtc.currentSnapshot().state == .connected(target))
  }

  @Test("a hung microphone mute is retired and replaced")
  func microphoneMuteWatchdog() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(blockedMuteRoomID: 24)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.microphoneMuteWatchdogTimeout = 0.03
    configuration.connection.roomSilenceTimeout = 0.02
    configuration.connection.providerTeardownTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:24:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC { await driver.operations().contains("mute:24:false") }
    try await eventuallyRTC(timeout: .seconds(2)) {
      let snapshot = await rtc.currentSnapshot()
      let connectCount = await driver.operations().filter { $0 == "connect:24" }.count
      return connectCount >= 2
        && snapshot.state == .connected(target)
        && snapshot.microphonePublicationState == .published
        && !snapshot.microphoneMuted
    }

    await driver.releaseBlockedMute()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await rtc.currentSnapshot().state == .connected(target))
  }

  @Test("leave silences before asynchronous disconnect")
  func leaveSilencesFirst() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(disconnectDelay: .milliseconds(80))
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:30:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    await rtc.setDemand(InlineRTCDemand())
    try await eventuallyRTC { await driver.operations().contains("silence:30") }

    let operationsDuringDisconnect = await driver.operations()
    #expect(operationsDuringDisconnect.contains("disconnect-done:30") == false)
    try await eventuallyRTC { await rtc.currentSnapshot().state == .idle }
    try await eventuallyRTC { await driver.operations().contains("disconnect-done:30") }
    let operations = await driver.operations()
    let silenceIndex = try #require(operations.firstIndex(of: "silence:30"))
    let disconnectIndex = try #require(operations.firstIndex(of: "disconnect:30"))
    #expect(silenceIndex < disconnectIndex)
  }

  @Test("a hung silence operation cannot block disconnect or shutdown")
  func hungSilenceIsBounded() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(10)
    )
    let driver = FakeGridRTCDriver(blockSilenceRoomID: 36)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.roomSilenceTimeout = 0.03
    configuration.connection.providerTeardownTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:36:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    await rtc.setDemand(InlineRTCDemand())
    try await eventuallyRTC { await driver.operations().contains("silence:36") }
    try await eventuallyRTC(timeout: .milliseconds(250)) {
      await driver.operations().contains("disconnect:36")
    }

    let shutdownStartedAt = ContinuousClock.now
    await rtc.shutdown()
    #expect(shutdownStartedAt.duration(to: .now) < .milliseconds(250))
    await driver.releaseBlockedSilence()
  }

  @Test("room switch retires the previous provider before starting the replacement")
  func roomSwitchSerializesRoutineRetirement() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(disconnectDelay: .milliseconds(80))
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.retirementBarrierTimeout = 0.2
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let first = InlineRTCSessionID("grid-test:1:33:1")
    let second = InlineRTCSessionID("grid-test:1:34:1")

    await rtc.setDemand(demand(target: first, microphoneEnabled: false))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    await rtc.setDemand(demand(target: second, microphoneEnabled: false))
    try await eventuallyRTC { await driver.operations().contains("connect:34") }

    let operations = await driver.operations()
    let retiredIndex = try #require(operations.firstIndex(of: "disconnect-done:33"))
    let replacementIndex = try #require(operations.firstIndex(of: "connect:34"))
    #expect(retiredIndex < replacementIndex)
  }

  @Test("hung provider teardown releases Grid leases and cannot block shutdown")
  func hungProviderTeardownIsBounded() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(10)
    )
    let driver = FakeGridRTCDriver(blockDisconnectRoomID: 35)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.retirementBarrierTimeout = 0.01
    configuration.connection.providerTeardownTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:35:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    await rtc.setDemand(InlineRTCDemand())
    try await eventuallyRTC { await driver.operations().contains("disconnect:35") }

    let shutdownStartedAt = ContinuousClock.now
    await rtc.shutdown()
    let shutdownDuration = shutdownStartedAt.duration(to: .now)
    #expect(shutdownDuration < .milliseconds(200))
    #expect(await rtc.currentSnapshot().state == .idle)
    try await eventuallyRTC {
      await audio.currentSnapshot().captureLeaseCount == 0
    }

    await driver.releaseBlockedDisconnect(roomID: 35)
  }

  @Test("repeated stuck disconnects cannot accumulate beyond the provider circuit")
  func disconnectCircuitBreaker() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(10)
    )
    let driver = FakeGridRTCDriver(blockDisconnectRoomID: 39)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.retirementBarrierTimeout = 0.01
    configuration.connection.providerTeardownTimeout = 0.03
    configuration.connection.maxAbandonedProviderOperations = 2
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:39:1")

    for expectedCount in 1 ... 2 {
      await rtc.setDemand(demand(target: target, microphoneEnabled: false))
      try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
      await rtc.setDemand(InlineRTCDemand())
      try await eventuallyRTC {
        await rtc.currentSnapshot().abandonedProviderOperationCount == expectedCount
      }
    }
    #expect(await rtc.currentSnapshot().providerCircuitOpen)

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await driver.operations().filter { $0 == "connect:39" }.count == 2)
    #expect(await driver.operations().filter { $0 == "disconnect:39" }.count == 2)

    await driver.releaseBlockedDisconnect(roomID: 39)
    try await eventuallyRTC(timeout: .seconds(2)) {
      let snapshot = await rtc.currentSnapshot()
      return !snapshot.providerCircuitOpen
        && snapshot.abandonedProviderOperationCount == 0
        && snapshot.state == .connected(target)
    }
    #expect(await driver.operations().filter { $0 == "connect:39" }.count == 3)
  }

  @Test("microphone publication failure preserves the connected room")
  func publicationFailureDoesNotTearDownRoom() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(publishFailures: 1)
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:31:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      guard snapshot.state == .connected(target) else { return false }
      if case .failed = snapshot.microphonePublicationState { return true }
      return false
    }

    #expect(await driver.operations().filter { $0 == "connect:31" }.count == 1)
    #expect(await driver.operations().contains("disconnect:31") == false)

    // A network recovery signal retries only the failed media substate.
    await rtc.networkBecameAvailable()
    try await eventuallyRTC {
      await rtc.currentSnapshot().microphonePublicationState == .published
    }
    #expect(await driver.operations().filter { $0 == "connect:31" }.count == 1)
    #expect(await driver.operations().contains("disconnect:31") == false)
  }

  @Test("repeated network and wake signals keep a healthy provider room intact")
  func healthyRecoverySignalsAreNondestructive() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:32:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.state == .connected(target)
        && snapshot.microphonePublicationState == .published
        && !snapshot.microphoneMuted
    }

    for _ in 0 ..< 100 {
      await rtc.networkBecameAvailable()
      await rtc.applicationDidWake()
    }
    try await Task.sleep(for: .milliseconds(30))

    let snapshot = await rtc.currentSnapshot()
    let operations = await driver.operations()
    #expect(snapshot.state == .connected(target))
    #expect(snapshot.reconnectCount == 0)
    #expect(operations.filter { $0 == "connect:32" }.count == 1)
    #expect(operations.filter { $0 == "publish:32:muted=true" }.count == 1)
    #expect(operations.filter { $0 == "mute:32:false" }.count == 1)
    #expect(operations.contains("disconnect:32") == false)
  }

  @Test("missing local PCM is visible and recovers without lying about publication")
  func localAudioFlowHealth() async throws {
    let audioDriver = RTCFakeAudioDriver()
    let audio = GridAudioEngine(
      driver: audioDriver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:37:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.microphonePublicationState == .published && !snapshot.microphoneMuted
    }
    await driver.emitToCurrentRoom(.localAudioFlow(.missing))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      guard snapshot.localAudioFlowState == .missing else { return false }
      if case .failed = snapshot.microphonePublicationState { return true }
      return false
    }
    try await eventuallyRTC { await audioDriver.operations().contains("recover") }

    await driver.emitToCurrentRoom(.localAudioFlow(.flowing))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.localAudioFlowState == .flowing
        && snapshot.microphonePublicationState == .published
        && snapshot.lastError == nil
    }
    #expect(await driver.operations().filter { $0 == "connect:37" }.count == 1)
  }

  @Test("missing remote PCM is visible and clears when delivery resumes")
  func remoteAudioFlowHealth() async throws {
    let audioDriver = RTCFakeAudioDriver()
    let audio = GridAudioEngine(
      driver: audioDriver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:38:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    await driver.emitToCurrentRoom(.remoteAudioFlow(identity: "remote", state: .missing))
    try await eventuallyRTC {
      await rtc.currentSnapshot().remoteAudioFlowStates["remote"] == .missing
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await audioDriver.operations().contains("recover") == false)

    await driver.emitToCurrentRoom(.remoteAudioFlow(identity: "remote", state: .flowing))
    try await eventuallyRTC {
      await rtc.currentSnapshot().remoteAudioFlowStates["remote"] == .flowing
    }
    #expect(await rtc.currentSnapshot().state == .connected(target))
    #expect(await driver.operations().filter { $0 == "connect:38" }.count == 1)
  }

  @Test("denied microphone permission still allows a listen-only connection")
  func deniedPermissionConnectsListenOnly() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied, requested: .denied)
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:32:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.state == .connected(target)
        && snapshot.microphonePublicationState == .waitingForPermission
    }

    #expect(await driver.operations().contains("connect:32"))
    #expect(await driver.operations().contains("publish:32:muted=true") == false)
  }

  @Test("mic intent changing during publication does not replace the room")
  func intentChangeDuringPublicationKeepsRoom() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(blockedPublishRoomID: 32)
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:32:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC { await driver.operations().contains("publish:32:muted=true") }
    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    await driver.releaseBlockedPublish()

    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.microphonePublicationState == .published && snapshot.microphoneMuted
    }
    let operations = await driver.operations()
    #expect(operations.filter { $0 == "connect:32" }.count == 1)
    #expect(operations.filter { $0 == "publish:32:muted=true" }.count == 1)
    #expect(operations.contains("disconnect:32") == false)
  }

  @Test("process engine preserves command order and broadcasts coherent snapshots")
  func processEngineMailbox() async throws {
    let rtcDriver = FakeGridRTCDriver()
    let engine = InlineRTCSession(
      audioDriver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(),
      rtcDriver: rtcDriver,
      captureCooldown: .milliseconds(20)
    )
    let recorder = GridEngineSnapshotRecorder()
    let mirrorRecorder = GridEngineSnapshotRecorder()
    let snapshots = await engine.subscribe()
    let mirrorSnapshots = await engine.subscribe()
    let eventsTask = Task {
      for await snapshot in snapshots {
        guard !Task.isCancelled else { return }
        await recorder.append(snapshot)
      }
    }
    let mirrorEventsTask = Task {
      for await snapshot in mirrorSnapshots {
        guard !Task.isCancelled else { return }
        await mirrorRecorder.append(snapshot)
      }
    }
    defer {
      eventsTask.cancel()
      mirrorEventsTask.cancel()
    }

    await engine.start()
    let target = InlineRTCSessionID("grid-test:1:40:1")
    engine.setDemand(demand(target: target, microphoneEnabled: false))

    try await eventuallyRTC {
      let firstReceived = await recorder.containsRTCState(.connected(target))
      let secondReceived = await mirrorRecorder.containsRTCState(.connected(target))
      return firstReceived && secondReceived
    }
    await rtcDriver.emitToCurrentRoom(.reconnecting(mode: .quick))
    try await eventuallyRTC {
      let firstReceived = await recorder.containsRTCState(.reconnecting(target))
      let secondReceived = await mirrorRecorder.containsRTCState(.reconnecting(target))
      return firstReceived && secondReceived
    }

    // Rapid intent is submitted synchronously in caller order and reconciles
    // to the last value without caller-owned Tasks racing each other.
    engine.setDemand(demand(target: target, microphoneEnabled: true))
    engine.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      await rtcDriver.currentMutedState(roomID: 40) == true
    }

    engine.setDemand(InlineRTCDemand())
    await engine.shutdown()
    #expect(await rtcDriver.operations().contains("disconnect-done:40"))
  }

  @Test("duplicate LiveKit reconnect events count one completed recovery")
  func duplicateReconnectEventsCountOneRecovery() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:42:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }

    await driver.emitToCurrentRoom(.reconnecting(mode: .quick))
    await driver.emitToCurrentRoom(.reconnecting(mode: .quick))
    try await eventuallyRTC {
      let rtcSnapshot = await rtc.currentSnapshot()
      return rtcSnapshot.state == .reconnecting(target)
    }

    await driver.emitToCurrentRoom(.reconnected(mode: .quick))
    await driver.emitToCurrentRoom(.reconnected(mode: .quick))
    try await eventuallyRTC {
      let rtcSnapshot = await rtc.currentSnapshot()
      return rtcSnapshot.state == .connected(target)
    }
    #expect(await rtc.currentSnapshot().reconnectCount == 1)
  }

  @Test("a full reconnect waits for the muted microphone publication to return")
  func fullReconnectWaitsForMicrophoneRepublish() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:43:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    let initialPublishCount = await driver.operations().filter { $0 == "publish:43:muted=true" }.count

    await driver.emitToCurrentRoom(.reconnecting(mode: .full))
    await driver.emitToCurrentRoom(.reconnected(mode: .full))
    await driver.emitToCurrentRoom(.reconnected(mode: .full))
    try await eventuallyRTC {
      let rtcSnapshot = await rtc.currentSnapshot()
      return rtcSnapshot.state == .connected(target)
        && !rtcSnapshot.microphonePublished
    }

    // The SDK fork republishes the same intentionally-muted local track.
    await driver.emitToCurrentRoom(.localMicrophonePublished(muted: true))
    try await eventuallyRTC {
      let rtcSnapshot = await rtc.currentSnapshot()
      return rtcSnapshot.microphonePublicationState == .published
        && rtcSnapshot.microphoneMuted
    }
    #expect(await rtc.currentSnapshot().reconnectCount == 1)
    #expect(await driver.operations().filter { $0 == "publish:43:muted=true" }.count == initialPublishCount)
  }

  @Test("shutdown starts a cold mailbox and acknowledges completion")
  func coldShutdown() async {
    let engine = InlineRTCSession(
      audioDriver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(),
      rtcDriver: FakeGridRTCDriver(),
      captureCooldown: .milliseconds(20)
    )

    await engine.shutdown()
  }

  @Test("permission prompt never blocks room demand or listen-only connection")
  func permissionPromptDoesNotBlockConnection() async throws {
    let permission = BlockingGridMicrophonePermissionDriver()
    let rtcDriver = FakeGridRTCDriver()
    let engine = InlineRTCSession(
      audioDriver: RTCFakeAudioDriver(),
      permissionDriver: permission,
      rtcDriver: rtcDriver,
      captureCooldown: .milliseconds(20)
    )
    let recorder = GridEngineSnapshotRecorder()
    let snapshots = await engine.subscribe()
    let eventsTask = Task {
      for await snapshot in snapshots {
        guard !Task.isCancelled else { return }
        await recorder.append(snapshot)
      }
    }
    defer { eventsTask.cancel() }

    await engine.start()
    engine.requestMicrophonePermission()
    try await eventuallyRTC { await permission.hasStartedRequest() }

    let target = InlineRTCSessionID("grid-test:1:41:1")
    engine.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC {
      await recorder.containsRTCState(.connected(target))
    }
    #expect(await rtcDriver.operations().contains("connect:41"))
    #expect(await rtcDriver.operations().contains("publish:41:muted=true") == false)

    await permission.resolve(.authorized)
    try await eventuallyRTC {
      await rtcDriver.operations().contains("publish:41:muted=true")
    }
  }

  private func demand(
    target: InlineRTCSessionID,
    microphoneEnabled: Bool,
    outputVolume: Float = 1
  ) -> InlineRTCDemand {
    InlineRTCDemand(
      target: target,
      credentials: InlineRTCCredentials(
        target: target,
        serverURL: URL(string: "wss://grid.invalid")!,
        participantIdentity: "test",
        token: "token",
        expiresAt: Date().addingTimeInterval(60)
      ),
      microphoneEnabled: microphoneEnabled,
      outputVolume: outputVolume
    )
  }
}

private actor RTCFakeAudioDriver: GridAudioDriver {
  private var log: [String] = []

  func configure(_: InlineRTCConfiguration) async throws {}
  func setPrepared(_: Bool) async throws {}

  func recoverPreparedAudio(preserving _: AudioInputRouteTarget?) async throws {
    log.append("recover")
  }

  func applyInputRoute(_: AudioInputRouteTarget, restartPreparedAudio _: Bool) async throws {}

  func inputDeviceInventory() async -> AudioInputDeviceInventory {
    AudioInputDeviceInventory(
      automaticDeviceID: "default",
      automaticDeviceName: "Default Microphone",
      devices: [],
      routeEpoch: 0
    )
  }

  func operations() -> [String] {
    log
  }
}

private actor FakeGridRTCDriver: GridRTCDriver {
  nonisolated let lifecycleEvents: AsyncStream<GridRTCLifecycleEventEnvelope>
  nonisolated let participantSnapshots: AsyncStream<GridRTCParticipantSnapshotEnvelope>
  private nonisolated let lifecycleContinuation: AsyncStream<GridRTCLifecycleEventEnvelope>.Continuation
  private var log: [String] = []
  private var roomIDs: [GridRTCRoomHandle: Int64] = [:]
  private var mutedStates: [Int64: Bool] = [:]
  private let blockedRoomID: Int64?
  private let blockedPublishRoomID: Int64?
  private let blockedMuteRoomID: Int64?
  private let blockSilenceRoomID: Int64?
  private let blockDisconnectRoomID: Int64?
  private let disconnectDelay: Duration
  private var blockedConnectContinuations: [CheckedContinuation<Void, Never>] = []
  private var blockedConnectCallsRemaining: Int
  private var blockedPublishCallsRemaining: Int
  private var blockedMuteCallsRemaining: Int
  private var blockedPublishContinuations: [CheckedContinuation<Void, Never>] = []
  private var blockedMuteContinuations: [CheckedContinuation<Void, Never>] = []
  private var blockedSilenceContinuations: [CheckedContinuation<Void, Never>] = []
  private var blockedDisconnectContinuations: [Int64: [CheckedContinuation<Void, Never>]] = [:]
  private var publishFailuresRemaining: Int

  init(
    blockedRoomID: Int64? = nil,
    blockedConnectCalls: Int = .max,
    blockedPublishRoomID: Int64? = nil,
    blockedMuteRoomID: Int64? = nil,
    blockSilenceRoomID: Int64? = nil,
    blockDisconnectRoomID: Int64? = nil,
    publishFailures: Int = 0,
    disconnectDelay: Duration = .zero
  ) {
    let stream = AsyncStream.makeStream(
      of: GridRTCLifecycleEventEnvelope.self,
      bufferingPolicy: .bufferingNewest(16)
    )
    lifecycleEvents = stream.stream
    lifecycleContinuation = stream.continuation
    participantSnapshots = AsyncStream { continuation in continuation.finish() }
    self.blockedRoomID = blockedRoomID
    self.blockedPublishRoomID = blockedPublishRoomID
    self.blockedMuteRoomID = blockedMuteRoomID
    self.blockSilenceRoomID = blockSilenceRoomID
    self.blockDisconnectRoomID = blockDisconnectRoomID
    blockedConnectCallsRemaining = blockedRoomID == nil ? 0 : max(blockedConnectCalls, 0)
    blockedPublishCallsRemaining = blockedPublishRoomID == nil ? 0 : 1
    blockedMuteCallsRemaining = blockedMuteRoomID == nil ? 0 : 1
    publishFailuresRemaining = publishFailures
    self.disconnectDelay = disconnectDelay
  }

  func makeRoom(configuration _: InlineRTCConfiguration) async throws -> GridRTCRoomHandle {
    let handle = GridRTCRoomHandle()
    log.append("make")
    return handle
  }

  func connect(_ room: GridRTCRoomHandle, credentials: InlineRTCCredentials) async throws {
    let roomID = credentials.target.testRoomID
    roomIDs[room] = roomID
    log.append("connect:\(roomID)")
    if blockedRoomID == roomID, blockedConnectCallsRemaining > 0 {
      blockedConnectCallsRemaining -= 1
      await withCheckedContinuation { continuation in
        blockedConnectContinuations.append(continuation)
      }
    }
  }

  func publishPreparedMicrophone(_ room: GridRTCRoomHandle, initiallyMuted: Bool) async throws {
    let roomID = roomIDs[room] ?? -1
    mutedStates[roomID] = initiallyMuted
    log.append("publish:\(roomID):muted=\(initiallyMuted)")
    if publishFailuresRemaining > 0 {
      publishFailuresRemaining -= 1
      throw FakeGridRTCDriverError.publishFailed
    }
    if blockedPublishRoomID == roomID, blockedPublishCallsRemaining > 0 {
      blockedPublishCallsRemaining -= 1
      await withCheckedContinuation { continuation in
        blockedPublishContinuations.append(continuation)
      }
    }
  }

  func setMicrophoneMuted(_ muted: Bool, in room: GridRTCRoomHandle) async throws {
    let roomID = roomIDs[room] ?? -1
    mutedStates[roomID] = muted
    log.append("mute:\(roomID):\(muted)")
    if blockedMuteRoomID == roomID, blockedMuteCallsRemaining > 0 {
      blockedMuteCallsRemaining -= 1
      await withCheckedContinuation { continuation in
        blockedMuteContinuations.append(continuation)
      }
    }
  }

  func setOutputVolume(_ volume: Float, in room: GridRTCRoomHandle) async {
    let roomID = roomIDs[room] ?? -1
    log.append("volume:\(roomID):\(volume)")
  }

  func silence(_ room: GridRTCRoomHandle) async {
    let roomID = roomIDs[room] ?? -1
    mutedStates[roomID] = true
    log.append("silence:\(roomID)")
    if blockSilenceRoomID == roomID {
      await withCheckedContinuation { continuation in
        blockedSilenceContinuations.append(continuation)
      }
    }
  }

  func disconnect(_ room: GridRTCRoomHandle) async {
    let roomID = roomIDs[room] ?? -1
    log.append("disconnect:\(roomID)")
    if blockDisconnectRoomID == roomID {
      await withCheckedContinuation { continuation in
        blockedDisconnectContinuations[roomID, default: []].append(continuation)
      }
    }
    try? await Task.sleep(for: disconnectDelay)
    log.append("disconnect-done:\(roomID)")
  }

  func releaseBlockedConnect() {
    let continuations = blockedConnectContinuations
    blockedConnectContinuations.removeAll()
    continuations.forEach { $0.resume() }
  }

  func releaseBlockedPublish() {
    let continuations = blockedPublishContinuations
    blockedPublishContinuations.removeAll()
    continuations.forEach { $0.resume() }
  }

  func releaseBlockedMute() {
    let continuations = blockedMuteContinuations
    blockedMuteContinuations.removeAll()
    continuations.forEach { $0.resume() }
  }

  func releaseBlockedSilence() {
    let continuations = blockedSilenceContinuations
    blockedSilenceContinuations.removeAll()
    continuations.forEach { $0.resume() }
  }

  func releaseBlockedDisconnect(roomID: Int64) {
    let continuations = blockedDisconnectContinuations.removeValue(forKey: roomID) ?? []
    continuations.forEach { $0.resume() }
  }

  func operations() -> [String] {
    log
  }

  func currentMutedState(roomID: Int64) -> Bool? {
    mutedStates[roomID]
  }

  func emitToCurrentRoom(_ event: GridRTCLifecycleEvent) {
    guard let room = roomIDs.keys.first else { return }
    lifecycleContinuation.yield(GridRTCLifecycleEventEnvelope(room: room, event: event))
  }
}

private enum FakeGridRTCDriverError: Error {
  case publishFailed
}

private extension InlineRTCSessionID {
  var testRoomID: Int64 {
    let components = rawValue.split(separator: ":")
    guard components.count >= 2 else { return -1 }
    return Int64(components[components.count - 2]) ?? -1
  }
}

private actor GridEngineSnapshotRecorder {
  private var snapshots: [InlineRTCState] = []

  func append(_ snapshot: InlineRTCState) {
    snapshots.append(snapshot)
  }

  func containsRTCState(_ state: InlineRTCConnectionState) -> Bool {
    snapshots.contains { $0.rtc.state == state }
  }
}

private enum EventuallyRTCError: Error {
  case timedOut
}

private func eventuallyRTC(
  timeout: Duration = .seconds(1),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw EventuallyRTCError.timedOut
}
