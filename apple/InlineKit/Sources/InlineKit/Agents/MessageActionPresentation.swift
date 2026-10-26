import Foundation
import InlineProtocol

/// What tapping a message action does, decided once for every platform.
public enum MessageActionIntent: Equatable, Sendable {
  case callback
  case copyText(String)
  /// A web URL, or an app link such as `codex://threads/<id>`.
  case openURL(URL, isWeb: Bool)
  case openLink(peer: Peer, messageID: Int64?)
  case unavailable
}

public struct MessageActionConfirmation: Equatable, Sendable {
  public let title: String
  public let text: String?
  public let confirmTitle: String
}

public struct MessageActionAlertContent: Equatable, Sendable {
  public let title: String?
  public let text: String

  public init(title: String?, text: String) {
    self.title = title
    self.text = text
  }

  public init?(_ ui: InlineProtocol.MessageActionResponseUi) {
    guard case let .alert(alert)? = ui.kind else { return nil }
    let text = alert.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = alert.hasTitle ? alert.title.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    guard !text.isEmpty || !title.isEmpty else { return nil }
    self.init(title: title.isEmpty ? nil : title, text: text)
  }
}

/// Render-ready state for one action button (spec §6 actions).
public struct MessageActionPresentation: Equatable, Sendable {
  public enum Style: Equatable, Sendable {
    case standard
    case primary
    case destructive
  }

  public let style: Style
  public let intent: MessageActionIntent
  public let confirmation: MessageActionConfirmation?
  /// Set when the viewer lacks the bot grant the action requires.
  public let disabledReason: String?

  public var isEnabled: Bool { disabledReason == nil && intent != .unavailable }

  public init(
    action: InlineProtocol.MessageAction,
    access: AgentGrantAccess?,
    ownerName: String?,
    botName: String?
  ) {
    style = switch action.style {
    case .primary: .primary
    case .destructive: .destructive
    case .default, .UNRECOGNIZED: .standard
    }
    let intent = Self.intent(for: action.action)
    self.intent = intent
    confirmation = action.hasConfirm ? Self.confirmation(action.confirm, actionTitle: action.text) : nil
    disabledReason = Self.disabledReason(
      requirement: action.requiredGrant,
      access: access,
      ownerName: ownerName,
      botName: botName
    )
  }

  /// "Only Bob can approve". Nil when the viewer qualifies or when grants are
  /// not known yet; the server rejects an unauthorized invocation either way.
  public static func disabledReason(
    requirement: InlineProtocol.AgentGrantRequirement,
    access: AgentGrantAccess?,
    ownerName: String?,
    botName: String?
  ) -> String? {
    guard requirement != .none, let access, !access.satisfies(requirement) else { return nil }
    let owner = ownerName ?? String(localized: "the agent’s owner")
    let agent = botName ?? String(localized: "this agent")
    return switch requirement {
    case .approve:
      String(localized: "Only \(owner) can approve")
    case .access:
      String(localized: "Only people with access to \(agent) can answer")
    case .invoke:
      String(localized: "Ask \(owner) for access to \(agent)")
    case .steer:
      String(localized: "Only \(owner) and people they allow can steer \(agent)")
    case .view:
      String(localized: "Ask \(owner) for access to \(agent)’s work")
    case .configure, .owner:
      String(localized: "Only \(owner) can change this")
    case .none, .UNRECOGNIZED:
      String(localized: "You can’t use this")
    }
  }

  static func intent(for action: InlineProtocol.MessageAction.OneOf_Action?) -> MessageActionIntent {
    switch action {
    case .callback:
      return .callback
    case let .copyText(copy):
      return .copyText(copy.text)
    case let .openURL(open):
      guard let url = Self.safeURL(open.url) else { return .unavailable }
      let scheme = url.scheme?.lowercased()
      return .openURL(url, isWeb: scheme == "https" || scheme == "http")
    case let .openLink(link):
      guard link.hasPeerID else { return .unavailable }
      return .openLink(peer: link.peerID.toPeer(), messageID: link.hasMessageID ? link.messageID : nil)
    case nil:
      return .unavailable
    }
  }

  /// Web URLs and app schemes only; local files and script URLs never open.
  static func safeURL(_ string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= 4_096, let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(), !scheme.isEmpty
    else { return nil }
    let blocked: Set<String> = ["file", "javascript", "data", "vbscript", "about", "blob"]
    guard !blocked.contains(scheme) else { return nil }
    if scheme == "http" || scheme == "https" { return url.host?.isEmpty == false ? url : nil }
    return url
  }

  private static func confirmation(
    _ confirm: InlineProtocol.MessageActionConfirm,
    actionTitle: String
  ) -> MessageActionConfirmation {
    let title = confirm.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = confirm.hasText ? confirm.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let confirmTitle = confirm.hasConfirmText
      ? confirm.confirmText.trimmingCharacters(in: .whitespacesAndNewlines)
      : ""
    return .init(
      title: title.isEmpty ? actionTitle : title,
      text: text.isEmpty ? nil : text,
      confirmTitle: confirmTitle.isEmpty ? actionTitle : confirmTitle
    )
  }
}

public extension MessageActionIntent {
  /// The confirmation shown before opening a non-web app link.
  func destinationConfirmation() -> MessageActionConfirmation? {
    guard case let .openURL(url, isWeb) = self, !isWeb else { return nil }
    return .init(
      title: String(localized: "Open this link?"),
      text: url.absoluteString,
      confirmTitle: String(localized: "Open")
    )
  }
}
