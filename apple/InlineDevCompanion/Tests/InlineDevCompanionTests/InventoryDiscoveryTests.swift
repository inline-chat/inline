import Foundation
import Testing
@testable import InlineDevCompanion

struct InventoryDiscoveryTests {
  private let repositoryRoot = URL(fileURLWithPath: "/tmp/inline", isDirectory: true)

  @Test
  func parsesMatchingPackageVersion() {
    let data = Data(#"{"name":"@inline-openclaw/inline","version":"0.0.55"}"#.utf8)

    #expect(
      InventoryDiscovery.parsePackageVersion(
        data,
        expectedName: "@inline-openclaw/inline"
      ) == "0.0.55"
    )
  }

  @Test
  func rejectsDifferentPackage() {
    let data = Data(#"{"name":"openclaw","version":"2026.6.11"}"#.utf8)

    #expect(
      InventoryDiscovery.parsePackageVersion(
        data,
        expectedName: "@inline-openclaw/inline"
      ) == nil
    )
  }

  @Test
  func parsesHermesManifestVersion() {
    let manifest = """
      name: inline-platform
      version: '0.0.5'
      description: Inline adapter
      """

    #expect(InventoryDiscovery.parseHermesVersion(manifest) == "0.0.5")
  }

  @Test
  func debugBuildUsesBuildOnlyWrapper() {
    let command = InlineAppBuildRunner.command(for: .debug, repositoryRoot: repositoryRoot)

    #expect(command.executableURL.path == "/bin/bash")
    #expect(command.arguments == [
      "/tmp/inline/scripts/macos/open-debug-app.sh",
      "--no-stop",
      "--no-open",
      "--no-logs",
    ])
  }

  @Test
  func secondDebugBuildUsesSecondProfile() {
    let command = InlineAppBuildRunner.command(for: .debug2, repositoryRoot: repositoryRoot)

    #expect(command.arguments.contains("--second"))
    #expect(command.arguments.contains("--no-open"))
  }

  @Test
  func devBuildUsesStableLocalBuild() {
    let command = InlineAppBuildRunner.command(for: .dev, repositoryRoot: repositoryRoot)

    #expect(command.arguments == [
      "/tmp/inline/scripts/macos/build-local-app.sh",
      "--channel",
      "stable",
    ])
  }
}
