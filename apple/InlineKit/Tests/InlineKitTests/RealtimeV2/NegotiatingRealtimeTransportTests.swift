import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("Negotiating realtime transport", .serialized)
struct NegotiatingRealtimeTransportTests {
  @Test("V3 RPC multiplexer does not wait for responses and preserves correlation")
  func v3RPCMultiplexerDispatchesBeforeResponses() async throws {
    let harness = DeferredInvocationHarness()
    let multiplexer = InlineProtocolV3RPCMultiplexer(
      beginInvoke: { request, acknowledged, completion in
        await harness.begin(
          request: request,
          acknowledged: acknowledged,
          completion: completion
        )
      },
      acknowledge: { messageID, _ in
        await harness.acknowledge(messageID: messageID)
      },
      deliver: { messageID, _, result in
        await harness.deliver(messageID: messageID, result: result)
      }
    )

    try await multiplexer.dispatch(messageID: 11, call: .with { $0.method = .getMe })
    try await multiplexer.dispatch(messageID: 22, call: .with { $0.method = .getMe })

    #expect(await harness.pendingCount == 2)
    #expect(await harness.deliveredMessageIDs.isEmpty)

    await harness.acknowledge(at: 0)
    await harness.acknowledge(at: 1)
    #expect(await harness.acknowledgedMessageIDs == [11, 22])

    await harness.complete(at: 1)
    await harness.complete(at: 0)
    #expect(await harness.deliveredMessageIDs == [22, 11])
  }

  @Test("V3 heartbeat dispatch returns before the authenticated probe completes")
  func v3HeartbeatDoesNotBlockLegacyPingCaller() async {
    let harness = DeferredProbeHarness()
    let dispatcher = InlineProtocolV3ProbeDispatcher(
      beginProbe: { pingID in try await harness.begin(pingID: pingID) },
      deliver: { nonce, result in await harness.deliver(nonce: nonce, result: result) }
    )

    let task = dispatcher.dispatch(nonce: 42)
    let started = await waitForProbeCondition {
      await harness.startedPingID != nil
    }
    #expect(started)
    #expect(await harness.deliveredNonces.isEmpty)

    await harness.complete()
    await task.value
    #expect(await harness.startedPingID == 42)
    #expect(await harness.deliveredNonces == [42])
  }

  @Test("transient disconnect restarts the negotiated child and stop remains ordered")
  func transientDisconnectRestartsChildAndStopRemainsOrdered() async {
    let child = RestartableTestTransport()
    let transport = NegotiatingRealtimeTransport(
      hasInlineProtocolCredentials: { true },
      makeLegacyTransport: { child },
      makeInlineProtocolTransport: { child }
    )
    let observer = Task {
      for await _ in transport.events {
        guard !Task.isCancelled else { return }
      }
    }

    await transport.start()
    #expect(await child.startCount == 1)
    #expect(await transport.isApplicationAuthenticatedOnConnect())

    await child.disconnect()
    await transport.start()
    #expect(await child.startCount == 2)

    await transport.stop()
    #expect(await child.stopCount == 1)
    #expect(await child.stopEventDelivered)

    observer.cancel()
  }
}

private func waitForProbeCondition(
  timeout: Duration = .seconds(1),
  _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while await condition() == false {
    if clock.now >= deadline { return false }
    try? await clock.sleep(for: .milliseconds(10))
  }
  return true
}

private actor DeferredInvocationHarness {
  private var acknowledgements: [@Sendable () async -> Void] = []
  private var completions: [InlineProtocolV3RPCMultiplexer.Completion] = []
  private(set) var acknowledgedMessageIDs: [UInt64] = []
  private(set) var deliveredMessageIDs: [UInt64] = []

  var pendingCount: Int { completions.count }

  func begin(
    request: RealtimeV3Request,
    acknowledged: @escaping @Sendable () async -> Void,
    completion: @escaping InlineProtocolV3RPCMultiplexer.Completion
  ) {
    #expect(request.body != nil)
    acknowledgements.append(acknowledged)
    completions.append(completion)
  }

  func acknowledge(at index: Int) async {
    await acknowledgements[index]()
  }

  func acknowledge(messageID: UInt64) {
    acknowledgedMessageIDs.append(messageID)
  }

  func complete(at index: Int) async {
    await completions[index](.success(RealtimeV3Response()))
  }

  func deliver(
    messageID: UInt64,
    result: Result<RealtimeV3Response, any Error>
  ) {
    if case .success = result {
      deliveredMessageIDs.append(messageID)
    }
  }
}

private actor DeferredProbeHarness {
  private var continuation: CheckedContinuation<Void, any Error>?
  private(set) var startedPingID: Int64?
  private(set) var deliveredNonces: [UInt64] = []

  func begin(pingID: Int64) async throws {
    startedPingID = pingID
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func complete() {
    continuation?.resume()
    continuation = nil
  }

  func deliver(nonce: UInt64, result: Result<Void, any Error>) {
    if case .success = result {
      deliveredNonces.append(nonce)
    }
  }
}

private actor RestartableTestTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var stopEventDelivered = false

  func start() async {
    startCount += 1
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    stopCount += 1
    let delivery = StopEventDelivery()
    let sendTask = Task { [events] in
      await events.send(.disconnected(errorDescription: "stopped"))
      await delivery.markDelivered()
    }

    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(500)
    while !(await delivery.delivered), clock.now < deadline {
      try? await clock.sleep(for: .milliseconds(10))
    }

    stopEventDelivered = await delivery.delivered
    if !stopEventDelivered { sendTask.cancel() }
  }

  func send(_ message: ClientMessage) async throws {}

  func isApplicationAuthenticatedOnConnect() async -> Bool { true }

  func disconnect() async {
    await events.send(.disconnected(errorDescription: "test_disconnect"))
  }
}

private actor StopEventDelivery {
  private(set) var delivered = false

  func markDelivered() {
    delivered = true
  }
}
