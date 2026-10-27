import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Agent compose target")
struct AgentComposeTargetTests {
  private static let bot: Int64 = 900
  private static let otherBot: Int64 = 901
  private static let human: Int64 = 7

  private static func isBot(_ id: Int64) -> Bool { id == bot || id == otherBot }

  private static func mention(_ text: String, userID: Int64) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.mentionUserId: userID])
  }

  private static func draft(_ parts: NSAttributedString...) -> NSAttributedString {
    let value = NSMutableAttributedString()
    parts.forEach(value.append)
    return value
  }

  @Test("reads the leading run of mentions across whitespace")
  func leadingRun() {
    let text = Self.draft(
      NSAttributedString(string: "  "),
      Self.mention("@alice", userID: Self.human),
      NSAttributedString(string: " "),
      Self.mention("@codex", userID: Self.bot),
      NSAttributedString(string: " compare these "),
      Self.mention("@claude", userID: Self.otherBot)
    )
    #expect(AgentComposeTargetResolver.leadingMentionUserIDs(in: text) == [Self.human, Self.bot])
  }

  @Test("a mention later in the text is not leading")
  func laterMention() {
    let text = Self.draft(NSAttributedString(string: "hey "), Self.mention("@codex", userID: Self.bot))
    #expect(AgentComposeTargetResolver.leadingMentionUserIDs(in: text).isEmpty)
  }

  @Test("a leading mention of only others hides the agent, even in its own thread")
  func addressedToOthers() {
    let target = AgentComposeTargetResolver.resolve(
      leadingMentionUserIDs: [Self.human],
      replyToUserID: Self.bot,
      agentThreadBotUserID: Self.bot,
      directMessageBotUserID: nil,
      isBot: Self.isBot
    )
    #expect(target == nil)
  }

  @Test("the first bot in the leading run is the target")
  func leadingBot() {
    let target = AgentComposeTargetResolver.resolve(
      leadingMentionUserIDs: [Self.human, Self.otherBot],
      replyToUserID: nil,
      agentThreadBotUserID: Self.bot,
      directMessageBotUserID: nil,
      isBot: Self.isBot
    )
    #expect(target == AgentComposeTarget(botUserID: Self.otherBot, reason: .leadingMention))
  }

  @Test("a reply to an agent beats the thread's own agent")
  func replyToBot() {
    let target = AgentComposeTargetResolver.resolve(
      leadingMentionUserIDs: [],
      replyToUserID: Self.otherBot,
      agentThreadBotUserID: Self.bot,
      directMessageBotUserID: nil,
      isBot: Self.isBot
    )
    #expect(target == AgentComposeTarget(botUserID: Self.otherBot, reason: .reply))
  }

  @Test("a reply to a person in the agent's thread still reaches the agent")
  func replyToHumanInAgentThread() {
    let target = AgentComposeTargetResolver.resolve(
      leadingMentionUserIDs: [],
      replyToUserID: Self.human,
      agentThreadBotUserID: Self.bot,
      directMessageBotUserID: nil,
      isBot: Self.isBot
    )
    #expect(target == AgentComposeTarget(botUserID: Self.bot, reason: .agentThread))
  }

  @Test("a DM with a bot reaches it; a group thread without addressing does not")
  func directMessageAndGroup() {
    #expect(AgentComposeTargetResolver.resolve(
      leadingMentionUserIDs: [],
      replyToUserID: nil,
      agentThreadBotUserID: nil,
      directMessageBotUserID: Self.bot,
      isBot: Self.isBot
    ) == AgentComposeTarget(botUserID: Self.bot, reason: .directMessage))
    #expect(AgentComposeTargetResolver.resolve(
      leadingMentionUserIDs: [],
      replyToUserID: Self.human,
      agentThreadBotUserID: nil,
      directMessageBotUserID: nil,
      isBot: Self.isBot
    ) == nil)
  }

  @Test("work state ignores older revisions; output mode falls back to the agent default")
  @MainActor
  func workStateRevisions() {
    let store = AgentWorkStateStore()
    let peer = Peer.thread(id: 1)
    let key = AgentWorkState.Key(peer: peer, botUserID: Self.bot)
    #expect(store.outputMode(peer: peer, botUserID: Self.bot) == .detailed)
    store.apply(AgentWorkState(key: key, sessionID: 3, runState: .working, revision: 5))
    store.apply(AgentWorkState(key: key, sessionID: 3, runState: .idle, revision: 4))
    #expect(store.state(peer: peer, botUserID: Self.bot)?.runState == .working)
    store.setDefaultOutputMode(.friendly, botUserID: Self.bot)
    #expect(store.outputMode(peer: peer, botUserID: Self.bot) == .friendly)
    store.setOutputModeOverride(.detailed, peer: peer, botUserID: Self.bot)
    #expect(store.outputMode(peer: peer, botUserID: Self.bot) == .detailed)
  }

  @Test("a moved work never moves back on a late update from the chat it left")
  @MainActor
  func movedWorkStaysMoved() {
    let store = AgentWorkStateStore()
    let source = Peer.thread(id: 10)
    let destination = Peer.thread(id: 11)
    let sourceKey = AgentWorkState.Key(peer: source, botUserID: Self.bot)
    let destinationKey = AgentWorkState.Key(peer: destination, botUserID: Self.bot)
    store.apply(AgentWorkState(key: sourceKey, sessionID: 3, runState: .working, revision: 5))
    // The move: same revision, into a subthread of the source.
    store.apply(AgentWorkState(
      key: destinationKey, sessionID: 3, runState: .working, revision: 5, parentChatID: 10
    ))
    #expect(store.state(peer: source, botUserID: Self.bot) == nil)
    #expect(store.state(peer: destination, botUserID: Self.bot)?.revision == 5)
    // A late source page, at the same or an older revision, is ignored.
    store.apply(AgentWorkState(key: sourceKey, sessionID: 3, runState: .idle, revision: 5))
    store.apply(AgentWorkState(key: sourceKey, sessionID: 3, runState: .idle, revision: 4))
    #expect(store.state(peer: source, botUserID: Self.bot) == nil)
    #expect(store.state(peer: destination, botUserID: Self.bot)?.runState == .working)
    // Newer state in the destination still applies.
    store.apply(AgentWorkState(
      key: destinationKey, sessionID: 3, runState: .idle, revision: 6, parentChatID: 10
    ))
    #expect(store.state(peer: destination, botUserID: Self.bot)?.runState == .idle)
  }

  @Test("server revisions order a DM move and an unseen intermediate thread")
  @MainActor
  func movedWorkSkipsUnseenAncestors() {
    let store = AgentWorkStateStore()
    let source = AgentWorkState.Key(peer: .user(id: 9), botUserID: Self.bot)
    let destination = AgentWorkState.Key(peer: .thread(id: 12), botUserID: Self.bot)
    store.apply(AgentWorkState(key: source, sessionID: 3, runState: .working, revision: 5))
    // The intermediate child (revision 6) has not synced to this device.
    store.apply(AgentWorkState(key: destination, sessionID: 3, runState: .working, revision: 7, parentChatID: 11))
    store.apply(AgentWorkState(key: source, sessionID: 3, runState: .idle, revision: 5))
    #expect(store.state(peer: source.peer, botUserID: Self.bot) == nil)
    #expect(store.state(peer: destination.peer, botUserID: Self.bot)?.revision == 7)
  }

  @Test("grant requirements: owner always qualifies, access needs any grant")
  func grantRequirements() {
    let owner = AgentGrantAccess(botUserID: Self.bot, ownerUserID: 1, viewerUserID: 1, operations: [], revision: 1)
    let teammate = AgentGrantAccess(
      botUserID: Self.bot, ownerUserID: 1, viewerUserID: 2, operations: [.invoke], revision: 1
    )
    let stranger = AgentGrantAccess(botUserID: Self.bot, ownerUserID: 1, viewerUserID: 3, operations: [], revision: 1)
    #expect(owner.satisfies(.approve))
    #expect(teammate.satisfies(.access))
    #expect(!teammate.satisfies(.approve))
    #expect(!stranger.satisfies(.access))
    #expect(MessageActionPresentation.disabledReason(
      requirement: .approve, access: teammate, ownerName: "Bob", botName: "Codex"
    ) == "Only Bob can approve")
    #expect(MessageActionPresentation.disabledReason(
      requirement: .approve, access: nil, ownerName: "Bob", botName: "Codex"
    ) == nil)
  }

  @Test("open URL actions never open local files or scripts")
  func safeURLs() {
    #expect(MessageActionPresentation.safeURL("https://inline.chat") != nil)
    #expect(MessageActionPresentation.safeURL("codex://threads/abc") != nil)
    #expect(MessageActionPresentation.safeURL("file:///etc/passwd") == nil)
    #expect(MessageActionPresentation.safeURL("javascript:alert(1)") == nil)
  }
}
