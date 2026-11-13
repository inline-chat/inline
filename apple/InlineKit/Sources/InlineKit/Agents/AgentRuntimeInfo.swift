import Foundation
import InlineProtocol

/// What a bot's bridge runtime last reported: where it runs, what it runs and
/// whether it is ready. Kept with the agent's output default so a bot's chat
/// info renders it on its first frame. Owner-only fields are nil for others.
public struct AgentRuntimeInfo: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case online
    case offline
    case needsSetup
    case unknown
  }

  /// `AgentSessionProvider` raw value, so unknown providers still round-trip.
  public var providerRawValue: Int
  public var status: Status
  public var setupReasonRawValue: Int?
  public var setupText: String?
  public var setupMinVersion: String?
  public var machineLabel: String?
  public var executableVersion: String?
  public var lastSeen: Date?
  /// Owner only.
  public var bridgeVersion: String?

  public init(
    providerRawValue: Int,
    status: Status,
    setupReasonRawValue: Int? = nil,
    setupText: String? = nil,
    setupMinVersion: String? = nil,
    machineLabel: String? = nil,
    executableVersion: String? = nil,
    lastSeen: Date? = nil,
    bridgeVersion: String? = nil
  ) {
    self.providerRawValue = providerRawValue
    self.status = status
    self.setupReasonRawValue = setupReasonRawValue
    self.setupText = setupText
    self.setupMinVersion = setupMinVersion
    self.machineLabel = machineLabel
    self.executableVersion = executableVersion
    self.lastSeen = lastSeen
    self.bridgeVersion = bridgeVersion
  }

  public init(_ runtime: InlineProtocol.AgentRuntime) {
    let status: Status = switch runtime.status {
    case .online: .online
    case .offline: .offline
    case .needsSetup: .needsSetup
    case .unspecified, .UNRECOGNIZED: .unknown
    }
    let setup: InlineProtocol.AgentRuntimeSetup? = runtime.hasSetup ? runtime.setup : nil
    self.init(
      providerRawValue: runtime.provider.rawValue,
      status: status,
      setupReasonRawValue: setup.map(\.reason.rawValue),
      setupText: setup.flatMap { $0.hasText ? Self.nonEmpty($0.text) : nil },
      setupMinVersion: setup.flatMap { $0.hasMinVersion ? Self.nonEmpty($0.minVersion) : nil },
      machineLabel: runtime.hasMachineLabel ? Self.nonEmpty(runtime.machineLabel) : nil,
      executableVersion: runtime.hasExecutableVersion ? Self.nonEmpty(runtime.executableVersion) : nil,
      lastSeen: runtime.hasLastSeen && runtime.lastSeen > 0
        ? Date(timeIntervalSince1970: TimeInterval(runtime.lastSeen))
        : nil,
      bridgeVersion: runtime.hasBridgeVersion ? Self.nonEmpty(runtime.bridgeVersion) : nil
    )
  }

  public var provider: InlineProtocol.AgentSessionProvider {
    InlineProtocol.AgentSessionProvider(rawValue: providerRawValue) ?? .unspecified
  }

  /// "Codex", "Claude Code"…; nil when the bridge did not say.
  public var providerName: String? {
    switch provider {
    case .codex: "Codex"
    case .codexCloud: "Codex Cloud"
    case .claude: "Claude Code"
    case .openCode: "OpenCode"
    case .amp: "Amp"
    case .unspecified, .UNRECOGNIZED: nil
    }
  }

  /// "Codex 0.52.0", or whichever half is known.
  public var runtimeTitle: String? {
    switch (providerName, executableVersion) {
    case let (name?, version?): "\(name) \(version)"
    case let (name?, nil): name
    case let (nil, version?): version
    case (nil, nil): nil
    }
  }

  /// The bridge's own fix text, else a short one from the reason.
  public var setupSummary: String? {
    guard status == .needsSetup else { return nil }
    if let setupText { return setupText }
    let runtime = providerName ?? String(localized: "the runtime")
    let reason = setupReasonRawValue.flatMap(InlineProtocol.AgentRuntimeSetup.Reason.init(rawValue:))
    return switch reason {
    case .updateRuntime:
      setupMinVersion.map { String(localized: "Update \(runtime) to \($0) or later.") }
        ?? String(localized: "Update \(runtime).")
    case .updateInline: String(localized: "Update the Inline CLI on this machine.")
    case .executableMissing: String(localized: "\(runtime) isn’t installed on this machine.")
    case .executableChanged: String(localized: "\(runtime) changed. Run setup again on this machine.")
    case .signIn: String(localized: "Sign in to \(runtime) on this machine.")
    case .folderUnavailable: String(localized: "The bot’s folder isn’t available.")
    case .organization: String(localized: "\(runtime) needs organization access.")
    case .other, .unspecified, .UNRECOGNIZED, nil: String(localized: "Finish setup on the bot’s machine.")
    }
  }

  private static func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// One line for a bot's status in its chat info: its runtime when it reports
/// one, else the server-derived presence. Nil when neither is known.
public struct BotStatusSummary: Equatable, Sendable {
  public enum Tone: Equatable, Sendable {
    case online
    case offline
    case attention
  }

  public let title: String
  public let detail: String?
  public let tone: Tone

  public init(title: String, detail: String?, tone: Tone) {
    self.title = title
    self.detail = detail
    self.tone = tone
  }

  public static func make(
    user: User,
    runtime: AgentRuntimeInfo?,
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> BotStatusSummary? {
    if let runtime {
      switch runtime.status {
      case .needsSetup:
        return .init(title: String(localized: "Needs Setup"), detail: runtime.setupSummary, tone: .attention)
      case .online:
        return .init(title: String(localized: "Online"), detail: nil, tone: .online)
      case .offline:
        let seen = runtime.lastSeen ?? user.lastOnline
        return .init(
          title: String(localized: "Offline"),
          detail: seen.map { lastSeen($0, now: now, calendar: calendar, locale: locale) },
          tone: .offline
        )
      case .unknown:
        break
      }
    }
    guard user.bot, let online = user.online else { return nil }
    if online { return .init(title: String(localized: "Online"), detail: nil, tone: .online) }
    return .init(
      title: String(localized: "Offline"),
      detail: user.lastOnline.map { lastSeen($0, now: now, calendar: calendar, locale: locale) },
      tone: .offline
    )
  }

  private static func lastSeen(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
    "Last seen \(BotOnlineStatus.lastSeen(date, now: now, calendar: calendar, locale: locale))"
  }
}

/// What someone else's grant lets them do, in words.
public extension AgentGrantAccess {
  var viewerAccessSummary: String {
    if isOwner { return String(localized: "Owner") }
    let ops = operations.subtracting([.unspecified])
    if ops.isEmpty { return String(localized: "No access") }
    if ops.contains(.configure) { return String(localized: "Can use and configure") }
    if ops.contains(.invoke), ops.contains(.steer) { return String(localized: "Can start and steer") }
    if ops.contains(.invoke) { return String(localized: "Can start work") }
    return String(localized: "Can answer its questions")
  }
}
