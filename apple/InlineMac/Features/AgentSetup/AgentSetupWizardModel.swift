import Foundation
import InlineCLIInstaller
import Logger
import Observation

struct AgentSetupProgressItem: Equatable, Identifiable {
  enum ID: String, Equatable, Identifiable {
    case cli
    case authentication
    case discovery
    case preflight
    case bot
    case integration
    case access
    case service
    case verification
    case configuration

    var id: String { rawValue }
  }

  enum Outcome: Equatable {
    case ready
    case authenticated
    case found(Int)
    case cli(String)
  }

  enum State: Equatable {
    case pending
    case active(startedAt: Date)
    case completed(Outcome?)
    case failed
  }

  let id: ID
  var state: State = .pending
  var detail: String?
}

private struct AgentSetupTelemetryFailure: PrivacySafeErrorCategoryProviding {
  let code: String
  let phase: String
  let target: String

  var privacySafeErrorCategory: String {
    let safeCode = Self.allowlistedCodes.contains(code) ? code : "other"
    let safePhase = Self.allowlistedPhases.contains(phase) ? phase : "unknown"
    let safeTarget = Self.allowlistedTargets.contains(target) ? target : "unknown"
    return "agent_setup:\(safeTarget):\(safePhase):\(safeCode)"
  }

  private static let allowlistedCodes: Set<String> = [
    "agent_setup_failed",
    "agent_setup_requires_direct_app",
    "cli_auth_failed",
    "cli_auth_handoff_failed",
    "cli_auth_launch_failed",
    "cli_auth_protocol_mismatch",
    "cli_auth_timed_out",
    "cli_auth_unavailable",
    "cli_checksumMismatch",
    "cli_conflictingInstallation",
    "cli_install_incomplete",
    "cli_installationFailed",
    "cli_invalidArchive",
    "cli_invalidManifest",
    "cli_invalidSignature",
    "cli_launch_failed",
    "cli_missing",
    "cli_network",
    "cli_operationInProgress",
    "cli_output_drain_timed_out",
    "cli_output_too_large",
    "cli_packageManaged",
    "cli_permissionDenied",
    "cli_unavailable",
    "cli_unsupportedArchitecture",
    "inline_not_authenticated",
    "invalid_cli_response",
    "invalid_target",
    "io_error",
    "mapped_bot_missing",
    "not_authenticated",
    "operation_in_progress",
    "provider_integration_failed",
    "realtime_connection_error",
    "realtime_timeout",
    "setup_conflict",
    "setup_timed_out",
    "timeout",
    "unexpected_target",
    "websocket_error",
  ]

  private static let allowlistedPhases: Set<String> = [
    "access",
    "authentication",
    "bot",
    "cli",
    "configuration",
    "discovery",
    "integration",
    "preflight",
    "service",
    "unknown",
    "verification",
  ]

  private static let allowlistedTargets: Set<String> = [
    "amp",
    "claude",
    "codex",
    "hermes",
    "openclaw",
    "opencode",
    "unknown",
  ]
}

@MainActor
@Observable
final class AgentSetupWizardModel {
  enum Phase: Equatable {
    case idle
    case choosingLocation
    case remoteSetup
    case installingCLI
    case signingIn
    case discovering
    case choosing
    case noHarnesses
    case settingUp(String)
    case completed
    case failed
  }

  enum FailureOperation: Equatable {
    case preparation
    case targetSetup
  }

  private(set) var phase: Phase = .choosingLocation
  private(set) var discovery: AgentHarnessDiscovery?
  private(set) var result: AgentSetupResult?
  private(set) var failure: AgentSetupFailure?
  private(set) var failureOperation: FailureOperation?
  private(set) var progressItems: [AgentSetupProgressItem] = []
  private(set) var isCancelling = false
  var selectedTargetID: String?

  @ObservationIgnored private let dependencies: AppDependencies
  @ObservationIgnored private let runner: any AgentSetupCLIRunning
  @ObservationIgnored private let log = Log.scoped("AgentSetup")
  @ObservationIgnored private var installation: CLIInstallation?
  @ObservationIgnored private var task: Task<Void, Never>?

  init(
    dependencies: AppDependencies,
    runner: any AgentSetupCLIRunning = CLIAgentSetupRunner()
  ) {
    self.dependencies = dependencies
    self.runner = runner
  }

  var installedTargets: [AgentHarnessTarget] {
    discovery?.targets.filter(\.installed) ?? []
  }

  var missingTargets: [AgentHarnessTarget] {
    discovery?.targets.filter { !$0.installed } ?? []
  }

  var selectedTarget: AgentHarnessTarget? {
    guard let selectedTargetID else { return nil }
    return installedTargets.first { $0.id == selectedTargetID }
  }

  var isBusy: Bool {
    switch phase {
    case .installingCLI, .signingIn, .discovering, .settingUp:
      true
    case .idle, .choosingLocation, .remoteSetup, .choosing, .noHarnesses, .completed, .failed:
      false
    }
  }

  var isReady: Bool {
    guard result?.status == "ready", result?.service.ready == true else { return false }
    return result?.readiness?.ready ?? true
  }

  var canRepairSelectedSetup: Bool {
    failure?.supportsConfirmedReplacement == true && selectedTarget?.family == .gateway
  }

  var canGoBack: Bool {
    switch phase {
    case .remoteSetup, .choosing, .noHarnesses, .failed:
      true
    case .idle, .choosingLocation, .installingCLI, .signingIn, .discovering, .settingUp,
         .completed:
      false
    }
  }

  var canRetryFailure: Bool {
    guard let code = failure?.code else { return false }
    return ![
      "agent_setup_requires_direct_app",
      "cli_auth_unavailable",
      "cli_invalidmanifest",
    ].contains(code.lowercased())
  }

  var showsActionFooter: Bool {
    switch phase {
    case .idle, .choosingLocation, .remoteSetup:
      false
    case .failed:
      canRepairSelectedSetup || canRetryFailure
    case .installingCLI, .signingIn, .discovering, .choosing, .noHarnesses, .settingUp,
         .completed:
      true
    }
  }

  var documentationURL: URL {
    discovery?.documentationURL
      ?? failure?.recoveryURL
      ?? URL(string: "https://inline.chat/docs/agents")!
  }

  var agentInstructionsURL: URL {
    URL(string: "https://inline.chat/docs/agents.md")!
  }

  var remoteSetupPrompt: String {
    "Set up this agent as a bot in Inline by following \(agentInstructionsURL.absoluteString)"
  }

  func chooseLocalSetup() {
    start()
  }

  func chooseRemoteSetup() {
    guard !isBusy else { return }
    phase = .remoteSetup
  }

  func returnToLocationChoice() {
    guard !isBusy else { return }
    discovery = nil
    result = nil
    failure = nil
    failureOperation = nil
    progressItems = []
    selectedTargetID = nil
    phase = .choosingLocation
  }

  func goBack() {
    guard canGoBack, !isBusy else { return }
    switch phase {
    case .remoteSetup, .noHarnesses:
      returnToLocationChoice()
    case .choosing:
      returnToLocationChoice()
    case .failed where failureOperation == .targetSetup:
      failure = nil
      failureOperation = nil
      result = nil
      progressItems = []
      phase = .choosing
    case .failed:
      returnToLocationChoice()
    case .idle, .choosingLocation, .installingCLI, .signingIn, .discovering, .settingUp,
         .completed:
      break
    }
  }

  func start() {
    guard !isBusy else { return }
    task?.cancel()
    isCancelling = false
    task = Task { [weak self] in
      guard let self else { return }
      defer { task = nil }
      await prepare()
    }
  }

  func setUpSelectedTarget() {
    setUpSelectedTarget(replaceExisting: false)
  }

  func retryWithReplacement() {
    guard canRepairSelectedSetup else { return }
    setUpSelectedTarget(replaceExisting: true)
  }

  private func setUpSelectedTarget(replaceExisting: Bool) {
    guard !isBusy, let target = selectedTarget, let installation else { return }
    task?.cancel()
    isCancelling = false
    task = Task { [weak self] in
      guard let self else { return }
      defer { task = nil }
      phase = .settingUp(target.displayName)
      failure = nil
      failureOperation = nil
      result = nil
      progressItems = Self.targetSetupProgress
      beginProgress(.preflight)
      log.info(
        "AGENT_SETUP phase=setup_start target=\(target.id) replaceExisting=\(replaceExisting)"
      )
      do {
        let progressChannel = AsyncStream.makeStream(of: AgentSetupProgressEvent.self)
        let progressTask = Task { @MainActor [weak self] in
          for await event in progressChannel.stream {
            guard let self else { return }
            self.receiveCLIProgress(event)
          }
        }
        let setupResult: AgentSetupResult
        do {
          setupResult = try await runner.setup(
            target: target,
            installation: installation,
            replaceExisting: replaceExisting,
            progress: { event in
              progressChannel.continuation.yield(event)
            }
          )
        } catch {
          progressChannel.continuation.finish()
          await progressTask.value
          throw error
        }
        progressChannel.continuation.finish()
        await progressTask.value
        try Task.checkCancellation()
        completeRemainingSetupProgress(with: setupResult)
        result = setupResult
        phase = .completed
        let readinessCode = setupResult.readiness?.code ?? "none"
        log.info(
          "AGENT_SETUP phase=setup_complete target=\(target.id) status=\(setupResult.status) serviceReady=\(setupResult.service.ready) readinessCode=\(readinessCode)"
        )
      } catch is CancellationError {
        isCancelling = false
        progressItems = []
        phase = .choosing
      } catch {
        failureOperation = .targetSetup
        fail(error)
      }
    }
  }

  func chooseAnotherHarness() {
    guard !isBusy else { return }
    result = nil
    failure = nil
    failureOperation = nil
    progressItems = []
    selectedTargetID = nil
    phase = .choosing
  }

  func retryFailure() {
    guard phase == .failed, canRetryFailure else { return }
    if failureOperation == .targetSetup, selectedTarget != nil, installation != nil {
      setUpSelectedTarget()
    } else {
      start()
    }
  }

  func cancelOperation() {
    guard isBusy, !isCancelling else { return }
    isCancelling = true
    task?.cancel()
    runner.cancel()
  }

  func cancel() {
    task?.cancel()
    runner.cancel()
  }

  func cancelForApplicationTermination() {
    task?.cancel()
    runner.cancelAndWait()
  }

  func openBot() {
    guard isReady, let botID = result?.bot.id else { return }
    MainWindowOpenCoordinator.shared.openWindow(.chat(peer: .user(id: botID)))
  }

  private func prepare() async {
    discovery = nil
    result = nil
    failure = nil
    failureOperation = nil
    progressItems = Self.preparationProgress
    selectedTargetID = nil
    isCancelling = false
    log.info("AGENT_SETUP phase=prepare_start")

    do {
      guard dependencies.auth.getIsLoggedIn() else {
        throw AgentSetupFailure(
          code: "inline_not_authenticated",
          message: "Sign in to Inline for Mac before setting up an agent.",
          recoveryURL: URL(string: "https://inline.chat/docs/agents")!
        )
      }

      guard CLIAuthBootstrapper.isSupportedInCurrentProcess else {
        throw AgentSetupFailure(
          code: "agent_setup_requires_direct_app",
          message: "This sandboxed Inline build cannot configure local agent harnesses.",
          hint: "Use Inline’s direct macOS beta, or run `inline agents setup` in Terminal.",
          recoveryURL: URL(string: "https://inline.chat/docs/agents")!
        )
      }

      phase = .installingCLI
      beginProgress(.cli)
      let preparedInstallation = try await prepareCLI()
      try Task.checkCancellation()
      installation = preparedInstallation
      completeProgress(.cli, outcome: .ready)

      phase = .signingIn
      beginProgress(.authentication)
      _ = try await LocalCLIAuthenticationService.authenticate(
        preparedInstallation,
        dependencies: dependencies
      )
      try Task.checkCancellation()
      completeProgress(.authentication, outcome: .authenticated)

      phase = .discovering
      beginProgress(.discovery)
      let harnesses = try await runner.discover(installation: preparedInstallation)
      try Task.checkCancellation()
      discovery = harnesses
      let installedTargets = harnesses.targets.filter(\.installed)
      completeProgress(.discovery, outcome: .found(installedTargets.count))
      guard !installedTargets.isEmpty else {
        log.info("AGENT_SETUP phase=discovery_complete installedTargets=0")
        phase = .noHarnesses
        return
      }
      log.info(
        "AGENT_SETUP phase=discovery_complete installedTargets=\(installedTargets.count)"
      )
      selectedTargetID = installedTargets.count == 1 ? installedTargets[0].id : nil
      phase = .choosing
    } catch is CancellationError {
      isCancelling = false
      progressItems = []
      phase = .choosingLocation
    } catch {
      failureOperation = .preparation
      fail(error)
    }
  }

  private func prepareCLI() async throws -> CLIInstallation {
    await dependencies.cliInstaller.refresh()
    try Task.checkCancellation()
    switch dependencies.cliInstaller.phase {
    case let .ready(plan):
      switch plan.disposition {
      case .current:
        guard plan.localInstallation != nil else {
          throw installerFailure(
            code: "cli_missing",
            message: "Inline CLI was detected, but its executable could not be found."
          )
        }
        if let compatible = await dependencies.cliInstaller.compatibleLocalInstallationForAgentSetup(),
           compatible.version == plan.release.version {
          return compatible
        }
        return try await installCLI()
      case .install, .update, .packageManaged, .conflictingInstallation:
        return try await installCLI()
      }
    case .installed:
      if let compatible = await dependencies.cliInstaller.compatibleLocalInstallationForAgentSetup() {
        return compatible
      }
      return try await installCLI()
    case let .failed(failure) where failure.kind == .network:
      if let local = await dependencies.cliInstaller.compatibleLocalInstallationForAgentSetup() {
        return local
      }
      throw failureForInstaller(failure)
    case let .failed(failure):
      throw failureForInstaller(failure)
    case .checkingLocal, .checkingRemote, .downloading, .verifying, .installing:
      throw installerFailure(
        code: "cli_install_in_progress",
        message: "Another Inline CLI installation or update is still running. Wait for it to finish, then retry setup."
      )
    case .idle:
      throw installerFailure(
        code: "cli_install_incomplete",
        message: "Inline CLI installation did not finish."
      )
    }
  }

  private func installCLI() async throws -> CLIInstallation {
    let result = await dependencies.cliInstaller.installForAgentSetup()
    try Task.checkCancellation()
    return switch result {
    case let .installed(installation), let .alreadyInstalled(installation):
      installation
    case let .failed(failure):
      throw failureForInstaller(failure)
    }
  }

  private func fail(_ error: any Error) {
    isCancelling = false
    failActiveProgress()
    if let setupFailure = error as? AgentSetupFailure {
      failure = setupFailure
    } else if let authFailure = error as? CLIAuthBootstrapError {
      failure = failureForAuthentication(authFailure)
    } else if let installerFailure = error as? CLIInstallerFailure {
      failure = failureForInstaller(installerFailure)
    } else if let brokerFailure = error as? LocalCLIAuthBroker.Error {
      failure = AgentSetupFailure(
        code: "cli_auth_handoff_failed",
        message: CLIAgentSetupRunner.safeStructuredText(brokerFailure.localizedDescription, maximumScalars: 1_000),
        hint: "Retry sign-in from Inline, or run `inline login` in Terminal.",
        recoveryURL: URL(string: "https://inline.chat/docs/agents")!
      )
    } else {
      failure = AgentSetupFailure(
        code: "agent_setup_failed",
        message: "Inline could not finish agent setup.",
        hint: "Try again, or continue with the setup guide and CLI diagnostics.",
        recoveryURL: URL(string: "https://inline.chat/docs/agents")!
      )
    }
    let failureCode = failure?.code ?? "unknown"
    let failedPhase = failure?.failedPhase ?? "unknown"
    let failedTarget = selectedTargetID ?? "unknown"
    log.error(
      "AGENT_SETUP phase=failed code=\(failureCode) failedPhase=\(failedPhase)",
      error: AgentSetupTelemetryFailure(
        code: failureCode,
        phase: failedPhase,
        target: failedTarget
      )
    )
    phase = .failed
  }

  private func receiveCLIProgress(_ event: AgentSetupProgressEvent) {
    guard case .settingUp = phase else { return }
    if event.phase == .configuration,
       !progressItems.contains(where: { $0.id == .configuration }) {
      // Legacy CLIs cannot report individual setup phases. Keep completed
      // evidence, but replace speculative pending/active rows with one step.
      progressItems = progressItems.filter {
        if case .completed = $0.state { return true }
        return false
      }
      progressItems.append(AgentSetupProgressItem(id: .configuration))
    }
    guard let id = Self.progressID(for: event.phase) else { return }
    switch event.event {
    case .phaseStarted:
      beginProgress(id, detail: event.message ?? event.timeoutSeconds.map {
        "This step can take up to \($0) seconds."
      })
    case .phaseCompleted:
      completeProgress(
        id,
        outcome: event.outcome.map(AgentSetupProgressItem.Outcome.cli),
        detail: event.message
      )
    }
  }

  private func beginProgress(_ id: AgentSetupProgressItem.ID, detail: String? = nil) {
    guard let index = progressItems.firstIndex(where: { $0.id == id }) else { return }
    if case .completed = progressItems[index].state { return }
    progressItems[index].state = .active(startedAt: Date())
    progressItems[index].detail = detail
  }

  private func completeProgress(
    _ id: AgentSetupProgressItem.ID,
    outcome: AgentSetupProgressItem.Outcome? = nil,
    detail: String? = nil
  ) {
    guard let index = progressItems.firstIndex(where: { $0.id == id }) else { return }
    progressItems[index].state = .completed(outcome)
    progressItems[index].detail = detail
  }

  private func failActiveProgress() {
    if let index = progressItems.lastIndex(where: {
      if case .active = $0.state { return true }
      return false
    }) {
      progressItems[index].state = .failed
    } else if let index = progressItems.firstIndex(where: {
      if case .pending = $0.state { return true }
      return false
    }) {
      progressItems[index].state = .failed
    }
  }

  private func completeRemainingSetupProgress(with result: AgentSetupResult) {
    for index in progressItems.indices {
      if case .completed = progressItems[index].state { continue }
      let outcome: AgentSetupProgressItem.Outcome? = switch progressItems[index].id {
      case .service:
        .cli(result.service.action)
      case .verification:
        .cli(Self.isReadyResult(result) ? "ready" : "action_required")
      case .cli, .authentication, .discovery, .preflight, .bot, .integration, .access,
           .configuration:
        nil
      }
      progressItems[index].state = .completed(outcome)
    }
  }

  private static func isReadyResult(_ result: AgentSetupResult) -> Bool {
    guard result.status == "ready", result.service.ready else { return false }
    return result.readiness?.ready ?? true
  }

  private static func progressID(
    for phase: AgentSetupProgressEvent.Phase
  ) -> AgentSetupProgressItem.ID? {
    switch phase {
    case .preflight: .preflight
    case .bot: .bot
    case .integration: .integration
    case .access: .access
    case .service: .service
    case .verification: .verification
    case .configuration: .configuration
    }
  }

  private static let preparationProgress: [AgentSetupProgressItem] = [
    AgentSetupProgressItem(id: .cli),
    AgentSetupProgressItem(id: .authentication),
    AgentSetupProgressItem(id: .discovery),
  ]

  private static let targetSetupProgress: [AgentSetupProgressItem] = [
    AgentSetupProgressItem(id: .preflight),
    AgentSetupProgressItem(id: .bot),
    AgentSetupProgressItem(id: .integration),
    AgentSetupProgressItem(id: .access),
    AgentSetupProgressItem(id: .service),
    AgentSetupProgressItem(id: .verification),
  ]

  private func failureForAuthentication(_ error: CLIAuthBootstrapError) -> AgentSetupFailure {
    let code: String
    let hint: String
    switch error {
    case .unexpectedUser:
      code = "cli_different_account"
      hint = "Run `inline logout`, then try again so the CLI can sign in to this Inline account."
    case .invalidHandshake:
      code = "cli_auth_protocol_mismatch"
      hint = "Update the Inline CLI, then try again."
    case .timedOut:
      code = "cli_auth_timed_out"
      hint = "Try again, or run `inline login` in Terminal."
    case .couldNotLaunch:
      code = "cli_auth_launch_failed"
      hint = "Reinstall the Inline CLI, then try again."
    case .unavailableInSandbox:
      code = "cli_auth_unavailable"
      hint = "Use Inline’s direct macOS beta, or run `inline agents setup` in Terminal."
    case .commandFailed:
      code = "cli_auth_failed"
      hint = "Run `inline login` in Terminal, then try again."
    }
    return AgentSetupFailure(
      code: code,
      message: error.localizedDescription,
      hint: hint,
      recoveryURL: URL(string: "https://inline.chat/docs/agents")!
    )
  }

  private func failureForInstaller(_ failure: CLIInstallerFailure) -> AgentSetupFailure {
    AgentSetupFailure(
      code: "cli_\(failure.kind.rawValue)",
      message: CLIAgentSetupRunner.safeStructuredText(failure.message, maximumScalars: 1_000),
      hint: "Use the manual CLI installation guide if automatic installation keeps failing.",
      recoveryURL: failure.recoveryURL
    )
  }

  private func installerFailure(code: String, message: String) -> AgentSetupFailure {
    AgentSetupFailure(
      code: code,
      message: message,
      recoveryURL: CLIInstallerConfiguration.production.documentationURL
    )
  }
}
