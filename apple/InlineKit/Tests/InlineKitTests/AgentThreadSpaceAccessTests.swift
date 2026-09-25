@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Agent thread destination access")
struct AgentThreadSpaceAccessTests {
  private func member(userID: Int64 = 42, spaceID: Int64 = 8, publicAccess: Bool) -> InlineProtocol.Member {
    .with {
      $0.userID = userID
      $0.spaceID = spaceID
      $0.canAccessPublicChats = publicAccess
    }
  }

  @Test("owned agents still need membership in both public and private space threads", arguments: [true, false])
  func missingMembership(isPublic: Bool) {
    #expect(throws: AgentThreadSpaceAccessError.notAMember) {
      try AgentThreadSpaceAccess.validate(botUserID: 42, spaceID: 8, isPublic: isPublic, members: [])
    }
  }

  @Test("membership of another bot or another space does not grant access")
  func wrongMembership() {
    #expect(throws: AgentThreadSpaceAccessError.notAMember) {
      try AgentThreadSpaceAccess.validate(
        botUserID: 42, spaceID: 8, isPublic: true,
        members: [member(userID: 43, publicAccess: true), member(spaceID: 9, publicAccess: true)]
      )
    }
  }

  @Test("private-only agent can join a private thread without being granted public access")
  func privateAccess() throws {
    try AgentThreadSpaceAccess.validate(
      botUserID: 42, spaceID: 8, isPublic: false, members: [member(publicAccess: false)]
    )
  }

  @Test("private-only membership is insufficient for a public thread")
  func publicAccessDenied() {
    #expect(throws: AgentThreadSpaceAccessError.publicAccessDenied) {
      try AgentThreadSpaceAccess.validate(
        botUserID: 42, spaceID: 8, isPublic: true, members: [member(publicAccess: false)]
      )
    }
  }

  @Test("public-capable agent can join either visibility", arguments: [true, false])
  func publicAccessAllowed(isPublic: Bool) throws {
    try AgentThreadSpaceAccess.validate(
      botUserID: 42, spaceID: 8, isPublic: isPublic, members: [member(publicAccess: true)]
    )
  }
}
