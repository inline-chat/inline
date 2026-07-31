@testable import InlineCLIInstaller
import Foundation
import Testing

@Suite("Inline CLI installer controller")
@MainActor
struct CLIInstallerControllerTests {
  @Test("publishes check state and a ready plan")
  func publishesCheckState() async {
    let service = MockCLIInstaller()
    let controller = CLIInstallerController(service: service)

    await controller.refresh()

    guard case let .ready(plan) = controller.phase else {
      Issue.record("Expected a ready plan")
      return
    }
    #expect(plan.release.version == "1.2.3")
    #expect(plan.disposition == .install)
    #expect(await service.observedPhases() == [.checkingLocal, .checkingRemote])
  }

  @Test("returns a typed failure")
  func returnsTypedFailure() async {
    let expected = CLIInstallerFailure(
      kind: .permissionDenied,
      title: "No Permission",
      message: "Can’t write there.",
      recoveryURL: URL(string: "https://inline.chat/docs/cli")!
    )
    let service = MockCLIInstaller(installFailure: expected)
    let controller = CLIInstallerController(service: service)

    let result = await controller.install()

    #expect(result == .failed(expected))
    #expect(controller.phase == .failed(expected))
  }
}

private actor MockCLIInstaller: CLIInstalling {
  private let installFailure: CLIInstallerFailure?
  private var phases: [CLIInstallerPhase] = []

  init(installFailure: CLIInstallerFailure? = nil) {
    self.installFailure = installFailure
  }

  func check(progress: @escaping CLIInstallerProgress) async throws -> CLIInstallPlan {
    await publish(.checkingLocal, progress: progress)
    await publish(.checkingRemote, progress: progress)
    return Self.plan
  }

  func install(progress: @escaping CLIInstallerProgress) async throws -> CLIServiceInstallOutcome {
    if let installFailure { throw installFailure }
    let plan = try await check(progress: progress)
    let installation = CLIInstallation(
      executableURL: plan.destinationURL!,
      version: plan.release.version,
      source: .inline,
      isOnPath: true
    )
    await publish(.installed(installation), progress: progress)
    return CLIServiceInstallOutcome(installation: installation, didInstall: true)
  }

  func observedPhases() -> [CLIInstallerPhase] {
    phases
  }

  private func publish(_ phase: CLIInstallerPhase, progress: CLIInstallerProgress) async {
    phases.append(phase)
    await progress(phase)
  }

  private static let plan = CLIInstallPlan(
    localInstallation: nil,
    release: CLIRelease(
      version: "1.2.3",
      archiveURL: URL(string: "https://example.com/inline.tar.gz")!,
      sha256: String(repeating: "a", count: 64),
      size: 100
    ),
    destinationURL: URL(fileURLWithPath: "/usr/local/bin/inline"),
    disposition: .install
  )
}
