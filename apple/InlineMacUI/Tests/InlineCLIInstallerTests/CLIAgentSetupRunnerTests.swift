import Foundation
import Testing
@testable import InlineCLIInstaller

@Suite("CLI agent setup app protocol")
struct CLIAgentSetupRunnerTests {
  @Test("uses the released CLI argument contract")
  func usesReleasedCLIArguments() {
    #expect(CLIAgentSetupRunner.discoveryArguments == [
      "--json", "--compact", "agents", "discover",
    ])
    #expect(CLIAgentSetupRunner.setupArguments(targetID: "codex", replaceExisting: false) == [
      "--json", "--compact", "agents", "setup", "--target", "codex", "--non-interactive",
      "--app-protocol", "1",
    ])
    #expect(CLIAgentSetupRunner.setupArguments(targetID: "hermes", replaceExisting: true) == [
      "--json", "--compact", "agents", "setup", "--target", "hermes", "--non-interactive",
      "--app-protocol", "1", "--replace",
    ])
    #expect(CLIAgentSetupRunner.setupArguments(
      targetID: "codex",
      replaceExisting: false,
      appProtocol: false
    ) == [
      "--json", "--compact", "agents", "setup", "--target", "codex", "--non-interactive",
    ])
  }

  @Test("falls back only for an older CLI that rejects the app protocol flag")
  func identifiesUnsupportedAppProtocol() {
    #expect(CLIAgentSetupRunner.isUnsupportedAppProtocol(
      status: 2,
      standardError: Data("error: unexpected argument '--app-protocol'".utf8)
    ))
    #expect(!CLIAgentSetupRunner.isUnsupportedAppProtocol(
      status: 1,
      standardError: Data("setup failed after accepting --app-protocol".utf8)
    ))
    #expect(!CLIAgentSetupRunner.isUnsupportedAppProtocol(
      status: 2,
      standardError: Data("error: missing required argument '--target'".utf8)
    ))
  }

  @Test("decodes installed harness discovery")
  func decodesDiscovery() throws {
    let data = Data(
      #"{"protocolVersion":1,"action":"agents.discover","documentationUrl":"https://inline.chat/docs/agents","targets":[{"id":"codex","displayName":"Codex","family":"bridge","installed":true},{"id":"hermes","displayName":"Hermes","family":"gateway","installed":false}]}"#.utf8
    )

    let discovery = try CLIAgentSetupRunner.parseDiscovery(data)

    #expect(discovery.targets.count == 2)
    #expect(discovery.targets.first?.id == "codex")
    #expect(discovery.targets.first?.installed == true)
  }

  @Test("decodes a ready setup result")
  func decodesSetupResult() throws {
    let data = Data(
      #"{"protocolVersion":1,"ok":true,"action":"agents.setup","status":"ready","documentationUrl":"https://inline.chat/docs/agents","openUrl":"in://user/42","target":"codex","family":"bridge","instance":"codex-example","bot":{"id":42,"username":"codex_bot","name":"Codex"},"service":{"kind":"inline_bridge","action":"started","ready":true,"status":"running"},"integration":{"kind":"bridge_provider","action":"configured","version":"1"},"mapping":{"source":"bridge_account","action":"upserted"}}"#.utf8
    )

    let result = try CLIAgentSetupRunner.parseSetup(data)

    #expect(result.target == "codex")
    #expect(result.bot.id == 42)
    #expect(result.service.ready)
    #expect(result.readiness == nil)
  }

  @Test("decodes progress events and the final streamed result")
  func decodesStreamedSetup() throws {
    let event = Data(
      #"{"protocolVersion":1,"event":"phase.completed","phase":"bot","outcome":"reused"}"#.utf8
    )
    let output = Data(
      (#"{"protocolVersion":1,"event":"phase.started","phase":"bot"}"# + "\n"
        + #"{"protocolVersion":1,"event":"result","result":{"protocolVersion":1,"ok":true,"action":"agents.setup","status":"ready","documentationUrl":"https://inline.chat/docs/agents","openUrl":"in://user/42","target":"codex","family":"bridge","instance":"codex-example","bot":{"id":42,"username":"codex_bot","name":"Codex"},"service":{"kind":"inline_bridge","action":"started","ready":true,"status":"running"}}}"#
        + "\n").data(using: .utf8)!
    )

    let progress = try #require(CLIAgentSetupRunner.parseProgressEvent(event))
    let result = try CLIAgentSetupRunner.parseSetup(output)

    #expect(progress.event == .phaseCompleted)
    #expect(progress.phase == .bot)
    #expect(progress.outcome == "reused")
    #expect(result.bot.id == 42)
  }

  @Test("rejects progress outcomes outside the fixed code alphabet")
  func rejectsUnsafeProgressOutcome() {
    let event = Data(
      #"{"protocolVersion":1,"event":"phase.completed","phase":"bot","outcome":"bot 42 at /tmp/example"}"#.utf8
    )

    #expect(CLIAgentSetupRunner.parseProgressEvent(event) == nil)
  }

  @Test("decodes a configured result that still needs a model provider")
  func decodesProviderRequiredResult() throws {
    let data = Data(
      #"{"protocolVersion":1,"ok":true,"action":"agents.setup","status":"configured","documentationUrl":"https://inline.chat/docs/agents","openUrl":"in://user/42","target":"hermes","family":"gateway","instance":"default","bot":{"id":42,"username":"hermes_bot","name":"Hermes"},"service":{"kind":"gateway","action":"reconciled","ready":true},"readiness":{"ready":false,"code":"provider_configuration_required","message":"Hermes is connected to Inline, but credentials for its selected model provider could not be resolved.","command":"hermes model","verified":false},"integration":{"kind":"plugin","action":"kept","version":"0.0.8"},"mapping":{"source":"inline_config","action":"upserted"}}"#.utf8
    )

    let result = try CLIAgentSetupRunner.parseSetup(data)

    #expect(result.status == "configured")
    #expect(result.service.ready)
    #expect(result.readiness?.ready == false)
    #expect(result.readiness?.code == "provider_configuration_required")
    #expect(result.readiness?.command == "hermes model")
    #expect(result.readiness?.verified == false)
  }

  @Test("decodes readiness metadata from an older producer without verification")
  func decodesReadinessWithoutVerification() throws {
    let data = Data(
      #"{"protocolVersion":1,"ok":true,"action":"agents.setup","status":"configured","documentationUrl":"https://inline.chat/docs/agents","openUrl":"in://user/42","target":"hermes","family":"gateway","instance":"default","bot":{"id":42,"username":"hermes_bot","name":"Hermes"},"service":{"kind":"gateway","action":"reconciled","ready":true},"readiness":{"ready":false,"code":"inline_adapter_not_ready","message":"The Inline adapter did not connect.","command":"hermes logs"},"integration":{"kind":"plugin","action":"kept","version":"0.0.8"},"mapping":{"source":"inline_config","action":"upserted"}}"#.utf8
    )

    let result = try CLIAgentSetupRunner.parseSetup(data)

    #expect(result.readiness?.code == "inline_adapter_not_ready")
    #expect(result.readiness?.verified == nil)
  }

  @Test("rejects a future protocol version")
  func rejectsFutureProtocol() {
    let data = Data(
      #"{"protocolVersion":2,"action":"agents.discover","documentationUrl":"https://inline.chat/docs/agents","targets":[]}"#.utf8
    )

    #expect(throws: AgentSetupFailure.self) {
      try CLIAgentSetupRunner.parseDiscovery(data)
    }
  }

  @Test("removes Inline overrides and relative PATH entries")
  func sanitizesEnvironment() {
    let environment = CLIAgentSetupRunner.sanitizedEnvironment([
      "INLINE_TOKEN": "not-a-real-token",
      "PATH": "relative-bin:/custom/bin",
    ])

    #expect(environment["INLINE_TOKEN"] == nil)
    #expect(environment["PATH"]?.contains("relative-bin") == false)
    #expect(environment["PATH"]?.contains("/custom/bin") == true)
    #expect(environment["PATH"]?.contains("/.volta/bin") == true)
    #expect(environment["PATH"]?.contains("/Library/pnpm") == true)
  }

  @Test("drains verbose output without retaining unbounded data")
  func drainsVerboseOutputWithinLimit() async {
    let standardOutput = Pipe()
    let standardError = Pipe()
    let payload = Data(repeating: 0x61, count: CLIAgentSetupRunner.maximumOutputBytes * 2)
    async let output = drain(payload, through: standardOutput)
    async let error = drain(payload, through: standardError)

    #expect(await output.count == CLIAgentSetupRunner.maximumOutputBytes)
    #expect(await error.count == CLIAgentSetupRunner.maximumOutputBytes)
  }

  @Test("redacts credentials and home paths in structured failures")
  func redactsStructuredFailureText() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let sanitized = CLIAgentSetupRunner.safeStructuredText(
      "\(home)/agent token=secret-value Bearer abc.def \"token\":\"json-secret\" password: \"quoted-secret\" --api-key flag-secret",
      maximumScalars: 1_000
    )

    #expect(!sanitized.contains(home))
    #expect(!sanitized.contains("secret-value"))
    #expect(!sanitized.contains("abc.def"))
    #expect(!sanitized.contains("json-secret"))
    #expect(!sanitized.contains("quoted-secret"))
    #expect(!sanitized.contains("flag-secret"))
  }

  @Test("keeps non-secret structured failure prose")
  func keepsNonSecretFailureProse() {
    let prose = "Provider login is required before setup can continue."
    #expect(CLIAgentSetupRunner.safeStructuredText(prose, maximumScalars: 1_000) == prose)
  }

  @Test("accepts versionless released errors and rejects future error protocols")
  func validatesStructuredErrorProtocol() throws {
    let released = Data(
      #"{"error":{"code":"not_authenticated","message":"Run inline login.","hint":"Sign in first.","examples":[]}}"#.utf8
    )
    let future = Data(
      #"{"protocolVersion":2,"error":{"code":"future","message":"A future error."}}"#.utf8
    )

    let releasedFailure = try #require(CLIAgentSetupRunner.parseFailure(released, targetID: "codex"))
    let futureFailure = try #require(CLIAgentSetupRunner.parseFailure(future, targetID: "codex"))

    #expect(releasedFailure.code == "not_authenticated")
    #expect(releasedFailure.retryCommand == "inline agents setup --target codex --non-interactive")
    #expect(futureFailure.code == "invalid_cli_response")
  }

  @Test("cancellation cannot return during the process launch transition")
  func cancellationWaitsForLaunchTransition() throws {
    let state = AgentSetupProcessState()
    let operationID = try #require(state.begin())
    let launchEntered = DispatchSemaphore(value: 0)
    let permitLaunch = DispatchSemaphore(value: 0)
    let cancellationAttempted = DispatchSemaphore(value: 0)
    let cancellationReturned = DispatchSemaphore(value: 0)
    let launchFinished = DispatchSemaphore(value: 0)
    let probe = LaunchProbe()

    DispatchQueue.global(qos: .userInitiated).async {
      let launched = try? state.launch(Process(), operationID: operationID) {
        launchEntered.signal()
        permitLaunch.wait()
        probe.markStarted()
      }
      probe.markLaunchResult(launched == true)
      launchFinished.signal()
    }
    #expect(launchEntered.wait(timeout: .now() + 2) == .success)

    DispatchQueue.global(qos: .userInitiated).async {
      cancellationAttempted.signal()
      _ = state.requestCancellation()
      probe.markCancellationReturned()
      cancellationReturned.signal()
    }
    #expect(cancellationAttempted.wait(timeout: .now() + 2) == .success)
    #expect(cancellationReturned.wait(timeout: .now() + 0.1) == .timedOut)

    permitLaunch.signal()
    #expect(launchFinished.wait(timeout: .now() + 2) == .success)
    #expect(cancellationReturned.wait(timeout: .now() + 2) == .success)
    #expect(probe.launchSucceeded)
    #expect(probe.startedBeforeCancellationReturned)
    state.finish(operationID)
  }

  @Test("a cancellation latched before launch prevents process start")
  func cancellationBeforeLaunchPreventsStart() throws {
    let state = AgentSetupProcessState()
    let operationID = try #require(state.begin())
    let probe = LaunchProbe()

    _ = state.requestCancellation()
    let launched = try state.launch(Process(), operationID: operationID) {
      probe.markStarted()
    }

    #expect(!launched)
    #expect(!probe.didStart)
    state.finish(operationID)
  }

  @Test("refuses a non-Inline executable at the setup boundary")
  func refusesNonInlineExecutable() {
    let configuration = CLIInstallerConfiguration(
      manifestURL: URL(string: "https://example.com/manifest.json")!,
      documentationURL: URL(string: "https://example.com/docs")!,
      expectedSigningIdentifier: "chat.inline.cli",
      expectedTeamIdentifier: "2487AN8AL4",
      installLocations: [],
      searchesEnvironmentPath: false
    )

    #expect(throws: CLIInstallerFailure.self) {
      try CLIExecutableVerifier.verify(
        URL(fileURLWithPath: "/bin/echo"),
        configuration: configuration
      )
    }
  }

  @Test("synchronous cancellation returns only after a stubborn child exits")
  func synchronousCancellationWaitsForExit() throws {
    let process = Process()
    let readyPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap '' TERM; printf R; while :; do sleep 1; done"]
    process.standardOutput = readyPipe
    try process.run()
    try? readyPipe.fileHandleForWriting.close()
    let ready = try readyPipe.fileHandleForReading.read(upToCount: 1)
    #expect(ready == Data("R".utf8))

    CLIAgentSetupRunner.stopAndWait(process)

    #expect(!process.isRunning)
  }

  private func drain(_ payload: Data, through pipe: Pipe) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        try? pipe.fileHandleForWriting.write(contentsOf: payload)
        try? pipe.fileHandleForWriting.close()
      }
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: CLIAgentSetupRunner.boundedDrain(pipe.fileHandleForReading))
      }
    }
  }
}

private final class LaunchProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false
  private var cancellationReturned = false
  private var launchResult = false

  var didStart: Bool { lock.withLock { started } }
  var launchSucceeded: Bool { lock.withLock { launchResult } }
  var startedBeforeCancellationReturned: Bool {
    lock.withLock { started && cancellationReturned }
  }

  func markStarted() {
    lock.withLock { started = true }
  }

  func markCancellationReturned() {
    lock.withLock { cancellationReturned = true }
  }

  func markLaunchResult(_ value: Bool) {
    lock.withLock { launchResult = value }
  }
}
