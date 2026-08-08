import Foundation

public enum InlineCommandID: String, Hashable, Sendable {
  case clear
}

public enum InlineCommandTransaction: String, Hashable, Sendable {
  case collapseHistory
}

public enum InlineCommandAppAction: String, Hashable, Sendable {
  case none
}

public enum InlineCommandAction: Hashable, Sendable {
  case sendMessage
  case transaction(InlineCommandTransaction)
  case app(InlineCommandAppAction)
}

public struct InlineCommandDefinition: Identifiable, Hashable, Sendable {
  public let id: InlineCommandID
  public let command: String
  public let title: String
  public let description: String
  public let action: InlineCommandAction

  public init(
    id: InlineCommandID,
    command: String,
    title: String,
    description: String,
    action: InlineCommandAction
  ) {
    self.id = id
    self.command = command
    self.title = title
    self.description = description
    self.action = action
  }
}

public enum ComposeCommandSource: Identifiable, Hashable, Sendable {
  case bot(PeerBotCommandSuggestion)
  case inline(InlineCommandDefinition)

  public var id: String {
    switch self {
      case let .bot(command): "bot:\(command.id)"
      case let .inline(command): "inline:\(command.id.rawValue)"
    }
  }
}

public enum InlineCommands {
  public static let all: [InlineCommandDefinition] = [
    InlineCommandDefinition(
      id: .clear,
      command: "clear",
      title: "/clear",
      description: "Collapse history for you — nothing is deleted.",
      action: .transaction(.collapseHistory)
    ),
  ]

  /// Bot commands always precede Inline commands so a bot's advertised actions remain primary.
  public static func suggestions(
    matching query: String,
    botSuggestions: [PeerBotCommandSuggestion]
  ) -> [ComposeCommandSource] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let inline = all.filter { command in
      normalized.isEmpty ||
        command.command.localizedCaseInsensitiveContains(normalized) ||
        command.description.localizedCaseInsensitiveContains(normalized)
    }
    return botSuggestions.map(ComposeCommandSource.bot) + inline.map(ComposeCommandSource.inline)
  }

  /// Bare exact commands are app-owned. Qualified commands such as `/clear@bot` remain bot messages.
  public static func resolveExact(_ text: String) -> InlineCommandDefinition? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.hasPrefix("/"), !normalized.contains("@") else { return nil }
    return all.first { "/\($0.command)" == normalized }
  }
}
