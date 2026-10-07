@testable import InlineGrid
import InlineProtocol
import Testing

@Suite("Grid committed call admission")
struct GridCallClaimAdmissionTests {
  private func call(membershipID: String = "membership-a", owned: Bool = true) -> GridCurrentCall {
    .with {
      $0.callID = "stable-call"
      $0.membershipID = membershipID
      $0.spaceID = 42
      $0.roomID = 7
      $0.ownedByCurrentSession = owned
    }
  }

  private func authority(membershipID: String = "membership-a") -> GridOwnedRoomAuthority {
    .init(spaceID: 42, roomID: 7, membershipID: membershipID)
  }

  private func grid(membershipID: String = "membership-a", owned: Bool = true) -> InlineProtocol.Grid {
    .with {
      $0.spaceID = 42
      $0.enabled = true
      $0.rooms = [.with {
        $0.id = 7
        $0.avatars = [.with {
          $0.membershipID = membershipID
          $0.ownedByCurrentSession = owned
        }]
      }]
    }
  }

  @Test("the claim survives its own changed-event repair when exact membership agrees")
  func ownChangedEventDoesNotLoseClaim() {
    let claim = call()
    #expect(GridCallClaimAdmission.accepts(
      committedCall: claim, newestGrid: grid(), acceptedAuthority: authority()
    ))
  }

  @Test("an A to B to A move cannot admit the first A response")
  func oldOwnerIncarnationCannotRevive() {
    #expect(!GridCallClaimAdmission.accepts(
      committedCall: call(membershipID: "a-first"),
      newestGrid: grid(membershipID: "a-second"),
      acceptedAuthority: authority(membershipID: "a-second")
    ))
  }

  @Test("a later raw Leave prevents an old claim from admitting even if UI still shows its avatar")
  func laterLeaveWins() {
    #expect(!GridCallClaimAdmission.accepts(
      committedCall: call(), newestGrid: grid(), acceptedAuthority: nil
    ))
  }

  @Test("a claimed owner loses admission if the newest Grid shows takeover")
  func newerGridOwnershipWinsWithoutSelfDelivery() {
    #expect(!GridCallClaimAdmission.accepts(
      committedCall: call(), newestGrid: grid(owned: false), acceptedAuthority: nil
    ))
  }

  @Test("missing Grid or disabled space cannot grant media access")
  func missingAuthorizationFailsClosed() {
    #expect(!GridCallClaimAdmission.accepts(
      committedCall: call(), newestGrid: nil, acceptedAuthority: nil
    ))
    var disabled = grid()
    disabled.enabled = false
    #expect(!GridCallClaimAdmission.accepts(
      committedCall: call(), newestGrid: disabled, acceptedAuthority: authority()
    ))
  }

  @Test("an optimistic owned avatar cannot override a raw takeover snapshot")
  func optimisticAvatarCannotGrantAuthority() {
    #expect(!GridCallClaimAdmission.accepts(
      committedCall: call(), newestGrid: grid(),
      acceptedAuthority: authority(membershipID: "newer-owner-membership")
    ))
  }
}
