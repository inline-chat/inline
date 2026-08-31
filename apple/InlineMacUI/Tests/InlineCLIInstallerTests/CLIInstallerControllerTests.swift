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

  @Test("uses the side-by-side installation policy for agent setup")
  func usesAgentSetupInstallationPolicy() async {
    let service = MockCLIInstaller()
    let controller = CLIInstallerController(service: service)

    _ = await controller.installForAgentSetup()

    #expect(await service.agentSetupInstallCalls() == 1)
  }

  @Test("exposes a compatible local CLI for offline agent setup")
  func exposesCompatibleOfflineCLI() async {
    let service = MockCLIInstaller()
    let controller = CLIInstallerController(service: service)

    let installation = await controller.compatibleLocalInstallationForAgentSetup()

    #expect(installation?.version == "1.2.3")
  }

  @Test("reserves an operation before service progress arrives", arguments: [false, true])
  func reservesOperationBeforeProgress(installFirst: Bool) async {
    let service = MockCLIInstaller(pausesBeforeFirstProgress: true)
    let controller = CLIInstallerController(service: service)
    let firstOperation = Task {
      if installFirst {
        _ = await controller.install()
      } else {
        await controller.refresh()
      }
    }
    await service.waitForFirstCheck()

    #expect(controller.phase == .checkingLocal)
    await controller.refresh()
    let overlappingInstall = await controller.installForAgentSetup()
    if case let .failed(failure) = overlappingInstall {
      #expect(failure.kind == .operationInProgress)
    } else {
      Issue.record("Expected the overlapping installation to be rejected")
    }
    #expect(await service.numberOfChecks() == 1)
    #expect(await service.agentSetupInstallCalls() == 0)

    await service.releaseFirstCheck()
    await firstOperation.value
    #expect(!controller.phase.isBusy)
  }
}

private actor MockCLIInstaller: CLIInstalling {
  private let installFailure: CLIInstallerFailure?
  private var phases: [CLIInstallerPhase] = []
  private var agentSetupCalls = 0
  private let pausesBeforeFirstProgress: Bool
  private var checkCalls = 0
  private var firstCheckStarted: CheckedContinuation<Void, Never>?
  private var firstCheckRelease: CheckedContinuation<Void, Never>?

  init(installFailure: CLIInstallerFailure? = nil, pausesBeforeFirstProgress: Bool = false) {
    self.installFailure = installFailure
    self.pausesBeforeFirstProgress = pausesBeforeFirstProgress
  }

  func check(progress: @escaping CLIInstallerProgress) async throws -> CLIInstallPlan {
    checkCalls += 1
    if pausesBeforeFirstProgress, checkCalls == 1 {
      firstCheckStarted?.resume()
      firstCheckStarted = nil
      await withCheckedContinuation { firstCheckRelease = $0 }
    }
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
  func installForAgentSetup(
    progress: @escaping CLIInstallerProgress
  ) async throws -> CLIServiceInstallOutcome {
    agentSetupCalls += 1
    return try await install(progress: progress)
  }

  func agentSetupInstallCalls() -> Int {
    agentSetupCalls
  }

  func compatibleLocalInstallationForAgentSetup() -> CLIInstallation? {
    Self.installation
  }

  func observedPhases() -> [CLIInstallerPhase] {
    phases
  }

  func numberOfChecks() -> Int {
    checkCalls
  }

  func waitForFirstCheck() async {
    guard checkCalls == 0 else { return }
    await withCheckedContinuation { firstCheckStarted = $0 }
  }

  func releaseFirstCheck() {
    firstCheckRelease?.resume()
    firstCheckRelease = nil
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

  private static let installation = CLIInstallation(
    executableURL: URL(fileURLWithPath: "/usr/local/bin/inline"),
    version: "1.2.3",
    source: .inline,
    isOnPath: true
  )
}
