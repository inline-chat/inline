#if os(macOS)
import Atomics
import Foundation

/// Single-producer/single-consumer PCM storage between LiveKit's mixed-audio
/// callback and Core Audio's output callback. The consumer never allocates or
/// waits on a lock; an underrun is rendered as silence.
final class MacGridAudioSampleBuffer: @unchecked Sendable {
  let capacity: Int

  var availableCount: Int {
    let read = readIndex.load(ordering: .acquiring)
    let write = writeIndex.load(ordering: .acquiring)
    return min(Int(write &- read), capacity)
  }

  private let storage: UnsafeMutablePointer<Float>
  private let readIndex = ManagedAtomic<UInt64>(0)
  private let writeIndex = ManagedAtomic<UInt64>(0)

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
    storage = .allocate(capacity: capacity)
    storage.initialize(repeating: 0, count: capacity)
  }

  deinit {
    storage.deinitialize(count: capacity)
    storage.deallocate()
  }

  /// Writes a complete PCM chunk or drops it if the consumer has fallen more
  /// than one buffer behind. Keeping chunk boundaries avoids partial WebRTC
  /// packets and bounds playout latency during an output-device stall.
  @discardableResult
  func write(_ source: UnsafeBufferPointer<Float>) -> Int {
    guard !source.isEmpty, source.count <= capacity else { return 0 }
    let write = writeIndex.load(ordering: .relaxed)
    let read = readIndex.load(ordering: .acquiring)
    let available = min(Int(write &- read), capacity)
    guard source.count <= capacity - available else { return 0 }

    for offset in source.indices {
      storage[Int((write &+ UInt64(offset)) % UInt64(capacity))] = source[offset]
    }
    writeIndex.store(write &+ UInt64(source.count), ordering: .releasing)
    return source.count
  }

  /// Reads available samples in FIFO order and zero-fills the remainder.
  @discardableResult
  func read(into destination: UnsafeMutableBufferPointer<Float>) -> Int {
    guard !destination.isEmpty else { return 0 }
    let read = readIndex.load(ordering: .relaxed)
    let write = writeIndex.load(ordering: .acquiring)
    let count = min(destination.count, min(Int(write &- read), capacity))

    if count > 0 {
      for offset in 0 ..< count {
        destination[offset] = storage[Int((read &+ UInt64(offset)) % UInt64(capacity))]
      }
      readIndex.store(read &+ UInt64(count), ordering: .releasing)
    }
    if count < destination.count {
      destination.baseAddress?.advanced(by: count).initialize(
        repeating: 0,
        count: destination.count - count
      )
    }
    return count
  }
}

enum MacGridAudioPlayoutRead: Equatable, Sendable {
  case buffering
  case playing
  case underflow(samplesRead: Int)
}

/// Adds a small, bounded phase buffer between WebRTC's fixed-duration PCM
/// packets and Core Audio's device-sized render callbacks. After an underrun,
/// playout returns to silence until the same threshold is rebuilt instead of
/// alternating a short packet with a zero-filled tail on every callback.
final class MacGridAudioPlayoutBuffer: @unchecked Sendable {
  let startupThreshold: Int

  private let samples: MacGridAudioSampleBuffer
  /// Only the Core Audio consumer callback reads or writes this flag.
  private var primed = false

  init(capacity: Int, startupThreshold: Int) {
    precondition(startupThreshold > 0 && startupThreshold <= capacity)
    samples = MacGridAudioSampleBuffer(capacity: capacity)
    self.startupThreshold = startupThreshold
  }

  @discardableResult
  func write(_ source: UnsafeBufferPointer<Float>) -> Int {
    samples.write(source)
  }

  func read(into destination: UnsafeMutableBufferPointer<Float>) -> MacGridAudioPlayoutRead {
    if !primed {
      guard samples.availableCount >= startupThreshold else {
        zero(destination)
        return .buffering
      }
      primed = true
    }

    let count = samples.read(into: destination)
    guard count == destination.count else {
      primed = false
      return .underflow(samplesRead: count)
    }
    return .playing
  }

  private func zero(_ destination: UnsafeMutableBufferPointer<Float>) {
    for index in destination.indices {
      destination[index] = 0
    }
  }
}
#endif
