import Foundation

public enum InlineCommandAction: Hashable, Sendable {
  case collapseHistory
}

public struct InlineCommandDefinition: Identifiable, Hashable, Sendable {
  public let command: String
  public let description: String
  public let action: InlineCommandAction

  public var id: String { command }

  public init(command: String, description: String, action: InlineCommandAction) {
    self.command = command
    self.description = description
    self.action = action
  }
}

/// The single semantic boundary for app-owned slash commands. UI surfaces ask this registry what
/// to present and what local action to run; they never turn an app command into outgoing chat text.
public enum InlineCommandRegistry {
  public static let commands: [InlineCommandDefinition] = [
    InlineCommandDefinition(
      command: "clear",
      description: "Collapse history for you — nothing is deleted.",
      action: .collapseHistory
    ),
  ]

  public static func suggestions(matching query: String) -> [InlineCommandDefinition] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return commands }
    return commands.filter {
      $0.command.contains(query) || $0.description.lowercased().contains(query)
    }
  }

  public static func action(forStandaloneText text: String) -> InlineCommandAction? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard text.first == "/", !text.dropFirst().contains(where: { $0.isWhitespace }) else { return nil }
    return commands.first { "/\($0.command)" == text }?.action
  }
}

public enum ComposeCommandSuggestion: Identifiable, Hashable, Sendable {
  case bot(PeerBotCommandSuggestion)
  case inline(InlineCommandDefinition)

  public var id: String {
    switch self {
    case let .bot(command): "bot-\(command.id)"
    case let .inline(command): "inline-\(command.id)"
    }
  }
}
