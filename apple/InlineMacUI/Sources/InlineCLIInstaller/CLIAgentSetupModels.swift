import Foundation

public enum AgentHarnessFamily: String, Codable, Sendable {
  case gateway
  case bridge
}

public struct AgentHarnessTarget: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let family: AgentHarnessFamily
  public let installed: Bool

  public init(
    id: String,
    displayName: String,
    family: AgentHarnessFamily,
    installed: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.family = family
    self.installed = installed
  }
}

public struct AgentHarnessDiscovery: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let action: String
  public let documentationURL: URL
  public let targets: [AgentHarnessTarget]

  public init(
    protocolVersion: Int,
    action: String,
    documentationURL: URL,
    targets: [AgentHarnessTarget]
  ) {
    self.protocolVersion = protocolVersion
    self.action = action
    self.documentationURL = documentationURL
    self.targets = targets
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case action
    case documentationURL = "documentationUrl"
    case targets
  }
}

public struct AgentSetupResult: Codable, Equatable, Sendable {
  public struct Bot: Codable, Equatable, Sendable {
    public let id: Int64
    public let username: String
    public let name: String
  }

  public struct Service: Codable, Equatable, Sendable {
    public let kind: String
    public let action: String
    public let ready: Bool
    public let status: String?
  }

  public struct Readiness: Codable, Equatable, Sendable {
    public let ready: Bool
    public let code: String?
    public let message: String?
    public let command: String?
    public let verified: Bool?
  }

  public let protocolVersion: Int
  public let ok: Bool
  public let action: String
  public let status: String
  public let documentationURL: URL
  public let openURL: URL
  public let target: String
  public let family: AgentHarnessFamily
  public let instance: String
  public let bot: Bot
  public let service: Service
  public let readiness: Readiness?

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case ok
    case action
    case status
    case documentationURL = "documentationUrl"
    case openURL = "openUrl"
    case target
    case family
    case instance
    case bot
    case service
    case readiness
  }
}

public struct AgentSetupProgressEvent: Codable, Equatable, Sendable {
  public enum Event: String, Codable, Sendable {
    case phaseStarted = "phase.started"
    case phaseCompleted = "phase.completed"
  }

  public enum Phase: String, Codable, Sendable {
    case preflight
    case bot
    case integration
    case access
    case service
    case verification
    case configuration
  }

  public let protocolVersion: Int
  public let event: Event
  public let phase: Phase
  public let outcome: String?
  public let message: String?
  public let timeoutSeconds: Int?

  public init(
    protocolVersion: Int,
    event: Event,
    phase: Phase,
    outcome: String? = nil,
    message: String? = nil,
    timeoutSeconds: Int? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.event = event
    self.phase = phase
    self.outcome = outcome
    self.message = message
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct AgentSetupFailure: LocalizedError, Equatable, Sendable {
  public let code: String
  public let message: String
  public let hint: String?
  public let examples: [String]
  public let recoveryURL: URL
  public let status: String?
  public let failedPhase: String?
  public let timedOut: Bool
  public let completedChanges: [String]
  public let recoveryCommands: [String]
  public let diagnosticReportPath: String?
  public let retryCommand: String?

  public init(
    code: String,
    message: String,
    hint: String? = nil,
    examples: [String] = [],
    recoveryURL: URL,
    status: String? = nil,
    failedPhase: String? = nil,
    timedOut: Bool = false,
    completedChanges: [String] = [],
    recoveryCommands: [String] = [],
    diagnosticReportPath: String? = nil,
    retryCommand: String? = nil
  ) {
    self.code = code
    self.message = message
    self.hint = hint
    self.examples = examples
    self.recoveryURL = recoveryURL
    self.status = status
    self.failedPhase = failedPhase
    self.timedOut = timedOut
    self.completedChanges = completedChanges
    self.recoveryCommands = recoveryCommands
    self.diagnosticReportPath = diagnosticReportPath
    self.retryCommand = retryCommand
  }

  public var errorDescription: String? { message }

  public var recoverySuggestion: String? {
    let suggestions = [hint].compactMap { $0 }
      + recoveryCommands
      + [retryCommand, examples.first].compactMap { $0 }
    return suggestions.isEmpty ? nil : suggestions.joined(separator: "\n")
  }

  public var isPartial: Bool {
    status == "partial" || !completedChanges.isEmpty
  }

  public var supportsConfirmedReplacement: Bool {
    code == "setup_conflict" || code == "mapped_bot_missing"
  }

  public var presentation: AgentSetupFailurePresentation {
    let diagnostic = ([code, message, hint].compactMap { $0 })
      .joined(separator: "\n")
      .lowercased()

    if diagnostic.contains("openclaw"),
       diagnostic.contains("unknown command 'inspect'") {
      return AgentSetupFailurePresentation(
        title: "OpenClaw Needs an Update",
        detail: "The OpenClaw installation Inline found is too old for this setup.",
        message: "Update OpenClaw, then try setup again. If OpenClaw is installed more than once, update every copy so Inline cannot select an older one.",
        label: "What You Can Do",
        systemImage: "arrow.down.circle",
        actionLabel: "Open Update Instructions",
        actionURL: URL(string: "https://docs.openclaw.ai/install/updating")
      )
    }

    if diagnostic.contains("openclaw"),
       diagnostic.contains("cannot find module") {
      return AgentSetupFailurePresentation(
        title: "OpenClaw Plugin Couldn’t Load",
        detail: "OpenClaw found the Inline plugin but could not start it.",
        message: "Update OpenClaw and its Inline plugin, then try setup again. Your completed setup steps are still preserved.",
        label: "What You Can Do",
        systemImage: "wrench.and.screwdriver",
        actionLabel: "Open Repair Instructions",
        actionURL: URL(string: "https://inline.chat/docs/openclaw#install")
      )
    }

    if diagnostic.contains("openclaw"),
       diagnostic.contains("invalid config") {
      return AgentSetupFailurePresentation(
        title: "OpenClaw Configuration Needs Attention",
        detail: "OpenClaw rejected one or more settings in its current configuration.",
        message: "Update OpenClaw first, then try setup again. If the configuration is still rejected, open Technical Details for the exact settings OpenClaw could not read.",
        label: "What You Can Do",
        systemImage: "slider.horizontal.3",
        actionLabel: "Open Configuration Guide",
        actionURL: URL(string: "https://inline.chat/docs/openclaw#configure")
      )
    }

    if code == "amp_cli_incompatible"
      || (diagnostic.contains("amp")
        && diagnostic.contains("incompatible with the installed amp cli")) {
      return AgentSetupFailurePresentation(
        title: "Amp Needs an Update",
        detail: "The Amp installation Inline found is too old for this setup.",
        message: "Update Amp, then try setup again. If Amp is installed more than once, make sure Inline is no longer selecting an older copy.",
        label: "What You Can Do",
        systemImage: "arrow.down.circle",
        actionLabel: "Open Update Instructions",
        actionURL: URL(string: "https://ampcode.com/docs/cli#update")
      )
    }

    if code == "plugin_update_required",
       diagnostic.contains("hermes") {
      return AgentSetupFailurePresentation(
        title: "Hermes Adapter Needs an Update",
        detail: "Inline verified the existing bot, but its Hermes adapter is too old to finish setup.",
        message: "Allow Inline to update the Hermes adapter, then try setup again. The verified bot identity will be preserved.",
        label: "What You Can Do",
        systemImage: "arrow.down.circle",
        actionLabel: "Open Adapter Update Instructions",
        actionURL: URL(string: "https://inline.chat/docs/hermes#update")
      )
    }

    if code == "setup_conflict",
       diagnostic.contains("hermes") {
      return AgentSetupFailurePresentation(
        title: "Hermes Found an Existing Connection",
        detail: "Inline stopped before changing the existing Hermes credential because the older adapter could not verify which bot it belongs to.",
        message: "Recommended: update the Inline adapter first to keep the existing Hermes connection, then try setup again. If you no longer need that connection, you can replace it with the selected Inline bot.",
        label: "Choose What to Do",
        systemImage: "exclamationmark.shield",
        actionLabel: "Open Update Steps (Recommended)",
        actionURL: URL(string: "https://inline.chat/docs/hermes#update"),
        replacementActionLabel: "Replace Existing Connection…",
        replacementConfirmationTitle: "Replace Existing Hermes Connection?",
        replacementConfirmationMessage: "Hermes will use the selected Inline bot instead of its current Inline credential and bot mapping. The previous bot will not be deleted, and other agent setups will not change.",
        replacementConfirmationActionLabel: "Replace and Continue"
      )
    }

    return AgentSetupFailurePresentation(
      title: timedOut ? "Setup Timed Out" : "Setup Couldn’t Finish",
      detail: timedOut
        ? "The setup deadline was reached. Inline kept completed steps and recovery details."
        : "Inline kept completed steps and the diagnostic information needed to recover.",
      message: message,
      label: "What Happened",
      systemImage: "exclamationmark.circle",
      actionLabel: nil,
      actionURL: nil
    )
  }
}

public struct AgentSetupFailurePresentation: Equatable, Sendable {
  public let title: String
  public let detail: String
  public let message: String
  public let label: String
  public let systemImage: String
  public let actionLabel: String?
  public let actionURL: URL?
  public let replacementActionLabel: String?
  public let replacementConfirmationTitle: String?
  public let replacementConfirmationMessage: String?
  public let replacementConfirmationActionLabel: String?

  public init(
    title: String,
    detail: String,
    message: String,
    label: String,
    systemImage: String,
    actionLabel: String?,
    actionURL: URL?,
    replacementActionLabel: String? = nil,
    replacementConfirmationTitle: String? = nil,
    replacementConfirmationMessage: String? = nil,
    replacementConfirmationActionLabel: String? = nil
  ) {
    self.title = title
    self.detail = detail
    self.message = message
    self.label = label
    self.systemImage = systemImage
    self.actionLabel = actionLabel
    self.actionURL = actionURL
    self.replacementActionLabel = replacementActionLabel
    self.replacementConfirmationTitle = replacementConfirmationTitle
    self.replacementConfirmationMessage = replacementConfirmationMessage
    self.replacementConfirmationActionLabel = replacementConfirmationActionLabel
  }
}

public protocol AgentSetupCLIRunning: Sendable {
  func discover(installation: CLIInstallation) async throws -> AgentHarnessDiscovery
  func setup(
    target: AgentHarnessTarget,
    installation: CLIInstallation,
    replaceExisting: Bool,
    progress: @escaping @Sendable (AgentSetupProgressEvent) -> Void
  ) async throws -> AgentSetupResult
  func cancel()
  func cancelAndWait()
}
