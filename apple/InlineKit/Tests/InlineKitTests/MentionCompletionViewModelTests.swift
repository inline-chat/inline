import Foundation
@testable import InlineKit
import InlineProtocol
import Testing

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
    #expect(userIds(model.items) == [2])

    model.updateParticipants([
      user(1, firstName: "Alice"),
      user(2, firstName: "Bob"),
      user(3, firstName: "Carol"),
      user(4, firstName: "Bobby"),
    ])

    #expect(model.query == "bo")
    #expect(userIds(model.items) == [2, 4])
  }

  @Test("filters pending and current users")
  func filtersPendingAndCurrentUsers() {
    let model = MentionCompletionViewModel(currentUserId: { 2 })
    model.updateParticipants([
      user(1, firstName: "Alice"),
      user(2, firstName: "Current"),
      user(3, firstName: "Pending", pendingSetup: true),
    ])

    #expect(userIds(model.items) == [1])
  }

  @Test("search matches usernames and compact names")
  func searchMatchesUsernamesAndCompactNames() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateParticipants([
      user(1, firstName: "Mary", lastName: "Jane", username: "mj"),
      user(2, firstName: "Ada", lastName: "Lovelace", username: "ada"),
    ])

    model.filter(with: "maryj")
    #expect(userIds(model.items) == [1])

    model.filter(with: "ada")
    #expect(userIds(model.items) == [2])
  }

  @Test("bare at shows participants and space members before direct chats")
  func bareAtShowsParticipantsAndSpaceMembersBeforeDirectChats() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates([
      candidate(3, firstName: "Charlie", source: .directChat, lastMsgId: 12),
      candidate(2, firstName: "Bob", source: .spaceMember),
      candidate(1, firstName: "Alice", source: .participant),
    ])

    #expect(userIds(model.items) == [1, 2])

    model.filter(with: "char")
    #expect(userIds(model.items) == [3])
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
    #expect(userIds(model.items) == [3])
  }

  @Test("participant source wins over lower priority duplicates")
  func participantSourceWinsOverLowerPriorityDuplicates() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates([
      candidate(1, firstName: "Alice", source: .directChat, lastMsgId: 12),
      candidate(1, firstName: "Alice", source: .participant),
    ])

    #expect(userIds(model.items) == [1])
  }

  @Test("exact query match accepts first name username and diacritics")
  func exactQueryMatchAcceptsFirstNameUsernameAndDiacritics() {
    let jose = user(1, firstName: "José", lastName: "Silva", username: "ze")

    #expect(MentionCompletionViewModel.query("jose", exactlyMatches: jose))
    #expect(MentionCompletionViewModel.query("ze", exactlyMatches: jose))
    #expect(!MentionCompletionViewModel.query("jos", exactlyMatches: jose))
  }

  @Test("bot mentions use the complete first-name field while human mentions stay short")
  func botMentionsUseCompleteName() {
    var bot = user(1, firstName: "Mo's Codex")
    bot.user.bot = true
    let human = user(2, firstName: "Mary", lastName: "Jane")

    #expect(MentionCompletionViewModel.mentionText(for: bot) == "@Mo's Codex")
    #expect(MentionCompletionViewModel.mentionText(for: human) == "@Mary")
  }

  @Test("agents search and insert as the backing bot plus Agent identity")
  func agentsSearchAndInsert() throws {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    let bot = user(200, firstName: "Research Bot", username: "research_bot")
    var profile = BotAgentProfile()
    profile.id = 7
    profile.botUserID = 200
    profile.name = "Data Analyst"
    profile.handle = "data"
    profile.emoji = "📊"
    profile.description_p = "Analyzes product metrics"
    let agent = MentionableBotAgent(profile: profile, botUserInfo: bot)

    model.updateCandidates(.init(users: [], groups: [], agents: [agent]))
    model.filter(with: "metrics")

    let item = try #require(model.items.first)
    #expect(item.agent?.id == 7)
    #expect(item.userInfo?.user.id == 200)
    #expect(model.mentionText(for: item) == "@📊 Data Analyst")
    #expect(item.subtitle == "via Research Bot · Analyzes product metrics")
  }

  @Test("exact dena beats names and prefixes; Aden never matches across fields")
  func denaScreenshot() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates([
      candidate(1, firstName: "Aden", username: "aden", source: .directChat, lastMsgId: 999, isPinned: true),
      candidate(2, firstName: "Dena", username: "denaa", source: .participant, lastMsgId: 800, isPinned: true),
      candidate(3, firstName: "Dena", lastName: "Sohrabi", username: "dena", source: .directChat, lastMsgId: 1),
    ])

    model.filter(with: "dena")
    #expect(userIds(model.items) == [3, 2])
    #expect(model.selectedUser?.id == 3)
    model.filter(with: "de")
    #expect(userIds(model.items) == [2, 3, 1])
  }

  @Test("pinned Danny wins equal prefixes regardless of name or message ID")
  func dannyScreenshot() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates([
      candidate(1, firstName: "Daniel Edrisian", username: "dedrisian", source: .spaceMember),
      candidate(2, firstName: "Daniel Kovacs", username: "daniel.kovacs", source: .directChat, lastMsgId: 900),
      candidate(3, firstName: "Danny", username: "dan_bot", source: .directChat, lastMsgId: 10, isPinned: true),
    ])

    model.filter(with: "dan")
    #expect(userIds(model.items) == [3, 2, 1])
    #expect(model.selectedUser?.id == 3)
  }

  @Test("relevance wins over pins and activity; ties use pins then descending message IDs")
  func relevanceAndChatPriority() {
    let inputs = [
      candidate(1, firstName: "Exact Handle", username: "dan", source: .directChat, lastMsgId: 1),
      candidate(2, firstName: "Dan", source: .participant, lastMsgId: 2),
      candidate(3, firstName: "Danny", source: .spaceMember, lastMsgId: 3, isPinned: true),
      candidate(4, firstName: "Daniel", source: .directChat, lastMsgId: 20),
      candidate(5, firstName: "Danielle", source: .participant, lastMsgId: 10),
      candidate(6, firstName: "Jordan", source: .participant, lastMsgId: 999, isPinned: true),
    ]
    let model = MentionCompletionViewModel(currentUserId: { nil })
    for input in [inputs, inputs.reversed().map(\.self)] {
      model.updateCandidates(input)
      model.filter(with: "dan")
      #expect(userIds(model.items) == [1, 2, 3, 4, 5, 6])
    }
  }

  @Test("complete ties retain source, alphabetical and stable identity order")
  func deterministicFallback() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates([
      candidate(4, firstName: "Dan A", source: .spaceMember),
      candidate(3, firstName: "Dan C", source: .participant),
      candidate(2, firstName: "Dan B", source: .participant),
      candidate(1, firstName: "Dan B", source: .participant),
    ])
    model.filter(with: "dan")
    #expect(userIds(model.items) == [1, 2, 3, 4])
  }

  @Test("deduplication keeps participant identity and merges pin and maximum message ID")
  func duplicateSignalsSurvive() throws {
    let inputs = [
      candidate(1, firstName: "Danny", source: .participant),
      candidate(1, firstName: "Danny", source: .spaceMember, lastMsgId: 500),
      candidate(1, firstName: "Danny", source: .directChat, lastMsgId: 10, isPinned: true),
    ]
    let model = MentionCompletionViewModel(currentUserId: { nil })
    for input in [inputs, inputs.reversed().map(\.self)] {
      model.updateCandidates(input)
      #expect(model.items.count == 1)
      let item = try #require(model.items.first)
      guard case let .user(user) = item else {
        Issue.record("Expected user candidate")
        return
      }
      #expect(user.source == .participant)
      #expect(user.isPinned)
      #expect(user.lastMsgId == 500)
    }
  }

  @Test("bare at reorders eligible users but does not admit direct-chat fallbacks")
  func bareAtChatPriority() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates([
      candidate(1, firstName: "Alice", source: .participant),
      candidate(2, firstName: "Bob", source: .spaceMember, lastMsgId: 100),
      candidate(3, firstName: "Zoe", source: .spaceMember, lastMsgId: 10, isPinned: true),
      candidate(4, firstName: "Dora", source: .directChat, lastMsgId: 999, isPinned: true),
    ])
    #expect(userIds(model.items) == [3, 2, 1])
  }

  @Test("refresh preserves selected identity across reordering; typing selects the best row")
  func selectionFollowsIdentity() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    var inputs = [
      candidate(1, firstName: "Daniel", source: .participant),
      candidate(2, firstName: "Danny", source: .participant),
    ]
    model.updateCandidates(inputs)
    model.filter(with: "da")
    model.selectNext()
    #expect(model.selectedUser?.id == 2)

    inputs[1].isPinned = true
    model.updateCandidates(inputs)
    #expect(userIds(model.items) == [2, 1])
    #expect(model.selectedIndex == 0)
    #expect(model.selectedUser?.id == 2)
    model.selectNext()
    #expect(model.selectedUser?.id == 1)
    model.filter(with: "dan")
    #expect(model.selectedUser?.id == 2)
    model.selectPrevious()
    #expect(model.selectedUser?.id == 1)
  }

  @Test("normalization and compact word matching stay field-local")
  func normalizedFieldMatching() {
    let model = MentionCompletionViewModel(currentUserId: { nil }, locale: Locale(identifier: "en_US"))
    model.updateParticipants([
      user(1, firstName: "José", lastName: "Silva"),
      user(2, firstName: "Mary", lastName: "Jane", username: "mj"),
      user(3, firstName: "مریم"),
    ])
    for (query, id) in [("  JOSÉ ", Int64(1)), ("maryj", 2), ("sil", 1), ("مری", 3)] {
      model.filter(with: query)
      #expect(userIds(model.items) == [id])
    }
    model.filter(with: "janemj")
    #expect(model.items.isEmpty)
  }

  @Test("groups and Agents do not match across independent fields")
  func groupAndAgentFieldBoundaries() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    let group = group(10, name: "Aden", description: "Aden")
    let agent = agent(20, name: "Aden", handle: "aden", description: "Aden", botId: 200)
    model.updateCandidates(.init(users: [], groups: [group], agents: [agent]))
    model.filter(with: "dena")
    #expect(model.items.isEmpty)
    model.filter(with: "den")
    #expect(model.items.count == 2)
  }

  @Test("names and handles beat description or backing-bot discovery")
  func descriptionsRankLast() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates(.init(
      users: [candidate(1, firstName: "Metrics Team", source: .participant)],
      groups: [group(10, name: "Analysts", description: "metrics")],
      agents: [agent(20, name: "Researcher", handle: "research", description: "metrics", botId: 200)]
    ))
    model.filter(with: "metrics")
    #expect(model.items.map(\.id) == ["user:1", "group:10", "agent:20"])
  }

  @Test("Agents inherit the backing bot's available pin and message priority")
  func agentsInheritChatPriority() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates(.init(
      users: [
        candidate(100, firstName: "Bot", source: .directChat, lastMsgId: 999),
        candidate(200, firstName: "Bot", source: .directChat, lastMsgId: 1, isPinned: true),
      ],
      groups: [],
      agents: [
        agent(10, name: "Data Analyst", handle: "analyst", botId: 100),
        agent(20, name: "Data Researcher", handle: "researcher", botId: 200),
      ]
    ))
    model.filter(with: "data")
    #expect(model.items.map(\.id) == ["agent:20", "agent:10"])
  }

  @Test("large candidate sets keep priority and exact matches without result truncation")
  func largeCandidateSet() {
    let model = MentionCompletionViewModel(currentUserId: { nil })
    model.updateCandidates((1 ... 5_000).map { id in
      candidate(
        Int64(id), firstName: "Daniel \(id)", username: "person_\(id)",
        source: .directChat, lastMsgId: Int64(id), isPinned: id == 4_999
      )
    })
    for query in ["d", "da", "dan", "dani", "danie", "daniel"] {
      model.filter(with: query)
      #expect(model.items.count == 5_000)
      #expect(userIds(Array(model.items.prefix(3))) == [4_999, 5_000, 4_998])
    }
    model.filter(with: "person_1")
    #expect(model.items.first?.id == "user:1")
  }

  private func group(_ id: Int64, name: String, description: String? = nil) -> InlineKit.UserGroup {
    InlineKit.UserGroup(
      id: id, spaceId: 1, name: name, description: description,
      memberCount: 1, currentUserIsMember: false, date: Date(timeIntervalSince1970: 1)
    )
  }

  private func agent(
    _ id: Int64,
    name: String,
    handle: String,
    description: String? = nil,
    botId: Int64
  ) -> MentionableBotAgent {
    var profile = BotAgentProfile()
    profile.id = id
    profile.botUserID = botId
    profile.name = name
    profile.handle = handle
    if let description { profile.description_p = description }
    return MentionableBotAgent(profile: profile, botUserInfo: user(botId, firstName: "Bot", username: "bot"))
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
    lastMsgId: Int64? = nil,
    isPinned: Bool = false
  ) -> MentionCompletionUser {
    MentionCompletionUser(
      userInfo: user(id, firstName: firstName, lastName: lastName, username: username),
      source: source,
      lastMsgId: lastMsgId,
      isPinned: isPinned
    )
  }

  private func userIds(_ items: [MentionCompletionItem]) -> [Int64] {
    items.compactMap { $0.userInfo?.user.id }
  }
}
