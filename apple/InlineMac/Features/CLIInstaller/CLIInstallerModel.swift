import Foundation
import InlineCLIInstaller
import Observation

@MainActor
@Observable
final class CLIInstallerModel {
  enum SignInIssue: Equatable {
    case unsupportedBuild
    case appNotSignedIn
    case differentAccount
    case authenticationFailed(String)
  }

  enum Phase: Equatable {
    case idle
    case installing
    case signingIn
    case ready(
      installation: CLIInstallation,
      authentication: CLIAuthBootstrapResult
    )
    case signInNeeded(
      installation: CLIInstallation,
      issue: SignInIssue
    )
    case failed(CLIInstallerFailure)
    case cancelled
  }

  private(set) var phase: Phase = .idle

  @ObservationIgnored private let dependencies: AppDependencies
  @ObservationIgnored private var task: Task<Void, Never>?

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
  }

  var isBusy: Bool {
    switch phase {
    case .installing, .signingIn:
      true
    case .idle, .ready, .signInNeeded, .failed, .cancelled:
      false
    }
  }

  var documentationURL: URL {
    if case let .failed(failure) = phase {
      return failure.recoveryURL
    }
    return CLIInstallerConfiguration.production.documentationURL
  }

  func start() {
    guard !isBusy else { return }
    task?.cancel()
    phase = .installing
    task = Task { [weak self] in
      guard let self else { return }
      await run()
    }
  }

  func cancelOperation() {
    guard isBusy else { return }
    task?.cancel()
  }

  func cancelForApplicationTermination() {
    task?.cancel()
  }

  private func run() async {
    defer { task = nil }

    let result = await dependencies.cliInstaller.install()
    guard !Task.isCancelled else {
      phase = .cancelled
      return
    }

    switch result {
    case let .installed(installation), let .alreadyInstalled(installation):
      await authenticate(installation)
    case let .failed(failure):
      phase = .failed(failure)
    }
  }

  private func authenticate(_ installation: CLIInstallation) async {
    guard CLIAuthBootstrapper.isSupportedInCurrentProcess else {
      phase = .signInNeeded(
        installation: installation,
        issue: .unsupportedBuild
      )
      return
    }

    guard dependencies.auth.getIsLoggedIn() else {
      phase = .signInNeeded(
        installation: installation,
        issue: .appNotSignedIn
      )
      return
    }

    phase = .signingIn

    do {
      let result = try await LocalCLIAuthenticationService.authenticate(
        installation,
        dependencies: dependencies
      )
      try Task.checkCancellation()
      phase = .ready(
        installation: installation,
        authentication: result
      )
    } catch is CancellationError {
      phase = .cancelled
    } catch {
      let issue: SignInIssue = isUnexpectedUser(error)
        ? .differentAccount
        : .authenticationFailed(error.localizedDescription)
      phase = .signInNeeded(
        installation: installation,
        issue: issue
      )
    }
  }

  private func isUnexpectedUser(_ error: any Error) -> Bool {
    guard let bootstrapError = error as? CLIAuthBootstrapError else { return false }
    return bootstrapError == .unexpectedUser
  }
}
