import Foundation
import InlineProtocol

/// How a message sent by an agent for its sender reads: "Sent via Codex" on the
/// last message of the run, an agent badge on the sender's avatar, and one
/// generic sentence on hover or long-press. Never mentions the device, OS, CLI
/// or MCP.
public struct MessageViaPresentation: Equatable, Sendable {
  /// What the badge on the sender's avatar draws.
  public enum Mark: Equatable, Sendable {
    /// A known agent id ("claude-code", "codex") or "agent" for an unnamed one.
    /// The badge draws only for agents with an icon.
    case agent(String)
    /// A bot the sender owns; draw its avatar.
    case bot(UserInfo)
  }

  /// "Codex", "Claude Code", "an AI agent", or the bot's name.
  public let name: String
  /// Nil when there is nothing to draw, such as a bot this device hasn't loaded.
  public let mark: Mark?
  private let isBot: Bool

  /// "Sent via Codex".
  public var label: String { "Sent via \(name)" }

  public init(name: String, mark: Mark?, isBot: Bool = false) {
    self.name = name
    self.mark = mark
    self.isBot = isBot
  }

  /// "Mo sent this using Codex, an AI agent."
  public func detail(senderName: String?) -> String {
    let sender = senderName.flatMap { $0.isEmpty ? nil : $0 } ?? "The sender"
    if isBot {
      return "\(sender) sent this using their bot \(name)."
    }
    if mark == .agent(Self.genericAgentId) {
      return "\(sender) sent this using an AI agent."
    }
    return "\(sender) sent this using \(name), an AI agent."
  }

  public static let genericAgentId = "agent"

  /// `cachedUser` should read memory only, so rendering never touches the
  /// database. A bot this device hasn't loaded shows the name it had when the
  /// message was sent, without a badge.
  public init?(via: MessageVia?, cachedUser: (Int64) -> UserInfo?) {
    guard let via, let source = via.source else { return nil }
    let sentName = via.hasName && !via.name.isEmpty ? via.name : nil
    switch source {
      case let .app(app):
        let id = app.isEmpty ? Self.genericAgentId : app
        self.init(name: sentName ?? Self.fallbackName(for: id), mark: .agent(id))
      case let .botUserID(botUserID):
        if let bot = cachedUser(botUserID) {
          self.init(name: bot.user.shortDisplayName, mark: .bot(bot), isBot: true)
        } else {
          self.init(name: sentName ?? "a bot", mark: nil, isBot: true)
        }
    }
  }

  static func fallbackName(for id: String) -> String {
    id == genericAgentId ? "an AI agent" : id
  }
}

public extension FullMessage {
  /// Present when an agent sent this message for its sender. Reads the
  /// in-memory user cache on the main thread only; elsewhere a bot signer reads
  /// as an unnamed agent.
  var viaPresentation: MessageViaPresentation? {
    let via = message.via
    guard via != nil else { return nil }
    if Thread.isMainThread {
      return MainActor.assumeIsolated {
        MessageViaPresentation(via: via) { ObjectCache.shared.getCachedUser(id: $0) }
      }
    }
    return MessageViaPresentation(via: via) { _ in nil }
  }
}
