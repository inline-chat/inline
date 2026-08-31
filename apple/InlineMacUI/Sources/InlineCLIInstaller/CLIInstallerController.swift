import Foundation
import Observation

@MainActor
@Observable
public final class CLIInstallerController {
  public private(set) var phase: CLIInstallerPhase = .idle

  @ObservationIgnored private let service: any CLIInstalling
  @ObservationIgnored private let recoveryURL: URL

  public init(configuration: CLIInstallerConfiguration = .production) {
    service = CLIInstallerService(configuration: configuration)
    recoveryURL = configuration.documentationURL
  }

  public init(
    service: any CLIInstalling,
    recoveryURL: URL = CLIInstallerConfiguration.production.documentationURL
  ) {
    self.service = service
    self.recoveryURL = recoveryURL
  }

  public func refresh() async {
    guard !phase.isBusy else { return }
    phase = .checkingLocal

    do {
      let plan = try await service.check(progress: apply)
      phase = .ready(plan)
    } catch {
      phase = .failed(failure(from: error))
    }
  }

  public func install() async -> CLIInstallResult {
    await install(forAgentSetup: false)
  }

  public func installForAgentSetup() async -> CLIInstallResult {
    await install(forAgentSetup: true)
  }

  public func compatibleLocalInstallationForAgentSetup() async -> CLIInstallation? {
    await service.compatibleLocalInstallationForAgentSetup()
  }

  private func install(forAgentSetup: Bool) async -> CLIInstallResult {
    guard !phase.isBusy else {
      return .failed(
        CLIInstallerFailure(
          kind: .operationInProgress,
          title: "Inline CLI Installation In Progress",
          message: "Wait for the current Inline CLI operation to finish, then try again.",
          recoveryURL: recoveryURL
        )
      )
    }

    phase = .checkingLocal
    do {
      let outcome: CLIServiceInstallOutcome
      if forAgentSetup {
        outcome = try await service.installForAgentSetup(progress: apply)
      } else {
        outcome = try await service.install(progress: apply)
      }
      phase = .installed(outcome.installation)
      return outcome.didInstall
        ? .installed(outcome.installation)
        : .alreadyInstalled(outcome.installation)
    } catch {
      let failure = failure(from: error)
      phase = .failed(failure)
      return .failed(failure)
    }
  }

  private func apply(_ nextPhase: CLIInstallerPhase) {
    phase = nextPhase
  }

  private func failure(from error: any Error) -> CLIInstallerFailure {
    if let failure = error as? CLIInstallerFailure {
      return failure
    }

    return CLIInstallerFailure(
      kind: .installationFailed,
      title: "Couldn’t Install Inline CLI",
      message: error.localizedDescription,
      recoveryURL: recoveryURL
    )
  }
}
