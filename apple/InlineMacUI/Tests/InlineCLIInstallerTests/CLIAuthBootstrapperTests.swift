@testable import InlineCLIInstaller
import Foundation
import Testing

@Suite("Inline CLI authentication bootstrap")
struct CLIAuthBootstrapperTests {
  @Test("accepts a bounded callback handshake")
  func acceptsReadyHandshake() throws {
    let data = Data(
      #"{"version":1,"status":"ready","callbackUrl":"inline://cli-auth?version=1&port=54321&capability=abcdefghijklmnopqrstuvwxyz012345"}"#.utf8
    )
    let request = try CLIAuthBootstrapper.parseReady(data)
    #expect(request.callbackURL.host == "cli-auth")
  }

  @Test("rejects an external callback handshake")
  func rejectsExternalHandshake() {
    let data = Data(
      #"{"version":1,"status":"ready","callbackUrl":"https://example.com/cli-auth"}"#.utf8
    )
    #expect(throws: CLIAuthBootstrapError.self) {
      try CLIAuthBootstrapper.parseReady(data)
    }
  }

  @Test("accepts only token-free authenticated results")
  func acceptsAuthenticatedResult() throws {
    let data = Data(
      #"{"status":"authenticated","userId":42,"tokenSaved":true,"profileLoaded":false,"warning":null}"#.utf8
    )
    let result = try CLIAuthBootstrapper.parseResult(data)
    #expect(result.userID == 42)
    #expect(!result.profileLoaded)
  }

  @Test("uses the expected-user extension only with a compatible CLI")
  func gatesExpectedUserArgumentByVersion() {
    let releasedArguments = CLIAuthBootstrapper.authenticationArguments(
      cliVersion: "0.7.2",
      expectedUserID: 42
    )
    let extendedArguments = CLIAuthBootstrapper.authenticationArguments(
      cliVersion: "0.7.3",
      expectedUserID: 42
    )

    #expect(!releasedArguments.contains("--expected-user-id"))
    #expect(extendedArguments.suffix(2) == ["--expected-user-id", "42"])
  }

  @Test("accepts an authenticated result only for the expected account")
  func validatesExpectedUser() throws {
    let result = CLIAuthBootstrapResult(userID: 42, profileLoaded: true, warning: nil)

    #expect(
      try CLIAuthBootstrapper.validateResult(result, expectedUserID: 42) == result
    )
    #expect(throws: CLIAuthBootstrapError.self) {
      try CLIAuthBootstrapper.validateResult(result, expectedUserID: 7)
    }
  }

  @Test("removes Inline overrides from the child environment")
  func sanitizesEnvironment() {
    let environment = CLIAuthBootstrapper.sanitizedEnvironment([
      "HOME": "/Users/test",
      "PATH": "/custom/bin",
      "INLINE_TOKEN": "secret",
      "INLINE_API_BASE_URL": "https://example.com",
    ])
    #expect(environment["HOME"] == "/Users/test")
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(environment["INLINE_TOKEN"] == nil)
    #expect(environment["INLINE_API_BASE_URL"] == nil)
  }

  @Test("describes bootstrap timeouts as a recoverable sign-in failure")
  func describesTimeout() {
    #expect(
      CLIAuthBootstrapError.timedOut.errorDescription ==
        "The installed CLI did not finish signing in within two minutes."
    )
  }

  @Test("cancellation latched before auth launch prevents the child from starting")
  func cancellationBeforeAuthLaunchPreventsStart() throws {
    let state = AuthProcessCancellationState()
    let probe = AuthLaunchProbe()

    state.cancel()
    let launched = try state.launch {
      probe.markStarted()
    }

    #expect(!launched)
    #expect(!probe.didStart)
  }

  @Test("auth cancellation cannot return during the launch transition")
  func authCancellationWaitsForLaunchTransition() {
    let state = AuthProcessCancellationState()
    let launchEntered = DispatchSemaphore(value: 0)
    let permitLaunch = DispatchSemaphore(value: 0)
    let cancellationReturned = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
      _ = try? state.launch {
        launchEntered.signal()
        permitLaunch.wait()
      }
    }
    #expect(launchEntered.wait(timeout: .now() + 2) == .success)

    DispatchQueue.global(qos: .userInitiated).async {
      state.cancel()
      cancellationReturned.signal()
    }
    #expect(cancellationReturned.wait(timeout: .now() + 0.1) == .timedOut)

    permitLaunch.signal()
    #expect(cancellationReturned.wait(timeout: .now() + 2) == .success)
    #expect(state.isCancellationRequested)
  }

  @Test("auth cancellation takes priority over pipe and process errors")
  func cancellationWinsOverAuthErrors() async {
    let gate = AuthCancellationGate()
    let task = Task {
      await gate.waitBeforeFailureMapping()
      try CLIAuthBootstrapper.rethrowUnlessCancelled(CLIAuthBootstrapError.invalidHandshake)
    }

    await gate.waitUntilReached()
    task.cancel()
    await gate.release()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }
}

private actor AuthCancellationGate {
  private var reached = false
  private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func waitBeforeFailureMapping() async {
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

private final class AuthLaunchProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false

  var didStart: Bool { lock.withLock { started } }

  func markStarted() {
    lock.withLock { started = true }
  }
}
