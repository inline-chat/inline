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
    let command = InlineAppBuildRunner.command(
      for: .macOS(.debug),
      repositoryRoot: repositoryRoot
    )

    #expect(command.executableURL.path == "/bin/bash")
    #expect(command.arguments == [
      "/tmp/inline/scripts/macos/open-debug-app.sh",
      "--no-stop",
      "--no-open",
      "--no-logs",
      "--verbose",
    ])
  }

  @Test
  func secondDebugBuildUsesSecondProfile() {
    let command = InlineAppBuildRunner.command(
      for: .macOS(.debug2),
      repositoryRoot: repositoryRoot
    )

    #expect(command.arguments.contains("--second"))
    #expect(command.arguments.contains("--no-open"))
  }

  @Test
  func devBuildUsesStableLocalBuild() {
    let command = InlineAppBuildRunner.command(
      for: .macOS(.dev),
      repositoryRoot: repositoryRoot
    )

    #expect(command.arguments == [
      "/tmp/inline/scripts/macos/build-local-app.sh",
      "--channel",
      "stable",
    ])
  }

  @Test
  func iOSBuildTargetsConnectedDeviceAndRunsAfterBuilding() {
    let command = InlineAppBuildRunner.command(
      for: .iOS(deviceID: "device-123", deviceName: "Mo's iPhone"),
      repositoryRoot: repositoryRoot
    )

    #expect(command.arguments == [
      "/tmp/inline/scripts/ios/open-debug-app.sh",
      "--device",
      "device-123",
      "--no-logs",
      "--verbose",
    ])
  }

  @Test
  func buildMarkerPreservesExistingRunningEntries() {
    let existing = "Long-lived development server\n"

    #expect(
      InlineAppBuildRunner.runningFileContents(
        existing,
        appending: "Inline Dev Companion: macOS build"
      ) == "Long-lived development server\nInline Dev Companion: macOS build\n"
    )
  }

  @Test
  func parsesInstalledIOSVersionMetadata() {
    let data = Data(
      #"{"result":{"apps":[{"bundleIdentifier":"chat.inline.InlineIOS.debug","bundleVersion":"841","name":"Inline Debug","version":"0.1"}]}}"#.utf8
    )

    let application = InventoryDiscovery.parseInstalledIOSApplication(data)

    #expect(application?.name == "Inline Debug")
    #expect(application?.displayVersion == "0.1 (841)")
  }

  @Test
  func parsesRunningIOSProcessByExecutableName() {
    let data = Data(
      #"{"result":{"runningProcesses":[{"executable":"/private/InlineIOS","processIdentifier":15977}]}}"#.utf8
    )

    #expect(InventoryDiscovery.parseRunningIOSProcessID(data) == 15977)
  }

  @Test
  func rejectsDifferentIOSProcessWithSimilarName() {
    let data = Data(
      #"{"result":{"runningProcesses":[{"executable":"/private/InlineIOSHelper","processIdentifier":15977}]}}"#.utf8
    )

    #expect(InventoryDiscovery.parseRunningIOSProcessID(data) == nil)
  }

  @Test
  func parsesXcode27StructuredDeviceOSVersion() {
    let data = Data(
      #"{"result":{"devices":[{"identifier":"device-123","properties":{"connection":{"pairingState":"paired","transportType":"wired"},"hardware":{"marketingName":"iPhone SE","platform":"iOS","productType":"iPhone","reality":"physical","udid":"device-123"},"software":{"osVersionNumber":{"components":[27,0,0,0,0],"originalComponentsCount":2,"stringValue":"27.0"}},"state":{"name":"Mo's iPhone SE"}}}]}}"#.utf8
    )

    #expect(InventoryDiscovery.parsePhysicalIOSDeviceNames(data) == ["Mo's iPhone SE"])
  }
}
