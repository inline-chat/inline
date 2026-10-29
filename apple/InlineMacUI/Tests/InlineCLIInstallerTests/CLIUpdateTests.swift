@testable import InlineCLIInstaller
import Foundation
import Testing

@Suite("CLI automatic update trust and protocol")
struct CLIUpdateTests {
  private struct Vector: Decodable {
    let keys: [String: String]
    var envelope: Envelope
    struct Envelope: Codable {
      var payload: String
      var signatures: [Signature]
      struct Signature: Codable { let keyId: String; let signature: String }
    }
  }

  @Test("CryptoKit verifies the same exact signed payload as Rust and the publisher")
  func verifiesSharedVector() throws {
    let url: URL
    if let path = ProcessInfo.processInfo.environment["INLINE_CLI_SIGNATURE_FIXTURE"] { url = URL(fileURLWithPath: path) }
    else {
      url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../../cli/tests/fixtures/signed-channel.json").standardizedFileURL
    }
    var vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    let encoded = try JSONEncoder().encode(vector.envelope)
    let payload = try CLIReleaseVerification.payload(in: encoded, channel: .alpha, keys: vector.keys)
    #expect(String(decoding: payload, as: UTF8.self).contains("1.2.3-alpha.4"))
    #expect(throws: (any Error).self) { try CLIReleaseVerification.payload(in: encoded, channel: .stable, keys: vector.keys) }
    #expect(throws: (any Error).self) { try CLIReleaseVerification.payload(in: encoded, channel: .alpha, keys: [:]) }
    vector.envelope.payload = Data("{}".utf8).base64EncodedString()
    #expect(throws: (any Error).self) { try CLIReleaseVerification.payload(in: JSONEncoder().encode(vector.envelope), channel: .alpha, keys: vector.keys) }
  }

  @Test("legacy bootstrap is limited to a rejected updater subcommand")
  func distinguishesLegacyEngineFromAnUpdaterFailure() {
    #expect(CLIAgentSetupRunner.isUnsupportedUpdateEngine(status: 2, standardError: Data("error: unexpected argument 'status' found".utf8)))
    #expect(!CLIAgentSetupRunner.isUnsupportedUpdateEngine(status: 1, standardError: Data("release status verification failed".utf8)))
    #expect(!CLIAgentSetupRunner.isUnsupportedUpdateEngine(status: 2, standardError: Data("invalid update state".utf8)))
  }

  @Test("app protocol carries opt-out and pending bridge state without touching auth")
  func decodesUpdateState() throws {
    let data = Data(#"{"schemaVersion":1,"autoUpdate":false,"channel":"alpha","followsApp":true,"currentVersion":"0.7.19-alpha.8","installationMethod":"managed","automaticUpdatesAvailable":true,"outcome":"staged","failure":null,"staged":{"version":"0.7.19-alpha.9"},"retryAt":null,"bridges":[{"version":"0.7.19-alpha.8","candidateVersion":"0.7.19-alpha.9","phase":"waiting_for_idle"}]}"#.utf8)
    let status = try JSONDecoder().decode(CLIUpdateStatus.self, from: data)
    #expect(!status.autoUpdate)
    #expect(status.bridges?.first?.phase == "waiting_for_idle")
    #expect(CLIUpdateOperation.configure(enabled: false, appChannel: .alpha, register: false).arguments == ["update", "config", "--app-channel", "alpha", "--json", "--auto", "off"])
    let environment = CLIAgentSetupRunner.sanitizedEnvironment(["INLINE_DISABLE_AUTOUPDATE": "true", "INLINE_RELEASE_MANIFEST_URL": "https://untrusted.invalid", "INLINE_TOKEN": "secret"])
    #expect(environment["INLINE_DISABLE_AUTOUPDATE"] == "1")
    #expect(environment["INLINE_RELEASE_MANIFEST_URL"] == nil)
    #expect(environment["INLINE_TOKEN"] == nil)
  }
}
