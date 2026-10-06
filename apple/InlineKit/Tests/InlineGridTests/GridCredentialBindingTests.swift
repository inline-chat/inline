@testable import InlineGrid
import InlineProtocol
import Testing

@Suite("Grid credential authority binding")
struct GridCredentialBindingTests {
  private var target: GridMediaTarget {
    .init(callID: "call-a", membershipID: "owner-a", spaceID: 42, roomID: 7, generation: 3)
  }

  private func credentials(
    callID: String = "call-a",
    membershipID: String = "owner-a",
    participantIdentity: String = "inline-grid-user-11-owner-a"
  ) -> GridConnectionCredentials {
    .with {
      $0.connection = .with { $0.roomID = 7
        $0.generation = 3
      }
      $0.callID = callID
      $0.membershipID = membershipID
      $0.participantIdentity = participantIdentity
    }
  }

  @Test("active transfer contract requires stable call and current owner together")
  func strictContractBindsBothIdentities() {
    #expect(GridCredentialBinding.accepts(
      credentials: credentials(), target: target, userID: 11, callTransferEnabled: true
    ))
    #expect(!GridCredentialBinding.accepts(
      credentials: credentials(callID: "previous-call"), target: target, userID: 11, callTransferEnabled: true
    ))
    #expect(!GridCredentialBinding.accepts(
      credentials: credentials(membershipID: "previous-owner"), target: target, userID: 11, callTransferEnabled: true
    ))
  }

  @Test("old server's absent binding fields remain compatible only capability OFF")
  func oldServerCompatibilityStaysOffOnly() {
    let legacy = credentials(callID: "", membershipID: "")
    #expect(GridCredentialBinding.accepts(
      credentials: legacy, target: target, userID: 11, callTransferEnabled: false
    ))
    #expect(!GridCredentialBinding.accepts(
      credentials: legacy, target: target, userID: 11, callTransferEnabled: true
    ))
  }

  @Test("legacy compatibility never accepts another account or owner incarnation")
  func legacyIdentityStillHasExactAuthority() {
    #expect(!GridCredentialBinding.accepts(
      credentials: credentials(callID: "", membershipID: "", participantIdentity: "inline-grid-user-12-owner-a"),
      target: target, userID: 11, callTransferEnabled: false
    ))
    #expect(!GridCredentialBinding.accepts(
      credentials: credentials(callID: "", membershipID: "", participantIdentity: "inline-grid-user-11-previous-owner"),
      target: target, userID: 11, callTransferEnabled: false
    ))
  }

  @Test("supplied binding fields are never ignored in OFF compatibility mode")
  func nonemptyBindingsStayStrictWhenOff() {
    #expect(!GridCredentialBinding.accepts(
      credentials: credentials(callID: "previous-call"), target: target, userID: 11, callTransferEnabled: false
    ))
    #expect(!GridCredentialBinding.accepts(
      credentials: credentials(membershipID: "previous-owner"), target: target, userID: 11, callTransferEnabled: false
    ))
  }

  @Test("same owner credentials cannot cross a room generation")
  func generationIsAlsoRequired() {
    var stale = credentials()
    stale.connection.generation = 2
    #expect(!GridCredentialBinding.accepts(
      credentials: stale, target: target, userID: 11, callTransferEnabled: false
    ))
  }
}
