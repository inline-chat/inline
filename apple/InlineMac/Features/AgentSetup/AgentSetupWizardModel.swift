import Foundation
import InlineCLIInstaller
import Observation

@MainActor
@Observable
final class AgentSetupWizardModel {
  enum Phase: Equatable {
    case idle
    case installingCLI
    case signingIn
    case discovering
    case choosing
    case noHarnesses
    case settingUp(String)
    case completed
    case failed
  }

  private(set) var phase: Phase = .idle
  private(set) var discovery: AgentHarnessDiscovery?
  private(set) var result: AgentSetupResult?
  private(set) var failure: AgentSetupFailure?
  private(set) var isCancelling = false
  var selectedTargetID: String?

  @ObservationIgnored private let dependencies: AppDependencies
  @ObservationIgnored private let runner: any AgentSetupCLIRunning
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
    case .idle, .choosing, .noHarnesses, .completed, .failed:
      false
    }
  }

  var isReady: Bool {
    result?.status == "ready" && result?.service.ready == true
  }

  var canRepairSelectedSetup: Bool {
    failure?.supportsConfirmedReplacement == true && selectedTarget?.family == .gateway
  }

  var documentationURL: URL {
    discovery?.documentationURL
      ?? failure?.recoveryURL
      ?? URL(string: "https://inline.chat/docs/agents")!
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
      result = nil
      do {
        let setupResult = try await runner.setup(
          target: target,
          installation: installation,
          replaceExisting: replaceExisting
        )
        try Task.checkCancellation()
        result = setupResult
        phase = .completed
        if isReady {
          openBot()
        }
      } catch is CancellationError {
        isCancelling = false
        phase = .choosing
      } catch {
        fail(error)
      }
    }
  }

  func chooseAnotherHarness() {
    guard !isBusy else { return }
    result = nil
    failure = nil
    selectedTargetID = nil
    phase = .choosing
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
    selectedTargetID = nil
    isCancelling = false

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
      let preparedInstallation = try await prepareCLI()
      try Task.checkCancellation()
      installation = preparedInstallation

      phase = .signingIn
      _ = try await LocalCLIAuthenticationService.authenticate(
        preparedInstallation,
        dependencies: dependencies
      )
      try Task.checkCancellation()

      phase = .discovering
      let harnesses = try await runner.discover(installation: preparedInstallation)
      try Task.checkCancellation()
      discovery = harnesses
      guard harnesses.targets.contains(where: { $0.installed }) else {
        phase = .noHarnesses
        return
      }
      phase = .choosing
    } catch is CancellationError {
      isCancelling = false
      phase = .idle
    } catch {
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
    case .idle, .checkingLocal, .checkingRemote, .downloading, .verifying, .installing:
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
    if let setupFailure = error as? AgentSetupFailure {
      failure = setupFailure
    } else if let authFailure = error as? CLIAuthBootstrapError {
      failure = failureForAuthentication(authFailure)
    } else {
      failure = AgentSetupFailure(
        code: "agent_setup_failed",
        message: "Inline could not finish agent setup.",
        hint: "Try again, or continue with the setup guide and CLI diagnostics.",
        recoveryURL: URL(string: "https://inline.chat/docs/agents")!
      )
    }
    phase = .failed
  }

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
      message: failure.message,
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
