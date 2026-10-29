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
        .appendingPathComponent("../../../../cli/tests/fixtures/signed-channel.json").standardizedFileURL
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
    #expect(status.revision == nil)
    #expect(status.bridges?.first?.phase == "waiting_for_idle")
    #expect(CLIUpdateOperation.configure(enabled: false, appChannel: .alpha, register: false).arguments == ["update", "config", "--app-channel", "alpha", "--json", "--auto", "off"])
    let environment = CLIAgentSetupRunner.sanitizedEnvironment(["INLINE_DISABLE_AUTOUPDATE": "true", "INLINE_RELEASE_MANIFEST_URL": "https://untrusted.invalid", "INLINE_TOKEN": "secret"])
    #expect(environment["INLINE_DISABLE_AUTOUPDATE"] == "1")
    #expect(environment["INLINE_RELEASE_MANIFEST_URL"] == nil)
    #expect(environment["INLINE_TOKEN"] == nil)
  }
}

@MainActor
private final class CLIUpdateGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    opened = true
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume() }
  }
}

@MainActor
private final class CLIUpdateWrites {
  var values: [Bool] = []
}

@MainActor
@Suite("CLI update policy ordering")
struct CLIUpdateCoordinatorTests {
  private func status(enabled: Bool, revision: UInt64) throws -> CLIUpdateStatus {
    try JSONDecoder().decode(CLIUpdateStatus.self, from: Data("""
    {"schemaVersion":1,"revision":\(revision),"autoUpdate":\(enabled),"channel":"alpha","followsApp":true,"currentVersion":"1.2.3","installationMethod":"managed","automaticUpdatesAvailable":true,"outcome":"current"}
    """.utf8))
  }

  @Test("an opt-out is written after older registration while background work stays independent")
  func offCannotBeOvertakenByAnOlderWrite() async throws {
    let coordinator = CLIUpdateCoordinator()
    let started = CLIUpdateGate(), release = CLIUpdateGate(), enqueued = CLIUpdateGate()
    let writes = CLIUpdateWrites()
    let failSafe = Task {
      try? await Task.sleep(for: .seconds(5))
      release.open()
    }
    defer { failSafe.cancel() }
    let older = Task {
      try await coordinator.run(.configure(enabled: true, appChannel: .alpha, register: true)) {
        started.open()
        await release.wait()
        writes.values.append(true)
        return try status(enabled: true, revision: 1)
      }
    }
    await started.wait()
    let newer = Task {
      enqueued.open()
      return try await coordinator.run(.configure(enabled: false, appChannel: .alpha, register: false)) {
        writes.values.append(false)
        return try status(enabled: false, revision: 2)
      }
    }
    await enqueued.wait()
    let background = try await coordinator.run(.background) { try status(enabled: true, revision: 0) }
    #expect(background.revision == 0)
    #expect(writes.values.isEmpty)
    release.open()
    _ = try await older.value
    let saved = try await newer.value
    #expect(writes.values == [true, false])
    #expect(!saved.autoUpdate)
  }

  @Test("failed policy writes do not block a later opt-out")
  func aFailedWriteDoesNotPoisonTheQueue() async throws {
    enum Failure: Error { case expected }
    let coordinator = CLIUpdateCoordinator()
    do {
      _ = try await coordinator.run(.followApp(.alpha)) { throw Failure.expected }
      Issue.record("A failed write succeeded")
    } catch Failure.expected {}
    let saved = try await coordinator.run(.configure(enabled: false, appChannel: .alpha, register: false)) {
      try status(enabled: false, revision: 1)
    }
    #expect(!saved.autoUpdate)
  }

  @Test("late status responses cannot turn a confirmed opt-out back on")
  func ignoresOlderRevisions() throws {
    let coordinator = CLIUpdateCoordinator()
    #expect(coordinator.accepts(try status(enabled: false, revision: 4)))
    #expect(!coordinator.accepts(try status(enabled: true, revision: 3)))
    #expect(coordinator.accepts(try status(enabled: false, revision: 4)))
    #expect(coordinator.accepts(try status(enabled: true, revision: 5)))
  }
}
