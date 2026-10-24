import Foundation
@testable import InlineGrid
import InlineProtocol
@testable import InlineRTC
import Testing

/// A restart, staying alone, or a long connected call must never push the user
/// out of a room by itself.
@Suite("Grid presence continuity", .serialized)
@MainActor
struct GridPresenceContinuityTests {
  @MainActor
  final class ActiveFlag {
    var isActive: Bool
    init(_ isActive: Bool) { self.isActive = isActive }
  }

  private func listOwnedCall(_ control: GridAuthorityMembershipControl) {
    control.setupHome = .with {
      $0.spaces = [.with { $0.spaceID = 42
        $0.activeAvatarCount = 1
      }]
      $0.currentCall = .with {
        $0.callID = "call-a"
        $0.membershipID = "membership-a"
        $0.spaceID = 42
        $0.roomID = 7
        $0.ownedByCurrentSession = true
      }
      $0.callTransferEnabled = true
    }
  }

  private func moves(_ control: GridAuthorityMembershipControl) -> Int {
    control.submissions.filter { $0.method == .moveGridCallHere }.count
  }

  @Test("a restart resumes this session's call once, listen-only, keeping the saved preference")
  func restartResumesOnceListenOnly() async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control, defaultsValues: ["grid.microphoneEnabled": true])
    do {
      try await fixture.seedAccount()
      listOwnedCall(control)
      await fixture.service.handle(GridRoomLifecycleEvent.realtimeConnection(.connected))
      try await eventuallyGridAuthority { moves(control) == 1 }
      #expect(!fixture.service.media.isMicrophoneEnabled)
      #expect(fixture.defaults.bool(forKey: "grid.microphoneEnabled"))

      // A failed resume leaves the call to the user's Resume, never a loop.
      control.fail(0)
      try await eventuallyGridAuthority { !fixture.service.membershipMutationInFlight }
      await fixture.service.loadHome()
      #expect(fixture.service.currentCall?.ownedByCurrentSession == true)
      #expect(!fixture.service.hasLocalAdmission)
      try await Task.sleep(for: .milliseconds(100))
      #expect(moves(control) == 1)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("a background app resumes only once it is active")
  func resumeWaitsForActiveApp() async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control)
    let flag = ActiveFlag(false)
    var effects = GridPlatformEffects()
    effects.isApplicationActive = { flag.isActive }
    fixture.service.configurePlatformEffects(effects)
    do {
      try await fixture.seedAccount()
      listOwnedCall(control)
      await fixture.service.handle(GridRoomLifecycleEvent.realtimeConnection(.connected))
      try await Task.sleep(for: .milliseconds(100))
      #expect(moves(control) == 0)

      flag.isActive = true
      await fixture.service.loadHome()
      try await eventuallyGridAuthority { moves(control) == 1 }
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("an explicit Grid action in this process prevents an automatic resume")
  func explicitActionPreventsResume() async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control)
    do {
      try await fixture.seedAccount()
      fixture.service.join(roomID: 999)
      listOwnedCall(control)
      await fixture.service.handle(GridRoomLifecycleEvent.realtimeConnection(.connected))
      try await Task.sleep(for: .milliseconds(100))
      #expect(moves(control) == 0)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("a connected call refreshes credentials before they expire without reconnecting", arguments: [
    (expiresIn: 60.0, refreshes: 1),
    (expiresIn: 240.0, refreshes: 0),
  ])
  func connectedCredentialsStayFresh(expiresIn: Double, refreshes: Int) async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control)
    do {
      let token = try await fixture.seedAccount()
      let base = fixture.claimResult(membershipID: "membership-a")
      var expiring = try #require(base.credentials)
      expiring.expiresAt = Int64(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
      let response = GridRoomMutationResult(grids: base.grids, credentials: expiring, currentCall: base.currentCall)
      let operation = GridMembershipOperation(
        kind: .join(roomID: 7), spaceID: 42, expectedMembershipID: "",
        intentRevision: 0, accountToken: token, microphoneEnabled: false,
        automaticMicrophoneChange: nil, accessRevision: 0, revision: 1, startedAt: Date()
      )
      await fixture.service.handle(.joined(operation, response))
      try await eventuallyGridAuthority { fixture.service.media.connectionState == .connected }

      var fresh = try #require(response.credentials)
      fresh.expiresAt = Int64(Date().addingTimeInterval(300).timeIntervalSince1970)
      control.setupConnection = fresh
      control.setupGrid = .with {
        $0.grid = response.grids[0]
        if let call = response.currentCall {
          $0.currentCall = call
        }
      }
      await fixture.service.handle(GridRoomLifecycleEvent.heartbeat)
      try await eventuallyGridAuthority { control.prepareConnectionCount == refreshes }
      try await Task.sleep(for: .milliseconds(100))
      #expect(control.prepareConnectionCount == refreshes)
      #expect(fixture.service.media.connectionState == .connected)
      #expect(await fixture.rtc.connectedIdentities.count == 1)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }
}
