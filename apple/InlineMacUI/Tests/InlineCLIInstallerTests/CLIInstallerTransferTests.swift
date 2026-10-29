@testable import InlineCLIInstaller
import CryptoKit
import Foundation
import Testing

private final class CLITransferFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cli-fixture.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let data: Data
    if request.url?.path == "/oversized" {
      data = Data(repeating: 32, count: 128 * 1_024)
    } else {
      let header = request.url?.path == "/archive" ? "X-Fixture-Archive" : "X-Fixture-Manifest"
      data = Data(base64Encoded: request.value(forHTTPHeaderField: header) ?? "") ?? Data()
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Suite("CLI bootstrap transfer boundaries")
struct CLIInstallerTransferTests {
  private func configuration(_ root: URL, path: String = "/manifest", maximum: Int = 256 * 1_024) -> CLIInstallerConfiguration {
    let production = CLIInstallerConfiguration.production
    return CLIInstallerConfiguration(
      manifestURL: URL(string: "https://cli-fixture.invalid\(path)")!,
      documentationURL: production.documentationURL,
      expectedSigningIdentifier: production.expectedSigningIdentifier,
      expectedTeamIdentifier: production.expectedTeamIdentifier,
      installLocations: [root.appending(path: "bin/inline")], searchesEnvironmentPath: false,
      maximumManifestBytes: maximum
    )
  }

  private func session(manifest: Data = Data(), archive: Data = Data()) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CLITransferFixtureProtocol.self]
    config.httpAdditionalHeaders = ["X-Fixture-Manifest": manifest.base64EncodedString(), "X-Fixture-Archive": archive.base64EncodedString()]
    return URLSession(configuration: config)
  }

  @Test("unknown-length metadata is stopped at the manifest byte limit")
  func boundsMetadataBeforeDecoding() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let network = session()
    defer { network.invalidateAndCancel() }
    let service = CLIInstallerService(configuration: configuration(root, path: "/oversized", maximum: 1_024), session: network)
    do {
      _ = try await service.check(progress: { _ in })
      Issue.record("Oversized metadata was accepted")
    } catch let failure as CLIInstallerFailure { #expect(failure.kind == .invalidManifest) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test("hard links are rejected before extraction and regular archives reach signature verification", arguments: [false, true])
  func rejectsUnsafeArchiveBeforeChangingAnExternalFile(hardLink: Bool) async throws {
#if arch(arm64)
    let root = URL(fileURLWithPath: "/tmp").appending(path: "inline-transfer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: false)
    let outside = root.appending(path: "outside")
    try Data("must survive".utf8).write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
    let archive = try tarFixture(hardLink: hardLink, outside: outside)
    let sha = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    let manifest = try JSONSerialization.data(withJSONObject: ["version": "1.2.3", "targets": ["aarch64-apple-darwin": ["url": "https://cli-fixture.invalid/archive", "sha256": sha, "size": archive.count]]])
    let network = session(manifest: manifest, archive: archive)
    defer { network.invalidateAndCancel() }
    let service = CLIInstallerService(configuration: configuration(root), session: network)
    do {
      _ = try await service.install(progress: { _ in })
      Issue.record("An unsigned fixture executable was installed")
    } catch let failure as CLIInstallerFailure {
      #expect(failure.kind == (hardLink ? .invalidArchive : .invalidSignature))
    }
    #expect(try Data(contentsOf: outside) == Data("must survive".utf8))
    let mode = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "bin/inline").path))
#endif
  }

  private func tarFixture(hardLink: Bool, outside: URL) throws -> Data {
    var header = [UInt8](repeating: 0, count: 512)
    func field(_ text: String, at offset: Int) {
      for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte }
    }
    field("inline", at: 0)
    field("0000755", at: 100)
    field("0000000", at: 108)
    field("0000000", at: 116)
    field(hardLink ? "00000000000" : "00000000003", at: 124)
    field("00000000000", at: 136)
    field("        ", at: 148)
    header[156] = hardLink ? 49 : 48
    if hardLink { field(outside.path, at: 157) }
    field("ustar", at: 257)
    field("00", at: 263)
    let sum = header.reduce(0) { $0 + Int($1) }
    field(String(format: "%06o", sum) + "\0 ", at: 148)
    var tar = Data(header)
    if !hardLink { tar.append(Data("bin".utf8)); tar.append(Data(repeating: 0, count: 509)) }
    tar.append(Data(repeating: 0, count: 1_024))
    let process = Process()
    let input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: tar)
    try input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return result
  }
}
