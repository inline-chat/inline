import Foundation
import InlineProtocol

/// A bot's answer to someone pressing one of its controls (a message button or
/// an Agent Settings item): what to show or do for that person, on the device
/// they pressed on.
public enum BotResponseUi: Equatable, Sendable {
  case toast(String)
  case alert(MessageActionAlertContent)
  case openURL(BotResponseOpenURL)

  public init?(_ ui: InlineProtocol.MessageActionResponseUi) {
    switch ui.kind {
    case let .toast(toast):
      let text = toast.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      self = .toast(text)
    case .alert:
      guard let alert = MessageActionAlertContent(ui) else { return nil }
      self = .alert(alert)
    case let .openURL(open):
      guard let url = BotResponseOpenURL(open) else { return nil }
      self = .openURL(url)
    case nil:
      return nil
    }
  }
}

/// A URL a bot asked to open for the person who pressed.
public struct BotResponseOpenURL: Equatable, Sendable, CustomStringConvertible {
  /// How long after the press an answer may still open its URL.
  public static let openWindow: TimeInterval = 30

  public let url: URL
  /// The URL carries a credential (a one-time login): never show, copy or log it.
  public let isSensitive: Bool
  /// The agent's machine, for messages.
  public let hostLabel: String?
  /// The bot's advice for when a loopback URL can't be reached from here.
  public let unreachableText: String?

  public var isWeb: Bool {
    let scheme = url.scheme?.lowercased()
    return scheme == "http" || scheme == "https"
  }

  /// Points at the agent's own machine (127.0.0.0/8, ::1, localhost): it only
  /// opens from that machine.
  public var isLoopback: Bool {
    guard isWeb, let host = url.host?.lowercased() else { return false }
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return bare == "localhost" || bare.hasSuffix(".localhost") || bare == "::1" || bare.hasPrefix("127.")
  }

  public init(url: URL, isSensitive: Bool, hostLabel: String? = nil, unreachableText: String? = nil) {
    self.url = url
    self.isSensitive = isSensitive
    self.hostLabel = hostLabel
    self.unreachableText = unreachableText
  }

  init?(_ open: InlineProtocol.MessageActionResponseOpenUrl) {
    guard let url = MessageActionPresentation.safeURL(open.url) else { return nil }
    self.init(
      url: url,
      isSensitive: open.sensitive,
      hostLabel: open.hasHostLabel ? Self.trimmedNonEmpty(open.hostLabel) : nil,
      unreachableText: open.hasUnreachableText ? Self.trimmedNonEmpty(open.unreachableText) : nil
    )
  }

  private static func trimmedNonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Keeps credentials out of logs and debug output.
  public var description: String {
    isSensitive ? "BotResponseOpenURL(\(url.scheme ?? "?")://\(url.host ?? "?"), sensitive)" : "BotResponseOpenURL(\(url))"
  }
}

/// What the app does with a bot's URL answer.
public enum BotResponseOpenDecision: Equatable, Sendable {
  case open(URL)
  /// A non-web app link: show the destination and open on confirmation.
  case confirm(URL, MessageActionConfirmation)
  /// A loopback URL this device can't reach: explain instead of opening a dead page.
  case unreachable(MessageActionAlertContent)
  /// The answer came too long after the press; opening now would surprise.
  case expired
}

public enum BotResponseURLResolver {
  public typealias Probe = @Sendable (URL) async -> Bool

  public static func decide(
    _ open: BotResponseOpenURL,
    pressedAt: Date,
    now: @Sendable () -> Date = { Date() },
    probe: Probe = LoopbackProbe.isReachable
  ) async -> BotResponseOpenDecision {
    guard isFresh(pressedAt: pressedAt, now: now()) else { return .expired }
    if open.isLoopback, await !probe(open.url) {
      return .unreachable(unreachableAlert(open))
    }
    guard isFresh(pressedAt: pressedAt, now: now()) else { return .expired }
    guard open.isWeb else {
      // Credentials stay off screen: show where it goes, not the full link.
      let destination = open.isSensitive ? "\(open.url.scheme ?? "")://\(open.url.host ?? "")" : open.url.absoluteString
      return .confirm(open.url, .init(
        title: String(localized: "Open this link?"),
        text: destination,
        confirmTitle: String(localized: "Open")
      ))
    }
    return .open(open.url)
  }

  static func isFresh(pressedAt: Date, now: Date) -> Bool {
    let elapsed = now.timeIntervalSince(pressedAt)
    return elapsed >= -1 && elapsed <= BotResponseOpenURL.openWindow
  }

  static func unreachableAlert(_ open: BotResponseOpenURL) -> MessageActionAlertContent {
    let title = open.hostLabel.map { String(localized: "This only opens on \($0)") }
      ?? String(localized: "This only opens on the agent’s computer")
    return .init(
      title: title,
      text: open.unreachableText ?? String(localized: "It points to the computer the agent runs on, and this device can’t reach it.")
    )
  }
}

/// Checks whether a loopback URL answers on this device, without sending its
/// path, query or fragment (where one-time logins live).
public enum LoopbackProbe {
  public static func isReachable(_ url: URL) async -> Bool {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
    components.path = "/"
    components.query = nil
    components.fragment = nil
    components.user = nil
    components.password = nil
    guard let origin = components.url else { return false }
    var request = URLRequest(url: origin, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
    request.httpMethod = "HEAD"
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 1.5
    configuration.timeoutIntervalForResource = 2
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      let (_, response) = try await session.data(for: request)
      // Any HTTP answer means something listens there; the page decides the rest.
      return response is HTTPURLResponse
    } catch {
      return false
    }
  }
}
