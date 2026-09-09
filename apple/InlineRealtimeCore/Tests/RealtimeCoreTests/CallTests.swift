import Testing

@testable import RealtimeCore

@Suite struct CallTests {
  @Test func queuedCallsHaveIdentityCancellationExpiryAndCapacity() throws {
    var s = Scenario()
    s.core = Core(configuration: Configuration(maxQueuedCalls: 2))
    s.send(.start(generation: 1))
    let first = Call(id: CallID(1), payload: "a", expiresAt: 5)
    let second = Call(id: CallID(2), payload: "b", expiresAt: 5)
    s.send(.request(first))
    #expect(s.send(.request(first)).contains(.event(.callRejected(first.id))))
    s.send(.request(second))
    #expect(
      s.send(.request(Call(id: CallID(3), payload: "c"))).contains(.event(.callRejected(CallID(3))))
    )
    #expect(s.send(.cancelCall(second.id)).contains(.event(.callFinished(second.id, .cancelled))))
    #expect(s.send(.timeout, at: 5).contains(.event(.callFinished(first.id, .expired))))
    #expect(s.core.directQueue.isEmpty)
  }
  @Test func callerExpiryIncludesCapacityWaitAndRequestTime() throws {
    var s = Scenario(capacity: 1)
    try s.open()
    let request = try attempt(s.send(.request(Call(id: CallID(1), payload: "query", expiresAt: 5))))
    let expired = s.send(.timeout, at: 5)
    #expect(expired.contains(.event(.callFinished(CallID(1), .expired))))
    #expect(expired.contains(.cancel(request)))
    #expect(s.core.outstandingSends == 1)
    let stale = s.send(.response(request, .result("late")))
    #expect(!stale.contains(.event(.callFinished(CallID(1), .result("late")))))
    s.send(.sendFinished(request))
    #expect(s.core.outstandingSends == 0)
  }
  @Test func localWriterCapacityIsReleasedOnlyByActualCompletion() throws {
    var s = Scenario()
    s.core = Core(configuration: Configuration(capacity: 2, maxPendingSends: 1))
    try s.open()
    let first = try attempt(s.send(.request(Call(id: CallID(1), payload: "one"))))
    s.send(.request(Call(id: CallID(2), payload: "two")))
    let replied = s.send(.response(first, .result("one")))
    #expect(transmissions(replied).isEmpty)
    #expect(s.core.outstandingRequests == 0)
    #expect(s.core.outstandingSends == 1)
    #expect(transmissions(s.send(.sendFinished(first))) == [.direct("two")])
  }
  @Test func stopSettlesCallersButStillJoinsWriter() throws {
    var s = Scenario(capacity: 1)
    let connection = try s.open()
    let first = try attempt(s.send(.request(Call(id: CallID(1), payload: "one"))))
    s.send(.request(Call(id: CallID(2), payload: "two")))
    let stop = s.send(.stop)
    #expect(stop.contains(.event(.callFinished(CallID(1), .cancelled))))
    #expect(stop.contains(.event(.callFinished(CallID(2), .cancelled))))
    #expect(!stop.contains(.event(.drained)))
    s.send(.disconnected(connection))
    #expect(s.send(.sendFinished(first)).contains(.event(.drained)))
  }
  @Test func terminalAuthorizationFailureSettlesQueuedCallsAndRejectsNewOnes() throws {
    var s = Scenario()
    let start = s.send(.start(generation: 1))
    let connection = try #require(
      start.compactMap { if case .connect(let id) = $0 { id } else { nil } }.first)
    s.send(.request(Call(id: CallID(1), payload: "queued")))
    let load = try credentialOperation(s.send(.connected(connection)))
    let rejected = s.send(.credentialsFinished(load, .loaded(nil)))
    #expect(rejected.contains(.event(.callFinished(CallID(1), .failed))))
    #expect(s.core.directQueue.isEmpty)
    #expect(
      s.send(.request(Call(id: CallID(2), payload: "new"))).contains(
        .event(.callRejected(CallID(2)))))
  }

}
