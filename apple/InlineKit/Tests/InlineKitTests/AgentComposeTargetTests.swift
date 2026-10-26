import Foundation
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

  @Test("work state ignores older revisions and defaults to Detailed")
  @MainActor
  func workStateRevisions() {
    let store = AgentWorkStateStore()
    let key = AgentWorkState.Key(chatID: 1, botUserID: Self.bot)
    #expect(store.outputMode(chatID: 1, botUserID: Self.bot) == .detailed)
    store.apply(.init(key: key, runState: .working, outputMode: .friendly, revision: 5))
    store.apply(.init(key: key, runState: .idle, outputMode: .detailed, revision: 4))
    #expect(store.state(chatID: 1, botUserID: Self.bot)?.runState == .working)
    #expect(store.outputMode(chatID: 1, botUserID: Self.bot) == .friendly)
  }
}
