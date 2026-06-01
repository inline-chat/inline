import Foundation

public struct UrlPreviewDisplayContent: Equatable, Sendable {
  public let source: String?
  public let title: String
  public let subtitle: String?
}

public extension UrlPreview {
  var openURL: URL? {
    Self.openURL(for: url)
  }

  func displayContent(maxDescriptionLength: Int) -> UrlPreviewDisplayContent {
    let source = displaySource
    let title = title?.nilIfEmpty ?? source ?? url
    let description = description?.limitedDisplayText(maxLength: maxDescriptionLength)
    let subtitleSource = title.isSameDisplayText(as: source) ? nil : source
    let subtitle = [subtitleSource, description]
      .compactMap(\.self)
      .joined(separator: " • ")
      .nilIfEmpty

    return UrlPreviewDisplayContent(source: source, title: title, subtitle: subtitle)
  }

  var displaySource: String? {
    let host = displayUrl.flatMap(Self.normalizedHost(for:)) ?? Self.normalizedHost(for: url)
    if let provider = knownProviderName(provider: provider, siteName: siteName, host: host) {
      return provider
    }

    return host
  }

  private static func normalizedHost(for url: String) -> String? {
    let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let host = URLComponents(string: value)?.host
      ?? URLComponents(string: "https://\(value)")?.host

    return host?.nilIfEmpty?.lowercased()
      .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
  }

  private static func openURL(for url: String) -> URL? {
    let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    if URLComponents(string: value)?.scheme != nil {
      return webURL(from: value)
    }

    if value.hasPrefix("//") {
      return webURL(from: "https:\(value)")
    }

    return webURL(from: "https://\(value)")
  }

  private static func webURL(from value: String) -> URL? {
    guard let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          components.host?.nilIfEmpty != nil,
          components.user == nil,
          components.password == nil
    else {
      return nil
    }

    return components.url
  }

  private func knownProviderName(provider: String?, siteName: String?, host: String?) -> String? {
    for knownProvider in KnownURLPreviewProvider.allCases {
      if let host, knownProvider.matches(host: host) {
        return knownProvider.displayName
      }

      if knownProvider.matches(label: provider) || knownProvider.matches(label: siteName) {
        return knownProvider.displayName
      }
    }

    return nil
  }
}

private enum KnownURLPreviewProvider: CaseIterable {
  case loom
  case youtube
  case vimeo
  case github
  case figma
  case notion
  case linear
  case sentry
  case x
  case reddit
  case tiktok
  case instagram
  case linkedIn

  var displayName: String {
    switch self {
    case .loom: "Loom"
    case .youtube: "YouTube"
    case .vimeo: "Vimeo"
    case .github: "GitHub"
    case .figma: "Figma"
    case .notion: "Notion"
    case .linear: "Linear"
    case .sentry: "Sentry"
    case .x: "X"
    case .reddit: "Reddit"
    case .tiktok: "TikTok"
    case .instagram: "Instagram"
    case .linkedIn: "LinkedIn"
    }
  }

  private var aliases: Set<String> {
    switch self {
    case .loom: ["loom"]
    case .youtube: ["youtube", "you tube"]
    case .vimeo: ["vimeo"]
    case .github: ["github", "git hub"]
    case .figma: ["figma"]
    case .notion: ["notion"]
    case .linear: ["linear"]
    case .sentry: ["sentry"]
    case .x: ["x", "twitter"]
    case .reddit: ["reddit"]
    case .tiktok: ["tiktok", "tik tok"]
    case .instagram: ["instagram"]
    case .linkedIn: ["linkedin", "linked in"]
    }
  }

  private var hosts: Set<String> {
    switch self {
    case .loom: ["loom.com"]
    case .youtube: ["youtube.com", "youtu.be", "youtube-nocookie.com"]
    case .vimeo: ["vimeo.com"]
    case .github: ["github.com"]
    case .figma: ["figma.com"]
    case .notion: ["notion.so", "notion.site"]
    case .linear: ["linear.app"]
    case .sentry: ["sentry.io"]
    case .x: ["x.com", "twitter.com"]
    case .reddit: ["reddit.com", "redd.it"]
    case .tiktok: ["tiktok.com"]
    case .instagram: ["instagram.com"]
    case .linkedIn: ["linkedin.com"]
    }
  }

  func matches(host: String) -> Bool {
    hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
  }

  func matches(label: String?) -> Bool {
    guard let label = label?.normalizedProviderLabel else { return false }
    return aliases.contains(label)
  }
}

private extension String {
  var nilIfEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  var normalizedProviderLabel: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return value.isEmpty ? nil : value
  }

  func limitedDisplayText(maxLength: Int) -> String? {
    guard let value = nilIfEmpty else { return nil }
    guard maxLength > 0 else { return nil }
    guard value.count > maxLength else { return value }

    if maxLength <= 3 {
      return String(value.prefix(maxLength))
    }

    return "\(value.prefix(maxLength - 3))..."
  }

  func isSameDisplayText(as other: String?) -> Bool {
    normalizedProviderLabel == other?.normalizedProviderLabel
  }
}
