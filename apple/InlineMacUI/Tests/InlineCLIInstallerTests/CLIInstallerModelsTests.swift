@testable import InlineCLIInstaller
import Foundation
import Testing

@Suite("Inline CLI installer models")
struct CLIInstallerModelsTests {
  @Test("recognizes release checksums")
  func recognizesChecksums() {
    #expect(CLIInstallerService.isSHA256(String(repeating: "a", count: 64)))
    #expect(!CLIInstallerService.isSHA256(String(repeating: "g", count: 64)))
    #expect(!CLIInstallerService.isSHA256("abc"))
  }

  @Test("extracts CLI versions from command output")
  func extractsVersions() {
    #expect(CLIInstallerService.versionString(in: "inline 0.4.0\n") == "0.4.0")
    #expect(CLIInstallerService.versionString(in: "inline v1.2.3") == "1.2.3")
    #expect(CLIInstallerService.versionString(in: "not a version") == nil)
  }

  @Test("compares versions component by component")
  func comparesVersions() {
    #expect(CLIInstallerService.isOlder("0.4.0", than: "0.5.0"))
    #expect(!CLIInstallerService.isOlder("0.5.0", than: "0.5.0"))
    #expect(!CLIInstallerService.isOlder("1.0", than: "0.9.9"))
    #expect(CLIInstallerService.isOlder(nil, than: "0.5.0"))
  }

  @Test("classifies Homebrew paths")
  func classifiesHomebrewPaths() {
    #expect(CLIInstallerService.isHomebrewPath("/opt/homebrew/bin/inline"))
    #expect(CLIInstallerService.isHomebrewPath("/opt/homebrew/Caskroom/inline/0.4.0/inline"))
    #expect(!CLIInstallerService.isHomebrewPath("/usr/local/bin/inline"))
  }

  @Test("agent setup finds a compatible side-by-side CLI behind shadowing candidates")
  func selectsCompatibleAgentSetupCLI() {
    let installations = [
      CLIInstallation(
        executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/inline"),
        version: "0.7.1",
        source: .homebrew,
        isOnPath: true
      ),
      CLIInstallation(
        executableURL: URL(fileURLWithPath: "/usr/local/bin/inline"),
        version: nil,
        source: .external,
        isOnPath: true
      ),
      CLIInstallation(
        executableURL: URL(fileURLWithPath: "/Users/example/.local/bin/inline"),
        version: "0.7.4",
        source: .inline,
        isOnPath: false
      ),
    ]

    let compatible = CLIInstallerService.compatibleInstallationForAgentSetup(
      in: installations,
      minimumVersion: "0.7.4"
    )

    #expect(compatible?.executableURL.path == "/Users/example/.local/bin/inline")
  }

  @Test("agent setup refuses releases and alternates below its lifecycle-safe CLI floor")
  func enforcesAgentSetupVersionFloor() {
    let stale = CLIInstallation(
      executableURL: URL(fileURLWithPath: "/Users/example/.local/bin/inline"),
      version: "0.7.2",
      source: .inline,
      isOnPath: false
    )
    let requiredVersion = CLIInstallerService.requiredAgentSetupVersion(for: "0.7.2")

    #expect(CLIInstallerService.minimumAgentSetupVersion == "0.7.4")
    #expect(!CLIInstallerService.supportsAgentSetup(releaseVersion: "0.7.3"))
    #expect(CLIInstallerService.supportsAgentSetup(releaseVersion: "0.7.4"))
    #expect(requiredVersion == "0.7.4")
    #expect(
      CLIInstallerService.compatibleInstallationForAgentSetup(
        in: [stale],
        minimumVersion: requiredVersion
      ) == nil
    )
  }

  @Test("cancellation before the installer commit boundary leaves the destination untouched")
  func cancellationPreventsInstallerCommit() async {
    let gate = InstallerCommitGate()
    let probe = InstallerCommitProbe()
    let task = Task {
      await gate.waitBeforeCommit()
      try CLIInstallerService.performInstallUnlessCancelled {
        probe.markInstalled()
      }
    }

    await gate.waitUntilReached()
    task.cancel()
    await gate.release()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(!probe.didInstall)
  }

  @Test("agent setup does not reuse an excluded or stale alternate CLI")
  func rejectsUnsafeAgentSetupAlternates() {
    let currentURL = URL(fileURLWithPath: "/Users/example/.local/bin/inline")
    let installations = [
      CLIInstallation(
        executableURL: currentURL,
        version: "0.7.4",
        source: .inline,
        isOnPath: false
      ),
      CLIInstallation(
        executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/inline"),
        version: "0.7.2",
        source: .homebrew,
        isOnPath: true
      ),
    ]

    let compatible = CLIInstallerService.compatibleInstallationForAgentSetup(
      in: installations,
      minimumVersion: "0.7.4",
      excluding: currentURL
    )

    #expect(compatible == nil)
  }

  @Test("menu state stays presentation-ready")
  func menuState() {
    let release = CLIRelease(
      version: "0.5.0",
      archiveURL: URL(string: "https://example.com/inline.tar.gz")!,
      sha256: String(repeating: "a", count: 64),
      size: 100
    )
    let install = CLIInstallPlan(
      localInstallation: nil,
      release: release,
      destinationURL: URL(fileURLWithPath: "/usr/local/bin/inline"),
      disposition: .install
    )
    let update = CLIInstallPlan(
      localInstallation: nil,
      release: release,
      destinationURL: URL(fileURLWithPath: "/usr/local/bin/inline"),
      disposition: .update
    )

    #expect(CLIInstallerPhase.ready(install).menuTitle == "Install Inline CLI…")
    #expect(CLIInstallerPhase.ready(update).menuTitle == "Update Inline CLI…")
    #expect(!CLIInstallerPhase.downloading(version: "0.5.0", expectedBytes: 100).allowsPrimaryAction)
  }
}

private actor InstallerCommitGate {
  private var reached = false
  private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func waitBeforeCommit() async {
    reached = true
    let waiters = reachedWaiters
    reachedWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilReached() async {
    guard !reached else { return }
    await withCheckedContinuation { continuation in
      reachedWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private final class InstallerCommitProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var installed = false

  var didInstall: Bool { lock.withLock { installed } }

  func markInstalled() {
    lock.withLock { installed = true }
  }
}
