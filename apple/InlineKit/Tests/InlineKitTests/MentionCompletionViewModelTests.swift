import Testing
@testable import InlineKit

@MainActor
@Suite("Mention Completion View Model")
struct MentionCompletionViewModelTests {
  @Test("participant refresh keeps latest query")
  func participantRefreshKeepsLatestQuery() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateParticipants([
      user(1, firstName: "Alice"),
      user(2, firstName: "Bob"),
      user(3, firstName: "Carol"),
    ])

    model.filter(with: "bo")
    #expect(model.items.map(\.user.id) == [2])

    model.updateParticipants([
      user(1, firstName: "Alice"),
      user(2, firstName: "Bob"),
      user(3, firstName: "Carol"),
      user(4, firstName: "Bobby"),
    ])

    #expect(model.query == "bo")
    #expect(model.items.map(\.user.id) == [2, 4])
  }

  @Test("filters pending and current users")
  func filtersPendingAndCurrentUsers() {
    let model = MentionCompletionViewModel(currentUserId: { 2 })
    model.updateParticipants([
      user(1, firstName: "Alice"),
      user(2, firstName: "Current"),
      user(3, firstName: "Pending", pendingSetup: true),
    ])

    #expect(model.items.map(\.user.id) == [1])
  }

  @Test("search matches usernames and compact names")
  func searchMatchesUsernamesAndCompactNames() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateParticipants([
      user(1, firstName: "Mary", lastName: "Jane", username: "mj"),
      user(2, firstName: "Ada", lastName: "Lovelace", username: "ada"),
    ])

    model.filter(with: "maryj")
    #expect(model.items.map(\.user.id) == [1])

    model.filter(with: "ada")
    #expect(model.items.map(\.user.id) == [2])
  }

  @Test("bare at shows participants and space members before direct chats")
  func bareAtShowsParticipantsAndSpaceMembersBeforeDirectChats() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates([
      candidate(3, firstName: "Charlie", source: .directChat, lastMsgId: 12),
      candidate(2, firstName: "Bob", source: .spaceMember),
      candidate(1, firstName: "Alice", source: .participant),
    ])

    #expect(model.items.map(\.user.id) == [1, 2])

    model.filter(with: "char")
    #expect(model.items.map(\.user.id) == [3])
  }

  @Test("direct chat candidates require a last message")
  func directChatCandidatesRequireLastMessage() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates([
      candidate(1, firstName: "Alice", source: .directChat, lastMsgId: nil),
      candidate(2, firstName: "Alan", source: .directChat, lastMsgId: 0),
      candidate(3, firstName: "Alana", source: .directChat, lastMsgId: 42),
    ])

    model.filter(with: "ala")
    #expect(model.items.map(\.user.id) == [3])
  }

  @Test("participant source wins over lower priority duplicates")
  func participantSourceWinsOverLowerPriorityDuplicates() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates([
      candidate(1, firstName: "Alice", source: .directChat, lastMsgId: 12),
      candidate(1, firstName: "Alice", source: .participant),
    ])

    #expect(model.items.map(\.user.id) == [1])
  }

  @Test("exact query match accepts first name username and diacritics")
  func exactQueryMatchAcceptsFirstNameUsernameAndDiacritics() {
    let jose = user(1, firstName: "José", lastName: "Silva", username: "ze")

    #expect(MentionCompletionViewModel.query("jose", exactlyMatches: jose))
    #expect(MentionCompletionViewModel.query("ze", exactlyMatches: jose))
    #expect(!MentionCompletionViewModel.query("jos", exactlyMatches: jose))
  }

  private func user(
    _ id: Int64,
    firstName: String,
    lastName: String? = nil,
    username: String? = nil,
    pendingSetup: Bool = false
  ) -> UserInfo {
    var user = User(
      id: id,
      email: nil,
      firstName: firstName,
      lastName: lastName,
      username: username
    )
    user.pendingSetup = pendingSetup
    return UserInfo(user: user)
  }

  private func candidate(
    _ id: Int64,
    firstName: String,
    lastName: String? = nil,
    username: String? = nil,
    source: MentionCompletionSource,
    lastMsgId: Int64? = nil
  ) -> MentionCompletionUser {
    MentionCompletionUser(
      userInfo: user(id, firstName: firstName, lastName: lastName, username: username),
      source: source,
      lastMsgId: lastMsgId
    )
  }
}
