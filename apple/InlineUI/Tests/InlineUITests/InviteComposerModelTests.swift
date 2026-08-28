import InlineKit
import Testing

@testable import Invite

@MainActor
@Suite("Invite composer search projection")
struct InviteComposerModelTests {
  @Test("keeps leading-at username results beside the incomplete email candidate")
  func leadingAtUsernameAndEmailCandidateCoexist() {
    let model = InviteComposerModel(destination: .inline)
    model.query = "@deploy"
    model.localUsers = [userInfo(id: 42, name: "Deploy Helper", username: "deploybot")]

    #expect(model.emailSuggestion?.isActionable == false)
    #expect(model.userTargets.map(\.id) == ["user:42"])
  }

  @Test("shows one-character local results")
  func showsOneCharacterLocalResults() {
    let model = InviteComposerModel(destination: .inline)
    model.query = "d"
    model.localUsers = [userInfo(id: 42, name: "Deploy Helper", username: "deploybot")]

    #expect(model.userTargets.map(\.id) == ["user:42"])
  }

  @Test("deduplicates remote results with local identity and ordering precedence")
  func localResultsTakePrecedence() {
    let model = InviteComposerModel(destination: .inline)
    model.query = "helper"
    model.localUsers = [userInfo(id: 42, name: "Local Helper", username: "helper")]
    model.remoteUsers = [
      userInfo(id: 42, name: "Remote Duplicate", username: "helper"),
      userInfo(id: 43, name: "Remote Helper", username: "remotehelper"),
    ]

    #expect(model.userTargets.map(\.id) == ["user:42", "user:43"])
    #expect(model.userTargets.first?.title == "Local Helper")
  }

  @Test("clears stale result projections as soon as the query changes")
  func queryChangeClearsStaleResults() {
    let model = InviteComposerModel(destination: .inline)
    model.query = "helper"
    model.localUsers = [userInfo(id: 42, name: "Old Helper", username: "oldhelper")]
    model.remoteUsers = [userInfo(id: 43, name: "Remote Helper", username: "remotehelper")]

    model.query = "someone else"

    #expect(model.localUsers.isEmpty)
    #expect(model.remoteUsers.isEmpty)
    #expect(model.userTargets.isEmpty)
    #expect(model.isSearching == false)
  }

  private func userInfo(id: Int64, name: String, username: String) -> UserInfo {
    UserInfo(user: User(id: id, email: nil, firstName: name, username: username))
  }
}
