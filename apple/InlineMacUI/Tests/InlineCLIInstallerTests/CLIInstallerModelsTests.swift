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
