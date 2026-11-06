import Foundation

/// Finds and orders slash commands for the compose picker on every platform.
///
/// Ranking, best first:
/// 1. exact command name
/// 2. command name prefix (`/st` → `/start`)
/// 3. word prefix inside the name (`/logs` → `/deploy_logs`)
/// 4. substring of the name (2+ characters)
/// 5. letters in order (`/dpl` → `/deploy`, 3+ characters)
/// 6. bot name prefix (`/claude` lists Claude's commands, 2+ characters)
/// 7. word prefix in the description (3+ characters)
///
/// Equal matches keep the server's bot order (the DM's bot, then bots in the chat, then space-wide
/// bots) and each bot's own command order; app commands follow bot commands. `cmd@bot` narrows the
/// list to bots whose username or name starts with `bot`.
public enum ComposeCommandSearch {
  public static func suggestions(
    matching query: String,
    botCommands: [PeerBotCommandSuggestion],
    inlineCommands: [InlineCommandDefinition],
    peer: Peer? = nil
  ) -> [ComposeCommandSuggestion] {
    let query = Query(query)
    let inlineNames = Set(inlineCommands.map { $0.command.lowercased() })
    let directMessageBotId = peer?.asUserId()

    var botRanks: [Int64: Int] = [:]
    for command in botCommands where botRanks[command.botId] == nil {
      botRanks[command.botId] = botRanks.count
    }

    var ranked: [(rank: Rank, suggestion: ComposeCommandSuggestion)] = []
    ranked.reserveCapacity(botCommands.count + inlineCommands.count)

    for (index, command) in botCommands.enumerated() {
      if let botQuery = query.bot, !matchesBot(botQuery, command: command) { continue }
      guard let tier = query.tier(
        command: command.normalizedCommand,
        description: command.description,
        botNames: botNames(for: command)
      ) else { continue }

      let botRank = command.botId == directMessageBotId ? -1 : (botRanks[command.botId] ?? 0)
      // A bot command that shares its name with an app command needs its bot label and an
      // explicit `@bot` target, or the two rows look identical.
      let suggestion = inlineNames.contains(command.normalizedCommand) ? command.markedAmbiguous() : command
      ranked.append((Rank(tier: tier, group: botRank, index: index), .bot(suggestion)))
    }

    if query.bot == nil {
      for (index, command) in inlineCommands.enumerated() {
        guard let tier = query.tier(
          command: command.command.lowercased(),
          description: command.description,
          botNames: []
        ) else { continue }
        ranked.append((Rank(tier: tier, group: Int.max, index: index), .inline(command)))
      }
    }

    return ranked.sorted { $0.rank < $1.rank }.map(\.suggestion)
  }

  // MARK: - Matching

  private struct Rank: Comparable {
    let tier: Int
    let group: Int
    let index: Int

    static func < (lhs: Rank, rhs: Rank) -> Bool {
      (lhs.tier, lhs.group, lhs.index) < (rhs.tier, rhs.group, rhs.index)
    }
  }

  private struct Query {
    let command: String
    let bot: String?

    init(_ raw: String) {
      let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if let at = normalized.firstIndex(of: "@") {
        command = String(normalized[..<at])
        bot = String(normalized[normalized.index(after: at)...])
      } else {
        command = normalized
        bot = nil
      }
    }

    func tier(command name: String, description: String, botNames: [String]) -> Int? {
      let query = command
      guard !query.isEmpty else { return 0 }
      if name == query { return 0 }
      if name.hasPrefix(query) { return 1 }
      if ComposeCommandSearch.words(in: name).dropFirst().contains(where: { $0.hasPrefix(query) }) { return 2 }

      let length = query.count
      if length >= 2, name.contains(query) { return 3 }
      if length >= 3, ComposeCommandSearch.isSubsequence(query, of: name) { return 4 }
      if length >= 2, botNames.contains(where: { $0.hasPrefix(query) }) { return 5 }
      if length >= 3,
         ComposeCommandSearch.words(in: description.lowercased()).contains(where: { $0.hasPrefix(query) })
      {
        return 6
      }
      return nil
    }
  }

  private static func matchesBot(_ botQuery: String, command: PeerBotCommandSuggestion) -> Bool {
    botQuery.isEmpty || botNames(for: command).contains { $0.hasPrefix(botQuery) }
  }

  /// Username plus each word of the display name, lowercased.
  private static func botNames(for command: PeerBotCommandSuggestion) -> [String] {
    var names: [String] = []
    if let username = command.botUsername?.lowercased(), !username.isEmpty {
      names.append(username)
    }
    names.append(contentsOf: words(in: command.botDisplayName.lowercased()).map(String.init))
    return names
  }

  private static func words(in value: String) -> [Substring] {
    value.split { !$0.isLetter && !$0.isNumber }
  }

  private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    var remaining = needle[...]
    for character in haystack where character == remaining.first {
      remaining = remaining.dropFirst()
      if remaining.isEmpty { return true }
    }
    return remaining.isEmpty
  }
}
