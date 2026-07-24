import Foundation

/// Synchronous, order-preserving ingress for the process media actor.
///
/// The UI can submit desired state without spawning caller-owned Tasks. Only
/// consecutive complete-demand values are replaceable; lifecycle boundaries
/// and shutdown acknowledgements remain lossless. Repeated idempotent nudges
/// are retained at most once in the current shutdown-delimited segment.
final class GridEngineCommandMailbox: @unchecked Sendable {
  let signals: AsyncStream<Void>

  private let signalContinuation: AsyncStream<Void>.Continuation
  private let lock = NSLock()
  private var queue: [GridEngineCommand] = []
  private var finished = false

  init() {
    let stream = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    signals = stream.stream
    signalContinuation = stream.continuation
  }

  func enqueue(_ command: GridEngineCommand) {
    let shouldSignal = lock.withLock {
      guard !finished else { return false }
      if case .setDemand = command,
         let last = queue.indices.last,
         case .setDemand = queue[last] {
        queue[last] = command
        return true
      }
      if let key = command.coalescingKey,
         currentSegmentContains(key) {
        return false
      }
      queue.append(command)
      return true
    }
    if shouldSignal { signalContinuation.yield(()) }
  }

  func dequeue() -> GridEngineCommand? {
    lock.withLock {
      guard !queue.isEmpty else { return nil }
      return queue.removeFirst()
    }
  }

  func finish() {
    let shouldFinish = lock.withLock {
      guard !finished else { return false }
      finished = true
      queue.removeAll()
      return true
    }
    if shouldFinish { signalContinuation.finish() }
  }

  var pendingCount: Int {
    lock.withLock { queue.count }
  }

  private func currentSegmentContains(_ key: GridEngineCommand.CoalescingKey) -> Bool {
    for command in queue.reversed() {
      switch command {
      case .setDemand, .retryInput, .retryOutput, .shutdown:
        return false
      default:
        break
      }
      if command.coalescingKey == key { return true }
    }
    return false
  }
}

private extension GridEngineCommand {
  enum CoalescingKey: Equatable {
    case refreshDevices
    case requestMicrophonePermission
    case retryAudio
    case networkBecameAvailable
    case applicationDidWake
  }

  var coalescingKey: CoalescingKey? {
    switch self {
    case .refreshDevices: .refreshDevices
    case .requestMicrophonePermission: .requestMicrophonePermission
    case .retryAudio: .retryAudio
    case .networkBecameAvailable: .networkBecameAvailable
    case .applicationDidWake: .applicationDidWake
    case .setDemand, .retryInput, .retryOutput, .shutdown: nil
    }
  }
}
