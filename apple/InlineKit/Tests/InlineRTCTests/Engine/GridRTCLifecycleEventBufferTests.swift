import Foundation
import Testing

@testable import InlineRTC

@Suite("Grid RTC lifecycle delivery")
struct GridRTCLifecycleEventBufferTests {
  @Test("snapshot bursts cannot evict disconnect or retirement edges")
  func snapshotBurstPreservesEdges() async {
    let buffer = GridRTCLifecycleEventBuffer()
    let room = GridRTCRoomHandle()
    let disconnected = GridRTCLifecycleEventEnvelope(room: room, event: .disconnected(error: nil))
    let released = GridRTCLifecycleEventEnvelope(room: room, event: .retiredLocalMediaMutationReleased)
    buffer.yield(disconnected)
    for revision in 1 ... 1_000 {
      buffer.yield(snapshot(room, revision: UInt64(revision)))
    }
    buffer.yield(released)
    #expect(buffer.pendingCount == 3)
    buffer.finish()

    var received: [GridRTCLifecycleEventEnvelope] = []
    for await event in buffer.makeStream() { received.append(event) }
    #expect(received == [disconnected, snapshot(room, revision: 1_000), released])
  }

  @Test("snapshots retain reconnect ordering and coalesce independently per room")
  func snapshotsRespectLifecycleBarriers() async {
    let buffer = GridRTCLifecycleEventBuffer()
    let room = GridRTCRoomHandle()
    let retiringRoom = GridRTCRoomHandle()
    let reconnecting = GridRTCLifecycleEventEnvelope(room: room, event: .reconnecting(mode: .full))
    let reconnected = GridRTCLifecycleEventEnvelope(room: room, event: .reconnected(mode: .full))
    buffer.yield(reconnecting)
    for revision in 1 ... 1_000 {
      buffer.yield(snapshot(room, revision: UInt64(revision)))
      buffer.yield(snapshot(retiringRoom, revision: UInt64(revision)))
    }
    buffer.yield(reconnected)
    buffer.yield(snapshot(room, revision: 1_002))
    buffer.yield(snapshot(room, revision: 1_001))
    #expect(buffer.pendingCount == 5)
    buffer.finish()

    var received: [GridRTCLifecycleEventEnvelope] = []
    for await event in buffer.makeStream() { received.append(event) }
    #expect(received == [
      reconnecting, snapshot(room, revision: 1_000), snapshot(retiringRoom, revision: 1_000),
      reconnected, snapshot(room, revision: 1_002),
    ])
  }

  @Test("cancelling an idle consumer releases its wait and ignores later provider callbacks")
  func cancellationReleasesWaiter() async {
    let buffer = GridRTCLifecycleEventBuffer()
    let stream = buffer.makeStream()
    let consumer = Task {
      for await _ in stream {}
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while !buffer.hasWaitingConsumer, ContinuousClock.now < deadline {
      await Task.yield()
    }
    #expect(buffer.hasWaitingConsumer)
    consumer.cancel()
    await consumer.value
    buffer.yield(snapshot(GridRTCRoomHandle(), revision: 1))
    #expect(buffer.pendingCount == 0)
  }

  @Test("concurrent callbacks and an active consumer preserve every critical edge")
  func concurrentDeliveryPreservesEdges() async {
    let buffer = GridRTCLifecycleEventBuffer()
    let room = GridRTCRoomHandle()
    let consumer = Task {
      var count = 0
      for await _ in buffer.makeStream() { count += 1 }
      return count
    }
    await withTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 8 {
        group.addTask {
          for _ in 0 ..< 100 {
            buffer.yield(GridRTCLifecycleEventEnvelope(room: room, event: .localMicrophoneUnpublished))
          }
        }
      }
    }
    buffer.finish()
    #expect(await consumer.value == 800)
  }

  @Test("periodic playout checks remain bounded while a consumer is suspended")
  func repeatedPlayoutChecksCoalesce() async {
    let buffer = GridRTCLifecycleEventBuffer()
    let room = GridRTCRoomHandle()
    let frames = GridRTCLifecycleEventEnvelope(room: room, event: .remoteAudioFramesObserved(identity: "peer"))
    for revision in 1 ... 1_000 {
      buffer.yield(frames)
      buffer.yield(snapshot(room, revision: UInt64(revision)))
    }
    let missing = GridRTCLifecycleEventEnvelope(room: room, event: .remoteAudioFlow(identity: "peer", state: .missing))
    buffer.yield(missing)
    buffer.yield(frames)
    #expect(buffer.pendingCount == 4)
    buffer.finish()
    var received: [GridRTCLifecycleEventEnvelope] = []
    for await event in buffer.makeStream() { received.append(event) }
    #expect(received == [frames, snapshot(room, revision: 1_000), missing, frames])
  }

  private func snapshot(_ room: GridRTCRoomHandle, revision: UInt64) -> GridRTCLifecycleEventEnvelope {
    GridRTCLifecycleEventEnvelope(room: room, event: .screenSharesChanged(revision: revision, shares: []))
  }
}
