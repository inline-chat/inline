#if os(macOS)
import AudioToolbox
import Darwin
import Foundation
@testable import InlineRTC
import LiveKit
import Testing

@Suite("Mac Grid stable WebRTC audio bridge", .serialized)
struct MacGridWebRTCAudioBridgeTests {
  @Test("capture callbacks from different callers reach WebRTC on one worker")
  func captureUsesStableWorker() throws {
    let upstream = BridgeDelegate()
    let bridge = try MacGridWebRTCAudioBridge(upstream: upstream)
    defer { bridge.shutdown() }
    #expect(bridge.setRecordingActive(true))

    let firstPhysicalThread = currentThreadID()
    #expect(deliverCapturePacket(to: bridge, hostTime: 100) == noErr)
    #expect(upstream.waitForCapture(count: 1))

    let secondPhysicalThread = LockedValue<UInt64>(0)
    let physicalCallbackFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInteractive).async {
      secondPhysicalThread.set(currentThreadID())
      _ = deliverCapturePacket(to: bridge, hostTime: 200)
      physicalCallbackFinished.signal()
    }
    #expect(physicalCallbackFinished.wait(timeout: .now() + 1) == .success)
    #expect(upstream.waitForCapture(count: 2))

    let workerThreads = upstream.captureThreadIDs
    #expect(workerThreads.count == 2)
    #expect(workerThreads.first == workerThreads.last)
    #expect(workerThreads.first != firstPhysicalThread)
    #expect(workerThreads.first != secondPhysicalThread.value)
    let snapshot = bridge.snapshot()
    #expect(snapshot.captureWorkerActive)
    #expect(snapshot.captureHasDeliveredForCurrentActivation)
    #expect(snapshot.capturedPacketCount == 2)
    #expect(snapshot.lastCaptureDeliveryStatus == noErr)
    #expect(bridge.setRecordingActive(false))
  }

  @Test("native capture rates convert to exact WebRTC packets on the stable worker")
  func nativeCaptureRatesConvertOnStableWorker() throws {
    for nativeSampleRate in [24_000.0, 44_100.0, 48_000.0] {
      let upstream = BridgeDelegate()
      let bridge = try MacGridWebRTCAudioBridge(upstream: upstream)
      #expect(bridge.configureCaptureFormat(nativeSampleRate: nativeSampleRate))
      #expect(bridge.setRecordingActive(true))

      let nativeFrames = UInt32(nativeSampleRate / 100)
      let startHostTime = AudioGetCurrentHostTime()
      for index in 0..<4 {
        #expect(deliverNativeCaptureSlice(
          to: bridge,
          frameCount: nativeFrames,
          hostTime: startHostTime &+ AudioConvertNanosToHostTime(
            UInt64(index) * 10_000_000
          )
        ) == noErr)
      }

      #expect(upstream.waitForCapture(count: 4))
      let snapshot = bridge.snapshot()
      #expect(snapshot.captureNativeSampleRate == nativeSampleRate)
      #expect(snapshot.captureHasDeliveredForCurrentActivation)
      #expect(snapshot.captureConversionErrorCount == 0)
      #expect(snapshot.lastCaptureConversionStatus == noErr)
      #expect(snapshot.capturePacketizationErrorCount == 0)
      #expect(snapshot.lastCapturePacketizationStatus == noErr)
      #expect(upstream.captureFrameCounts == [480, 480, 480, 480])
      #expect(upstream.capturePeakSamples.allSatisfy { $0 > 7_000 && $0 < 10_000 })
      #expect(Set(upstream.captureThreadIDs).count == 1)
      #expect(bridge.setRecordingActive(false))
      bridge.shutdown()
    }
  }

  @Test("one large native slice can emit more packets than the callback ring")
  func largeNativeSliceIsDeliveredDirectlyFromWorker() throws {
    let upstream = BridgeDelegate()
    let bridge = try MacGridWebRTCAudioBridge(upstream: upstream)
    defer { bridge.shutdown() }
    #expect(bridge.configureCaptureFormat(nativeSampleRate: 24_000))
    #expect(bridge.setRecordingActive(true))

    #expect(deliverNativeCaptureSlice(
      to: bridge,
      frameCount: 4_096,
      hostTime: AudioGetCurrentHostTime()
    ) == noErr)

    // 4,096 native frames become 8,192 WebRTC frames: seventeen complete
    // 480-frame packets plus a 32-frame packetizer remainder. This exceeds
    // the callback packet ring's capacity and proves the worker bypasses it.
    #expect(upstream.waitForCapture(count: 17))
    let snapshot = bridge.snapshot()
    #expect(snapshot.capturedPacketCount == 17)
    #expect(snapshot.captureOverflowCount == 0)
    #expect(snapshot.captureConversionErrorCount == 0)
    #expect(snapshot.capturePacketizationErrorCount == 0)
    #expect(snapshot.captureQueuedFrames == 32)
    #expect(bridge.setRecordingActive(false))
  }

  @Test("invalid capture timestamps are packetization failures, not conversion failures")
  func invalidCaptureTimestampHasTruthfulBoundary() throws {
    let upstream = BridgeDelegate()
    let bridge = try MacGridWebRTCAudioBridge(upstream: upstream)
    defer { bridge.shutdown() }
    #expect(bridge.configureCaptureFormat(nativeSampleRate: 48_000))
    #expect(bridge.setRecordingActive(true))

    #expect(deliverNativeCaptureSlice(
      to: bridge,
      frameCount: 480,
      hostTime: 0,
      timestampFlags: []
    ) == noErr)
    #expect(waitUntil {
      bridge.snapshot().capturePacketizationErrorCount == 1
    })

    let snapshot = bridge.snapshot()
    #expect(snapshot.captureConversionErrorCount == 0)
    #expect(snapshot.lastCaptureConversionStatus == noErr)
    #expect(snapshot.capturePacketizationErrorCount == 1)
    #expect(snapshot.lastCapturePacketizationStatus == kAudio_ParamError)
    #expect(snapshot.captureDeliveryErrorCount == 0)
  }

  @Test("playout route generations keep one stable WebRTC worker")
  func playoutUsesStableWorker() throws {
    let upstream = BridgeDelegate()
    let bridge = try MacGridWebRTCAudioBridge(upstream: upstream)
    defer { bridge.shutdown() }
    #expect(bridge.setPlayoutActive(true))

    var firstOutput = [Int16](repeating: -1, count: 480 * 2)
    let firstPhysicalThread = currentThreadID()
    let firstPull = pullPlayout(
      from: bridge,
      into: &firstOutput,
      hostTime: 300
    )
    #expect(firstPull.status == noErr)
    #expect(firstPull.flags.contains(.unitRenderAction_OutputIsSilence))
    #expect(firstOutput.allSatisfy { $0 == 0 })
    #expect(upstream.waitForPlayout(count: 1))

    var secondOutput = [Int16](repeating: 0, count: 480 * 2)
    let secondPull = pullPlayout(
      from: bridge,
      into: &secondOutput,
      hostTime: 400
    )
    #expect(secondPull.status == noErr)
    #expect(!secondPull.flags.contains(.unitRenderAction_OutputIsSilence))
    #expect(secondOutput.allSatisfy { $0 == BridgeDelegate.playoutSample })
    #expect(upstream.waitForPlayout(count: 2))

    // A rebuilt AUHAL may invoke its callback from another Core Audio thread.
    // WebRTC's ObjC ADM permanently binds its playout thread checker to the
    // first caller, so a route generation must never move the upstream call to
    // that replacement physical thread.
    #expect(bridge.setPlayoutActive(false))
    #expect(bridge.setPlayoutActive(true, forceTransition: true))
    let pullsBeforeReplacementCallback = upstream.playoutThreadIDs.count
    let replacementPhysicalThread = LockedValue<UInt64>(0)
    let replacementCallbackFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInteractive).async {
      replacementPhysicalThread.set(currentThreadID())
      var replacementOutput = [Int16](repeating: -1, count: 480 * 2)
      _ = pullPlayout(
        from: bridge,
        into: &replacementOutput,
        hostTime: 500
      )
      replacementCallbackFinished.signal()
    }
    #expect(replacementCallbackFinished.wait(timeout: .now() + 1) == .success)
    #expect(upstream.waitForPlayout(count: pullsBeforeReplacementCallback + 1))
    #expect(waitUntil {
      bridge.snapshot().playoutHasPulledForCurrentActivation
    })

    let workerThreads = upstream.playoutThreadIDs
    #expect(workerThreads.count > pullsBeforeReplacementCallback)
    #expect(Set(workerThreads).count == 1)
    #expect(workerThreads.first != firstPhysicalThread)
    #expect(workerThreads.first != replacementPhysicalThread.value)
    let snapshot = bridge.snapshot()
    #expect(snapshot.playoutWorkerActive)
    #expect(snapshot.playoutHasPulledForCurrentActivation)
    #expect(snapshot.playoutPullCount >= 2)
    #expect(snapshot.lastPlayoutPullStatus == noErr)
    #expect(bridge.setPlayoutActive(false))
  }

  @Test("partial playout underrun preserves real PCM and is reported separately")
  func partialPlayoutUnderrunIsNotWholeBufferSilence() throws {
    let upstream = BridgeDelegate()
    let bridge = try MacGridWebRTCAudioBridge(upstream: upstream)
    defer { bridge.shutdown() }
    #expect(bridge.setPlayoutActive(true))

    var primingOutput = [Int16](repeating: -1, count: 480 * 2)
    let primingPull = pullPlayout(
      from: bridge,
      into: &primingOutput,
      hostTime: 500
    )
    #expect(primingPull.flags.contains(.unitRenderAction_OutputIsSilence))
    #expect(upstream.waitForPlayout(count: 3))

    var partialOutput = [Int16](repeating: -1, count: 1_920 * 2)
    let partialPull = pullPlayout(
      from: bridge,
      into: &partialOutput,
      hostTime: 600,
      frameCount: 1_920
    )

    #expect(partialPull.status == noErr)
    #expect(!partialPull.flags.contains(.unitRenderAction_OutputIsSilence))
    #expect(partialOutput.prefix(1_440 * 2).allSatisfy { $0 == BridgeDelegate.playoutSample })
    #expect(partialOutput.dropFirst(1_440 * 2).allSatisfy { $0 == 0 })
    let snapshot = bridge.snapshot()
    #expect(snapshot.latestPlayoutRequestedFrames == 1_920)
    #expect(snapshot.latestPlayoutCopiedFrames == 1_440)
    #expect(snapshot.latestPlayoutCallbackHadUnderrun)
    #expect(snapshot.consecutivePlayoutMissingFrames == 960)
  }

  @Test("playout underrun health is rolling and frame bounded")
  func playoutUnderrunHealthIsRolling() {
    #expect(
      MacGridWebRTCAudioBridge.updatedConsecutiveMissingFrames(
        previous: 0,
        requested: 1_920,
        copied: 1_440
      ) == 480
    )
    #expect(
      MacGridWebRTCAudioBridge.updatedConsecutiveMissingFrames(
        previous: 480,
        requested: 480,
        copied: 0
      ) == 960
    )
    #expect(
      MacGridWebRTCAudioBridge.updatedConsecutiveMissingFrames(
        previous: 960,
        requested: 480,
        copied: 480
      ) == 0
    )
    #expect(
      MacGridWebRTCAudioBridge.updatedConsecutiveMissingFrames(
        previous: .max,
        requested: 480,
        copied: 0
      ) == .max
    )
  }

  @Test("playout queue target accounts for device rate conversion")
  func playoutTargetAccountsForDeviceRate() {
    #expect(
      MacGridWebRTCAudioBridge.playoutTargetFrames(
        deviceBufferFrames: 480,
        deviceSampleRate: 48_000
      ) == 1_440
    )
    #expect(
      MacGridWebRTCAudioBridge.playoutTargetFrames(
        deviceBufferFrames: 512,
        deviceSampleRate: 24_000
      ) == 1_920
    )
    #expect(
      MacGridWebRTCAudioBridge.playoutTargetFrames(
        deviceBufferFrames: 2_048,
        deviceSampleRate: 48_000
      ) == 2_880
    )
  }

  @Test("terminal bridge rejects late callbacks without touching destroyed wakes")
  func callbacksAfterShutdownAreSafe() throws {
    let upstream = BridgeDelegate()
    let bridge = try MacGridWebRTCAudioBridge(upstream: upstream)
    #expect(bridge.setRecordingActive(true))
    #expect(bridge.setPlayoutActive(true))
    bridge.shutdown()

    #expect(deliverCapturePacket(to: bridge, hostTime: 700) == noErr)
    #expect(upstream.captureThreadIDs.isEmpty)

    var output = [Int16](repeating: -1, count: 480 * 2)
    let result = pullPlayout(from: bridge, into: &output, hostTime: 800)
    #expect(result.status == noErr)
    #expect(result.flags.contains(.unitRenderAction_OutputIsSilence))
    #expect(output.allSatisfy { $0 == 0 })
    #expect(upstream.playoutThreadIDs.isEmpty)
  }

  @Test("capture ring preserves packets across wrap and full boundaries")
  func captureRingWraparound() {
    let ring = MacGridCapturePacketRing(framesPerPacket: 4, packetCapacity: 3)

    func write(_ value: Int16, hostTime: UInt64) -> Bool {
      let packet = [Int16](repeating: value, count: 4)
      var timestamp = AudioTimeStamp()
      timestamp.mHostTime = hostTime
      timestamp.mFlags = .hostTimeValid
      return packet.withUnsafeBufferPointer { samples in
        ring.write(
          samples: samples.baseAddress!,
          timestamp: timestamp,
          actionFlags: [],
          busNumber: 1
        )
      }
    }

    var observed: [(Int16, UInt64)] = []
    func read() -> Bool {
      ring.read { samples, metadata in
        observed.append((samples[0], metadata.timestamp.mHostTime))
      }
    }

    #expect(write(1, hostTime: 101))
    #expect(write(2, hostTime: 102))
    #expect(write(3, hostTime: 103))
    #expect(!write(4, hostTime: 104))
    #expect(ring.availablePacketCount == 3)
    #expect(read())
    #expect(read())
    #expect(write(4, hostTime: 104))
    #expect(write(5, hostTime: 105))
    #expect(read())
    #expect(read())
    #expect(read())
    #expect(!read())
    #expect(observed.map(\.0) == [1, 2, 3, 4, 5])
    #expect(observed.map(\.1) == [101, 102, 103, 104, 105])
  }

  @Test("native capture ring preserves variable slices across wrap and full boundaries")
  func nativeCaptureRingWraparound() {
    let ring = MacGridNativeCaptureSliceRing(
      maximumFramesPerSlice: 4,
      sliceCapacity: 2
    )

    func write(_ value: Float, frames: UInt32, hostTime: UInt64) -> Bool {
      let slice = [Float](repeating: value, count: Int(frames))
      var timestamp = AudioTimeStamp()
      timestamp.mHostTime = hostTime
      timestamp.mFlags = .hostTimeValid
      return slice.withUnsafeBufferPointer { samples in
        ring.write(
          samples: samples.baseAddress!,
          frameCount: frames,
          timestamp: timestamp,
          actionFlags: [],
          busNumber: 1
        )
      }
    }

    var observed: [(Float, UInt32, UInt64)] = []
    func read() -> Bool {
      ring.read { samples, metadata in
        observed.append((
          samples[0],
          metadata.frameCount,
          metadata.timestamp.mHostTime
        ))
      }
    }

    #expect(write(1, frames: 2, hostTime: 101))
    #expect(write(2, frames: 4, hostTime: 102))
    #expect(!write(3, frames: 1, hostTime: 103))
    #expect(ring.availableSliceCount == 2)
    #expect(ring.availableFrameCount == 6)
    #expect(read())
    #expect(write(3, frames: 3, hostTime: 103))
    #expect(read())
    #expect(read())
    #expect(!read())
    #expect(ring.availableFrameCount == 0)
    #expect(observed.map(\.0) == [1, 2, 3])
    #expect(observed.map(\.1) == [2, 4, 3])
    #expect(observed.map(\.2) == [101, 102, 103])
  }

  @Test("playout ring preserves interleaved PCM across wrap and underflow")
  func playoutRingWraparound() {
    let ring = MacGridPlayoutSampleRing(channels: 2, capacityFrames: 5)
    let first: [Int16] = [10, 11, 20, 21, 30, 31]
    let second: [Int16] = [40, 41, 50, 51, 60, 61, 70, 71]
    #expect(first.withUnsafeBufferPointer {
      ring.write(samples: $0.baseAddress!, frameCount: 3)
    })

    var prefix = [Int16](repeating: -1, count: 4)
    let prefixFrames = prefix.withUnsafeMutableBufferPointer {
      ring.read(into: $0.baseAddress!, maximumFrames: 2)
    }
    #expect(prefixFrames == 2)
    #expect(prefix == [10, 11, 20, 21])
    #expect(second.withUnsafeBufferPointer {
      ring.write(samples: $0.baseAddress!, frameCount: 4)
    })
    #expect(!first.withUnsafeBufferPointer {
      ring.write(samples: $0.baseAddress!, frameCount: 1)
    })

    var remainder = [Int16](repeating: -1, count: 10)
    let remainderFrames = remainder.withUnsafeMutableBufferPointer {
      ring.read(into: $0.baseAddress!, maximumFrames: 5)
    }
    #expect(remainderFrames == 5)
    #expect(remainder == [30, 31, 40, 41, 50, 51, 60, 61, 70, 71])
    #expect(remainder.withUnsafeMutableBufferPointer {
      ring.read(into: $0.baseAddress!, maximumFrames: 5)
    } == 0)
  }

  @Test("capture SPSC publication remains ordered under sustained concurrency")
  func captureRingConcurrentStress() throws {
    let ring = MacGridCapturePacketRing(framesPerPacket: 4, packetCapacity: 8)
    let failure = LockedValue<String?>(nil)
    let producerFinished = DispatchSemaphore(value: 0)
    let consumerFinished = DispatchSemaphore(value: 0)
    let packetCount = 20_000

    DispatchQueue.global(qos: .userInteractive).async {
      var packet = [Int16](repeating: 0, count: 4)
      for index in 0..<packetCount {
        packet.withUnsafeMutableBufferPointer { samples in
          samples.update(repeating: Int16(index % 30_000))
        }
        var timestamp = AudioTimeStamp()
        timestamp.mHostTime = UInt64(index + 1)
        timestamp.mFlags = .hostTimeValid
        while !packet.withUnsafeBufferPointer({ samples in
          ring.write(
            samples: samples.baseAddress!,
            timestamp: timestamp,
            actionFlags: [],
            busNumber: 1
          )
        }) {
          sched_yield()
        }
      }
      producerFinished.signal()
    }

    DispatchQueue.global(qos: .userInteractive).async {
      var expected = 0
      while expected < packetCount {
        let consumed = ring.read { samples, metadata in
          let expectedSample = Int16(expected % 30_000)
          if samples[0] != expectedSample
            || samples[3] != expectedSample
            || metadata.timestamp.mHostTime != UInt64(expected + 1) {
            failure.set("capture packet \(expected) was torn or reordered")
          }
          expected += 1
        }
        if !consumed { sched_yield() }
      }
      consumerFinished.signal()
    }

    try #require(producerFinished.wait(timeout: .now() + 5) == .success)
    try #require(consumerFinished.wait(timeout: .now() + 5) == .success)
    #expect(failure.value == nil)
    #expect(ring.availablePacketCount == 0)
  }

  @Test("native capture SPSC publication remains ordered under sustained concurrency")
  func nativeCaptureRingConcurrentStress() throws {
    let ring = MacGridNativeCaptureSliceRing(
      maximumFramesPerSlice: 4,
      sliceCapacity: 8
    )
    let failure = LockedValue<String?>(nil)
    let producerFinished = DispatchSemaphore(value: 0)
    let consumerFinished = DispatchSemaphore(value: 0)
    let sliceCount = 20_000

    DispatchQueue.global(qos: .userInteractive).async {
      var slice = [Float](repeating: 0, count: 4)
      for index in 0..<sliceCount {
        let frameCount = UInt32(index % 4 + 1)
        slice.withUnsafeMutableBufferPointer { samples in
          samples.update(repeating: Float(index))
        }
        var timestamp = AudioTimeStamp()
        timestamp.mHostTime = UInt64(index + 1)
        timestamp.mFlags = .hostTimeValid
        while !slice.withUnsafeBufferPointer({ samples in
          ring.write(
            samples: samples.baseAddress!,
            frameCount: frameCount,
            timestamp: timestamp,
            actionFlags: [],
            busNumber: 1
          )
        }) {
          sched_yield()
        }
      }
      producerFinished.signal()
    }

    DispatchQueue.global(qos: .userInteractive).async {
      var expected = 0
      while expected < sliceCount {
        let consumed = ring.read { samples, metadata in
          let expectedFrames = UInt32(expected % 4 + 1)
          if samples[0] != Float(expected)
            || samples[Int(expectedFrames - 1)] != Float(expected)
            || metadata.frameCount != expectedFrames
            || metadata.timestamp.mHostTime != UInt64(expected + 1) {
            failure.set("native capture slice \(expected) was torn or reordered")
          }
          expected += 1
        }
        if !consumed { sched_yield() }
      }
      consumerFinished.signal()
    }

    try #require(producerFinished.wait(timeout: .now() + 5) == .success)
    try #require(consumerFinished.wait(timeout: .now() + 5) == .success)
    #expect(failure.value == nil)
    #expect(ring.availableSliceCount == 0)
  }

  @Test("playout SPSC publication remains ordered under sustained concurrency")
  func playoutRingConcurrentStress() throws {
    let channels = 2
    let framesPerWrite = 37
    let maximumReadFrames = 23
    let writeCount = 10_000
    let totalFrames = framesPerWrite * writeCount
    let ring = MacGridPlayoutSampleRing(channels: UInt32(channels), capacityFrames: 257)
    let failure = LockedValue<String?>(nil)
    let producerFinished = DispatchSemaphore(value: 0)
    let consumerFinished = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInteractive).async {
      var source = [Int16](repeating: 0, count: framesPerWrite * channels)
      for writeIndex in 0..<writeCount {
        let firstFrame = writeIndex * framesPerWrite
        for frameOffset in 0..<framesPerWrite {
          let sample = Int16((firstFrame + frameOffset) % 30_000)
          source[frameOffset * channels] = sample
          source[frameOffset * channels + 1] = sample
        }
        while !source.withUnsafeBufferPointer({ samples in
          ring.write(samples: samples.baseAddress!, frameCount: UInt32(framesPerWrite))
        }) {
          sched_yield()
        }
      }
      producerFinished.signal()
    }

    DispatchQueue.global(qos: .userInteractive).async {
      var destination = [Int16](
        repeating: -1,
        count: maximumReadFrames * channels
      )
      var consumedFrames = 0
      while consumedFrames < totalFrames {
        let requestedFrames = min(maximumReadFrames, totalFrames - consumedFrames)
        let frames = destination.withUnsafeMutableBufferPointer { samples in
          ring.read(
            into: samples.baseAddress!,
            maximumFrames: UInt32(requestedFrames)
          )
        }
        if frames == 0 {
          sched_yield()
          continue
        }
        for frameOffset in 0..<Int(frames) {
          let expected = Int16((consumedFrames + frameOffset) % 30_000)
          if destination[frameOffset * channels] != expected
            || destination[frameOffset * channels + 1] != expected {
            failure.set("playout frame \(consumedFrames + frameOffset) was torn or reordered")
          }
        }
        consumedFrames += Int(frames)
      }
      consumerFinished.signal()
    }

    try #require(producerFinished.wait(timeout: .now() + 5) == .success)
    try #require(consumerFinished.wait(timeout: .now() + 5) == .success)
    #expect(failure.value == nil)
    #expect(ring.availableFrames == 0)
  }
}

private func deliverCapturePacket(
  to bridge: MacGridWebRTCAudioBridge,
  hostTime: UInt64
) -> OSStatus {
  var samples = [Int16](repeating: 7, count: 480)
  var timestamp = AudioTimeStamp()
  timestamp.mHostTime = hostTime
  timestamp.mFlags = .hostTimeValid
  var actionFlags = AudioUnitRenderActionFlags()
  return samples.withUnsafeMutableBytes { bytes in
    var bufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(bytes.count),
        mData: bytes.baseAddress
      )
    )
    return withUnsafePointer(to: &timestamp) { timestampPointer in
      withUnsafePointer(to: &bufferList) { bufferListPointer in
        bridge.deliverRecordedData(
          CustomAudioDeviceRecordedData(
            context: CustomAudioDeviceIOContext(
              actionFlags: &actionFlags,
              timestamp: timestampPointer,
              inputBusNumber: 1,
              frameCount: 480
            ),
            inputData: bufferListPointer
          )
        )
      }
    }
  }
}

private func deliverNativeCaptureSlice(
  to bridge: MacGridWebRTCAudioBridge,
  frameCount: UInt32,
  hostTime: UInt64,
  timestampFlags: AudioTimeStampFlags = .hostTimeValid
) -> OSStatus {
  let samples = [Float](repeating: 0.25, count: Int(frameCount))
  var timestamp = AudioTimeStamp()
  timestamp.mHostTime = hostTime
  timestamp.mFlags = timestampFlags
  return samples.withUnsafeBufferPointer { samples in
    bridge.deliverNativeRecordedData(
      samples: samples.baseAddress!,
      frameCount: frameCount,
      timestamp: timestamp,
      actionFlags: [],
      busNumber: 1
    )
  }
}

private func pullPlayout(
  from bridge: MacGridWebRTCAudioBridge,
  into samples: inout [Int16],
  hostTime: UInt64,
  frameCount: UInt32 = 480
) -> (status: OSStatus, flags: AudioUnitRenderActionFlags) {
  var timestamp = AudioTimeStamp()
  timestamp.mHostTime = hostTime
  timestamp.mFlags = .hostTimeValid
  var actionFlags = AudioUnitRenderActionFlags()
  let status = samples.withUnsafeMutableBytes { bytes in
    var bufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 2,
        mDataByteSize: UInt32(bytes.count),
        mData: bytes.baseAddress
      )
    )
    return withUnsafePointer(to: &timestamp) { timestampPointer in
      withUnsafeMutablePointer(to: &bufferList) { bufferListPointer in
        bridge.getPlayoutData(
          CustomAudioDeviceIOContext(
            actionFlags: &actionFlags,
            timestamp: timestampPointer,
            inputBusNumber: 0,
            frameCount: frameCount
          ),
          outputData: bufferListPointer
        )
      }
    }
  }
  return (status, actionFlags)
}

private func currentThreadID() -> UInt64 {
  var threadID: UInt64 = 0
  pthread_threadid_np(nil, &threadID)
  return threadID
}

private func waitUntil(
  timeout: TimeInterval = 1,
  condition: () -> Bool
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    guard Date() < deadline else { return false }
    usleep(1_000)
  }
  return true
}

private final class BridgeDelegate: CustomAudioDeviceDelegate, @unchecked Sendable {
  static let playoutSample: Int16 = 42

  let preferredInputSampleRate = 48_000.0
  let preferredInputIOBufferDuration: TimeInterval = 0.010
  let preferredOutputSampleRate = 48_000.0
  let preferredOutputIOBufferDuration: TimeInterval = 0.010

  private let lock = NSLock()
  private let captureDelivered = DispatchSemaphore(value: 0)
  private let playoutPulled = DispatchSemaphore(value: 0)
  private var captureThreads: [UInt64] = []
  private var playoutThreads: [UInt64] = []
  private var capturedFrames: [UInt32] = []
  private var capturedFirstSampleValues: [Int16] = []
  private var capturedPeakSampleValues: [Int16] = []

  var captureThreadIDs: [UInt64] { lock.withLock { captureThreads } }
  var playoutThreadIDs: [UInt64] { lock.withLock { playoutThreads } }
  var captureFrameCounts: [UInt32] { lock.withLock { capturedFrames } }
  var captureFirstSamples: [Int16] {
    lock.withLock { capturedFirstSampleValues }
  }
  var capturePeakSamples: [Int16] {
    lock.withLock { capturedPeakSampleValues }
  }

  func getPlayoutData(
    _ context: CustomAudioDeviceIOContext,
    outputData: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus {
    lock.withLock { playoutThreads.append(currentThreadID()) }
    let buffer = outputData.pointee.mBuffers
    guard let rawData = buffer.mData else { return kAudio_ParamError }
    let sampleCount = Int(context.frameCount * buffer.mNumberChannels)
    let data = rawData.assumingMemoryBound(to: Int16.self)
    data.update(repeating: Self.playoutSample, count: sampleCount)
    playoutPulled.signal()
    return noErr
  }

  func deliverRecordedData(_ data: CustomAudioDeviceRecordedData) -> OSStatus {
    let buffer = data.inputData.pointee.mBuffers
    guard let rawData = buffer.mData else { return kAudio_ParamError }
    let samples = rawData.assumingMemoryBound(to: Int16.self)
    let firstSample = samples.pointee
    var peakSample: Int16 = 0
    for index in 0..<Int(data.context.frameCount) {
      peakSample = max(peakSample, abs(samples[index]))
    }
    lock.withLock {
      captureThreads.append(currentThreadID())
      capturedFrames.append(data.context.frameCount)
      capturedFirstSampleValues.append(firstSample)
      capturedPeakSampleValues.append(peakSample)
    }
    captureDelivered.signal()
    return noErr
  }

  func waitForCapture(count: Int) -> Bool {
    wait(semaphore: captureDelivered) { captureThreads.count >= count }
  }

  func waitForPlayout(count: Int) -> Bool {
    wait(semaphore: playoutPulled) { playoutThreads.count >= count }
  }

  func notifyAudioInputParametersChange() {}
  func notifyAudioOutputParametersChange() {}
  func notifyAudioInputInterrupted() {}
  func notifyAudioOutputInterrupted() {}
  func dispatchAsync(_ block: @escaping @Sendable () -> Void) { block() }
  func dispatchSync(_ block: @escaping @Sendable () -> Void) { block() }

  private func wait(
    semaphore: DispatchSemaphore,
    condition: () -> Bool
  ) -> Bool {
    while !lock.withLock(condition) {
      guard semaphore.wait(timeout: .now() + 1) == .success else {
        return false
      }
    }
    return true
  }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }

  var value: Value { lock.withLock { storage } }

  func set(_ value: Value) {
    lock.withLock { storage = value }
  }
}
#endif
