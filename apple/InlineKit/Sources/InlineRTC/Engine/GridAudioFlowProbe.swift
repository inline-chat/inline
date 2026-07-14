import AVFoundation
import Atomics
import Foundation
import LiveKit

/// Counts PCM delivery without logging or allocating on Core Audio's real-time
/// render callback. Callers compare snapshots from an ordinary task to diagnose
/// capture and playout independently from signaling state.
final class GridAudioFlowProbe: NSObject, AudioRenderer, @unchecked Sendable {
  struct Snapshot: Equatable, Sendable {
    let frameCount: UInt64
    let sampleFormat: UInt
  }

  private let frameCount = ManagedAtomic<UInt64>(0)
  private let sampleFormat = ManagedAtomic<UInt>(0)

  func render(pcmBuffer: AVAudioPCMBuffer) {
    frameCount.wrappingIncrement(ordering: .relaxed)
    sampleFormat.store(pcmBuffer.format.commonFormat.rawValue, ordering: .relaxed)
  }

  func snapshot() -> Snapshot {
    Snapshot(
      frameCount: frameCount.load(ordering: .relaxed),
      sampleFormat: sampleFormat.load(ordering: .relaxed)
    )
  }
}
