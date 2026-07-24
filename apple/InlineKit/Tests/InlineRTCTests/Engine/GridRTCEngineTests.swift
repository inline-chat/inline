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

  @Test("RTC room creation is fenced until audio bootstrap succeeds")
  func audioBootstrapFailureFencesRoomCreation() async throws {
    let audioDriver = RTCFakeAudioDriver(configureFailures: 1)
    let audio = GridAudioEngine(
      driver: audioDriver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:52:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      guard case .failed = await audio.currentSnapshot().state,
            case .failed = await rtc.currentSnapshot().state
      else { return false }
      return true
    }
    #expect(await driver.operations().contains("make") == false)

    await audio.retry()
    await rtc.audioAvailabilityChanged()
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .connected(target)
    }
    #expect(await driver.operations().contains("make"))
  }

  @Test("screen sharing follows demand without microphone permission")
  func screenSharingFollowsDemandWithoutMicrophonePermission() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:13:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:7",
      name: "Main Display",
      displayID: 7
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await driver.operations().contains("screen:13:display:7")
    }
    #expect(await rtc.currentSnapshot().screenShareState == .published)
    #expect(await driver.operations().contains("publish:13:muted=true") == false)

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      await driver.operations().contains("screen:13:off")
    }
    #expect(await rtc.currentSnapshot().screenShareState == .off)
  }

  @Test("screen sharing fails when its local publication projection never arrives")
  func screenSharePublishProjectionTimeout() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver()
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.screenShareRepublishTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:57:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:57",
      name: "Main Display",
      displayID: 57
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState
        == .failed("Screen sharing could not be confirmed")
    }

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      let isActive = await driver.isScreenShareActive(roomID: 57)
      return snapshot.screenShareState == .off && !isActive
    }
  }

  @Test("a timely local publication projection cancels the publish timeout")
  func screenSharePublishProjectionConfirmation() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver()
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.screenShareRepublishTimeout = 0.2
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:58:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:58",
      name: "Main Display",
      displayID: 58
    )
    let localShare = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_publish_confirmation",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC { await driver.isScreenShareActive(roomID: 58) }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [localShare])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares == [localShare]
    }
    try await Task.sleep(for: .milliseconds(250))

    #expect(await rtc.currentSnapshot().screenShareState == .published)
  }

  @Test("failed screen publication is explicitly cleaned up")
  func failedScreenPublicationIsCleanedUp() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver(screenShareFailures: 1)
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:14:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:8",
      name: "Second Display",
      displayID: 8
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      if case .failed = await rtc.currentSnapshot().screenShareState { return true }
      return false
    }

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      await driver.operations().contains("screen:14:off")
    }
    #expect(await rtc.currentSnapshot().screenShareState == .off)
  }

  @Test("stop intent arriving during screen publication is reconciled")
  func stopIntentDuringScreenPublication() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver(blockedScreenShareRoomID: 15)
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:15:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:9",
      name: "Main Display",
      displayID: 9
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await driver.operations().contains("screen:15:display:9")
    }

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    await driver.releaseBlockedScreenShare()

    try await eventuallyRTC {
      await driver.operations().contains("screen:15:off")
    }
    #expect(await rtc.currentSnapshot().screenShareState == .off)
    #expect(await driver.operations().filter { $0 == "screen:15:display:9" }.count == 1)
  }

  @Test("failed screen-share Stop reconstructs the room and releases local capture")
  func failedScreenShareStopReconstructsRoom() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver(failScreenShareStopRoomID: 45)
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:45:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:45",
      name: "Main Display",
      displayID: 45
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC { await driver.isScreenShareActive(roomID: 45) }

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))

    try await eventuallyRTC {
      let operations = await driver.operations()
      let isActive = await driver.isScreenShareActive(roomID: 45)
      return operations.contains("quiesce-done:45") && !isActive
    }
    try await eventuallyRTC {
      await driver.operations().filter { $0 == "connect:45" }.count >= 2
    }
  }

  @Test("hung screen-share Stop is fenced and local capture is released")
  func hungScreenShareStopIsFenced() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver(blockedScreenShareStopRoomID: 46)
    defer { Task { await driver.releaseBlockedScreenShare() } }
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.screenShareRepublishTimeout = 5
    configuration.connection.providerTeardownTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:46:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:46",
      name: "Main Display",
      displayID: 46
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC { await driver.isScreenShareActive(roomID: 46) }

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      await driver.operations().contains("screen:46:off")
    }
    try await eventuallyRTC {
      let operations = await driver.operations()
      let isActive = await driver.isScreenShareActive(roomID: 46)
      return operations.contains("quiesce-done:46") && !isActive
    }
  }

  @Test("stop during a hung source switch fences its late completion")
  func stopDuringHungScreenShareSwitchIsFenced() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver(
      blockedScreenShareRoomID: 48,
      blockedScreenShareSourceID: "display:48:replacement"
    )
    defer { Task { await driver.releaseBlockedScreenShare() } }
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.screenShareRepublishTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:48:1")
    let initialSource = InlineRTCScreenCaptureSource(
      id: "display:48:initial",
      name: "Main Display",
      displayID: 48
    )
    let replacementSource = InlineRTCScreenCaptureSource(
      id: "display:48:replacement",
      name: "Second Display",
      displayID: 49
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: initialSource
    ))
    try await eventuallyRTC { await driver.isScreenShareActive(roomID: 48) }

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: replacementSource
    ))
    try await eventuallyRTC {
      await driver.operations().contains("screen:48:display:48:replacement")
    }
    await rtc.setDemand(demand(target: target, microphoneEnabled: false))

    try await eventuallyRTC {
      let operations = await driver.operations()
      let isActive = await driver.isScreenShareActive(roomID: 48)
      return operations.contains("quiesce-done:48") && !isActive
    }
    await driver.releaseBlockedScreenShare()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await driver.isScreenShareActive(roomID: 48) == false)
  }

  @Test("successful Stop waits for an empty publication projection")
  func successfulStopRequiresEmptyPublicationProjection() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver()
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.screenShareRepublishTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:47:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:47",
      name: "Main Display",
      displayID: 47
    )
    let localShare = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_stop_confirmation",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC { await driver.isScreenShareActive(roomID: 47) }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [localShare])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares == [localShare]
    }

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .stopping
    }
    try await eventuallyRTC {
      await driver.operations().contains("quiesce-done:47")
    }
  }

  @Test("system-ended screen capture is not automatically restarted")
  func systemEndedScreenCapture() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:16:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:10",
      name: "Main Display",
      displayID: 10
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .published
    }

    let localShare = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_local_system_stop",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [localShare])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares == [localShare]
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 2, shares: [])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .failed("Screen sharing stopped")
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await driver.operations().filter { $0 == "screen:16:display:10" }.count == 1)

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      await driver.operations().contains("screen:16:off")
    }
    #expect(await rtc.currentSnapshot().screenShareState == .off)
  }

  @Test("a delayed publish callback cannot confirm newer screen-share intent")
  func delayedScreenPublishCannotConfirmNewerIntent() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver(blockedScreenShareRoomID: 17)
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:17:1")
    let firstSource = InlineRTCScreenCaptureSource(
      id: "display:11",
      name: "First Display",
      displayID: 11
    )
    let latestSource = InlineRTCScreenCaptureSource(
      id: "display:12",
      name: "Second Display",
      displayID: 12
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: firstSource
    ))
    try await eventuallyRTC {
      await driver.operations().contains("screen:17:display:11")
    }
    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: latestSource
    ))
    let delayedOldPublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_delayed_old",
      captureSourceID: firstSource.id,
      isLocal: true,
      videoTrack: nil
    )
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [delayedOldPublication])
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(await rtc.currentSnapshot().screenShareState == .publishing)

    await driver.releaseBlockedScreenShare()
    try await eventuallyRTC {
      await driver.operations().contains("screen:17:display:12")
    }
    #expect(await rtc.currentSnapshot().screenShareState == .published)
  }

  @Test("complete screen-share snapshots preserve simultaneous sharers")
  func simultaneousScreenShareSnapshots() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:18:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .connected(target)
    }

    let local = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_local",
      captureSourceID: "display:1",
      isLocal: true,
      videoTrack: nil
    )
    let firstRemote = InlineRTCScreenShare(
      participantIdentity: "remote-1",
      publicationID: "TR_remote_1",
      isLocal: false,
      videoTrack: nil
    )
    let secondRemote = InlineRTCScreenShare(
      participantIdentity: "remote-2",
      publicationID: "TR_remote_2",
      isLocal: false,
      videoTrack: nil
    )
    await driver.emitToCurrentRoom(
      .screenSharesChanged(
        revision: 1,
        shares: [local, firstRemote, secondRemote]
      )
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares.map(\.publicationID)
        == ["TR_local", "TR_remote_1", "TR_remote_2"]
    }

    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 3, shares: [local, secondRemote])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares.map(\.publicationID)
        == ["TR_local", "TR_remote_2"]
    }

    await driver.emitToCurrentRoom(
      .screenSharesChanged(
        revision: 2,
        shares: [local, firstRemote, secondRemote]
      )
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(
      await rtc.currentSnapshot().screenShares.map(\.publicationID)
        == ["TR_local", "TR_remote_2"]
    )
  }

  @Test("full reconnect waits for LiveKit to replace the screen publication")
  func fullReconnectWaitsForScreenRepublish() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:19:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:19",
      name: "Main Display",
      displayID: 19
    )
    let oldPublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_old",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )
    let replacementPublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_replacement",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .published
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [oldPublication])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares == [oldPublication]
    }

    await driver.emitToCurrentRoom(.reconnecting(mode: .full))
    await driver.emitToCurrentRoom(.reconnected(mode: .full))
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 2, shares: [oldPublication])
    )
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 3, shares: [])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .publishing
    }
    #expect(
      await driver.operations().filter { $0 == "screen:19:display:19" }.count == 1
    )

    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 4, shares: [replacementPublication])
    )
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.screenShareState == .published
        && snapshot.screenShares == [replacementPublication]
    }
    #expect(
      await driver.operations().filter { $0 == "screen:19:display:19" }.count == 1
    )
  }

  @Test("full reconnect screen republish timeout reconstructs the provider room")
  func fullReconnectScreenRepublishTimeout() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.screenShareRepublishTimeout = 0.05
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(
      audio: audio,
      driver: driver,
      configuration: configuration
    )
    let target = InlineRTCSessionID("grid-test:1:29:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:29",
      name: "Main Display",
      displayID: 29
    )
    let oldPublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_timeout_old",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )
    let latePublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_timeout_late",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .published
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [oldPublication])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares == [oldPublication]
    }
    let oldRoom = try #require(await driver.currentRoom())
    await driver.emitToCurrentRoom(.reconnecting(mode: .full))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .reconnecting(target)
    }
    await driver.emitToCurrentRoom(.reconnected(mode: .full))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .connected(target)
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 2, shares: [])
    )

    try await eventuallyRTC {
      let operations = await driver.operations()
      return operations.filter { $0 == "connect:29" }.count == 2
        && operations.filter { $0 == "screen:29:display:29" }.count == 2
    }
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.state == .connected(target)
        && snapshot.screenShareState == .published
    }

    await driver.emit(
      .screenSharesChanged(revision: 3, shares: [latePublication]),
      to: oldRoom
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(await rtc.currentSnapshot().screenShares.isEmpty)
  }

  @Test("quick reconnect escalation fences full replacement before Stop")
  func stopDuringFullReconnectScreenRepublish() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:30:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:30",
      name: "Main Display",
      displayID: 30
    )
    let oldPublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_stop_old",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )
    let replacementPublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_stop_replacement",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .published
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [oldPublication])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares == [oldPublication]
    }
    await driver.emitToCurrentRoom(.reconnecting(mode: .quick))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .reconnecting(target)
    }
    // Mirrors LiveKit's didUpdateReconnectMode callback when a quick recovery
    // escalates to full before didCompleteReconnectWithMode(.full).
    await driver.emitToCurrentRoom(.reconnecting(mode: .full))
    try await Task.sleep(for: .milliseconds(20))

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false
    ))
    await driver.emitToCurrentRoom(.reconnected(mode: .full))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .connected(target)
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 2, shares: [oldPublication])
    )
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 3, shares: [])
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(
      await driver.operations().filter { $0 == "screen:30:off" }.isEmpty
    )

    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 4, shares: [replacementPublication])
    )
    try await eventuallyRTC {
      await driver.operations().filter { $0 == "screen:30:off" }.count == 1
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 5, shares: [])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .off
    }
    #expect(
      await driver.operations().filter { $0 == "screen:30:display:30" }.count == 1
    )
  }

  @Test("stop before full reconnect cleans up a late replacement")
  func stopBeforeFullReconnectCleansUpLateReplacement() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:32:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:32",
      name: "Main Display",
      displayID: 32
    )
    let oldPublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_pre_stop_old",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )
    let latePublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_pre_stop_late",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .published
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [oldPublication])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares == [oldPublication]
    }

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false
    ))
    try await eventuallyRTC {
      await driver.operations().filter { $0 == "screen:32:off" }.count == 1
    }
    await driver.emitToCurrentRoom(.reconnecting(mode: .full))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .reconnecting(target)
    }
    await driver.emitToCurrentRoom(.reconnected(mode: .full))
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 2, shares: [])
    )
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 3, shares: [latePublication])
    )

    try await eventuallyRTC {
      await driver.operations().filter { $0 == "screen:32:off" }.count == 2
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 4, shares: [])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .off
    }
  }

  @Test("full reconnect watchdog starts before completion with a lagging publication snapshot")
  func fullReconnectWatchdogStartsBeforeCompletion() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.screenShareRepublishTimeout = 0.05
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(
      audio: audio,
      driver: driver,
      configuration: configuration
    )
    let target = InlineRTCSessionID("grid-test:1:33:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:33",
      name: "Main Display",
      displayID: 33
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .published
    }
    let oldRoom = try #require(await driver.currentRoom())
    await driver.emitToCurrentRoom(.reconnecting(mode: .full))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .reconnecting(target)
    }
    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false
    ))

    // No reconnected event or local publication snapshot arrives. The bound
    // still fences the old room because applied provider state proves a local
    // track was in flight when reconnecting began.
    try await eventuallyRTC {
      await driver.operations().filter { $0 == "connect:33" }.count == 2
    }
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.state == .connected(target)
        && snapshot.screenShareState == .off
    }
    await driver.emit(
      .screenSharesChanged(revision: 1, shares: []),
      to: oldRoom
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(await rtc.currentSnapshot().screenShares.isEmpty)
  }

  @Test("full reconnect fences an initial screen publication still in flight")
  func fullReconnectFencesInitialScreenPublication() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    let driver = FakeGridRTCDriver(blockedScreenShareRoomID: 34)
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:34:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:34",
      name: "Main Display",
      displayID: 34
    )
    let initialPublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_inflight_initial",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )
    let latePublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_inflight_late",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      guard snapshot.screenShareState == .publishing else { return false }
      return await driver.operations().contains("screen:34:display:34")
    }

    await driver.emitToCurrentRoom(.reconnecting(mode: .full))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .reconnecting(target)
    }
    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false
    ))
    await driver.emitToCurrentRoom(.reconnected(mode: .full))
    await driver.releaseBlockedScreenShare()

    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [initialPublication])
    )
    try await eventuallyRTC {
      await driver.operations().filter { $0 == "screen:34:off" }.count == 1
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 2, shares: [])
    )
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 3, shares: [latePublication])
    )
    try await eventuallyRTC {
      await driver.operations().filter { $0 == "screen:34:off" }.count == 2
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 4, shares: [])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .off
    }
  }

  @Test("stop during full reconnect timeout fences a late replacement")
  func stopDuringFullReconnectScreenRepublishTimeout() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(current: .denied)
    )
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.screenShareRepublishTimeout = 0.05
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(
      audio: audio,
      driver: driver,
      configuration: configuration
    )
    let target = InlineRTCSessionID("grid-test:1:31:1")
    let source = InlineRTCScreenCaptureSource(
      id: "display:31",
      name: "Main Display",
      displayID: 31
    )
    let oldPublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_stop_timeout_old",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )
    let latePublication = InlineRTCScreenShare(
      participantIdentity: "local",
      publicationID: "TR_screen_stop_timeout_late",
      captureSourceID: source.id,
      isLocal: true,
      videoTrack: nil
    )

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShareState == .published
    }
    await driver.emitToCurrentRoom(
      .screenSharesChanged(revision: 1, shares: [oldPublication])
    )
    try await eventuallyRTC {
      await rtc.currentSnapshot().screenShares == [oldPublication]
    }
    let oldRoom = try #require(await driver.currentRoom())
    await driver.emitToCurrentRoom(.reconnecting(mode: .full))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .reconnecting(target)
    }
    await driver.emitToCurrentRoom(.reconnected(mode: .full))
    try await eventuallyRTC {
      await rtc.currentSnapshot().state == .connected(target)
    }

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false
    ))

    try await eventuallyRTC {
      await driver.operations().filter { $0 == "connect:31" }.count == 2
    }
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.state == .connected(target)
        && snapshot.screenShareState == .off
    }
    #expect(
      await driver.operations().filter { $0 == "screen:31:display:31" }.count == 1
    )
    #expect(await driver.operations().filter { $0 == "screen:31:off" }.isEmpty)

    await driver.emit(
      .screenSharesChanged(revision: 2, shares: [latePublication]),
      to: oldRoom
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(await rtc.currentSnapshot().screenShares.isEmpty)

    await rtc.setDemand(demand(
      target: target,
      microphoneEnabled: false,
      screenCaptureSource: source
    ))
    try await eventuallyRTC {
      await driver.operations().filter { $0 == "screen:31:display:31" }.count == 2
    }
    await driver.emit(
      .screenSharesChanged(revision: 3, shares: [latePublication]),
      to: oldRoom
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(
      await driver.operations().filter { $0 == "screen:31:display:31" }.count == 2
    )
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

  @Test("a retired connect completion cannot release the audio transport fence")
  func retiredConnectCannotReleaseAudioTransportFence() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(preparationRequiresRTCTransport: true),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(blockedRoomID: 53)
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:53:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC {
      await driver.operations().contains("connect:53")
    }
    #expect(await audio.isWaitingForRTCTransport())

    await rtc.setDemand(InlineRTCDemand())
    try await eventuallyRTC {
      await driver.operations().contains("quiesce-done:53")
    }
    await driver.releaseBlockedConnect()
    try await Task.sleep(for: .milliseconds(20))

    #expect(await audio.isWaitingForRTCTransport())
    #expect(await driver.operations().contains("publish:53:muted=true") == false)
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
    #expect(operations.contains("quiesce:22"))
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

  @Test("circuit-open retirement still releases every room's local media")
  func circuitOpenRetirementQuiescesLocally() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(blockedRoomID: 26, blockedConnectCalls: 2)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.initialConnectSlowWarningDelay = 0.01
    configuration.connection.initialConnectWatchdogTimeout = 0.03
    configuration.connection.providerTeardownTimeout = 0.1
    configuration.connection.maxAbandonedProviderOperations = 2
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:26:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC(timeout: .seconds(3)) {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.providerCircuitOpen
        && snapshot.abandonedProviderOperationCount == 2
    }

    await rtc.setDemand(InlineRTCDemand())
    let receipt = await rtc.shutdown()

    #expect(receipt.isQuiescent)
    #expect(receipt.microphonePublicationCount == 0)
    #expect(receipt.screenSharePublicationCount == 0)
    #expect(await audio.currentSnapshot().captureLeaseCount == 0)
    #expect(await driver.operations().filter { $0 == "quiesce-done:26" }.count >= 2)

    await driver.releaseBlockedConnect()
  }

  @Test("a hung microphone publication fences replacement until mutation ownership returns")
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
      await rtc.currentSnapshot().failedLocalQuiescenceCount == 1
    }
    #expect(await driver.operations().filter { $0 == "connect:23" }.count == 1)

    await driver.releaseBlockedPublish()
    try await eventuallyRTC(timeout: .seconds(2)) {
      let snapshot = await rtc.currentSnapshot()
      let connectCount = await driver.operations().filter { $0 == "connect:23" }.count
      return connectCount >= 2
        && snapshot.state == .connected(target)
        && snapshot.microphonePublicationState == .published
        && !snapshot.microphoneMuted
    }
    #expect(await driver.operations().filter { $0 == "publish:23:muted=true" }.count == 2)
    #expect(await rtc.currentSnapshot().state == .connected(target))
  }

  @Test("a hung microphone mute fences replacement until mutation ownership returns")
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
      await rtc.currentSnapshot().failedLocalQuiescenceCount == 1
    }
    #expect(await driver.operations().filter { $0 == "connect:24" }.count == 1)

    await driver.releaseBlockedMute()
    try await eventuallyRTC(timeout: .seconds(2)) {
      let snapshot = await rtc.currentSnapshot()
      return await driver.operations().filter { $0 == "connect:24" }.count >= 2
        && snapshot.state == .connected(target)
        && snapshot.microphonePublicationState == .published
        && !snapshot.microphoneMuted
    }
  }

  @Test("shutdown rejects a retained provider media mutation until it returns")
  func shutdownRetainsProviderMediaMutationOwnership() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(blockedPublishRoomID: 53)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.microphonePublishWatchdogTimeout = 0.03
    configuration.connection.providerTeardownTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:53:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC {
      await rtc.currentSnapshot().failedLocalQuiescenceCount == 1
    }

    let unsafeReceipt = await rtc.shutdown()
    #expect(!unsafeReceipt.isQuiescent)
    #expect(unsafeReceipt.localMediaMutationCount == 1)
    #expect(unsafeReceipt.locallyActiveRoomCount == 1)

    await driver.releaseBlockedPublish()
    try await eventuallyRTC(timeout: .seconds(2)) {
      await rtc.currentSnapshot().failedLocalQuiescenceCount == 0
    }
    let safeReceipt = await rtc.shutdown()
    #expect(safeReceipt.isQuiescent)
  }

  @Test("leave proves local quiescence before becoming idle")
  func leaveQuiescesLocallyFirst() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(disconnectDelay: .milliseconds(80))
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:30:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    #expect(await rtc.currentSnapshot().activeRoomCount == 1)
    await rtc.setDemand(InlineRTCDemand())
    try await eventuallyRTC { await driver.operations().contains("quiesce:30") }

    let operationsDuringQuiescence = await driver.operations()
    #expect(operationsDuringQuiescence.contains("quiesce-done:30") == false)
    let retiringSnapshot = await rtc.currentSnapshot()
    #expect(retiringSnapshot.activeRoomCount == 0)
    #expect(retiringSnapshot.retiringRoomCount == 1)
    #expect(retiringSnapshot.pendingRemoteLeaveCount == 0)
    try await eventuallyRTC { await rtc.currentSnapshot().state == .idle }
    try await eventuallyRTC { await driver.operations().contains("quiesce-done:30") }
    try await eventuallyRTC { await rtc.currentSnapshot().retiringRoomCount == 0 }
    let operations = await driver.operations()
    let startIndex = try #require(operations.firstIndex(of: "quiesce:30"))
    let finishIndex = try #require(operations.firstIndex(of: "quiesce-done:30"))
    #expect(startIndex < finishIndex)
  }

  @Test("local quiescence does not depend on the provider silence path")
  func localQuiescenceBypassesProviderSilence() async throws {
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
    try await eventuallyRTC { await driver.operations().contains("quiesce-done:36") }

    let shutdownStartedAt = ContinuousClock.now
    let receipt = await rtc.shutdown()
    #expect(shutdownStartedAt.duration(to: .now) < .milliseconds(250))
    #expect(receipt.isQuiescent)
    #expect(await driver.operations().contains("silence:36") == false)
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
    let retiredIndex = try #require(operations.firstIndex(of: "quiesce-done:33"))
    let replacementIndex = try #require(operations.firstIndex(of: "connect:34"))
    #expect(retiredIndex < replacementIndex)
  }

  @Test("room replacement rearms the custom ADM transport fence")
  func roomReplacementRearmsAudioTransportFence() async throws {
    let audioDriver = RTCFakeAudioDriver(
      preparationRequiresRTCTransport: true,
      initiallyRecordingActive: false
    )
    let audio = GridAudioEngine(
      driver: audioDriver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(5)
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let first = InlineRTCSessionID("grid-test:1:54:1")
    let second = InlineRTCSessionID("grid-test:1:55:1")

    await rtc.setDemand(demand(target: first, microphoneEnabled: false))
    try await eventuallyRTC(timeout: .seconds(2)) {
      await rtc.currentSnapshot().microphonePublicationState == .published
    }
    await rtc.setDemand(demand(target: second, microphoneEnabled: false))
    try await eventuallyRTC(timeout: .seconds(2)) {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.state == .connected(second)
        && snapshot.microphonePublicationState == .published
    }

    let operations = await audioDriver.operations()
    let firstStart = try #require(operations.firstIndex(of: "prepared:true"))
    let stop = try #require(
      operations[firstStart...].firstIndex(of: "prepared:false")
    )
    let replacementStart = try #require(
      operations[operations.index(after: stop)...].firstIndex(of: "prepared:true")
    )
    #expect(firstStart < stop)
    #expect(stop < replacementStart)
  }

  @Test("local quiescence is independent from a hung provider disconnect")
  func localQuiescenceBypassesProviderDisconnect() async throws {
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
    try await eventuallyRTC { await driver.operations().contains("quiesce-done:35") }

    let shutdownStartedAt = ContinuousClock.now
    let receipt = await rtc.shutdown()
    let shutdownDuration = shutdownStartedAt.duration(to: .now)
    #expect(shutdownDuration < .milliseconds(200))
    #expect(receipt.isQuiescent)
    #expect(await rtc.currentSnapshot().state == .idle)
    try await eventuallyRTC {
      await audio.currentSnapshot().captureLeaseCount == 0
    }

  }

  @Test("failed local quiescence is retained and shutdown cannot report success")
  func failedLocalQuiescenceIsNotReaped() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(10)
    )
    let driver = FakeGridRTCDriver(localQuiescenceFailureRoomID: 37)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.providerTeardownTimeout = 0.05
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:37:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    let receipt = await rtc.shutdown()

    #expect(!receipt.isQuiescent)
    #expect(receipt.locallyActiveRoomCount == 1)
    #expect(receipt.microphonePublicationCount > 0)
    #expect(!receipt.failures.isEmpty)
    #expect(await audio.currentSnapshot().captureLeaseCount == 1)
  }

  @Test("failed local quiescence fences a replacement room")
  func failedLocalQuiescenceFencesReplacement() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver(localQuiescenceFailureRoomID: 40)
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.retirementBarrierTimeout = 0.02
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let first = InlineRTCSessionID("grid-test:1:40:1")
    let replacement = InlineRTCSessionID("grid-test:1:41:1")

    await rtc.setDemand(demand(target: first, microphoneEnabled: false))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    await rtc.setDemand(demand(target: replacement, microphoneEnabled: false))
    try await eventuallyRTC { await rtc.currentSnapshot().failedLocalQuiescenceCount == 1 }
    try await Task.sleep(for: .milliseconds(100))

    #expect(await driver.operations().contains("connect:41") == false)
    #expect(await rtc.currentSnapshot().failedLocalQuiescenceCount == 1)
  }

  @Test("repeated room retirement does not accumulate local cleanup obligations")
  func repeatedLocalRetirementIsReaped() async throws {
    let audio = GridAudioEngine(
      driver: RTCFakeAudioDriver(),
      permissionDriver: TestGridMicrophonePermissionDriver(),
      captureCooldown: .milliseconds(10)
    )
    let driver = FakeGridRTCDriver()
    var configuration = InlineRTCConfiguration.voice
    configuration.connection.retirementBarrierTimeout = 0.01
    configuration.connection.providerTeardownTimeout = 0.03
    configuration.connection.maxAbandonedProviderOperations = 2
    let rtc = GridRTCEngine(audio: audio, driver: driver, configuration: configuration)
    let target = InlineRTCSessionID("grid-test:1:39:1")

    for expectedCount in 1 ... 3 {
      await rtc.setDemand(demand(target: target, microphoneEnabled: false))
      try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
      await rtc.setDemand(InlineRTCDemand())
      try await eventuallyRTC {
        await driver.operations().filter { $0 == "quiesce-done:39" }.count == expectedCount
      }
    }
    #expect(await driver.operations().filter { $0 == "connect:39" }.count == 3)
    #expect(await driver.operations().filter { $0 == "quiesce:39" }.count == 3)
    #expect(await rtc.currentSnapshot().providerCircuitOpen == false)
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

  @Test("sender-owned healthy AUHAL rebuilds RTC when outbound audio stops")
  func senderOwnedLocalAudioFailureRebuildsRTC() async throws {
    let audioDriver = RTCFakeAudioDriver(
      preparationRequiresRTCTransport: true,
      initiallyRecordingActive: true,
      recordingStartsWithMicrophoneSender: true
    )
    let audio = GridAudioEngine(
      driver: audioDriver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:47:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: true))
    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return snapshot.microphonePublicationState == .published && !snapshot.microphoneMuted
    }
    await driver.emitToCurrentRoom(.localAudioFlow(.missing))

    try await eventuallyRTC {
      let snapshot = await rtc.currentSnapshot()
      return await driver.operations().filter { $0 == "connect:47" }.count == 2
        && snapshot.state == .connected(target)
        && snapshot.microphonePublicationState == .published
        && !snapshot.microphoneMuted
    }
    #expect(await driver.operations().filter { $0 == "disconnect:47" }.count == 1)
    #expect(await audioDriver.operations().contains("recover") == false)
    #expect(await rtc.currentSnapshot().state == .connected(target))
  }

  @Test("missing remote PCM reconstructs the RTC room without restarting capture")
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
      await driver.operations().filter { $0 == "connect:38" }.count == 2
    }
    #expect(await audioDriver.operations().contains("recover") == false)
    #expect(await driver.operations().filter { $0 == "disconnect:38" }.count == 1)
    #expect(await rtc.currentSnapshot().state == .connected(target))
  }

  @Test("decoded remote PCM repairs stopped physical playout without replacing the room")
  func decodedPCMRepairsPhysicalPlayout() async throws {
    let audioDriver = RTCFakeAudioDriver()
    let audio = GridAudioEngine(
      driver: audioDriver,
      permissionDriver: TestGridMicrophonePermissionDriver()
    )
    let driver = FakeGridRTCDriver()
    let rtc = GridRTCEngine(audio: audio, driver: driver)
    let target = InlineRTCSessionID("grid-test:1:42:1")

    await rtc.setDemand(demand(target: target, microphoneEnabled: false))
    try await eventuallyRTC { await rtc.currentSnapshot().microphonePublicationState == .published }
    await audioDriver.setPlayingActive(false)
    await driver.emitToCurrentRoom(.remoteAudioFramesObserved(identity: "remote"))
    try await eventuallyRTC { await audioDriver.operations().contains("recover-playout") }

    #expect(await driver.operations().filter { $0 == "connect:42" }.count == 1)
    #expect(await rtc.currentSnapshot().state == .connected(target))
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
    _ = await engine.shutdown()
    #expect(await rtcDriver.operations().contains("disconnect-done:40"))
  }

  @Test("process engine opens a transport-gated ADM route only after connect")
  func processEngineInitializesTransportBeforeAudio() async throws {
    let audioDriver = RTCFakeAudioDriver(
      preparationRequiresRTCTransport: true,
      initiallyRecordingActive: false,
      inputRouteStartsRecording: true
    )
    let rtcDriver = FakeGridRTCDriver(blockedRoomID: 44)
    let engine = InlineRTCSession(
      audioDriver: audioDriver,
      permissionDriver: TestGridMicrophonePermissionDriver(),
      rtcDriver: rtcDriver,
      captureCooldown: .milliseconds(20)
    )
    let target = InlineRTCSessionID("grid-test:1:44:1")

    await engine.start()
    engine.setDemand(demand(target: target, microphoneEnabled: true))

    try await eventuallyRTC { await rtcDriver.operations().contains("connect:44") }
    let blockedAudioOperations = await audioDriver.operations()
    #expect(blockedAudioOperations.contains("input:automatic") == false)
    #expect(blockedAudioOperations.contains("prepared:true") == false)

    await rtcDriver.releaseBlockedConnect()
    try await eventuallyRTC {
      let connected = await rtcDriver.operations().contains("connect:44")
      let routed = await audioDriver.operations().contains("input:automatic")
      return connected && routed
    }
    let audioOperations = await audioDriver.operations()
    #expect(audioOperations.contains("input:automatic"))
    #expect(audioOperations.contains("prepared:true") == false)
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

    _ = await engine.shutdown()
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
    screenCaptureSource: InlineRTCScreenCaptureSource? = nil,
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
      screenCaptureSource: screenCaptureSource,
      outputVolume: outputVolume
    )
  }
}

private actor RTCFakeAudioDriver: GridAudioDriver {
  nonisolated let preparationRequiresRTCTransport: Bool
  nonisolated let recordingStartsWithMicrophoneSender: Bool
  private var log: [String] = []
  private var playingActive = true
  private var recordingActive: Bool?
  private let inputRouteStartsRecording: Bool
  private var configureFailuresRemaining: Int

  init(
    preparationRequiresRTCTransport: Bool = false,
    initiallyRecordingActive: Bool? = nil,
    inputRouteStartsRecording: Bool = false,
    configureFailures: Int = 0,
    recordingStartsWithMicrophoneSender: Bool = false
  ) {
    self.preparationRequiresRTCTransport = preparationRequiresRTCTransport
    recordingActive = initiallyRecordingActive
    self.inputRouteStartsRecording = inputRouteStartsRecording
    configureFailuresRemaining = max(configureFailures, 0)
    self.recordingStartsWithMicrophoneSender = recordingStartsWithMicrophoneSender
  }

  func configure(_: InlineRTCConfiguration) async throws {
    log.append("configure")
    if configureFailuresRemaining > 0 {
      configureFailuresRemaining -= 1
      throw FakeGridRTCDriverError.audioConfigureFailed
    }
  }

  func setPrepared(_ prepared: Bool) async throws {
    log.append("prepared:\(prepared)")
    if recordingActive != nil {
      recordingActive = prepared
    }
  }

  func recoverPreparedAudio(preserving _: AudioInputRouteTarget?) async throws {
    log.append("recover")
  }

  func recoverPlayout(preserving _: AudioOutputRouteTarget?) async throws {
    log.append("recover-playout")
    playingActive = true
  }

  func runtimeHealth() async -> GridAudioRuntimeHealth {
    GridAudioRuntimeHealth(
      isEngineRunning: true,
      isRecording: recordingActive ?? true,
      isPlaying: playingActive,
      route: InlineRTCAudioRoute(
        currentInputID: "default",
        defaultInputID: "default",
        currentOutputID: "default",
        defaultOutputID: "default",
        inputDeviceCount: 1,
        outputDeviceCount: 1,
        isInputRouteValid: true,
        isOutputRouteValid: true
      )
    )
  }

  func applyInputRoute(
    _ target: AudioInputRouteTarget,
    restartPreparedAudio _: Bool
  ) async throws -> GridAudioInputRouteApplication {
    log.append("input:\(target.logDescription)")
    if inputRouteStartsRecording {
      recordingActive = true
    }
    return .committed
  }

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

  func setPlayingActive(_ active: Bool) {
    playingActive = active
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
  private let blockedScreenShareRoomID: Int64?
  private let blockedScreenShareSourceID: String?
  private let blockedScreenShareStopRoomID: Int64?
  private let failScreenShareStopRoomID: Int64?
  private let blockSilenceRoomID: Int64?
  private let blockDisconnectRoomID: Int64?
  private let localQuiescenceFailureRoomID: Int64?
  private let disconnectDelay: Duration
  private var blockedConnectContinuations: [CheckedContinuation<Void, Never>] = []
  private var blockedConnectCallsRemaining: Int
  private var blockedPublishCallsRemaining: Int
  private var blockedMuteCallsRemaining: Int
  private var blockedScreenShareCallsRemaining: Int
  private var blockedScreenShareStopCallsRemaining: Int
  private var blockedPublishContinuations: [CheckedContinuation<Void, Never>] = []
  private var blockedMuteContinuations: [CheckedContinuation<Void, Never>] = []
  private var blockedScreenShareContinuations: [CheckedContinuation<Void, Never>] = []
  private var blockedSilenceContinuations: [CheckedContinuation<Void, Never>] = []
  private var blockedDisconnectContinuations: [Int64: [CheckedContinuation<Void, Never>]] = [:]
  private var publishFailuresRemaining: Int
  private var screenShareFailuresRemaining: Int
  private var activeScreenShareRoomIDs = Set<Int64>()
  private var locallyRetiringRooms = Set<GridRTCRoomHandle>()
  private var locallyQuiescedRooms = Set<GridRTCRoomHandle>()

  init(
    blockedRoomID: Int64? = nil,
    blockedConnectCalls: Int = .max,
    blockedPublishRoomID: Int64? = nil,
    blockedMuteRoomID: Int64? = nil,
    blockedScreenShareRoomID: Int64? = nil,
    blockedScreenShareSourceID: String? = nil,
    blockedScreenShareStopRoomID: Int64? = nil,
    failScreenShareStopRoomID: Int64? = nil,
    blockSilenceRoomID: Int64? = nil,
    blockDisconnectRoomID: Int64? = nil,
    localQuiescenceFailureRoomID: Int64? = nil,
    publishFailures: Int = 0,
    screenShareFailures: Int = 0,
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
    self.blockedScreenShareRoomID = blockedScreenShareRoomID
    self.blockedScreenShareSourceID = blockedScreenShareSourceID
    self.blockedScreenShareStopRoomID = blockedScreenShareStopRoomID
    self.failScreenShareStopRoomID = failScreenShareStopRoomID
    self.blockSilenceRoomID = blockSilenceRoomID
    self.blockDisconnectRoomID = blockDisconnectRoomID
    self.localQuiescenceFailureRoomID = localQuiescenceFailureRoomID
    blockedConnectCallsRemaining = blockedRoomID == nil ? 0 : max(blockedConnectCalls, 0)
    blockedPublishCallsRemaining = blockedPublishRoomID == nil ? 0 : 1
    blockedMuteCallsRemaining = blockedMuteRoomID == nil ? 0 : 1
    blockedScreenShareCallsRemaining = blockedScreenShareRoomID == nil ? 0 : 1
    blockedScreenShareStopCallsRemaining = blockedScreenShareStopRoomID == nil ? 0 : 1
    publishFailuresRemaining = publishFailures
    screenShareFailuresRemaining = screenShareFailures
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
    if locallyRetiringRooms.contains(room) {
      lifecycleContinuation.yield(
        GridRTCLifecycleEventEnvelope(room: room, event: .retiredLocalMediaMutationReleased)
      )
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
    if locallyRetiringRooms.contains(room) {
      lifecycleContinuation.yield(
        GridRTCLifecycleEventEnvelope(room: room, event: .retiredLocalMediaMutationReleased)
      )
    }
  }

  func screenCaptureSources() async throws -> [InlineRTCScreenCaptureSource] {
    []
  }

  func setScreenShare(
    _ source: InlineRTCScreenCaptureSource?,
    in room: GridRTCRoomHandle
  ) async throws {
    let roomID = roomIDs[room] ?? -1
    log.append("screen:\(roomID):\(source?.id ?? "off")")
    if screenShareFailuresRemaining > 0 {
      screenShareFailuresRemaining -= 1
      throw FakeGridRTCDriverError.screenShareFailed
    }
    if source == nil, failScreenShareStopRoomID == roomID {
      throw FakeGridRTCDriverError.screenShareFailed
    }
    if source != nil,
       blockedScreenShareRoomID == roomID,
       blockedScreenShareSourceID == nil || blockedScreenShareSourceID == source?.id,
       blockedScreenShareCallsRemaining > 0 {
      blockedScreenShareCallsRemaining -= 1
      await withCheckedContinuation { continuation in
        blockedScreenShareContinuations.append(continuation)
      }
    }
    if source == nil,
       blockedScreenShareStopRoomID == roomID,
       blockedScreenShareStopCallsRemaining > 0 {
      blockedScreenShareStopCallsRemaining -= 1
      await withCheckedContinuation { continuation in
        blockedScreenShareContinuations.append(continuation)
      }
    }
    if source == nil {
      activeScreenShareRoomIDs.remove(roomID)
    } else if !locallyQuiescedRooms.contains(room) {
      activeScreenShareRoomIDs.insert(roomID)
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

  func quiesceLocally(_ room: GridRTCRoomHandle) async -> GridLocalRoomQuiescenceReceipt {
    let roomID = roomIDs[room] ?? -1
    locallyRetiringRooms.insert(room)
    log.append("quiesce:\(roomID)")
    // Keep disconnect vocabulary for ordering assertions while avoiding the
    // provider-facing silence path that local quiescence intentionally bypasses.
    log.append("disconnect:\(roomID)")
    try? await Task.sleep(for: disconnectDelay)
    if localQuiescenceFailureRoomID == roomID {
      return GridLocalRoomQuiescenceReceipt(
        room: room,
        localResourcesReleased: false,
        microphonePublicationCount: 1,
        failures: ["injected local quiescence failure"]
      )
    }
    let localMediaMutationCount =
      (blockedPublishRoomID == roomID ? blockedPublishContinuations.count : 0)
      + (blockedMuteRoomID == roomID ? blockedMuteContinuations.count : 0)
    if localMediaMutationCount > 0 {
      return GridLocalRoomQuiescenceReceipt(
        room: room,
        localResourcesReleased: false,
        localMediaMutationCount: localMediaMutationCount,
        failures: ["injected retained local media mutation"]
      )
    }
    locallyQuiescedRooms.insert(room)
    activeScreenShareRoomIDs.remove(roomID)
    log.append("disconnect-done:\(roomID)")
    log.append("quiesce-done:\(roomID)")
    return GridLocalRoomQuiescenceReceipt(
      room: room,
      localResourcesReleased: true,
      failures: []
    )
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

  func releaseBlockedScreenShare() {
    let continuations = blockedScreenShareContinuations
    blockedScreenShareContinuations.removeAll()
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

  func isScreenShareActive(roomID: Int64) -> Bool {
    activeScreenShareRoomIDs.contains(roomID)
  }

  func emitToCurrentRoom(_ event: GridRTCLifecycleEvent) {
    guard let room = roomIDs.keys.first else { return }
    lifecycleContinuation.yield(GridRTCLifecycleEventEnvelope(room: room, event: event))
  }

  func currentRoom() -> GridRTCRoomHandle? {
    roomIDs.keys.first
  }

  func emit(_ event: GridRTCLifecycleEvent, to room: GridRTCRoomHandle) {
    lifecycleContinuation.yield(GridRTCLifecycleEventEnvelope(room: room, event: event))
  }
}

private enum FakeGridRTCDriverError: Error {
  case audioConfigureFailed
  case publishFailed
  case screenShareFailed
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
