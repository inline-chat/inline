import Foundation
import Testing
@testable import InlineProtocol

@Suite("Realtime V3 outbound writer")
struct RealtimeV3OutboundWriterTests {
  @Test("serializes carrier advancement with WebSocket wire order")
  func serializesWireWrites() async throws {
    let header = Array(UInt8(1) ... UInt8(64))
    let carrier = try InlineObfuscatedClientCarrier(randomHeader: header)
    let wire = ControlledWire()
    let writer = InlineProtocolOutboundWriter(outbound: carrier.outbound) { data in
      try await wire.send(data)
    }

    let first = Task { try await writer.send([1, 2, 3, 4]) }
    try await waitUntil { await wire.callCount == 1 }

    let second = Task { try await writer.send([5, 6, 7, 8], quickAck: true) }
    try await waitUntil { await writer.queuedWriteCount == 1 }
    let third = Task { try await writer.send([9, 10, 11, 12]) }
    try await waitUntil { await writer.queuedWriteCount == 2 }

    #expect(await wire.callCount == 1)
    #expect(await wire.maximumConcurrentCalls == 1)

    await wire.releaseCurrent()
    try await waitUntil { await wire.callCount == 2 }
    await wire.releaseCurrent()
    try await waitUntil { await wire.callCount == 3 }
    await wire.releaseCurrent()

    try await first.value
    try await second.value
    try await third.value

    let expectedCarrier = try InlineObfuscatedClientCarrier(randomHeader: header)
    let expected = try [
      expectedCarrier.outbound.process(InlineSecureTransport.encodeAbridgedPacket([1, 2, 3, 4])),
      expectedCarrier.outbound.process(InlineSecureTransport.encodeAbridgedPacket(
        [5, 6, 7, 8],
        requestQuickAck: true
      )),
      expectedCarrier.outbound.process(InlineSecureTransport.encodeAbridgedPacket([9, 10, 11, 12])),
    ].map(Data.init)

    #expect(await wire.frames == expected)
    #expect(await wire.maximumConcurrentCalls == 1)
  }

  @Test("a wire failure poisons the writer and every queued write")
  func wireFailureIsTerminal() async throws {
    let carrier = try InlineObfuscatedClientCarrier(randomHeader: Array(UInt8(1) ... UInt8(64)))
    let wire = ControlledWire(failFirst: true)
    let writer = InlineProtocolOutboundWriter(outbound: carrier.outbound) { data in
      try await wire.send(data)
    }

    let first = Task { try await writer.send([1, 2, 3, 4]) }
    try await waitUntil { await wire.callCount == 1 }
    let queued = Task { try await writer.send([5, 6, 7, 8]) }
    try await waitUntil { await writer.queuedWriteCount == 1 }
    await wire.releaseCurrent()

    await #expect(throws: ControlledWire.Failure.self) { try await first.value }
    await #expect(throws: ControlledWire.Failure.self) { try await queued.value }
    await #expect(throws: ControlledWire.Failure.self) {
      try await writer.send([9, 10, 11, 12])
    }
    #expect(await wire.callCount == 1)
  }

  @Test("closing fails both the active suspended write and queued writes")
  func closeFailsActiveAndQueuedWrites() async throws {
    let carrier = try InlineObfuscatedClientCarrier(randomHeader: Array(UInt8(1) ... UInt8(64)))
    let wire = ControlledWire()
    let writer = InlineProtocolOutboundWriter(outbound: carrier.outbound) { data in
      try await wire.send(data)
    }

    let active = Task { try await writer.send([1, 2, 3, 4]) }
    try await waitUntil { await wire.callCount == 1 }
    let queued = Task { try await writer.send([5, 6, 7, 8]) }
    try await waitUntil { await writer.queuedWriteCount == 1 }

    await writer.close(with: InlineProtocolV3ConnectionError.closed)

    await #expect(throws: InlineProtocolV3ConnectionError.closed) { try await active.value }
    await #expect(throws: InlineProtocolV3ConnectionError.closed) { try await queued.value }
    await wire.releaseCurrent()
  }

  @Test("rejects excess queued writes without advancing the carrier")
  func queueCapacityIsFinite() async throws {
    let carrier = try InlineObfuscatedClientCarrier(randomHeader: Array(UInt8(1) ... UInt8(64)))
    let wire = ControlledWire()
    let writer = InlineProtocolOutboundWriter(outbound: carrier.outbound, capacity: 1) { data in
      try await wire.send(data)
    }

    let active = Task { try await writer.send([1, 2, 3, 4]) }
    try await waitUntil { await wire.callCount == 1 }
    let queued = Task { try await writer.send([5, 6, 7, 8]) }
    try await waitUntil { await writer.queuedWriteCount == 1 }

    await #expect(throws: InlineProtocolV3ConnectionError.outboundBufferOverflow) {
      try await writer.send([9, 10, 11, 12])
    }
    #expect(await wire.callCount == 1)

    await wire.releaseCurrent()
    try await waitUntil { await wire.callCount == 2 }
    await wire.releaseCurrent()
    try await active.value
    try await queued.value
  }

  @Test("rejects queued bytes beyond the writer budget")
  func queueByteCapacityIsFinite() async throws {
    let carrier = try InlineObfuscatedClientCarrier(randomHeader: Array(UInt8(1) ... UInt8(64)))
    let wire = ControlledWire()
    let writer = InlineProtocolOutboundWriter(
      outbound: carrier.outbound,
      capacity: 4,
      byteCapacity: 4
    ) { data in
      try await wire.send(data)
    }

    let active = Task { try await writer.send([1, 2, 3, 4]) }
    try await waitUntil { await wire.callCount == 1 }
    let queued = Task { try await writer.send([5, 6, 7, 8]) }
    try await waitUntil { await writer.queuedByteCount == 4 }

    await #expect(throws: InlineProtocolV3ConnectionError.outboundBufferOverflow) {
      try await writer.send([9, 10, 11, 12])
    }

    await wire.releaseCurrent()
    try await waitUntil { await wire.callCount == 2 }
    await wire.releaseCurrent()
    try await active.value
    try await queued.value
  }

  private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
  ) async throws {
    for _ in 0 ..< 2_000 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw WaitFailure.timedOut
  }

  private enum WaitFailure: Error {
    case timedOut
  }
}

private actor ControlledWire {
  enum Failure: Error {
    case rejected
  }

  private(set) var frames: [Data] = []
  private(set) var callCount = 0
  private(set) var maximumConcurrentCalls = 0
  private var concurrentCalls = 0
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private let failFirst: Bool

  init(failFirst: Bool = false) {
    self.failFirst = failFirst
  }

  func send(_ data: Data) async throws {
    callCount += 1
    concurrentCalls += 1
    maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
    frames.append(data)
    await withCheckedContinuation { releaseContinuation = $0 }
    concurrentCalls -= 1
    if failFirst, callCount == 1 { throw Failure.rejected }
  }

  func releaseCurrent() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
