import Foundation
import InlineProtocol
import Testing
@testable import Auth
@testable import InlineKit

@Suite("Agent output mode account fences", .serialized)
@MainActor
struct AgentOutputModeAccountTests {
  enum Operation: CaseIterable, Sendable {
    case loadRuntime, loadSettings, loadParticipations
    case defaultSuccess, defaultFailure, overrideSuccess, overrideFailure

    nonisolated var method: InlineProtocol.Method {
      switch self {
        case .loadRuntime: .getAgentRuntime
        case .loadSettings: .getAgentSettings
        case .loadParticipations: .getAgentParticipations
        case .defaultSuccess, .defaultFailure: .updateAgentSettings
        case .overrideSuccess, .overrideFailure: .setAgentParticipation
      }
    }

    nonisolated var fails: Bool { self == .defaultFailure || self == .overrideFailure }

    nonisolated var response: InlineProtocol.RpcResult.OneOf_Result {
      let settings = InlineProtocol.AgentSettings.with {
        $0.botUserID = 9
        $0.defaultOutputMode = .friendly
      }
      let participation = InlineProtocol.AgentParticipation.with {
        $0.peerID = .with { $0.type = .chat(.with { $0.chatID = 7 }) }
        $0.botUserID = 9
        $0.outputMode = .friendly
        $0.revision = 1
      }
      return switch self {
        case .loadRuntime: .getAgentRuntime(.with {
            $0.runtime = .with { $0.botUserID = 9; $0.defaultOutputMode = .friendly }
          })
        case .loadSettings: .getAgentSettings(.with { $0.settings = settings })
        case .loadParticipations: .getAgentParticipations(.with { $0.participations = [participation] })
        case .defaultSuccess, .defaultFailure: .updateAgentSettings(.with { $0.settings = settings })
        case .overrideSuccess, .overrideFailure: .setAgentParticipation(.with { $0.participation = participation })
      }
    }

    func invoke(_ store: AgentWorkStateStore) async throws {
      switch self {
        case .loadRuntime, .loadSettings: await store.loadAgentSettings(botUserID: 9)
        case .loadParticipations: await store.loadOutputModes(peer: .thread(id: 7), botUserID: 9)
        case .defaultSuccess, .defaultFailure: try await store.updateDefaultOutputMode(.friendly, botUserID: 9)
        case .overrideSuccess, .overrideFailure:
          try await store.updateOutputModeOverride(.friendly, peer: .thread(id: 7), botUserID: 9)
      }
    }
  }

  @Test("held results and error rollbacks cannot repopulate a reset store", arguments: Operation.allCases)
  func resetRejectsCompletion(_ operation: Operation) async throws {
    let fixture = OutputModeFixture(operation)
    let call = Task { try? await operation.invoke(fixture.store) }
    await fixture.realtime.waitUntilHeld()
    let requestsBeforeReset = await fixture.realtime.requestTokens
    fixture.store.removeAll()
    await fixture.realtime.release()
    await call.value

    #expect(fixture.store.defaultOutputModes.isEmpty)
    #expect(fixture.store.outputOverrides.isEmpty)
    #expect(fixture.store.runtimeBotUserIDs.isEmpty)
    // Chained loads cannot start another request under a new store owner.
    #expect(await fixture.realtime.requestTokens == requestsBeforeReset)
  }

  @Test("logout and same-user reauthentication invalidate held profile settings", arguments: [false, true])
  func accountGenerationRejectsCompletion(signBackIn: Bool) async throws {
    let fixture = OutputModeFixture(.loadRuntime)
    let call = Task { await fixture.store.loadAgentSettings(botUserID: 9) }
    await fixture.realtime.waitUntilHeld()
    try fixture.accounts.logout(signBackIn: signBackIn)
    // Deliberately leave the store generation unchanged: the Auth lease must
    // independently reject a response from the old login, even for the same ID.
    await fixture.realtime.release()
    await call.value

    #expect(fixture.store.defaultOutputModes.isEmpty)
    #expect(fixture.store.runtimeBotUserIDs.isEmpty)
    #expect(await fixture.realtime.requestTokens.count == 1)
  }

  @Test("an unchanged account applies results and rolls back rejected optimistic changes", arguments: Operation.allCases)
  func unchangedOwnerKeepsBehavior(_ operation: Operation) async throws {
    let fixture = OutputModeFixture(operation)
    let token = try fixture.accounts.auth.beginAccountMutation()
    let call = Task { @MainActor in
      do { try await operation.invoke(fixture.store); return true } catch { return false }
    }
    await fixture.realtime.waitUntilHeld()
    await fixture.realtime.release()
    #expect(await call.value == !operation.fails)
    #expect(await fixture.realtime.requestTokens.allSatisfy { $0 == token })

    switch operation {
      case .loadRuntime, .loadSettings, .defaultSuccess:
        #expect(fixture.store.defaultOutputMode(botUserID: 9) == .friendly)
      case .loadParticipations, .overrideSuccess:
        #expect(fixture.store.outputModeOverride(peer: .thread(id: 7), botUserID: 9) == .friendly)
      case .defaultFailure:
        #expect(fixture.store.defaultOutputMode(botUserID: 9) == .detailed)
      case .overrideFailure:
        #expect(fixture.store.outputModeOverride(peer: .thread(id: 7), botUserID: 9) == nil)
    }
  }

  @Test("cancelling a caller cannot undo a confirmed write", arguments: [Operation.defaultSuccess, .overrideSuccess])
  func cancelledCallerKeepsConfirmedWrite(_ operation: Operation) async throws {
    let fixture = OutputModeFixture(operation)
    let call = Task { @MainActor in
      do { try await operation.invoke(fixture.store); return true } catch { return false }
    }
    // The transport has a successful response; hold its return to the caller.
    await fixture.realtime.waitUntilHeld()
    call.cancel()
    await fixture.realtime.release()

    #expect(await call.value)
    #expect(fixture.store.outputMode(peer: .thread(id: 7), botUserID: 9) == .friendly)
  }

  @Test("a cancelled read does not apply a held response")
  func cancelledReadIsDiscarded() async {
    let fixture = OutputModeFixture(.loadRuntime)
    let call = Task { await fixture.store.loadAgentSettings(botUserID: 9) }
    await fixture.realtime.waitUntilHeld()
    call.cancel()
    await fixture.realtime.release()
    await call.value

    #expect(fixture.store.defaultOutputModes.isEmpty)
    #expect(fixture.store.runtimeBotUserIDs.isEmpty)
    #expect(await fixture.realtime.requestTokens.count == 1)
  }
}

@MainActor
private struct OutputModeFixture {
  let accounts = OutputModeAccounts()
  let realtime: OutputModeRealtime
  let store: AgentWorkStateStore

  init(_ operation: AgentOutputModeAccountTests.Operation) {
    realtime = OutputModeRealtime(auth: accounts.auth, operation: operation)
    store = AgentWorkStateStore(auth: accounts.auth, outputModeRealtime: { [realtime] in realtime })
  }
}

private final class OutputModeAccounts: Sendable {
  private let cache: AuthSnapshotCache
  let auth: AuthHandle

  init() {
    let initial = AuthSnapshot(status: .authenticated(AuthCredentials(userId: 42, token: "test")), didHydrate: true)
    cache = AuthSnapshotCache(initial: initial)
    let store = AuthStore(cache: cache, mocked: true, namespace: UUID().uuidString,
                          readSnapshot: { @Sendable _, _, _ in initial })
    auth = AuthHandle(cache: cache, store: store)
  }

  func logout(signBackIn: Bool) throws {
    let logout = cache.beginLogout()
    #expect(cache.completeLogout(logout, snapshot: AuthSnapshot(status: .unauthenticated, didHydrate: true), publish: {}))
    guard signBackIn else { return }
    let attempt = cache.makeLoginAttempt()
    #expect(cache.beginAuthorityStaging(attempt))
    let next = AuthSnapshot(status: .authenticated(AuthCredentials(userId: 42, token: "replacement")), didHydrate: true)
    #expect(cache.finishAuthorityStaging(next, owner: attempt))
    #expect(cache.prepareStagedAuthorityFinalization(attempt))
    _ = try #require(cache.finalizeStagedAuthority(attempt, publish: { _ in }))
  }
}

private actor OutputModeRealtime: InlineRPCRealtime {
  let auth: AuthHandle
  let operation: AgentOutputModeAccountTests.Operation
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var requestTokens: [AuthAccountMutationToken] = []

  init(auth: AuthHandle, operation: AgentOutputModeAccountTests.Operation) {
    self.auth = auth
    self.operation = operation
  }

  func callRpcDirect(
    method: InlineProtocol.Method,
    input: InlineProtocol.RpcCall.OneOf_Input?,
    timeout: Duration?,
    accountToken: AuthAccountMutationToken?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    if let accountToken {
      try auth.validateAccountMutation(accountToken)
      requestTokens.append(accountToken)
    }
    guard method == operation.method else { return nil }
    held = true
    waiters.forEach { $0.resume() }
    waiters = []
    if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    if operation.fails { throw CancellationError() }
    return operation.response
  }

  func applyUpdatesAndWait(_: [InlineProtocol.Update], accountToken _: AuthAccountMutationToken) async throws {
    Issue.record("Output-mode reads apply their typed result, not an updates batch")
  }

  func waitUntilHeld() async {
    guard !held else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    released = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}
