import Foundation

/// Single-consumer provider ingress. Critical edges stay lossless and ordered;
/// complete screen-share snapshots and repeated playout checks coalesce only
/// between those edges. Separate streams would allow a republish snapshot to
/// overtake its reconnect fence.
final class GridRTCLifecycleEventBuffer: @unchecked Sendable {
  private enum ReplaceableKey: Equatable {
    case screenShares(GridRTCRoomHandle)
    case remoteAudioFrames(GridRTCRoomHandle, String)
  }

  private let lock = NSLock()
  private var pending: [GridRTCLifecycleEventEnvelope] = []
  private var waiter: CheckedContinuation<GridRTCLifecycleEventEnvelope?, Never>?
  private var finished = false

  func makeStream() -> AsyncStream<GridRTCLifecycleEventEnvelope> {
    AsyncStream(unfolding: { await self.next() }, onCancel: { self.finish() })
  }

  func yield(_ envelope: GridRTCLifecycleEventEnvelope) {
    let receiver: CheckedContinuation<GridRTCLifecycleEventEnvelope?, Never>? = lock.withLock {
      guard !finished else { return nil }
      if let receiver = waiter {
        waiter = nil
        return receiver
      }
      if let key = replaceableKey(envelope) {
        for index in pending.indices.reversed() {
          guard let pendingKey = replaceableKey(pending[index]) else { break }
          guard pendingKey == key else { continue }
          if case let .screenSharesChanged(revision, _) = envelope.event,
             case let .screenSharesChanged(previousRevision, _) = pending[index].event,
             revision > previousRevision {
            pending[index] = envelope
          }
          return nil
        }
      }
      pending.append(envelope)
      return nil
    }
    receiver?.resume(returning: envelope)
  }

  func finish() {
    let receiver = lock.withLock {
      finished = true
      let receiver = waiter
      waiter = nil
      return receiver
    }
    receiver?.resume(returning: nil)
  }

  var pendingCount: Int {
    lock.withLock { pending.count }
  }

  var hasWaitingConsumer: Bool {
    lock.withLock { waiter != nil }
  }

  private func replaceableKey(_ envelope: GridRTCLifecycleEventEnvelope) -> ReplaceableKey? {
    switch envelope.event {
    case .screenSharesChanged: .screenShares(envelope.room)
    case let .remoteAudioFramesObserved(identity): .remoteAudioFrames(envelope.room, identity)
    default: nil
    }
  }

  private func next() async -> GridRTCLifecycleEventEnvelope? {
    await withCheckedContinuation { continuation in
      // Resume outside the lock, including when cancellation already finished
      // the stream before this continuation was installed.
      let ready: (Bool, GridRTCLifecycleEventEnvelope?) = lock.withLock {
        if !pending.isEmpty { return (true, pending.removeFirst()) }
        if finished { return (true, nil) }
        precondition(waiter == nil, "Grid lifecycle events require one consumer")
        waiter = continuation
        return (false, nil)
      }
      if ready.0 { continuation.resume(returning: ready.1) }
    }
  }
}
