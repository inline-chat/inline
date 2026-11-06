import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Compose command search")
struct ComposeCommandSearchTests {
  @Test("prefix matches rank above substring, fuzzy, and description matches")
  func ranksByMatchQuality() {
    let commands = [
      Self.command("restart", "Restart the worker", bot: 1, username: "ops"),
      Self.command("status", "Show status", bot: 1, username: "ops"),
      Self.command("deploy", "Ship a build that starts now", bot: 1, username: "ops"),
      Self.command("start", "Start the bot", bot: 1, username: "ops"),
    ]

    #expect(Self.names(Self.search("start", commands)) == ["/start", "/restart", "/deploy"])
    #expect(Self.names(Self.search("st", commands)) == ["/status", "/start", "/restart"])
    #expect(Self.names(Self.search("dpl", commands)) == ["/deploy"])
  }

  @Test("a single letter only matches name prefixes")
  func shortQueriesStayFocused() {
    let commands = [
      Self.command("help", "Show the menu", bot: 1, username: "helper"),
      Self.command("ship", "Deploy", bot: 1, username: "helper"),
    ]
    #expect(Self.names(Self.search("h", commands)) == ["/help"])
  }

  @Test("an exact app command beats bot prefix matches, and app commands follow bots otherwise")
  func appCommandsInterleaveByMatchQuality() {
    let commands = [Self.command("clear_cache", "Drop caches", bot: 1, username: "ops")]
    let inline = InlineCommandRegistry.commands(for: .thread(id: 1))

    #expect(Self.names(Self.search("clear", commands, inline: inline)) == ["/clear", "/clear_cache"])
    #expect(Self.names(Self.search("", commands, inline: inline)) == ["/clear_cache", "/rename", "/clear", "/thread"])
  }

  @Test("a bot command named like an app command shows its bot and targets it explicitly")
  func appCommandCollisionIsDisambiguated() {
    let commands = [Self.command("clear", "Clear the bot session", bot: 1, username: "claude")]
    let results = Self.search("clear", commands, inline: InlineCommandRegistry.commands)

    guard case let .bot(botCommand)? = results.first(where: { if case .bot = $0 { true } else { false } }) else {
      Issue.record("Expected the bot command")
      return
    }
    #expect(botCommand.isAmbiguous)
    #expect(botCommand.insertionText == "/clear@claude ")
    #expect(results.count == 2)
  }

  @Test("in a DM, the DM's bot comes before other bots with equal matches")
  func directMessageBotFirst() {
    let commands = [
      Self.command("help", "Help", bot: 1, username: "alpha"),
      Self.command("help", "Help", bot: 2, username: "beta", ambiguous: true),
    ]
    let results = Self.search("help", commands, peer: .user(id: 2))
    #expect(results.compactMap(Self.botId) == [2, 1])
  }

  @Test("equal matches keep the server's bot order")
  func serverOrderBreaksTies() {
    let commands = [
      Self.command("status", "Status", bot: 9, username: "near"),
      Self.command("stats", "Stats", bot: 3, username: "far"),
    ]
    #expect(Self.search("sta", commands).compactMap(Self.botId) == [9, 3])
  }

  @Test("cmd@bot narrows by bot username or name prefix, including an empty bot part")
  func botSuffixNarrows() {
    let commands = [
      Self.command("help", "Help", bot: 1, username: "alpha", ambiguous: true),
      Self.command("help", "Help", bot: 2, username: "beta", ambiguous: true),
      Self.command("logs", "Logs", bot: 2, username: "beta"),
    ]
    let inline = InlineCommandRegistry.commands

    #expect(Self.search("help@be", commands, inline: inline).compactMap(Self.botId) == [2])
    #expect(Self.search("help@", commands, inline: inline).compactMap(Self.botId) == [1, 2])
    #expect(Self.search("@beta", commands, inline: inline).count == 2)
    #expect(Self.search("help@zeta", commands, inline: inline).isEmpty)
  }

  @Test("a bot name lists that bot's commands after real command matches")
  func botNameMatches() {
    let commands = [
      Self.command("ask", "Ask a question", bot: 1, username: "claude", displayName: "Claude"),
      Self.command("clip", "Clip a link", bot: 2, username: "saver"),
    ]
    #expect(Self.names(Self.search("cl", commands)) == ["/clip", "/ask"])
  }

  // MARK: - Helpers

  private static func search(
    _ query: String,
    _ commands: [PeerBotCommandSuggestion],
    inline: [InlineCommandDefinition] = [],
    peer: InlineKit.Peer? = nil
  ) -> [ComposeCommandSuggestion] {
    ComposeCommandSearch.suggestions(matching: query, botCommands: commands, inlineCommands: inline, peer: peer)
  }

  private static func names(_ suggestions: [ComposeCommandSuggestion]) -> [String] {
    suggestions.map { suggestion in
      switch suggestion {
      case let .bot(command): "/\(command.command)"
      case let .inline(command): "/\(command.command)"
      }
    }
  }

  private static func botId(_ suggestion: ComposeCommandSuggestion) -> Int64? {
    if case let .bot(command) = suggestion { return command.botId }
    return nil
  }

  private static func command(
    _ name: String,
    _ description: String,
    bot: Int64,
    username: String,
    displayName: String? = nil,
    ambiguous: Bool = false
  ) -> PeerBotCommandSuggestion {
    var user = InlineProtocol.User()
    user.id = bot
    user.username = username
    user.firstName = displayName ?? username.capitalized
    return PeerBotCommandSuggestion(
      command: name,
      description: description,
      normalizedCommand: name.lowercased(),
      botId: bot,
      botUsername: username,
      botDisplayName: displayName ?? username.capitalized,
      botUserInfo: UserInfo(user: User(from: user)),
      isAmbiguous: ambiguous
    )
  }
}
