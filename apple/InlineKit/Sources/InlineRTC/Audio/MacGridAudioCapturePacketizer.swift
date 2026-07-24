#if os(macOS)
import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import LiveKit

/// Converts variable AUHAL capture slices into the exact 10 ms packets used by
/// WebRTC's audio-processing pipeline. Storage is allocated once on the
/// control plane; `append` performs bounded copies only.
final class MacGridAudioCapturePacketizer: @unchecked Sendable {
  static let sampleRate = 48_000.0
  static let framesPerPacket: UInt32 = 480
  /// Core Audio host timestamps describe the physical callback timeline. A
  /// small allowance covers conversion rounding; a larger mismatch means a
  /// partial packet must not span two physical clock epochs.
  private static let maximumContinuityErrorNanoseconds: UInt64 = 5_000_000

  private let packetBuffer: AVAudioPCMBuffer
  private let packetData: UnsafeMutablePointer<Int16>
  private var packetStartTimestamp: AudioTimeStamp?
  private var bufferedFrames: UInt32 = 0
  private var previousCallbackHostTime: UInt64?
  private var previousCallbackFrameCount: UInt32 = 0
  private(set) var timestampDiscontinuityCount: UInt64 = 0
  /// Frames in the current verified physical timestamp epoch. Lifetime anomaly
  /// counters remain diagnostic, while this rolling fact allows a route to
  /// become healthy again after fresh contiguous audio proves recovery.
  private(set) var continuousFrameCount: UInt64 = 0

  init() throws {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Self.sampleRate,
      channels: 1,
      interleaved: true
    ), let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(Self.framesPerPacket)
    ) else {
      throw MacGridCoreAudioError.unavailable(
        "The WebRTC capture packet format is unavailable."
      )
    }
    buffer.frameLength = AVAudioFrameCount(Self.framesPerPacket)
    guard let data = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
      throw MacGridCoreAudioError.unavailable(
        "The WebRTC capture packet buffer has no storage."
      )
    }
    packetBuffer = buffer
    // SAFETY: `buffer` was created as interleaved signed Int16 PCM with a
    // capacity of `framesPerPacket`. It strongly owns `mData` for the lifetime
    // of this packetizer, and the pointer is only accessed within that capacity.
    packetData = data.assumingMemoryBound(to: Int16.self)
  }

  var pendingFrameCount: UInt32 { bufferedFrames }

  func reset() {
    bufferedFrames = 0
    packetStartTimestamp = nil
    previousCallbackHostTime = nil
    previousCallbackFrameCount = 0
    timestampDiscontinuityCount = 0
    continuousFrameCount = 0
  }

  /// Appends mono, 48 kHz, signed 16-bit PCM and synchronously emits complete
  /// 480-frame packets. The first physical host timestamp survives callbacks
  /// that straddle a packet boundary. `Span` prevents callback-owned samples
  /// from escaping this synchronous operation.
  func append(
    samples: borrowing Swift.Span<Int16>,
    timestamp: AudioTimeStamp,
    actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    delegate: any CustomAudioDeviceDelegate
  ) -> OSStatus {
    let frameCount = UInt32(samples.count)
    return samples.withUnsafeBufferPointer { samples in
      append(
        samples: samples,
        frameCount: frameCount,
        timestamp: timestamp,
        actionFlags: actionFlags,
        delegate: delegate
      )
    }
  }

  private func append(
    samples: UnsafeBufferPointer<Int16>,
    frameCount: UInt32,
    timestamp: AudioTimeStamp,
    actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    delegate: any CustomAudioDeviceDelegate
  ) -> OSStatus {
    guard let sampleStart = samples.baseAddress else {
      return frameCount == 0 ? noErr : kAudio_ParamError
    }
    guard timestamp.mFlags.contains(.hostTimeValid), timestamp.mHostTime > 0 else {
      bufferedFrames = 0
      packetStartTimestamp = nil
      previousCallbackHostTime = nil
      previousCallbackFrameCount = 0
      continuousFrameCount = 0
      timestampDiscontinuityCount &+= 1
      return kAudio_ParamError
    }
    if isTimestampDiscontinuous(timestamp) {
      // Dropping at most 479 pre-AEC frames is preferable to fabricating one
      // packet across a sleep, device reset, or route-clock discontinuity.
      // The lifetime count remains diagnostic; rolling contiguous frames must
      // subsequently re-prove health instead of poisoning this route forever.
      bufferedFrames = 0
      packetStartTimestamp = nil
      continuousFrameCount = 0
      timestampDiscontinuityCount &+= 1
    }
    rememberCallback(timestamp: timestamp, frameCount: frameCount)
    continuousFrameCount &+= UInt64(frameCount)
    var sourceOffset: UInt32 = 0
    while sourceOffset < frameCount {
      if bufferedFrames == 0 {
        packetStartTimestamp = Self.advanced(
          timestamp,
          byFrames: sourceOffset
        )
      }

      let available = Self.framesPerPacket - bufferedFrames
      let copiedFrames = min(available, frameCount - sourceOffset)
      let destination = packetData.advanced(by: Int(bufferedFrames))
      let source = sampleStart.advanced(by: Int(sourceOffset))
      // SAFETY: both pointers are Int16-aligned. `copiedFrames` is bounded by
      // the remaining source Span and the remaining 480-frame destination;
      // their storage is alive for this synchronous copy and does not overlap.
      UnsafeMutableRawPointer(destination).copyMemory(
        from: UnsafeRawPointer(source),
        byteCount: Int(copiedFrames) * MemoryLayout<Int16>.size
      )
      bufferedFrames += copiedFrames
      sourceOffset += copiedFrames

      guard bufferedFrames == Self.framesPerPacket,
            var packetTimestamp = packetStartTimestamp
      else { continue }

      let status = withUnsafePointer(to: &packetTimestamp) { timestampPointer in
        // SAFETY: `packetBuffer` owns this 480-frame AudioBufferList. Both it
        // and `timestampPointer` remain valid for the synchronous delegate
        // call; the LiveKit custom-device contract forbids retaining either.
        delegate.deliverRecordedData(
          CustomAudioDeviceRecordedData(
            context: CustomAudioDeviceIOContext(
              actionFlags: actionFlags,
              timestamp: timestampPointer,
              inputBusNumber: 1,
              frameCount: Self.framesPerPacket
            ),
            inputData: UnsafePointer(packetBuffer.mutableAudioBufferList)
          )
        )
      }
      bufferedFrames = 0
      packetStartTimestamp = nil
      guard status == noErr else { return status }
    }
    return noErr
  }

  private static func advanced(
    _ timestamp: AudioTimeStamp,
    byFrames frameOffset: UInt32
  ) -> AudioTimeStamp {
    guard frameOffset > 0 else { return timestamp }
    var result = timestamp
    if result.mFlags.contains(.sampleTimeValid) {
      result.mSampleTime += Double(frameOffset)
    }
    if result.mFlags.contains(.hostTimeValid) {
      let nanoseconds = UInt64(
        (Double(frameOffset) * 1_000_000_000 / sampleRate).rounded()
      )
      result.mHostTime &+= AudioConvertNanosToHostTime(nanoseconds)
    }
    return result
  }

  private func isTimestampDiscontinuous(_ timestamp: AudioTimeStamp) -> Bool {
    guard let previousCallbackHostTime else { return false }
    guard timestamp.mFlags.contains(.hostTimeValid), timestamp.mHostTime > 0 else {
      return true
    }
    let frameDurationNanoseconds = UInt64(
      (Double(previousCallbackFrameCount) * 1_000_000_000 / Self.sampleRate)
        .rounded()
    )
    let advance = AudioConvertNanosToHostTime(frameDurationNanoseconds)
    let (expectedHostTime, overflow) = previousCallbackHostTime.addingReportingOverflow(advance)
    guard !overflow else { return true }
    let difference = timestamp.mHostTime >= expectedHostTime
      ? timestamp.mHostTime - expectedHostTime
      : expectedHostTime - timestamp.mHostTime
    return AudioConvertHostTimeToNanos(difference)
      > Self.maximumContinuityErrorNanoseconds
  }

  private func rememberCallback(timestamp: AudioTimeStamp, frameCount: UInt32) {
    if timestamp.mFlags.contains(.hostTimeValid), timestamp.mHostTime > 0 {
      previousCallbackHostTime = timestamp.mHostTime
      previousCallbackFrameCount = frameCount
    } else {
      previousCallbackHostTime = nil
      previousCallbackFrameCount = 0
    }
  }
}
#endif
