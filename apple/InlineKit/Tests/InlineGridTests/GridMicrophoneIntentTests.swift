import Foundation
@testable import InlineGrid
import InlineProtocol
@testable import InlineRTC
import Testing

@Suite("Grid microphone intent", .serialized)
@MainActor
struct GridMicrophoneIntentTests {
  #if os(macOS)
  @Test("the saved microphone choice is restored on launch and defaults to muted", arguments: [true, false, nil])
  func savedChoiceIsRestored(saved: Bool?) async {
    let fixture = GridAuthorityTestFixture(defaultsValues: saved.map { ["grid.microphoneEnabled": $0] } ?? [:])
    #expect(fixture.service.media.isMicrophoneEnabled == (saved ?? false))
    #expect(!fixture.service.autoMuteWhenAlone)
    await fixture.close()
  }
  #endif

  @Test("solo waits, arrivals, departures and provider generations preserve microphone choice", arguments: [true, false])
  func populationChangesPreserveIntent(enabled: Bool) async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control, defaultsValues: [
      "grid.microphoneEnabled": !enabled,
      "grid.autoUnmuteOnJoin": true,
    ])
    do {
      let room = try await GridMicrophoneIntentRoom(fixture: fixture, control: control)
      // Exercise the public toggle as well as preferences, including on iOS.
      if fixture.service.media.isMicrophoneEnabled != enabled {
        fixture.service.toggleMicrophone(spaceID: 42)
      }
      for (occupants, generation) in [(1, 3), (2, 4), (1, 4), (2, 5)] {
        await room.apply(occupants: occupants, generation: generation)
        if occupants == 1 {
          // The opt-in solo mute fires after five seconds. Wait through that real timer.
          try await Task.sleep(for: .milliseconds(5_150))
        } else {
          try await eventuallyGridAuthority { fixture.service.media.connectionState == .connected }
          try await eventuallyGridAuthority { await fixture.rtc.microphoneMuted == !enabled }
        }
        // A delayed server echo of the old state cannot overwrite local choice.
        await room.echoAvatarMicrophone(enabled: !enabled)
        #expect(fixture.service.hasLocalAdmission)
        #expect(fixture.service.media.isMicrophoneEnabled == enabled)
        #expect(fixture.service.grids[42]?.rooms[0].avatars[0].microphoneEnabled == enabled)
      }
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("a phone in a room keeps audio running alone and through arrivals; the Mac idles alone", arguments: [true, false])
  func roomAudioRunsAlone(holdsAudio: Bool) async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control, holdsAudioWhileInRoom: holdsAudio)
    do {
      let room = try await GridMicrophoneIntentRoom(fixture: fixture, control: control)
      try await eventuallyGridAuthority { await fixture.audio.runtimeHealth().isRecording }

      // The last other person leaves: no media room remains.
      await room.apply(occupants: 1, generation: 3)
      try await eventuallyGridAuthority { fixture.service.media.connectionState == .disconnected }
      try await eventuallyGridAuthority { await fixture.audio.runtimeHealth().isRecording == holdsAudio }
      try await Task.sleep(for: .milliseconds(100))
      #expect(await fixture.audio.runtimeHealth().isRecording == holdsAudio)
      #expect(await fixture.audio.runtimeHealth().isPlaying == holdsAudio)
      #expect(fixture.service.hasLocalAdmission)

      // Someone arrives while the phone may be in the background.
      await room.apply(occupants: 2, generation: 4)
      try await eventuallyGridAuthority { fixture.service.media.connectionState == .connected }
      #expect(await fixture.audio.runtimeHealth().isRecording)

      // Leaving releases the room's audio on both platforms.
      fixture.service.leaveCurrentRoom(spaceID: 42)
      try await eventuallyGridAuthority { await !fixture.audio.runtimeHealth().isRecording }
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  #if os(macOS)
  enum SoloEnd: CaseIterable {
    case settingDisabled, withdraw, failedJoin, failedJoinWithAutoUnmute
  }

  @Test("disabling solo mute, withdrawal and failed joins never restore the microphone", arguments: SoloEnd.allCases)
  func soloMuteStaysClosed(end: SoloEnd) async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control, defaultsValues: [
      "grid.microphoneEnabled": true,
      "grid.autoMuteWhenAlone": true,
      "grid.autoUnmuteOnJoin": end == .failedJoinWithAutoUnmute,
    ])
    do {
      let room = try await GridMicrophoneIntentRoom(fixture: fixture, control: control)
      let service = fixture.service
      await room.apply(occupants: 1, generation: 3)
      try await Task.sleep(for: .milliseconds(5_150))
      // Refetch/snapshot tasks may reschedule the grace timer. Wait for its
      // actual edge rather than making this a wall-clock scheduling test.
      try await eventuallyGridAuthority { !service.media.isMicrophoneEnabled }
      try #require(service.hasLocalAdmission)
      #expect(!fixture.defaults.bool(forKey: "grid.microphoneEnabled"))

      switch end {
        case .settingDisabled:
          service.autoMuteWhenAlone = false
        case .withdraw:
          let receipt = await service.withdrawLocalAdmission().value
          #expect(receipt.isLocallyQuiescent)
        case .failedJoin, .failedJoinWithAutoUnmute:
          service.createAndJoin(spaceID: 42)
          try await eventuallyGridAuthority { control.submissions.count == 1 }
          // Only this explicit join action may open the microphone, and only
          // when the user opted into Auto-Unmute on Join.
          #expect(service.media.isMicrophoneEnabled == (end == .failedJoinWithAutoUnmute))
          control.fail(0)
          try await eventuallyGridAuthority { !service.membershipMutationInFlight }
      }

      #expect(!service.media.isMicrophoneEnabled)
      #expect(!fixture.defaults.bool(forKey: "grid.microphoneEnabled"))
      if end != .settingDisabled {
        #expect(!service.hasLocalAdmission)
        #expect(service.mediaSessionIdentity == nil)
      }
      try await eventuallyGridAuthority { !(await fixture.audio.runtimeHealth().isRecording) }
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("the opt-in solo mute persists through arrivals and departures until an explicit toggle")
  func soloAutoMuteIsOneWay() async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control, defaultsValues: [
      "grid.microphoneEnabled": true,
      "grid.autoMuteWhenAlone": true,
      "grid.autoUnmuteOnJoin": true,
    ])
    do {
      let room = try await GridMicrophoneIntentRoom(fixture: fixture, control: control)
      let service = fixture.service

      await room.apply(occupants: 1, generation: 3)
      try await Task.sleep(for: .milliseconds(5_150))
      try await eventuallyGridAuthority { !service.media.isMicrophoneEnabled }
      #expect(!service.media.isMicrophoneEnabled)
      #expect(service.grids[42]?.rooms[0].avatars[0].microphoneEnabled == false)
      // A privacy mute is also the saved preference, including across a restart.
      #expect(!fixture.defaults.bool(forKey: "grid.microphoneEnabled"))

      for (occupants, generation) in [(2, 4), (1, 4), (2, 5)] {
        await room.apply(occupants: occupants, generation: generation)
        if occupants == 2 {
          try await eventuallyGridAuthority { service.media.connectionState == .connected }
          try await eventuallyGridAuthority { await fixture.rtc.microphoneMuted }
        }
        await room.echoAvatarMicrophone(enabled: true)
        #expect(!service.media.isMicrophoneEnabled)
        #expect(service.grids[42]?.rooms[0].avatars[0].microphoneEnabled == false)
        #expect(!fixture.defaults.bool(forKey: "grid.microphoneEnabled"))
      }

      service.toggleMicrophone(spaceID: 42)
      try await eventuallyGridAuthority { await fixture.rtc.microphoneMuted == false }
      #expect(service.media.isMicrophoneEnabled)
      #expect(service.grids[42]?.rooms[0].avatars[0].microphoneEnabled == true)
      #expect(fixture.defaults.bool(forKey: "grid.microphoneEnabled"))

      await room.apply(occupants: 1, generation: 5)
      try await Task.sleep(for: .milliseconds(5_150))
      try await eventuallyGridAuthority { !service.media.isMicrophoneEnabled }
      #expect(!service.media.isMicrophoneEnabled)

      await room.apply(occupants: 2, generation: 6)
      try await eventuallyGridAuthority { service.media.connectionState == .connected }
      try await eventuallyGridAuthority { await fixture.rtc.microphoneMuted }
      #expect(!service.media.isMicrophoneEnabled)
      #expect(!fixture.defaults.bool(forKey: "grid.microphoneEnabled"))
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("an explicit join opens a muted microphone only with Auto-Unmute on Join enabled", arguments: [true, false])
  func explicitJoinHonorsAutoUnmute(enabled: Bool) async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control, defaultsValues: [
      "grid.microphoneEnabled": false,
      "grid.autoUnmuteOnJoin": enabled,
    ])
    do {
      let room = try await GridMicrophoneIntentRoom(fixture: fixture, control: control)
      await room.apply(occupants: 2, generation: 3)
      let service = fixture.service
      service.createAndJoin(spaceID: 42)
      try await eventuallyGridAuthority { control.submissions.count == 1 }
      #expect(service.media.isMicrophoneEnabled == enabled)

      let response = fixture.claimResult(membershipID: "membership-b", revision: 10)
      control.setupHome?.currentCall = try #require(response.currentCall)
      control.succeed(0, with: response)
      try await eventuallyGridAuthority { service.hasLocalAdmission && service.media.connectionState == .connected }
      try await eventuallyGridAuthority { await fixture.rtc.microphoneMuted == !enabled }
      #expect(service.media.isMicrophoneEnabled == enabled)
      #expect(fixture.defaults.bool(forKey: "grid.microphoneEnabled") == enabled)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }
  #endif
}

/// Drives one admitted room through occupancy and provider generation changes.
@MainActor
private final class GridMicrophoneIntentRoom {
  private let fixture: GridAuthorityTestFixture
  private let control: GridAuthorityMembershipControl
  private let response: GridRoomMutationResult
  private let call: GridCurrentCall
  private let credentials: GridConnectionCredentials
  private var revision: Int64 = 2

  init(fixture: GridAuthorityTestFixture, control: GridAuthorityMembershipControl) async throws {
    self.fixture = fixture
    self.control = control
    try await fixture.seedAccount()
    try await fixture.admit()
    response = fixture.claimResult(membershipID: "membership-a")
    call = try #require(response.currentCall)
    credentials = try #require(response.credentials)
    control.setupHome = .with {
      $0.spaces = [.with { $0.spaceID = 42 }]
      $0.currentCall = call
      $0.callTransferEnabled = true
    }
  }

  func apply(occupants: Int, generation: Int) async {
    var grid = response.grids[0]
    grid.callTransferEnabled = true
    grid.revision = revision
    revision += 1
    grid.rooms[0].avatars[0].microphoneEnabled = fixture.service.media.isMicrophoneEnabled
    if occupants == 1 {
      grid.rooms[0].avatars = [grid.rooms[0].avatars[0]]
      grid.rooms[0].clearConnection()
      control.setupConnection = nil
    } else {
      grid.rooms[0].connection.generation = Int32(generation)
      var credentials = credentials
      credentials.connection = grid.rooms[0].connection
      control.setupConnection = credentials
    }
    control.setupGrid = .with {
      $0.grid = grid
      $0.currentCall = call
    }
    await fixture.service.handle(GridEvent.with {
      $0.changed = .with { $0.spaceIds = [42]; $0.roomID = 7 }
    })
  }

  func echoAvatarMicrophone(enabled: Bool) async {
    await fixture.service.handle(GridEvent.with {
      $0.avatarStateChanged = .with {
        $0.spaceID = 42
        $0.roomID = 7
        $0.userID = 1
        $0.microphoneEnabled = enabled
        $0.microphoneRevision = Int32(revision)
      }
    })
  }
}
