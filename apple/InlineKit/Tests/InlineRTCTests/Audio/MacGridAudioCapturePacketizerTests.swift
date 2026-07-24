#if os(macOS)
import AudioToolbox
import Foundation
import LiveKit
import Testing

@testable import InlineRTC

@Suite("Mac Grid 10 ms capture packetizer")
struct MacGridAudioCapturePacketizerTests {
  @Test("preserves the first physical timestamp across callbacks")
  func preservesFirstTimestampAcrossCallbacks() throws {
    let packetizer = try MacGridAudioCapturePacketizer()
    let delegate = PacketDelegate()
    var flags: AudioUnitRenderActionFlags = []
    let firstHostTime = AudioGetCurrentHostTime()
    let first = [Int16](repeating: 11, count: 240)
    let second = [Int16](repeating: 22, count: 240)

    first.withUnsafeBufferPointer { samples in
      // SAFETY: the array owns `samples` for this closure, and the Span cannot
      // escape the synchronous packetizer call.
      let span = unsafe Swift.Span(_unsafeElements: samples)
      let status = packetizer.append(
        samples: span,
        timestamp: timestamp(hostTime: firstHostTime, sampleTime: 1_000),
        actionFlags: &flags,
        delegate: delegate
      )
      #expect(status == noErr)
    }
    #expect(delegate.packets.isEmpty)

    second.withUnsafeBufferPointer { samples in
      // SAFETY: the array owns `samples` for this closure, and the Span cannot
      // escape the synchronous packetizer call.
      let span = unsafe Swift.Span(_unsafeElements: samples)
      let status = packetizer.append(
        samples: span,
        timestamp: timestamp(
          hostTime: advanced(firstHostTime, byFrames: 240),
          sampleTime: 1_240
        ),
        actionFlags: &flags,
        delegate: delegate
      )
      #expect(status == noErr)
    }

    #expect(delegate.packets.count == 1)
    #expect(delegate.packets[0].timestamp.mHostTime == firstHostTime)
    #expect(delegate.packets[0].timestamp.mSampleTime == 1_000)
    #expect(delegate.packets[0].samples.prefix(240).allSatisfy { $0 == 11 })
    #expect(delegate.packets[0].samples.suffix(240).allSatisfy { $0 == 22 })
  }

  @Test("emits exact 480-frame packets without dropping callback overflow")
  func emitsExactPacketsWithoutDrops() throws {
    let packetizer = try MacGridAudioCapturePacketizer()
    let delegate = PacketDelegate()
    var flags: AudioUnitRenderActionFlags = []
    let firstHostTime = AudioGetCurrentHostTime()
    let samples = (0 ..< 1_440).map { Int16($0) }

    samples.withUnsafeBufferPointer { buffer in
      // SAFETY: the array owns this initialized storage for the closure. Each
      // derived Span stays within its bounds and cannot escape `append`.
      let allSamples = unsafe Swift.Span(_unsafeElements: buffer)
      let firstStatus = packetizer.append(
        samples: allSamples.extracting(0 ..< 512),
        timestamp: timestamp(hostTime: firstHostTime, sampleTime: 0),
        actionFlags: &flags,
        delegate: delegate
      )
      #expect(firstStatus == noErr)
      let secondStatus = packetizer.append(
        samples: allSamples.extracting(512 ..< 960),
        timestamp: timestamp(
          hostTime: advanced(firstHostTime, byFrames: 512),
          sampleTime: 512
        ),
        actionFlags: &flags,
        delegate: delegate
      )
      #expect(secondStatus == noErr)
      let thirdStatus = packetizer.append(
        samples: allSamples.extracting(960 ..< 1_440),
        timestamp: timestamp(
          hostTime: advanced(firstHostTime, byFrames: 960),
          sampleTime: 960
        ),
        actionFlags: &flags,
        delegate: delegate
      )
      #expect(thirdStatus == noErr)
    }

    #expect(delegate.packets.count == 3)
    #expect(delegate.packets.allSatisfy { $0.samples.count == 480 })
    #expect(delegate.packets.flatMap(\.samples) == samples)
    #expect(delegate.packets.map(\.timestamp.mSampleTime) == [0, 480, 960])
    #expect(delegate.packets[1].timestamp.mHostTime == advanced(firstHostTime, byFrames: 480))
  }

  @Test("never combines samples across a physical host-time discontinuity")
  func dropsPartialPacketAcrossHostTimeDiscontinuity() throws {
    let packetizer = try MacGridAudioCapturePacketizer()
    let delegate = PacketDelegate()
    var flags: AudioUnitRenderActionFlags = []
    let firstHostTime = AudioGetCurrentHostTime()
    let resetHostTime = advanced(firstHostTime, byFrames: 24_000)

    append(
      [Int16](repeating: 11, count: 240),
      to: packetizer,
      timestamp: timestamp(hostTime: firstHostTime, sampleTime: 0),
      flags: &flags,
      delegate: delegate
    )
    append(
      [Int16](repeating: 22, count: 240),
      to: packetizer,
      timestamp: timestamp(hostTime: resetHostTime, sampleTime: 24_000),
      flags: &flags,
      delegate: delegate
    )
    append(
      [Int16](repeating: 33, count: 240),
      to: packetizer,
      timestamp: timestamp(
        hostTime: advanced(resetHostTime, byFrames: 240),
        sampleTime: 24_240
      ),
      flags: &flags,
      delegate: delegate
    )

    #expect(packetizer.timestampDiscontinuityCount == 1)
    #expect(packetizer.continuousFrameCount == 480)
    #expect(packetizer.pendingFrameCount == 0)
    #expect(delegate.packets.count == 1)
    #expect(delegate.packets[0].timestamp.mHostTime == resetHostTime)
    #expect(delegate.packets[0].samples.prefix(240).allSatisfy { $0 == 22 })
    #expect(delegate.packets[0].samples.suffix(240).allSatisfy { $0 == 33 })
    #expect(!delegate.packets[0].samples.contains(11))
  }

  @Test("missing physical host time is rejected until a fresh epoch arrives")
  func missingHostTimeDoesNotReachWebRTC() throws {
    let packetizer = try MacGridAudioCapturePacketizer()
    let delegate = PacketDelegate()
    var flags: AudioUnitRenderActionFlags = []

    append(
      [Int16](repeating: 11, count: 480),
      to: packetizer,
      timestamp: AudioTimeStamp(),
      flags: &flags,
      delegate: delegate,
      expectedStatus: kAudio_ParamError
    )
    #expect(delegate.packets.isEmpty)
    #expect(packetizer.continuousFrameCount == 0)

    append(
      [Int16](repeating: 22, count: 480),
      to: packetizer,
      timestamp: timestamp(hostTime: AudioGetCurrentHostTime(), sampleTime: 480),
      flags: &flags,
      delegate: delegate
    )
    #expect(delegate.packets.count == 1)
    #expect(packetizer.continuousFrameCount == 480)
  }

  private func append(
    _ samples: [Int16],
    to packetizer: MacGridAudioCapturePacketizer,
    timestamp: AudioTimeStamp,
    flags: inout AudioUnitRenderActionFlags,
    delegate: PacketDelegate,
    expectedStatus: OSStatus = noErr
  ) {
    samples.withUnsafeBufferPointer { samples in
      // SAFETY: the array owns `samples` for this closure, and the Span cannot
      // escape the synchronous packetizer call.
      let span = unsafe Swift.Span(_unsafeElements: samples)
      let status = packetizer.append(
        samples: span,
        timestamp: timestamp,
        actionFlags: &flags,
        delegate: delegate
      )
      #expect(status == expectedStatus)
    }
  }

  private func timestamp(hostTime: UInt64, sampleTime: Float64) -> AudioTimeStamp {
    var value = AudioTimeStamp()
    value.mHostTime = hostTime
    value.mSampleTime = sampleTime
    value.mFlags = [.hostTimeValid, .sampleTimeValid]
    return value
  }

  private func advanced(_ hostTime: UInt64, byFrames frames: UInt32) -> UInt64 {
    let nanoseconds = UInt64(
      (Double(frames) * 1_000_000_000 / MacGridAudioCapturePacketizer.sampleRate)
        .rounded()
    )
    return hostTime + AudioConvertNanosToHostTime(nanoseconds)
  }
}

private final class PacketDelegate: CustomAudioDeviceDelegate, @unchecked Sendable {
  struct Packet {
    let timestamp: AudioTimeStamp
    let samples: [Int16]
  }

  var packets: [Packet] = []
  let preferredInputSampleRate = 48_000.0
  let preferredInputIOBufferDuration: TimeInterval = 0.010
  let preferredOutputSampleRate = 48_000.0
  let preferredOutputIOBufferDuration: TimeInterval = 0.010

  func getPlayoutData(
    _: CustomAudioDeviceIOContext,
    outputData _: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus {
    noErr
  }

  func deliverRecordedData(_ data: CustomAudioDeviceRecordedData) -> OSStatus {
    let buffer = data.inputData.pointee.mBuffers
    guard let rawData = buffer.mData else { return kAudio_ParamError }
    let samples = Array(
      UnsafeBufferPointer(
        start: rawData.assumingMemoryBound(to: Int16.self),
        count: Int(data.context.frameCount)
      )
    )
    packets.append(Packet(timestamp: data.context.timestamp.pointee, samples: samples))
    return noErr
  }

  func notifyAudioInputParametersChange() {}
  func notifyAudioOutputParametersChange() {}
  func notifyAudioInputInterrupted() {}
  func notifyAudioOutputInterrupted() {}
  func dispatchAsync(_ block: @escaping @Sendable () -> Void) { block() }
  func dispatchSync(_ block: @escaping @Sendable () -> Void) { block() }
}
#endif
