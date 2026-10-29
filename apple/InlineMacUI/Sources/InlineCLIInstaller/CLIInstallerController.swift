import Foundation
import Observation

@MainActor
@Observable
public final class CLIInstallerController {
  public var onInstallationChanged: (@MainActor (CLIInstallation) -> Void)?
  public private(set) var phase: CLIInstallerPhase = .idle

  @ObservationIgnored private let service: any CLIInstalling
  @ObservationIgnored private var configurationProvider: (@MainActor @Sendable () -> CLIInstallerConfiguration)?
  @ObservationIgnored private let recoveryURL: URL

  public init(configuration: CLIInstallerConfiguration = .production) {
    service = CLIInstallerService(configuration: configuration)
    recoveryURL = configuration.documentationURL
  }

  public convenience init(configurationProvider: @escaping @MainActor @Sendable () -> CLIInstallerConfiguration) {
    self.init(configuration: configurationProvider())
    self.configurationProvider = configurationProvider
  }

  private func refreshConfiguration() async {
    if let configurationProvider, let concrete = service as? CLIInstallerService {
      await concrete.updateConfiguration(configurationProvider())
    }
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
      await refreshConfiguration()
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
    await refreshConfiguration()
    return await service.compatibleLocalInstallationForAgentSetup()
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
      await refreshConfiguration()
      let outcome: CLIServiceInstallOutcome
      if forAgentSetup {
        outcome = try await service.installForAgentSetup(progress: apply)
      } else {
        outcome = try await service.install(progress: apply)
      }
      phase = .installed(outcome.installation)
      onInstallationChanged?(outcome.installation)
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
