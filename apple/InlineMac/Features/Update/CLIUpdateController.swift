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
  var automaticUpdatesEnabled = true {
    didSet {
      guard !readingStatus, automaticUpdatesEnabled != oldValue else { return }
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
      guard !isBusy else { return }
      await installer.refresh()
      if case let .ready(plan) = installer.phase {
        updateAvailable = plan.disposition == .update
      }
      if automaticUpdatesEnabled { nextCheck = .distantPast; await refresh(automatic: true, manual: true) }
      else if updateAvailable { statusText = "Update Available" }
      else { await refresh(automatic: false) }
    }
  }

  func applyNow() { Task { await refresh(automatic: true, manual: true) } }

  func refresh(automatic: Bool, manual: Bool = false) async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    let localService = CLIInstallerService(configuration: .production(channel: channel()))
    let publicInstallation = await installer.compatibleLocalInstallationForAgentSetup()
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
      guard canManage else { return }
      let pending = UserDefaults.standard.object(forKey: Self.pendingKey) as? Bool
      let configured = try await run(.configure(enabled: pending, appChannel: channel(), register: installation.source == .inline), at: installation)
      if pending != nil { UserDefaults.standard.removeObject(forKey: Self.pendingKey) }
      show(configured)
      guard automatic, (automaticUpdatesEnabled || manual), manual || Date() >= nextCheck else { return }
      statusText = "Checking for CLI Updates"
      let updated = try await run(manual ? .apply : .background, at: installation)
      show(updated)
      nextCheck = updated.retryAt.map { Date(timeIntervalSince1970: Double($0)) } ?? Date().addingTimeInterval(6 * 60 * 60)
    } catch {
      if supportsEngine {
        statusText = "CLI Update Will Retry"
        failureText = "The working version was kept. Check the connection and retry."
        nextCheck = Date().addingTimeInterval(60 * 60)
        reportFailure(stage: "engine")
        return
      }
      guard canManage else { statusText = "Managed by Homebrew"; return }
      // Legacy CLIs cannot expose the engine. Bootstrap only from signed metadata.
      guard automatic, automaticUpdatesEnabled || manual, manual || Date() >= nextCheck else {
        statusText = "CLI Update Support Required"; return
      }
      nextCheck = Date().addingTimeInterval(60 * 60)
      do {
        let bootstrap = CLIInstallerService(configuration: .production(channel: channel()), requiresSignedManifest: true)
        let outcome = try await bootstrap.install(progress: { _ in })
        self.installation = outcome.installation
        let status = try await run(.configure(enabled: UserDefaults.standard.object(forKey: Self.pendingKey) as? Bool, appChannel: channel(), register: true), at: outcome.installation)
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        show(status)
      } catch {
        failureText = "The working CLI was kept. Retry when the CLI release is available."
        statusText = "CLI Update Deferred"
        reportFailure(stage: "bootstrap")
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
    versionText = "\(status.currentVersion) · \(status.channel.capitalized)"
    failureText = status.failure.map { _ in "The working version was kept. The update will retry automatically." }
    let phases = status.bridges?.map(\.phase) ?? []
    if phases.contains("migration_required") { statusText = "Bridge Update Ready — Restart When Agents Finish" }
    else if phases.contains("waiting_for_idle") { statusText = "Waiting for Agents to Finish" }
    else if phases.contains("trial") { statusText = "Starting Updated Bridge" }
    else if phases.contains("rolled_back") { statusText = "Previous Bridge Version Restored" }
    else if status.failure != nil { statusText = "CLI Update Will Retry" }
    else if !automaticUpdatesEnabled { statusText = "Automatic CLI Updates Off" }
    else if status.outcome == "staged" { statusText = "CLI Update Ready" }
    else { statusText = "Up to Date" }
    if !status.automaticUpdatesAvailable, automaticUpdatesEnabled { statusText = "Automatic Updates Unavailable in This Environment" }
  }

  private func reportFailure(stage: String) {
    let event = Event(level: .error)
    event.message = SentryMessage(formatted: "Inline CLI update could not complete")
    event.tags = ["surface": "cli_update", "stage": stage]
    SentrySDK.capture(event: event)
  }
}
