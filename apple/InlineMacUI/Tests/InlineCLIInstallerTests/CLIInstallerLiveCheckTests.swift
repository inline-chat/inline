@testable import InlineCLIInstaller
import Foundation
import Testing

@Suite("Inline CLI installer live check")
struct CLIInstallerLiveCheckTests {
  @Test("checks the production manifest and a local signed CLI when explicitly enabled")
  func checksProductionState() async throws {
    guard ProcessInfo.processInfo.environment["INLINE_CLI_INSTALLER_LIVE_TEST"] == "1" else {
      return
    }

    let service = CLIInstallerService()
    let plan = try await service.check { _ in }

    #expect(!plan.release.version.isEmpty)
    #expect(plan.release.archiveURL.scheme == "https")
    if let installation = plan.localInstallation, installation.source != .external {
      #expect(installation.version != nil)
    }
  }

  @Test("downloads, verifies, and installs the production CLI when explicitly enabled")
  func installsProductionArtifactInTemporaryDirectory() async throws {
    guard ProcessInfo.processInfo.environment["INLINE_CLI_INSTALLER_LIVE_TEST"] == "1" else {
      return
    }

    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appending(path: "inline-cli-installer-live-\(UUID().uuidString)", directoryHint: .isDirectory)
    let binDirectory = temporaryDirectory.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let production = CLIInstallerConfiguration.production
    let configuration = CLIInstallerConfiguration(
      manifestURL: production.manifestURL,
      documentationURL: production.documentationURL,
      expectedSigningIdentifier: production.expectedSigningIdentifier,
      legacySigningIdentifiers: production.legacySigningIdentifiers,
      expectedTeamIdentifier: production.expectedTeamIdentifier,
      installLocations: [binDirectory.appending(path: "inline")],
      searchesEnvironmentPath: false
    )
    let service = CLIInstallerService(configuration: configuration)
    let outcome = try await service.install { _ in }

    #expect(outcome.didInstall)
    #expect(outcome.installation.source == .inline)
    #expect(outcome.installation.version != nil)
    #expect(FileManager.default.isExecutableFile(atPath: outcome.installation.executableURL.path))
  }
}
