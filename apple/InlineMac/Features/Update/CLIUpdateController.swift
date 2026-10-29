import Foundation
import InlineCLIInstaller
import Observation
import Sentry

@MainActor
@Observable
final class CLIUpdateController {
  private(set) var hasInstallation = false
  private(set) var canManage = false
  private(set) var isBusy = false
  private(set) var statusText = "CLI Not Installed"
  private(set) var versionText: String?
  private(set) var homebrewManaged = false
  private(set) var updateAvailable = false
  private(set) var failureText: String?
  private(set) var bridgeMigrationRequired = false
  private(set) var bridgeVersionText: String?
  private(set) var followsAppChannel = true
  @ObservationIgnored private var terminalVersion: String?
  var automaticUpdatesEnabled = true {
    didSet {
      guard !readingStatus, automaticUpdatesEnabled != oldValue else { return }
      if !automaticUpdatesEnabled && bootstrapIsAutomatic { bootstrapTask?.cancel() }
      UserDefaults.standard.set(automaticUpdatesEnabled, forKey: Self.pendingKey)
      Task { await persistPreference() }
    }
  }

  @ObservationIgnored private let installer: CLIInstallerController
  @ObservationIgnored private let channel: @MainActor @Sendable () -> CLIUpdateChannel
  @ObservationIgnored private var installation: CLIInstallation?
  @ObservationIgnored private var readingStatus = false
  @ObservationIgnored private var schedule: Task<Void, Never>?
  @ObservationIgnored private var nextCheck = Date.distantPast
  @ObservationIgnored private var bootstrapTask: Task<CLIServiceInstallOutcome, Error>?
  @ObservationIgnored private var bootstrapIsAutomatic = false
  private static let pendingKey = "cliAutomaticUpdatesPending"

  init(installer: CLIInstallerController, channel: @escaping @MainActor @Sendable () -> CLIUpdateChannel) {
    self.installer = installer
    self.channel = channel
    if let pending = UserDefaults.standard.object(forKey: Self.pendingKey) as? Bool {
      automaticUpdatesEnabled = pending
    }
    installer.onInstallationChanged = { [weak self] installation in
      guard let self else { return }
      self.installation = installation
      self.nextCheck = .distantPast
      Task { await self.refresh(automatic: true) }
    }
  }

  func start() {
    guard schedule == nil else { return }
    schedule = Task { [weak self] in
      try? await Task.sleep(for: .seconds(120))
      while !Task.isCancelled {
        guard self != nil else { return }
        await self?.refresh(automatic: true)
        try? await Task.sleep(for: .seconds(300))
      }
    }
    Task { await refresh(automatic: false) }
  }

  func channelChanged() {
    nextCheck = .distantPast
    Task { await refresh(automatic: true) }
  }

  func checkNow() {
    Task {
      guard !isBusy, let installation else { return }
      isBusy = true
      do {
        let check = try await CLIAgentSetupRunner(configuration: .production(channel: channel())).checkUpdate(installation: installation)
        updateAvailable = check.updateAvailable
        statusText = check.updateAvailable ? "Update Available" : "Up to Date"
        isBusy = false
        if automaticUpdatesEnabled { nextCheck = .distantPast; await refresh(automatic: true, manual: true) }
      } catch {
        isBusy = false
        failureText = "The CLI couldn’t check for updates. The working version was kept; retry later."
      }
    }
  }

  func useAppChannel() {
    Task {
      guard !isBusy, let installation else { return }
      isBusy = true
      do {
        show(try await run(.followApp(channel()), at: installation))
        nextCheck = .distantPast
        isBusy = false
        await refresh(automatic: true)
      } catch { isBusy = false; failureText = "The channel change will need a retry." }
    }
  }

  func applyNow() { Task { await refresh(automatic: true, manual: true) } }

  func refresh(automatic: Bool, manual: Bool = false) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    let localService = CLIInstallerService(configuration: .production(channel: channel()))
    let publicInstallation = await installer.compatibleLocalInstallationForAgentSetup()
    terminalVersion = publicInstallation?.version
    installation = await localService.managedUpdateInstallation() ?? publicInstallation
    guard let installation else {
      hasInstallation = false; canManage = false; statusText = "CLI Not Installed"; return
    }
    hasInstallation = true
    homebrewManaged = publicInstallation?.source == .homebrew
    canManage = installation.source == .inline
    var supportsEngine = false
    do {
      let status = try await run(.status, at: installation)
      supportsEngine = true
      show(status)
      guard installation.source == .inline else { statusText = "Managed by Homebrew"; return }
      let pending = UserDefaults.standard.object(forKey: Self.pendingKey) as? Bool
      let configured = try await run(.configure(enabled: pending, appChannel: channel(), register: installation.source == .inline), at: installation)
      if pending != nil { UserDefaults.standard.removeObject(forKey: Self.pendingKey) }
      show(configured)
      canManage = configured.installationMethod == "managed"
        || (configured.bridges?.contains { $0.phase != "migration_required" } ?? false)
      guard canManage else { statusText = "CLI Managed Externally"; return }
      guard automatic, (automaticUpdatesEnabled || manual), manual || Date() >= nextCheck else { return }
      statusText = "Checking for CLI Updates"
      let updated = try await run(manual ? .apply : .background, at: installation)
      show(updated)
      nextCheck = updated.retryAt.map { Date(timeIntervalSince1970: Double($0)) } ?? Date().addingTimeInterval(6 * 60 * 60)
    } catch {
      if supportsEngine || (error as? CLIUpdateFailure) != .unsupportedEngine {
        statusText = "CLI Update Will Retry"
        failureText = "The working version was kept. Check the connection and retry."
        if let status = try? await run(.status, at: installation) {
          show(status)
          nextCheck = status.retryAt.map { Date(timeIntervalSince1970: Double($0)) } ?? Date().addingTimeInterval(60 * 60)
        } else { nextCheck = Date().addingTimeInterval(60 * 60) }
        reportFailure(stage: "engine")
        return
      }
      guard canManage else { statusText = "Managed by Homebrew"; return }
      // Legacy CLIs cannot expose the engine. Bootstrap only from signed metadata.
      let disabled = ProcessInfo.processInfo.environment["INLINE_DISABLE_AUTOUPDATE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if automatic && !manual && ["1", "true", "on"].contains(disabled ?? "") {
        statusText = "Automatic Updates Unavailable in This Environment"; return
      }
      guard automatic, automaticUpdatesEnabled || manual, manual || Date() >= nextCheck else {
        statusText = "CLI Update Support Required"; return
      }
      nextCheck = Date().addingTimeInterval(60 * 60)
      do {
        let bootstrap = CLIInstallerService(configuration: .production(channel: channel()), requiresSignedManifest: true)
        bootstrapIsAutomatic = !manual
        let task = Task { try await bootstrap.install(progress: { _ in }) }
        bootstrapTask = task
        defer { bootstrapTask = nil; bootstrapIsAutomatic = false }
        let outcome = try await withTaskCancellationHandler {
          try await task.value
        } onCancel: { task.cancel() }
        self.installation = outcome.installation
        let status = try await run(.configure(enabled: UserDefaults.standard.object(forKey: Self.pendingKey) as? Bool, appChannel: channel(), register: true), at: outcome.installation)
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        show(status)
        report(outcome: "bootstrapped", stage: "bootstrap", version: status.currentVersion)
      } catch {
        if error is CancellationError {
          statusText = "Automatic CLI Updates Off"
          failureText = nil
          return
        }
        failureText = (error as? CLIInstallerFailure)?.message
          ?? "The working CLI was kept. Retry when the CLI release is available."
        statusText = "CLI Update Deferred"
        let stage: String
        switch (error as? CLIInstallerFailure)?.kind {
        case .network: stage = "bootstrap_network"
        case .invalidSignature, .checksumMismatch, .invalidManifest, .invalidArchive: stage = "bootstrap_verification"
        default: stage = "bootstrap_installation"
        }
        reportFailure(stage: stage)
      }
    }
  }

  private func persistPreference() async {
    guard let installation else { return }
    do {
      let status = try await run(.configure(enabled: automaticUpdatesEnabled, appChannel: channel(), register: false), at: installation)
      UserDefaults.standard.removeObject(forKey: Self.pendingKey)
      show(status)
    } catch {
      // Retain intent for the first successful legacy bootstrap or subsequent retry.
      failureText = "This setting will apply when the CLI update service is available."
    }
  }

  private func run(_ operation: CLIUpdateOperation, at installation: CLIInstallation) async throws -> CLIUpdateStatus {
    try await CLIAgentSetupRunner(configuration: .production(channel: channel())).update(installation: installation, operation: operation)
  }

  private func show(_ status: CLIUpdateStatus) {
    readingStatus = true
    automaticUpdatesEnabled = (UserDefaults.standard.object(forKey: Self.pendingKey) as? Bool) ?? status.autoUpdate
    readingStatus = false
    versionText = "CLI \(terminalVersion ?? status.currentVersion) · \(status.channel.capitalized)"
    followsAppChannel = status.followsApp
    let bridgeVersions = Set(status.bridges?.compactMap(\.version) ?? []).sorted()
    bridgeVersionText = bridgeVersions.isEmpty ? nil : "Bridge versions: \(bridgeVersions.joined(separator: ", "))"
    failureText = status.failure.map { stage in
      switch stage {
      case "signature", "checksum", "codesign", "manifest_identity", "manifest_replay", "release_rollback":
        "The release couldn’t be verified. The working version was kept; retry later."
      case "installation":
        "The working version was kept. Check free space and installation permissions, then retry."
      default:
        "The working version was kept. The update will retry automatically."
      }
    }
    let phases = status.bridges?.map(\.phase) ?? []
    bridgeMigrationRequired = phases.contains("migration_required")
    if bridgeMigrationRequired { statusText = "Bridge Update Ready — Restart When Agents Finish" }
    else if phases.contains("waiting_for_idle") { statusText = "Waiting for Agents to Finish" }
    else if phases.contains("maintenance_required") { statusText = "Bridge Update Needs Maintenance" }
    else if phases.contains("trial") { statusText = "Starting Updated Bridge" }
    else if phases.contains("rolled_back") { statusText = "Previous Bridge Version Restored" }
    else if status.failure != nil { statusText = "CLI Update Will Retry" }
    else if !automaticUpdatesEnabled { statusText = "Automatic CLI Updates Off" }
    else if status.outcome == "staged" { statusText = "CLI Update Ready" }
    else { statusText = "Up to Date" }
    if !status.automaticUpdatesAvailable, automaticUpdatesEnabled { statusText = "Automatic Updates Unavailable in This Environment" }
  }

  private func reportFailure(stage: String) { report(outcome: "failed", stage: stage) }

  private func report(outcome: String, stage: String, version: String? = nil) {
    let privacy = ProcessInfo.processInfo.environment["INLINE_CLI_TELEMETRY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !["off", "0", "false"].contains(privacy ?? "") else { return }
    let key = "cliUpdateReport.\(outcome).\(stage)"
    let now = Date()
    if let last = UserDefaults.standard.object(forKey: key) as? Date,
       last <= now, now.timeIntervalSince(last) < 24 * 60 * 60 { return }
    UserDefaults.standard.set(now, forKey: key)
    let event = Event(level: outcome == "failed" ? .error : .info)
    event.message = SentryMessage(formatted: "Inline CLI update")
    var tags = ["surface": "cli_update", "outcome": outcome, "stage": stage]
    if let version, version.utf8.count <= 64,
       version.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || [43, 45, 46].contains($0) }) {
      tags["cli_version"] = version
    }
    event.tags = tags
    SentrySDK.capture(event: event)
  }
}
