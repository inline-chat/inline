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
    case .idle, .choosing, .completed, .failed:
      false
    }
  }

  var documentationURL: URL {
    discovery?.documentationURL
      ?? failure?.recoveryURL
      ?? URL(string: "https://inline.chat/docs/agents")!
  }

  func start() {
    guard !isBusy else { return }
    task?.cancel()
    task = Task { [weak self] in
      guard let self else { return }
      await prepare()
    }
  }

  func setUpSelectedTarget() {
    guard !isBusy, let target = selectedTarget, let installation else { return }
    task?.cancel()
    task = Task { [weak self] in
      guard let self else { return }
      phase = .settingUp(target.displayName)
      failure = nil
      result = nil
      do {
        let setupResult = try await runner.setup(target: target, installation: installation)
        guard !Task.isCancelled else {
          isCancelling = false
          phase = .choosing
          return
        }
        result = setupResult
        phase = .completed
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

  func cancelSetup() {
    guard case .settingUp = phase, !isCancelling else { return }
    isCancelling = true
    task?.cancel()
    runner.cancel()
  }

  func cancel() {
    task?.cancel()
    runner.cancel()
  }

  func openBot() {
    guard let botID = result?.bot.id else { return }
    MainWindowOpenCoordinator.shared.openWindow(.chat(peer: .user(id: botID)))
  }

  private func prepare() async {
    discovery = nil
    result = nil
    failure = nil
    selectedTargetID = nil

    do {
      phase = .installingCLI
      let preparedInstallation = try await prepareCLI()
      guard !Task.isCancelled else { return }
      installation = preparedInstallation

      guard CLIAuthBootstrapper.isSupportedInCurrentProcess else {
        throw AgentSetupFailure(
          code: "cli_auth_unavailable",
          message: "This build of Inline cannot sign in the CLI automatically.",
          hint: "Run `inline login`, then reopen the setup wizard.",
          recoveryURL: URL(string: "https://inline.chat/docs/agents")!
        )
      }
      guard dependencies.auth.getIsLoggedIn() else {
        throw AgentSetupFailure(
          code: "inline_not_authenticated",
          message: "Sign in to Inline for Mac before setting up an agent.",
          recoveryURL: URL(string: "https://inline.chat/docs/agents")!
        )
      }

      phase = .signingIn
      _ = try await LocalCLIAuthenticationService.authenticate(
        preparedInstallation,
        dependencies: dependencies
      )
      guard !Task.isCancelled else { return }

      phase = .discovering
      let harnesses = try await runner.discover(installation: preparedInstallation)
      guard !Task.isCancelled else { return }
      discovery = harnesses
      guard harnesses.targets.contains(where: { $0.installed }) else {
        throw AgentSetupFailure(
          code: "no_local_agents",
          message: "No supported agent harness is installed on this Mac.",
          hint: "Install Codex, Claude, OpenCode, Amp, Hermes, or OpenClaw, then try again.",
          recoveryURL: harnesses.documentationURL
        )
      }
      phase = .choosing
    } catch is CancellationError {
      phase = .idle
    } catch {
      fail(error)
    }
  }

  private func prepareCLI() async throws -> CLIInstallation {
    await dependencies.cliInstaller.refresh()
    switch dependencies.cliInstaller.phase {
    case let .ready(plan):
      switch plan.disposition {
      case .current, .packageManaged:
        guard let local = plan.localInstallation else {
          throw installerFailure(
            code: "cli_missing",
            message: "Inline CLI was detected, but its executable could not be found."
          )
        }
        return local
      case .install, .update, .conflictingInstallation:
        return try await installCLI()
      }
    case let .installed(installation):
      return installation
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
    return switch await dependencies.cliInstaller.install() {
    case let .installed(installation), let .alreadyInstalled(installation):
      installation
    case let .failed(failure):
      throw failureForInstaller(failure)
    }
  }

  private func fail(_ error: any Error) {
    if let setupFailure = error as? AgentSetupFailure {
      failure = setupFailure
    } else {
      failure = AgentSetupFailure(
        code: "agent_setup_failed",
        message: error.localizedDescription,
        recoveryURL: URL(string: "https://inline.chat/docs/agents")!
      )
    }
    phase = .failed
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
