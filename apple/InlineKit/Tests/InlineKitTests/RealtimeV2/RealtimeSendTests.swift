import AsyncAlgorithms
import Auth
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("RealtimeV2.Send")
final class RealtimeSendTests {
  @Test("sendQueued runs optimistic immediately")
  func testSendQueuedRunsOptimisticImmediately() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: false)
    let transport = MockTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let id = UUID()
    _ = await realtime.sendQueued(SendTestTransaction(id: id))

    let optimisticRan = await SendTestRecorder.shared.didRunOptimistic(id)
    #expect(optimisticRan)

    withExtendedLifetime(realtime) {}
  }

  @Test("send completes with immediate rpc response")
  func testSendCompletesWithImmediateRpcResponse() async throws {
    await SendTestRecorder.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = ImmediateRoundTripTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected
      }
    }
    #expect(connected)

    let id = UUID()
    let result = try await realtime.send(SendTestTransaction(id: id))
    #expect(result == nil)
    #expect(await SendTestRecorder.shared.didRunOptimistic(id))
    #expect(await SendTestRecorder.shared.didRunApply(id))

    withExtendedLifetime(realtime) {}
  }

  @Test("send runs optimistic before rpc dispatch")
  func testSendRunsOptimisticBeforeRpcDispatch() async throws {
    await SendOrderingProbe.shared.reset()

    let auth = Auth.mocked(authenticated: true)
    let transport = OptimisticOrderingTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected
      }
    }
    #expect(connected)

    _ = try await realtime.send(SendOrderingTransaction(id: UUID()))
    #expect(await SendOrderingProbe.shared.didObserveRpcBeforeOptimistic() == false)

    withExtendedLifetime(realtime) {}
  }

  @Test("send fails when acked transaction cannot retry after reconnect")
  func testSendFailsWhenAckedTransactionCannotRetryAfterReconnect() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = AckThenDisconnectTransport()
    let storage = SendTestSyncStorage()
    let apply = SendTestApplyUpdates()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    let connected = await waitForCondition(timeout: .seconds(2)) {
      let stateObject = realtime.stateObject
      return await MainActor.run {
        stateObject.connectionState == .connected
      }
    }
    #expect(connected)

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try await realtime.send(AckNoRetryTransaction(id: UUID()))
          return ()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(5))
          throw SendTestTimeoutError.timedOut
        }
        _ = try await group.next()
        group.cancelAll()
      }
      Issue.record("Expected send to fail for acked non-retry transaction after reconnect")
    } catch let error as TransactionError {
      if case .ackedButNoResultAfterReconnect = error {
        // expected
      } else {
        Issue.record("Unexpected TransactionError: \(error)")
      }
    } catch SendTestTimeoutError.timedOut {
      Issue.record("Timed out waiting for send failure")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    withExtendedLifetime(realtime) {}
  }

  @Test("protocol session emits connectionError event")
  func testProtocolSessionEmitsConnectionErrorEvent() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    let sawConnectionError = SendTestFlag()

    await session.start()

    Task {
      for await event in session.events {
        if case .connectionError = event {
          await sawConnectionError.set()
          return
        }
      }
    }

    await transport.emit(.message(connectionErrorMessage()))

    let received = await waitForCondition {
      await sawConnectionError.get()
    }
    #expect(received)
  }
}

private struct SendTestTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = .UNRECOGNIZED(0)
  var type: TransactionKindType = .query()
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func optimistic() async {
    await SendTestRecorder.shared.markOptimistic(context.id)
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    await SendTestRecorder.shared.markApply(context.id)
  }
}

private actor SendTestRecorder {
  static let shared = SendTestRecorder()

  private var optimistic: Set<UUID> = []
  private var applied: Set<UUID> = []

  func reset() {
    optimistic.removeAll()
    applied.removeAll()
  }

  func markOptimistic(_ id: UUID) {
    optimistic.insert(id)
  }

  func markApply(_ id: UUID) {
    applied.insert(id)
  }

  func didRunOptimistic(_ id: UUID) -> Bool {
    optimistic.contains(id)
  }

  func didRunApply(_ id: UUID) -> Bool {
    applied.contains(id)
  }
}

private actor SendTestFlag {
  private var value = false

  func set() {
    value = true
  }

  func get() -> Bool {
    value
  }
}

private actor ImmediateRoundTripTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await channel.send(.message(open))

    case .rpcCall:
      var rpcResult = InlineProtocol.RpcResult()
      rpcResult.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(rpcResult)
      await channel.send(.message(response))

    default:
      break
    }
  }
}

private actor SendOrderingProbe {
  static let shared = SendOrderingProbe()

  private var optimisticRan = false
  private var rpcDispatchedBeforeOptimistic = false

  func reset() {
    optimisticRan = false
    rpcDispatchedBeforeOptimistic = false
  }

  func markOptimisticRan() {
    optimisticRan = true
  }

  func markRpcDispatched() {
    if !optimisticRan {
      rpcDispatchedBeforeOptimistic = true
    }
  }

  func didObserveRpcBeforeOptimistic() -> Bool {
    rpcDispatchedBeforeOptimistic
  }
}

private struct SendOrderingTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = sendOrderingMethod
  var type: TransactionKindType = .query()
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func optimistic() async {
    await SendOrderingProbe.shared.markOptimisticRan()
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

private actor OptimisticOrderingTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await channel.send(.message(open))

    case let .rpcCall(rpcCall):
      if rpcCall.method == sendOrderingMethod {
        await SendOrderingProbe.shared.markRpcDispatched()
      }

      var rpcResult = InlineProtocol.RpcResult()
      rpcResult.reqMsgID = message.id
      var response = ServerProtocolMessage()
      response.id = message.id
      response.body = .rpcResult(rpcResult)
      await channel.send(.message(response))

    default:
      break
    }
  }
}

private let sendOrderingMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_991)

private struct AckNoRetryTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let id: UUID
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = ackNoRetryMethod
  var type: TransactionKindType = .mutation(MutationConfig())
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

private actor AckThenDisconnectTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  private var started = false
  private var didAckAndDisconnectTargetRpc = false
  private let channel = AsyncChannel<TransportEvent>()

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
    await channel.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      var open = ServerProtocolMessage()
      open.id = message.id
      open.body = .connectionOpen(.init())
      await channel.send(.message(open))

    case let .rpcCall(rpcCall):
      if rpcCall.method == ackNoRetryMethod && !didAckAndDisconnectTargetRpc {
        didAckAndDisconnectTargetRpc = true

        var ack = ServerProtocolMessage()
        ack.id = message.id
        ack.body = .ack(.with {
          $0.msgID = message.id
        })
        await channel.send(.message(ack))
        try? await Task.sleep(for: .milliseconds(500))

        started = false
        await channel.send(.disconnected(errorDescription: "simulated_disconnect_after_ack"))
      } else {
        var rpcResult = InlineProtocol.RpcResult()
        rpcResult.reqMsgID = message.id
        var response = ServerProtocolMessage()
        response.id = message.id
        response.body = .rpcResult(rpcResult)
        await channel.send(.message(response))
      }

    default:
      break
    }
  }
}

private let ackNoRetryMethod: InlineProtocol.Method = .UNRECOGNIZED(9_999_992)

private enum SendTestTimeoutError: Error {
  case timedOut
}

private actor SendTestApplyUpdates: ApplyUpdates {
  func apply(updates: [InlineProtocol.Update], source: UpdateApplySource) async {}
}

private actor SendTestSyncStorage: SyncStorage {
  private var state = SyncState(lastSyncDate: 0)
  private var bucketStates: [BucketKey: BucketState] = [:]

  func getState() async -> SyncState {
    state
  }

  func setState(_ state: SyncState) async {
    self.state = state
  }

  func getBucketState(for key: BucketKey) async -> BucketState {
    bucketStates[key] ?? BucketState(date: 0, seq: 0)
  }

  func setBucketState(for key: BucketKey, state: BucketState) async {
    bucketStates[key] = state
  }

  func setBucketStates(states: [BucketKey: BucketState]) async {
    for (key, state) in states {
      bucketStates[key] = state
    }
  }

  func clearSyncState() async {
    state = SyncState(lastSyncDate: 0)
    bucketStates.removeAll()
  }
}

private func connectionErrorMessage() -> ServerProtocolMessage {
  var message = ServerProtocolMessage()
  message.id = 1
  message.body = .connectionError(.init())
  return message
}

private func waitForCondition(
  timeout: Duration = .seconds(1),
  pollInterval: Duration = .milliseconds(10),
  _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while await condition() == false {
    if clock.now >= deadline {
      return false
    }
    try? await clock.sleep(for: pollInterval)
  }

  return true
}
