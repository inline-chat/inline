import Testing

@testable import InlineProtocol

@Suite("Realtime V3 update ownership")
struct RealtimeV3UpdatePipeTests {
  @Test("buffers updates before the transport subscribes")
  func buffersBeforeSubscription() async throws {
    let pipe = InlineProtocolUpdatePipe(capacity: 2)
    #expect(pipe.yield(RealtimeV3Update()))

    var iterator = pipe.stream().makeAsyncIterator()
    let received = await iterator.next()
    #expect(received != nil)
    pipe.finish()
  }

  @Test("reports bounded-buffer overflow instead of silently dropping")
  func reportsOverflow() async throws {
    let pipe = InlineProtocolUpdatePipe(capacity: 1)
    #expect(pipe.yield(RealtimeV3Update()))
    #expect(pipe.yield(RealtimeV3Update()) == false)

    var iterator = pipe.stream().makeAsyncIterator()
    #expect(await iterator.next() != nil)
    pipe.finish()
  }

  @Test("reports byte-buffer overflow instead of retaining an oversized update queue")
  func reportsByteOverflow() async throws {
    var message = Message()
    message.message = String(repeating: "x", count: 64)
    var newMessage = UpdateNewMessage()
    newMessage.message = message
    var update = Update()
    update.update = .newMessage(newMessage)
    var updates = UpdatesPayload()
    updates.updates = [update]
    var serverMessage = ServerMessage()
    serverMessage.payload = .update(updates)
    var envelope = RealtimeV3Update()
    envelope.message = serverMessage
    let serializedBytes = try envelope.serializedData().count
    let pipe = InlineProtocolUpdatePipe(capacity: 2, byteCapacity: serializedBytes - 1)

    #expect(pipe.yield(envelope) == false)
    var iterator = pipe.stream().makeAsyncIterator()
    #expect(await iterator.next() == nil)
    pipe.finish()
  }

  @Test("rejects an update that would exceed cumulative byte budget before enqueue")
  func rejectsCumulativeByteOverflowBeforeEnqueue() async throws {
    var message = Message()
    message.message = "buffered update"
    var newMessage = UpdateNewMessage()
    newMessage.message = message
    var update = Update()
    update.update = .newMessage(newMessage)
    var updates = UpdatesPayload()
    updates.updates = [update]
    var serverMessage = ServerMessage()
    serverMessage.payload = .update(updates)
    var envelope = RealtimeV3Update()
    envelope.message = serverMessage

    let serializedBytes = try envelope.serializedData().count
    let pipe = InlineProtocolUpdatePipe(
      capacity: 2,
      byteCapacity: serializedBytes * 2 - 1
    )
    #expect(pipe.yield(envelope))
    #expect(pipe.yield(envelope) == false)

    var iterator = pipe.stream().makeAsyncIterator()
    #expect(await iterator.next() != nil)
    #expect(await iterator.next() == nil)
    pipe.finish()
  }
}
