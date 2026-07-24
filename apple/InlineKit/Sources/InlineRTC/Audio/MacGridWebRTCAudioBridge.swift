#if os(macOS)
import Atomics
import AudioToolbox
@preconcurrency import AVFoundation
import Darwin
import Foundation
import LiveKit

struct MacGridWebRTCAudioBridgeSnapshot: Equatable, Sendable {
  let captureWorkerActive: Bool
  let playoutWorkerActive: Bool
  let captureHasDeliveredForCurrentActivation: Bool
  let playoutHasPulledForCurrentActivation: Bool
  let captureQueuedFrames: UInt32
  let playoutQueuedFrames: UInt32
  let capturedPacketCount: UInt64
  let captureOverflowCount: UInt64
  let captureDeliveryErrorCount: UInt64
  let lastCaptureDeliveryStatus: OSStatus
  let captureConversionErrorCount: UInt64
  let lastCaptureConversionStatus: OSStatus
  let capturePacketizationErrorCount: UInt64
  let lastCapturePacketizationStatus: OSStatus
  let captureNativeSampleRate: Double
  let playoutPullCount: UInt64
  let playoutPullErrorCount: UInt64
  let lastPlayoutPullStatus: OSStatus
  let playoutUnderrunCount: UInt64
  let latestPlayoutRequestedFrames: UInt32
  let latestPlayoutCopiedFrames: UInt32
  let latestPlayoutCallbackHadUnderrun: Bool
  let consecutivePlayoutMissingFrames: UInt32
  let playoutTargetFrames: UInt32
}

/// Stable-thread boundary between replaceable Core Audio callbacks and M144's
/// custom audio device delegate.
///
/// Core Audio calls ``deliverNativeRecordedData(samples:frameCount:timestamp:actionFlags:busNumber:)``
/// and ``getPlayoutData(_:outputData:)`` through this proxy. Those methods only
/// move PCM through preallocated SPSC storage and signal Mach semaphores. The
/// two persistent pthreads are the only callers that cross into WebRTC, which
/// satisfies M144's one-thread-per-direction contract across AUHAL rebuilds.
final class MacGridWebRTCAudioBridge: CustomAudioDeviceDelegate, @unchecked Sendable {
  private static let captureFramesPerPacket: UInt32 = 480
  private static let capturePacketCapacity = 16
  private static let nativeCaptureSliceCapacity = 16
  private static let playoutFramesPerPacket: UInt32 = 480
  private static let playoutChannels: UInt32 = 2
  /// Stock AudioDeviceMac keeps three 10 ms render blocks in its ring. Keep
  /// that as the minimum, then grow the target for devices whose physical IO
  /// block converts to more than 20 ms at WebRTC's 48 kHz client format.
  private static let minimumPlayoutTargetFrames: UInt32 = 1_440
  private static let playoutCapacityFrames: UInt32 = 32_768
  /// One isolated callback can underrun while a Bluetooth converter or a new
  /// route settles. Thirty milliseconds of consecutive missing client-format
  /// frames is a sustained failure and must trigger directional recovery.
  static let sustainedPlayoutUnderrunFrames: UInt32 = 1_440

  private let upstream: any CustomAudioDeviceDelegate
  private let nativeCaptureRing: MacGridNativeCaptureSliceRing
  private let captureRing: MacGridCapturePacketRing
  private let playoutRing: MacGridPlayoutSampleRing
  private let playoutPacketData: UnsafeMutablePointer<Int16>

  private let captureWake: semaphore_t
  private let captureControlAcknowledged: semaphore_t
  private let playoutWake: semaphore_t
  private let playoutControlAcknowledged: semaphore_t

  private let terminating = ManagedAtomic(false)
  private let captureDesiredActive = ManagedAtomic(false)
  private let captureDesiredGeneration = ManagedAtomic<UInt64>(0)
  private let captureProcessedGeneration = ManagedAtomic<UInt64>(0)
  private let captureWorkerActive = ManagedAtomic(false)
  private let captureCallbacksInFlight = ManagedAtomic<UInt32>(0)
  private let playoutDesiredActive = ManagedAtomic(false)
  private let playoutDesiredGeneration = ManagedAtomic<UInt64>(0)
  private let playoutProcessedGeneration = ManagedAtomic<UInt64>(0)
  private let playoutWorkerActive = ManagedAtomic(false)
  private let playoutCallbacksInFlight = ManagedAtomic<UInt32>(0)
  private let playoutDemandObserved = ManagedAtomic(false)

  private let capturedPacketCount = ManagedAtomic<UInt64>(0)
  private let captureOverflowCount = ManagedAtomic<UInt64>(0)
  private let captureDeliveryErrorCount = ManagedAtomic<UInt64>(0)
  private let lastCaptureDeliveryStatus = ManagedAtomic<OSStatus>(noErr)
  private let captureConversionErrorCount = ManagedAtomic<UInt64>(0)
  private let lastCaptureConversionStatus = ManagedAtomic<OSStatus>(noErr)
  private let capturePacketizationErrorCount = ManagedAtomic<UInt64>(0)
  private let lastCapturePacketizationStatus = ManagedAtomic<OSStatus>(noErr)
  private let captureNativeSampleRateBits = ManagedAtomic<UInt64>(
    MacGridAUHALFormat.sampleRate.bitPattern
  )
  private let capturePacketizerPendingFrames = ManagedAtomic<UInt32>(0)
  private let captureTimestampDiscontinuities = ManagedAtomic<UInt64>(0)
  private let capturePacketizerContinuousFrames = ManagedAtomic<UInt64>(0)
  private let captureDeliveryGeneration = ManagedAtomic<UInt64>(0)
  private let playoutPullCount = ManagedAtomic<UInt64>(0)
  private let playoutPullErrorCount = ManagedAtomic<UInt64>(0)
  private let lastPlayoutPullStatus = ManagedAtomic<OSStatus>(noErr)
  private let playoutPullGeneration = ManagedAtomic<UInt64>(0)
  private let playoutUnderrunCount = ManagedAtomic<UInt64>(0)
  private let latestPlayoutRequestedFrames = ManagedAtomic<UInt32>(0)
  private let latestPlayoutCopiedFrames = ManagedAtomic<UInt32>(0)
  private let latestPlayoutCallbackHadUnderrun = ManagedAtomic(false)
  private let consecutivePlayoutMissingFrames = ManagedAtomic<UInt32>(0)
  private let playoutTargetFrames = ManagedAtomic<UInt32>(minimumPlayoutTargetFrames)
  private let latestPlayoutHostTime = ManagedAtomic<UInt64>(0)
  private let latestPlayoutSampleTimeBits = ManagedAtomic<UInt64>(0)
  private let latestPlayoutTimestampFlags = ManagedAtomic<UInt32>(0)

  private var captureThread: pthread_t?
  private var playoutThread: pthread_t?

  init(upstream: any CustomAudioDeviceDelegate) throws {
    self.upstream = upstream
    nativeCaptureRing = MacGridNativeCaptureSliceRing(
      maximumFramesPerSlice: MacGridAUHALFormat.maximumFramesPerSlice,
      sliceCapacity: Self.nativeCaptureSliceCapacity
    )
    captureRing = MacGridCapturePacketRing(
      framesPerPacket: Self.captureFramesPerPacket,
      packetCapacity: Self.capturePacketCapacity
    )
    playoutRing = MacGridPlayoutSampleRing(
      channels: Self.playoutChannels,
      capacityFrames: Self.playoutCapacityFrames
    )
    let semaphores = try Self.makeSemaphores()
    captureWake = semaphores.captureWake
    captureControlAcknowledged = semaphores.captureControlAcknowledged
    playoutWake = semaphores.playoutWake
    playoutControlAcknowledged = semaphores.playoutControlAcknowledged
    playoutPacketData = .allocate(
      capacity: Int(Self.playoutFramesPerPacket * Self.playoutChannels)
    )

    do {
      captureThread = try Self.spawnThread(
        name: "GridCaptureWorker",
        owner: self,
        entry: Self.captureThreadEntry
      )
      playoutThread = try Self.spawnThread(
        name: "GridRenderWorker",
        owner: self,
        entry: Self.playoutThreadEntry
      )
    } catch {
      terminating.store(true, ordering: .releasing)
      semaphore_signal(captureWake)
      semaphore_signal(playoutWake)
      if let captureThread {
        pthread_join(captureThread, nil)
        self.captureThread = nil
      }
      Self.destroySemaphore(captureWake)
      Self.destroySemaphore(captureControlAcknowledged)
      Self.destroySemaphore(playoutWake)
      Self.destroySemaphore(playoutControlAcknowledged)
      playoutPacketData.deallocate()
      throw error
    }
  }

  deinit {
    shutdown()
    playoutPacketData.deallocate()
  }

  var preferredInputSampleRate: Double { upstream.preferredInputSampleRate }
  var preferredInputIOBufferDuration: TimeInterval {
    upstream.preferredInputIOBufferDuration
  }
  var preferredOutputSampleRate: Double { upstream.preferredOutputSampleRate }
  var preferredOutputIOBufferDuration: TimeInterval {
    upstream.preferredOutputIOBufferDuration
  }

  var capturePacketizerPendingFrameCount: UInt32 {
    capturePacketizerPendingFrames.load(ordering: .relaxed)
  }

  var captureTimestampDiscontinuityCount: UInt64 {
    captureTimestampDiscontinuities.load(ordering: .relaxed)
  }

  var capturePacketizerContinuousFrameCount: UInt64 {
    capturePacketizerContinuousFrames.load(ordering: .relaxed)
  }

  func notifyAudioInputParametersChange() {
    upstream.notifyAudioInputParametersChange()
  }

  func notifyAudioOutputParametersChange() {
    upstream.notifyAudioOutputParametersChange()
  }

  func notifyAudioInputInterrupted() {
    upstream.notifyAudioInputInterrupted()
  }

  func notifyAudioOutputInterrupted() {
    upstream.notifyAudioOutputInterrupted()
  }

  func dispatchAsync(_ block: @escaping @Sendable () -> Void) {
    upstream.dispatchAsync(block)
  }

  func dispatchSync(_ block: @escaping @Sendable () -> Void) {
    upstream.dispatchSync(block)
  }

  func deliverRecordedData(_ data: CustomAudioDeviceRecordedData) -> OSStatus {
    captureCallbacksInFlight.wrappingIncrement(ordering: .acquiringAndReleasing)
    defer {
      captureCallbacksInFlight.wrappingDecrement(ordering: .acquiringAndReleasing)
    }
    guard captureWorkerActive.load(ordering: .acquiring) else { return noErr }
    guard data.context.frameCount == Self.captureFramesPerPacket else {
      return kAudioUnitErr_TooManyFramesToProcess
    }
    let inputData = data.inputData.pointee
    let inputBuffer = inputData.mBuffers
    guard inputData.mNumberBuffers == 1,
          inputBuffer.mNumberChannels == 1,
          let rawData = inputBuffer.mData,
          inputBuffer.mDataByteSize
            >= data.context.frameCount * UInt32(MemoryLayout<Int16>.size)
    else { return kAudio_ParamError }

    // SAFETY: the callback-scoped AudioBufferList was validated as one
    // interleaved Int16 channel containing exactly the packet copied below.
    let samples = UnsafeRawPointer(rawData).assumingMemoryBound(to: Int16.self)
    let enqueued = captureRing.write(
      samples: samples,
      timestamp: data.context.timestamp.pointee,
      actionFlags: data.context.actionFlags.pointee,
      busNumber: data.context.inputBusNumber
    )
    guard enqueued else {
      captureOverflowCount.wrappingIncrement(ordering: .relaxed)
      return kAudioUnitErr_CannotDoInCurrentContext
    }
    semaphore_signal(captureWake)
    return noErr
  }

  /// Publishes one native mono Float32 AUHAL slice to the persistent capture
  /// worker. This is the only live hardware-callback entry point; it performs
  /// one bounded copy and never converts, allocates, locks, or calls WebRTC.
  func deliverNativeRecordedData(
    samples: UnsafePointer<Float>,
    frameCount: UInt32,
    timestamp: AudioTimeStamp,
    actionFlags: AudioUnitRenderActionFlags,
    busNumber: Int
  ) -> OSStatus {
    captureCallbacksInFlight.wrappingIncrement(ordering: .acquiringAndReleasing)
    defer {
      captureCallbacksInFlight.wrappingDecrement(ordering: .acquiringAndReleasing)
    }
    guard captureWorkerActive.load(ordering: .acquiring) else { return noErr }
    guard frameCount > 0,
          frameCount <= MacGridAUHALFormat.maximumFramesPerSlice
    else { return kAudio_ParamError }
    guard nativeCaptureRing.write(
      samples: samples,
      frameCount: frameCount,
      timestamp: timestamp,
      actionFlags: actionFlags,
      busNumber: busNumber
    ) else {
      captureOverflowCount.wrappingIncrement(ordering: .relaxed)
      return kAudioUnitErr_CannotDoInCurrentContext
    }
    semaphore_signal(captureWake)
    return noErr
  }

  func getPlayoutData(
    _ context: CustomAudioDeviceIOContext,
    outputData: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus {
    playoutCallbacksInFlight.wrappingIncrement(ordering: .acquiringAndReleasing)
    defer {
      playoutCallbacksInFlight.wrappingDecrement(ordering: .acquiringAndReleasing)
    }
    let outputBuffer = outputData.pointee.mBuffers
    guard outputData.pointee.mNumberBuffers == 1,
          outputBuffer.mNumberChannels == Self.playoutChannels,
          let rawData = outputBuffer.mData,
          outputBuffer.mDataByteSize
            >= context.frameCount * Self.playoutChannels
              * UInt32(MemoryLayout<Int16>.size)
    else { return kAudio_ParamError }

    // Terminal teardown first closes every physical callback gate, but keep
    // this public delegate boundary safe if a stale caller arrives afterward.
    // In particular, never signal a Mach semaphore after `shutdown()` has
    // destroyed its port.
    if terminating.load(ordering: .acquiring) {
      memset(
        rawData,
        0,
        Int(context.frameCount * Self.playoutChannels)
          * MemoryLayout<Int16>.size
      )
      context.actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
      return noErr
    }

    rememberPlayoutTimestamp(context.timestamp.pointee)
    latestPlayoutRequestedFrames.store(context.frameCount, ordering: .relaxed)
    playoutDemandObserved.store(true, ordering: .releasing)
    // SAFETY: the output list was validated as one interleaved stereo Int16
    // buffer with capacity for the requested physical frame count.
    let destination = rawData.assumingMemoryBound(to: Int16.self)
    let copiedFrames: UInt32
    if playoutWorkerActive.load(ordering: .acquiring) {
      copiedFrames = playoutRing.read(
        into: destination,
        maximumFrames: context.frameCount
      )
    } else {
      copiedFrames = 0
    }
    if copiedFrames < context.frameCount {
      let missingFrames = context.frameCount - copiedFrames
      let missingSamples = missingFrames * Self.playoutChannels
      let start = destination.advanced(
        by: Int(copiedFrames * Self.playoutChannels)
      )
      memset(start, 0, Int(missingSamples) * MemoryLayout<Int16>.size)
      // A partial underrun still contains real PCM. Marking the whole callback
      // `OutputIsSilence` permits Core Audio to discard that prefix, producing
      // chopped/robotic output. Only a wholly empty callback is silent.
      if copiedFrames == 0 {
        context.actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
      } else {
        context.actionFlags.pointee.remove(.unitRenderAction_OutputIsSilence)
      }
      playoutUnderrunCount.wrappingIncrement(ordering: .relaxed)
    } else {
      context.actionFlags.pointee.remove(.unitRenderAction_OutputIsSilence)
    }
    latestPlayoutCopiedFrames.store(copiedFrames, ordering: .relaxed)
    latestPlayoutCallbackHadUnderrun.store(
      copiedFrames < context.frameCount,
      ordering: .releasing
    )
    let previousMissingFrames = consecutivePlayoutMissingFrames.load(ordering: .relaxed)
    consecutivePlayoutMissingFrames.store(
      Self.updatedConsecutiveMissingFrames(
        previous: previousMissingFrames,
        requested: context.frameCount,
        copied: copiedFrames
      ),
      ordering: .releasing
    )
    semaphore_signal(playoutWake)
    return noErr
  }

  func setRecordingActive(
    _ active: Bool,
    forceTransition: Bool = false,
    timeout: TimeInterval = 1
  ) -> Bool {
    updateWorkerControl(
      desiredActive: captureDesiredActive,
      desiredGeneration: captureDesiredGeneration,
      processedGeneration: captureProcessedGeneration,
      workerActive: captureWorkerActive,
      wake: captureWake,
      acknowledged: captureControlAcknowledged,
      active: active,
      forceTransition: forceTransition,
      timeout: timeout
    )
  }

  /// Sets the physical side of the next capture generation. WebRTC remains
  /// fixed at mono 48 kHz signed Int16; only the worker-owned converter sees
  /// this native rate. A running generation may be re-declared only when the
  /// rate is unchanged.
  @discardableResult
  func configureCaptureFormat(nativeSampleRate: Double) -> Bool {
    guard nativeSampleRate.isFinite, nativeSampleRate > 0 else { return false }
    let bits = nativeSampleRate.bitPattern
    if captureWorkerActive.load(ordering: .acquiring) {
      return captureNativeSampleRateBits.load(ordering: .acquiring) == bits
    }
    Self.waitForCallbacksToDrain(captureCallbacksInFlight)
    captureNativeSampleRateBits.store(bits, ordering: .releasing)
    return true
  }

  func setPlayoutActive(
    _ active: Bool,
    forceTransition: Bool = false,
    timeout: TimeInterval = 1
  ) -> Bool {
    updateWorkerControl(
      desiredActive: playoutDesiredActive,
      desiredGeneration: playoutDesiredGeneration,
      processedGeneration: playoutProcessedGeneration,
      workerActive: playoutWorkerActive,
      wake: playoutWake,
      acknowledged: playoutControlAcknowledged,
      active: active,
      forceTransition: forceTransition,
      timeout: timeout
    )
  }

  /// Must be called on the serialized ADM control path before a physical
  /// output starts. The worker still pulls WebRTC in exact 10 ms blocks; only
  /// the preallocated queue watermark changes.
  @discardableResult
  func configurePlayoutTarget(
    deviceBufferFrames: UInt32,
    deviceSampleRate: Double
  ) -> UInt32 {
    let target = Self.playoutTargetFrames(
      deviceBufferFrames: deviceBufferFrames,
      deviceSampleRate: deviceSampleRate
    )
    playoutTargetFrames.store(target, ordering: .releasing)
    return target
  }

  func snapshot() -> MacGridWebRTCAudioBridgeSnapshot {
    let captureGeneration = captureProcessedGeneration.load(ordering: .acquiring)
    let playoutGeneration = playoutProcessedGeneration.load(ordering: .acquiring)
    return MacGridWebRTCAudioBridgeSnapshot(
      captureWorkerActive: captureWorkerActive.load(ordering: .acquiring),
      playoutWorkerActive: playoutWorkerActive.load(ordering: .acquiring),
      captureHasDeliveredForCurrentActivation: captureGeneration > 0
        && captureDeliveryGeneration.load(ordering: .acquiring) == captureGeneration,
      playoutHasPulledForCurrentActivation: playoutGeneration > 0
        && playoutPullGeneration.load(ordering: .acquiring) == playoutGeneration,
      captureQueuedFrames: captureRing.availablePacketCount
        * Self.captureFramesPerPacket
        + capturePacketizerPendingFrames.load(ordering: .relaxed)
        + Self.webRTCFrames(
          nativeFrames: nativeCaptureRing.availableFrameCount,
          nativeSampleRate: Double(
            bitPattern: captureNativeSampleRateBits.load(ordering: .acquiring)
          )
        ),
      playoutQueuedFrames: playoutRing.availableFrames,
      capturedPacketCount: capturedPacketCount.load(ordering: .relaxed),
      captureOverflowCount: captureOverflowCount.load(ordering: .relaxed),
      captureDeliveryErrorCount: captureDeliveryErrorCount.load(ordering: .relaxed),
      lastCaptureDeliveryStatus: lastCaptureDeliveryStatus.load(ordering: .relaxed),
      captureConversionErrorCount: captureConversionErrorCount.load(ordering: .relaxed),
      lastCaptureConversionStatus: lastCaptureConversionStatus.load(ordering: .relaxed),
      capturePacketizationErrorCount:
        capturePacketizationErrorCount.load(ordering: .relaxed),
      lastCapturePacketizationStatus:
        lastCapturePacketizationStatus.load(ordering: .relaxed),
      captureNativeSampleRate: Double(
        bitPattern: captureNativeSampleRateBits.load(ordering: .acquiring)
      ),
      playoutPullCount: playoutPullCount.load(ordering: .relaxed),
      playoutPullErrorCount: playoutPullErrorCount.load(ordering: .relaxed),
      lastPlayoutPullStatus: lastPlayoutPullStatus.load(ordering: .relaxed),
      playoutUnderrunCount: playoutUnderrunCount.load(ordering: .relaxed),
      latestPlayoutRequestedFrames: latestPlayoutRequestedFrames.load(ordering: .relaxed),
      latestPlayoutCopiedFrames: latestPlayoutCopiedFrames.load(ordering: .relaxed),
      latestPlayoutCallbackHadUnderrun:
        latestPlayoutCallbackHadUnderrun.load(ordering: .relaxed),
      consecutivePlayoutMissingFrames:
        consecutivePlayoutMissingFrames.load(ordering: .acquiring),
      playoutTargetFrames: playoutTargetFrames.load(ordering: .acquiring)
    )
  }

  static func updatedConsecutiveMissingFrames(
    previous: UInt32,
    requested: UInt32,
    copied: UInt32
  ) -> UInt32 {
    guard copied < requested else { return 0 }
    let missing = requested - copied
    let result = previous.addingReportingOverflow(missing)
    return result.overflow ? .max : result.partialValue
  }

  static func webRTCFrames(
    nativeFrames: UInt64,
    nativeSampleRate: Double
  ) -> UInt32 {
    guard nativeSampleRate.isFinite, nativeSampleRate > 0 else { return 0 }
    let converted = Double(nativeFrames)
      * MacGridAUHALFormat.sampleRate / nativeSampleRate
    return UInt32(min(converted.rounded(.up), Double(UInt32.max)))
  }

  static func playoutTargetFrames(
    deviceBufferFrames: UInt32,
    deviceSampleRate: Double
  ) -> UInt32 {
    guard deviceSampleRate.isFinite, deviceSampleRate > 0 else {
      return minimumPlayoutTargetFrames
    }
    let convertedCallbackFrames = UInt64(
      ceil(Double(deviceBufferFrames) * MacGridAUHALFormat.sampleRate / deviceSampleRate)
    )
    let desired = max(
      UInt64(minimumPlayoutTargetFrames),
      convertedCallbackFrames + UInt64(playoutFramesPerPacket)
    )
    let packetFrames = UInt64(playoutFramesPerPacket)
    let rounded = ((desired + packetFrames - 1) / packetFrames) * packetFrames
    let maximumTarget = UInt64(playoutCapacityFrames - playoutFramesPerPacket)
    return UInt32(min(rounded, maximumTarget))
  }

  static func playoutQueueLatencyNanoseconds(
    deviceBufferFrames: UInt32,
    deviceSampleRate: Double
  ) -> UInt64 {
    UInt64(
      (Double(
        playoutTargetFrames(
          deviceBufferFrames: deviceBufferFrames,
          deviceSampleRate: deviceSampleRate
        )
      ) * 1_000_000_000 / MacGridAUHALFormat.sampleRate).rounded()
    )
  }

  func shutdown() {
    guard !terminating.exchange(true, ordering: .acquiringAndReleasing) else {
      return
    }
    // Gate new physical bridge access before releasing either ring. Calls that
    // already entered are bounded pointer copies and must finish before worker
    // joins can destroy their storage.
    captureWorkerActive.store(false, ordering: .releasing)
    playoutWorkerActive.store(false, ordering: .releasing)
    Self.waitForCallbacksToDrain(captureCallbacksInFlight)
    Self.waitForCallbacksToDrain(playoutCallbacksInFlight)
    semaphore_signal(captureWake)
    semaphore_signal(playoutWake)
    if let captureThread {
      pthread_join(captureThread, nil)
      self.captureThread = nil
    }
    if let playoutThread {
      pthread_join(playoutThread, nil)
      self.playoutThread = nil
    }
    captureWorkerActive.store(false, ordering: .releasing)
    playoutWorkerActive.store(false, ordering: .releasing)
    Self.destroySemaphore(captureWake)
    Self.destroySemaphore(captureControlAcknowledged)
    Self.destroySemaphore(playoutWake)
    Self.destroySemaphore(playoutControlAcknowledged)
  }
}

private extension MacGridWebRTCAudioBridge {
  static let captureThreadEntry: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { rawOwner in
    let owner = Unmanaged<MacGridWebRTCAudioBridge>
      .fromOpaque(rawOwner)
      .takeUnretainedValue()
    owner.runCaptureWorker()
    return nil
  }

  static let playoutThreadEntry: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { rawOwner in
    let owner = Unmanaged<MacGridWebRTCAudioBridge>
      .fromOpaque(rawOwner)
      .takeUnretainedValue()
    owner.runPlayoutWorker()
    return nil
  }

  func runCaptureWorker() {
    pthread_setname_np("GridCaptureWorker")
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    var processedGeneration: UInt64 = 0
    var converter: MacGridNativeCaptureConverter?
    while !terminating.load(ordering: .acquiring) {
      let desiredGeneration = captureDesiredGeneration.load(ordering: .acquiring)
      if desiredGeneration != processedGeneration {
        let active = captureDesiredActive.load(ordering: .acquiring)
        if !active {
          // Close the producer gate first, then prove every producer that saw
          // the previous generation has returned before resetting the ring.
          captureWorkerActive.store(false, ordering: .releasing)
          Self.waitForCallbacksToDrain(captureCallbacksInFlight)
          drainNativeCaptureSlices(using: converter)
          drainCapturePackets()
          converter = nil
        } else {
          // While inactive, physical callbacks return before touching storage.
          // Drain their short entry/exit window before publishing a fresh ring.
          Self.waitForCallbacksToDrain(captureCallbacksInFlight)
          let nativeSampleRate = Double(
            bitPattern: captureNativeSampleRateBits.load(ordering: .acquiring)
          )
          converter = try? MacGridNativeCaptureConverter(
            nativeSampleRate: nativeSampleRate,
            maximumInputFrames: MacGridAUHALFormat.maximumFramesPerSlice,
            packetDelegate: self
          )
        }
        nativeCaptureRing.reset()
        captureRing.reset()
        resetCapturePacketizerHealth()
        let workerIsActive = active && converter != nil
        if active, converter == nil {
          captureConversionErrorCount.wrappingIncrement(ordering: .relaxed)
          lastCaptureConversionStatus.store(kAudio_ParamError, ordering: .relaxed)
        }
        captureWorkerActive.store(workerIsActive, ordering: .releasing)
        processedGeneration = desiredGeneration
        captureProcessedGeneration.store(processedGeneration, ordering: .releasing)
        semaphore_signal(captureControlAcknowledged)
      }
      if captureWorkerActive.load(ordering: .acquiring) {
        drainNativeCaptureSlices(using: converter)
        drainCapturePackets()
      }
      Self.wait(captureWake)
    }
    drainNativeCaptureSlices(using: converter)
    drainCapturePackets()
  }

  func drainNativeCaptureSlices(using converter: MacGridNativeCaptureConverter?) {
    guard let converter else { return }
    while nativeCaptureRing.read({ samples, metadata in
      let result = converter.convert(
        samples: samples,
        frameCount: metadata.frameCount,
        timestamp: metadata.timestamp,
        actionFlags: metadata.actionFlags
      )
      capturePacketizerPendingFrames.store(
        converter.pendingPacketFrameCount,
        ordering: .relaxed
      )
      captureTimestampDiscontinuities.store(
        converter.timestampDiscontinuityCount,
        ordering: .relaxed
      )
      capturePacketizerContinuousFrames.store(
        converter.continuousFrameCount,
        ordering: .relaxed
      )
      switch result {
      case .success, .downstreamFailure:
        lastCaptureConversionStatus.store(noErr, ordering: .relaxed)
        lastCapturePacketizationStatus.store(noErr, ordering: .relaxed)
      case let .conversionFailure(status):
        lastCaptureConversionStatus.store(status, ordering: .relaxed)
        lastCapturePacketizationStatus.store(noErr, ordering: .relaxed)
        captureConversionErrorCount.wrappingIncrement(ordering: .relaxed)
      case let .packetizationFailure(status):
        lastCaptureConversionStatus.store(noErr, ordering: .relaxed)
        lastCapturePacketizationStatus.store(status, ordering: .relaxed)
        capturePacketizationErrorCount.wrappingIncrement(ordering: .relaxed)
      }
    }) {}
  }

  func resetCapturePacketizerHealth() {
    capturePacketizerPendingFrames.store(0, ordering: .relaxed)
    captureTimestampDiscontinuities.store(0, ordering: .relaxed)
    capturePacketizerContinuousFrames.store(0, ordering: .relaxed)
    lastCaptureConversionStatus.store(noErr, ordering: .relaxed)
    lastCapturePacketizationStatus.store(noErr, ordering: .relaxed)
  }

  func drainCapturePackets() {
    while captureRing.read({ samples, metadata in
      var timestamp = metadata.timestamp
      var actionFlags = metadata.actionFlags
      var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 1,
          mDataByteSize: Self.captureFramesPerPacket
            * UInt32(MemoryLayout<Int16>.size),
          mData: UnsafeMutableRawPointer(mutating: samples)
        )
      )
      _ = withUnsafePointer(to: &timestamp) { timestampPointer in
        withUnsafePointer(to: &bufferList) { bufferListPointer in
          deliverCapturePacketToUpstream(
            CustomAudioDeviceRecordedData(
              context: CustomAudioDeviceIOContext(
                actionFlags: &actionFlags,
                timestamp: timestampPointer,
                inputBusNumber: metadata.busNumber,
                frameCount: Self.captureFramesPerPacket
              ),
              inputData: bufferListPointer
            )
          )
        }
      }
    }) {}
  }

  func deliverCapturePacketToUpstream(
    _ data: CustomAudioDeviceRecordedData
  ) -> OSStatus {
    let status = upstream.deliverRecordedData(data)
    capturedPacketCount.wrappingIncrement(ordering: .relaxed)
    lastCaptureDeliveryStatus.store(status, ordering: .relaxed)
    captureDeliveryGeneration.store(
      captureProcessedGeneration.load(ordering: .acquiring),
      ordering: .releasing
    )
    if status != noErr {
      captureDeliveryErrorCount.wrappingIncrement(ordering: .relaxed)
    }
    return status
  }

  func runPlayoutWorker() {
    pthread_setname_np("GridRenderWorker")
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    var processedGeneration: UInt64 = 0
    while !terminating.load(ordering: .acquiring) {
      let desiredGeneration = playoutDesiredGeneration.load(ordering: .acquiring)
      if desiredGeneration != processedGeneration {
        let active = playoutDesiredActive.load(ordering: .acquiring)
        // The physical output callback is the ring consumer. Keep it gated
        // while indices are reset so a read can never race a generation reset.
        playoutWorkerActive.store(false, ordering: .releasing)
        Self.waitForCallbacksToDrain(playoutCallbacksInFlight)
        playoutRing.reset()
        playoutDemandObserved.store(false, ordering: .releasing)
        latestPlayoutRequestedFrames.store(0, ordering: .relaxed)
        latestPlayoutCopiedFrames.store(0, ordering: .relaxed)
        latestPlayoutCallbackHadUnderrun.store(false, ordering: .releasing)
        consecutivePlayoutMissingFrames.store(0, ordering: .releasing)
        playoutWorkerActive.store(active, ordering: .releasing)
        processedGeneration = desiredGeneration
        playoutProcessedGeneration.store(processedGeneration, ordering: .releasing)
        semaphore_signal(playoutControlAcknowledged)
      }
      if playoutWorkerActive.load(ordering: .acquiring),
         playoutDemandObserved.load(ordering: .acquiring) {
        fillPlayoutRing()
      }
      Self.wait(playoutWake)
    }
  }

  func fillPlayoutRing() {
    while playoutWorkerActive.load(ordering: .acquiring),
          playoutRing.availableFrames < playoutTargetFrames.load(ordering: .acquiring),
          playoutRing.writableFrames >= Self.playoutFramesPerPacket {
      var actionFlags = AudioUnitRenderActionFlags()
      var timestamp = makePlayoutTimestamp(
        queuedFrames: playoutRing.availableFrames
      )
      var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: Self.playoutChannels,
          mDataByteSize: Self.playoutFramesPerPacket
            * Self.playoutChannels
            * UInt32(MemoryLayout<Int16>.size),
          mData: playoutPacketData
        )
      )
      let status = withUnsafePointer(to: &timestamp) { timestampPointer in
        withUnsafeMutablePointer(to: &bufferList) { bufferListPointer in
          upstream.getPlayoutData(
            CustomAudioDeviceIOContext(
              actionFlags: &actionFlags,
              timestamp: timestampPointer,
              inputBusNumber: 0,
              frameCount: Self.playoutFramesPerPacket
            ),
            outputData: bufferListPointer
          )
        }
      }
      playoutPullCount.wrappingIncrement(ordering: .relaxed)
      lastPlayoutPullStatus.store(status, ordering: .relaxed)
      playoutPullGeneration.store(
        playoutProcessedGeneration.load(ordering: .acquiring),
        ordering: .releasing
      )
      if status != noErr {
        playoutPullErrorCount.wrappingIncrement(ordering: .relaxed)
        memset(
          playoutPacketData,
          0,
          Int(Self.playoutFramesPerPacket * Self.playoutChannels)
            * MemoryLayout<Int16>.size
        )
      }
      guard playoutRing.write(
        samples: UnsafePointer(playoutPacketData),
        frameCount: Self.playoutFramesPerPacket
      ) else { return }
    }
  }

  func rememberPlayoutTimestamp(_ timestamp: AudioTimeStamp) {
    latestPlayoutHostTime.store(
      timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : 0,
      ordering: .relaxed
    )
    latestPlayoutSampleTimeBits.store(
      timestamp.mSampleTime.bitPattern,
      ordering: .relaxed
    )
    latestPlayoutTimestampFlags.store(timestamp.mFlags.rawValue, ordering: .releasing)
  }

  func makePlayoutTimestamp(queuedFrames: UInt32) -> AudioTimeStamp {
    let flags = AudioTimeStampFlags(
      rawValue: latestPlayoutTimestampFlags.load(ordering: .acquiring)
    )
    var timestamp = AudioTimeStamp()
    timestamp.mFlags = flags
    timestamp.mHostTime = latestPlayoutHostTime.load(ordering: .relaxed)
    timestamp.mSampleTime = Double(
      bitPattern: latestPlayoutSampleTimeBits.load(ordering: .relaxed)
    )
    if !timestamp.mFlags.contains(.hostTimeValid) || timestamp.mHostTime == 0 {
      timestamp.mFlags.insert(.hostTimeValid)
      timestamp.mHostTime = AudioGetCurrentHostTime()
    }
    if queuedFrames > 0 {
      let nanoseconds = UInt64(
        (Double(queuedFrames) * 1_000_000_000 / MacGridAUHALFormat.sampleRate)
          .rounded()
      )
      timestamp.mHostTime &+= AudioConvertNanosToHostTime(nanoseconds)
      if timestamp.mFlags.contains(.sampleTimeValid) {
        timestamp.mSampleTime += Double(queuedFrames)
      }
    }
    return timestamp
  }

  // swiftlint:disable:next function_parameter_count
  func updateWorkerControl(
    desiredActive: ManagedAtomic<Bool>,
    desiredGeneration: ManagedAtomic<UInt64>,
    processedGeneration: ManagedAtomic<UInt64>,
    workerActive: ManagedAtomic<Bool>,
    wake: semaphore_t,
    acknowledged: semaphore_t,
    active: Bool,
    forceTransition: Bool = false,
    timeout: TimeInterval
  ) -> Bool {
    guard !terminating.load(ordering: .acquiring) else { return false }
    if !forceTransition,
       desiredActive.load(ordering: .acquiring) == active,
       workerActive.load(ordering: .acquiring) == active {
      return true
    }
    let noWait = mach_timespec_t(tv_sec: 0, tv_nsec: 0)
    while semaphore_timedwait(acknowledged, noWait) == KERN_SUCCESS {}
    let targetGeneration = desiredGeneration.load(ordering: .relaxed) &+ 1
    desiredActive.store(active, ordering: .relaxed)
    desiredGeneration.store(targetGeneration, ordering: .releasing)
    semaphore_signal(wake)
    if processedGeneration.load(ordering: .acquiring) == targetGeneration {
      return workerActive.load(ordering: .acquiring) == active
    }
    let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
    var machTimeout = mach_timespec_t(
      tv_sec: UInt32(timeoutNanoseconds / 1_000_000_000),
      tv_nsec: Int32(timeoutNanoseconds % 1_000_000_000)
    )
    repeat {
      let status = semaphore_timedwait(acknowledged, machTimeout)
      if processedGeneration.load(ordering: .acquiring) == targetGeneration {
        return workerActive.load(ordering: .acquiring) == active
      }
      if status == KERN_OPERATION_TIMED_OUT { return false }
      machTimeout = mach_timespec_t(tv_sec: 0, tv_nsec: 1_000_000)
    } while !terminating.load(ordering: .acquiring)
    return false
  }

  static func makeSemaphore(operation: String) throws -> semaphore_t {
    var semaphore: semaphore_t = 0
    let status = semaphore_create(
      mach_task_self_,
      &semaphore,
      SYNC_POLICY_FIFO,
      0
    )
    guard status == KERN_SUCCESS else {
      throw MacGridWebRTCAudioBridgeError.mach(status, operation: operation)
    }
    return semaphore
  }

  // swiftlint:disable:next large_tuple
  static func makeSemaphores() throws -> (
    captureWake: semaphore_t,
    captureControlAcknowledged: semaphore_t,
    playoutWake: semaphore_t,
    playoutControlAcknowledged: semaphore_t
  ) {
    var created: [semaphore_t] = []
    do {
      let captureWake = try makeSemaphore(operation: "create capture wake semaphore")
      created.append(captureWake)
      let captureControlAcknowledged = try makeSemaphore(
        operation: "create capture control semaphore"
      )
      created.append(captureControlAcknowledged)
      let playoutWake = try makeSemaphore(operation: "create playout wake semaphore")
      created.append(playoutWake)
      let playoutControlAcknowledged = try makeSemaphore(
        operation: "create playout control semaphore"
      )
      return (
        captureWake,
        captureControlAcknowledged,
        playoutWake,
        playoutControlAcknowledged
      )
    } catch {
      // A throwing Swift initializer does not own raw Mach ports through ARC.
      // Explicitly release every port created before the partial failure.
      created.forEach(destroySemaphore)
      throw error
    }
  }

  static func destroySemaphore(_ semaphore: semaphore_t) {
    semaphore_destroy(mach_task_self_, semaphore)
  }

  static func wait(_ semaphore: semaphore_t) {
    let timeout = mach_timespec_t(tv_sec: 0, tv_nsec: 100_000_000)
    semaphore_timedwait(semaphore, timeout)
  }

  static func waitForCallbacksToDrain(_ counter: ManagedAtomic<UInt32>) {
    while counter.load(ordering: .acquiring) > 0 {
      sched_yield()
    }
  }

  static func spawnThread(
    name: String,
    owner: MacGridWebRTCAudioBridge,
    entry: @escaping @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
  ) throws -> pthread_t {
    var thread: pthread_t?
    let status = pthread_create(
      &thread,
      nil,
      entry,
      Unmanaged.passUnretained(owner).toOpaque()
    )
    guard status == 0, let thread else {
      throw MacGridWebRTCAudioBridgeError.pthread(status, operation: "start \(name)")
    }
    return thread
  }
}

private enum MacGridNativeCaptureProcessingResult {
  case success
  case conversionFailure(OSStatus)
  case packetizationFailure(OSStatus)
  case downstreamFailure
}

private final class MacGridCaptureWorkerDeliveryDelegate:
  CustomAudioDeviceDelegate, @unchecked Sendable {
  private unowned let owner: MacGridWebRTCAudioBridge
  private(set) var deliveryCount: UInt64 = 0

  init(owner: MacGridWebRTCAudioBridge) {
    self.owner = owner
  }

  var preferredInputSampleRate: Double { owner.preferredInputSampleRate }
  var preferredInputIOBufferDuration: TimeInterval {
    owner.preferredInputIOBufferDuration
  }
  var preferredOutputSampleRate: Double { owner.preferredOutputSampleRate }
  var preferredOutputIOBufferDuration: TimeInterval {
    owner.preferredOutputIOBufferDuration
  }

  func deliverRecordedData(_ data: CustomAudioDeviceRecordedData) -> OSStatus {
    deliveryCount &+= 1
    return owner.deliverCapturePacketToUpstream(data)
  }

  func getPlayoutData(
    _ context: CustomAudioDeviceIOContext,
    outputData: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus {
    owner.getPlayoutData(context, outputData: outputData)
  }

  func notifyAudioInputParametersChange() {
    owner.notifyAudioInputParametersChange()
  }

  func notifyAudioOutputParametersChange() {
    owner.notifyAudioOutputParametersChange()
  }

  func notifyAudioInputInterrupted() { owner.notifyAudioInputInterrupted() }
  func notifyAudioOutputInterrupted() { owner.notifyAudioOutputInterrupted() }

  func dispatchAsync(_ block: @escaping @Sendable () -> Void) {
    owner.dispatchAsync(block)
  }

  func dispatchSync(_ block: @escaping @Sendable () -> Void) {
    owner.dispatchSync(block)
  }
}

private final class MacGridNativeCaptureConverter {
  private let converter: AVAudioConverter
  private let inputBuffer: AVAudioPCMBuffer
  private let outputBuffer: AVAudioPCMBuffer
  private let packetizer: MacGridAudioCapturePacketizer
  private let packetDelegate: MacGridCaptureWorkerDeliveryDelegate

  init(
    nativeSampleRate: Double,
    maximumInputFrames: UInt32,
    packetDelegate: MacGridWebRTCAudioBridge
  ) throws {
    guard nativeSampleRate.isFinite, nativeSampleRate > 0,
          let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nativeSampleRate,
            channels: 1,
            interleaved: true
          ),
          let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: MacGridAUHALFormat.sampleRate,
            channels: 1,
            interleaved: true
          ),
          let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
          let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(maximumInputFrames)
          )
    else {
      throw MacGridCoreAudioError.unavailable(
        "The native WebRTC capture converter is unavailable."
      )
    }
    let ratio = MacGridAUHALFormat.sampleRate / nativeSampleRate
    let maximumOutputFrames = AVAudioFrameCount(
      ceil(Double(maximumInputFrames) * ratio)
        + Double(MacGridAudioCapturePacketizer.framesPerPacket)
    )
    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: maximumOutputFrames
    ) else {
      throw MacGridCoreAudioError.unavailable(
        "The converted WebRTC capture buffer is unavailable."
      )
    }
    converter.primeMethod = .none
    self.converter = converter
    self.inputBuffer = inputBuffer
    self.outputBuffer = outputBuffer
    self.packetDelegate = MacGridCaptureWorkerDeliveryDelegate(
      owner: packetDelegate
    )
    packetizer = try MacGridAudioCapturePacketizer()
  }

  var pendingPacketFrameCount: UInt32 { packetizer.pendingFrameCount }
  var timestampDiscontinuityCount: UInt64 {
    packetizer.timestampDiscontinuityCount
  }
  var continuousFrameCount: UInt64 { packetizer.continuousFrameCount }

  func convert(
    samples: UnsafePointer<Float>,
    frameCount: UInt32,
    timestamp: AudioTimeStamp,
    actionFlags: AudioUnitRenderActionFlags
  ) -> MacGridNativeCaptureProcessingResult {
    guard frameCount > 0,
          frameCount <= UInt32(inputBuffer.frameCapacity),
          let inputData = inputBuffer.mutableAudioBufferList.pointee.mBuffers.mData,
          let outputData = outputBuffer.mutableAudioBufferList.pointee.mBuffers.mData
    else { return .conversionFailure(kAudio_ParamError) }

    UnsafeMutableRawPointer(inputData).copyMemory(
      from: UnsafeRawPointer(samples),
      byteCount: Int(frameCount) * MemoryLayout<Float>.size
    )
    inputBuffer.frameLength = AVAudioFrameCount(frameCount)
    outputBuffer.frameLength = 0
    var suppliedInput = false
    var conversionError: NSError?
    let conversionStatus = converter.convert(
      to: outputBuffer,
      error: &conversionError
    ) { _, inputStatus in
      guard !suppliedInput else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      suppliedInput = true
      inputStatus.pointee = .haveData
      return self.inputBuffer
    }
    guard conversionStatus != .error, conversionError == nil else {
      return .conversionFailure(
        conversionError.map { OSStatus(truncatingIfNeeded: $0.code) }
          ?? kAudio_ParamError
      )
    }

    let convertedFrames = UInt32(outputBuffer.frameLength)
    guard convertedFrames > 0 else { return .success }
    var convertedTimestamp = timestamp
    convertedTimestamp.mSampleTime = 0
    convertedTimestamp.mFlags.remove(.sampleTimeValid)
    var packetFlags = actionFlags
    let convertedSamples = outputData.assumingMemoryBound(to: Int16.self)
    let span = unsafe Swift.Span(
      _unsafeStart: UnsafePointer(convertedSamples),
      count: Int(convertedFrames)
    )
    let deliveryCount = packetDelegate.deliveryCount
    let status = packetizer.append(
      samples: span,
      timestamp: convertedTimestamp,
      actionFlags: &packetFlags,
      delegate: packetDelegate
    )
    guard status != noErr else { return .success }
    return packetDelegate.deliveryCount > deliveryCount
      ? .downstreamFailure
      : .packetizationFailure(status)
  }
}

struct MacGridNativeCaptureSliceMetadata {
  let frameCount: UInt32
  let timestamp: AudioTimeStamp
  let actionFlags: AudioUnitRenderActionFlags
  let busNumber: Int
}

/// One physical AUHAL callback produces native Float32 slices and the one
/// persistent capture worker consumes them. Publication occurs only after a
/// complete bounded copy into a producer-owned slot.
final class MacGridNativeCaptureSliceRing: @unchecked Sendable {
  private let maximumFramesPerSlice: UInt32
  private let sliceCapacity: UInt64
  private let samples: UnsafeMutablePointer<Float>
  private let metadata: UnsafeMutablePointer<MacGridNativeCaptureSliceMetadata>
  private let writeIndex = ManagedAtomic<UInt64>(0)
  private let readIndex = ManagedAtomic<UInt64>(0)
  private let queuedFrames = ManagedAtomic<UInt64>(0)

  init(maximumFramesPerSlice: UInt32, sliceCapacity: Int) {
    self.maximumFramesPerSlice = maximumFramesPerSlice
    self.sliceCapacity = UInt64(sliceCapacity)
    samples = .allocate(capacity: Int(maximumFramesPerSlice) * sliceCapacity)
    metadata = .allocate(capacity: sliceCapacity)
  }

  deinit {
    samples.deallocate()
    metadata.deallocate()
  }

  var availableSliceCount: UInt32 {
    let write = writeIndex.load(ordering: .acquiring)
    let read = readIndex.load(ordering: .acquiring)
    return UInt32(min(write &- read, sliceCapacity))
  }

  var availableFrameCount: UInt64 {
    queuedFrames.load(ordering: .acquiring)
  }

  func write(
    samples source: UnsafePointer<Float>,
    frameCount: UInt32,
    timestamp: AudioTimeStamp,
    actionFlags: AudioUnitRenderActionFlags,
    busNumber: Int
  ) -> Bool {
    guard frameCount > 0, frameCount <= maximumFramesPerSlice else {
      return false
    }
    let write = writeIndex.load(ordering: .relaxed)
    let read = readIndex.load(ordering: .acquiring)
    guard write &- read < sliceCapacity else { return false }
    let slot = Int(write % sliceCapacity)
    let destination = samples.advanced(
      by: slot * Int(maximumFramesPerSlice)
    )
    UnsafeMutableRawPointer(destination).copyMemory(
      from: UnsafeRawPointer(source),
      byteCount: Int(frameCount) * MemoryLayout<Float>.size
    )
    metadata[slot] = MacGridNativeCaptureSliceMetadata(
      frameCount: frameCount,
      timestamp: timestamp,
      actionFlags: actionFlags,
      busNumber: busNumber
    )
    queuedFrames.wrappingIncrement(by: UInt64(frameCount), ordering: .relaxed)
    writeIndex.store(write &+ 1, ordering: .releasing)
    return true
  }

  func read(
    _ body: (UnsafePointer<Float>, MacGridNativeCaptureSliceMetadata) -> Void
  ) -> Bool {
    let read = readIndex.load(ordering: .relaxed)
    let write = writeIndex.load(ordering: .acquiring)
    guard read != write else { return false }
    let slot = Int(read % sliceCapacity)
    let source = UnsafePointer(
      samples.advanced(by: slot * Int(maximumFramesPerSlice))
    )
    let sliceMetadata = metadata[slot]
    body(source, sliceMetadata)
    queuedFrames.wrappingDecrement(
      by: UInt64(sliceMetadata.frameCount),
      ordering: .relaxed
    )
    // Publish slot reuse only after every read from its sample and metadata
    // storage is complete. The producer may overwrite it immediately after
    // this release.
    readIndex.store(read &+ 1, ordering: .releasing)
    return true
  }

  func reset() {
    readIndex.store(0, ordering: .relaxed)
    queuedFrames.store(0, ordering: .relaxed)
    writeIndex.store(0, ordering: .releasing)
  }
}

struct MacGridCapturePacketMetadata {
  let timestamp: AudioTimeStamp
  let actionFlags: AudioUnitRenderActionFlags
  let busNumber: Int
}

/// One physical callback produces packets and one persistent capture worker
/// consumes them. Unsafe storage is confined to this ownership proof.
final class MacGridCapturePacketRing: @unchecked Sendable {
  private let framesPerPacket: UInt32
  private let packetCapacity: UInt64
  private let samples: UnsafeMutablePointer<Int16>
  private let metadata: UnsafeMutablePointer<MacGridCapturePacketMetadata>
  private let writeIndex = ManagedAtomic<UInt64>(0)
  private let readIndex = ManagedAtomic<UInt64>(0)

  init(framesPerPacket: UInt32, packetCapacity: Int) {
    self.framesPerPacket = framesPerPacket
    self.packetCapacity = UInt64(packetCapacity)
    samples = .allocate(capacity: Int(framesPerPacket) * packetCapacity)
    metadata = .allocate(capacity: packetCapacity)
  }

  deinit {
    samples.deallocate()
    metadata.deallocate()
  }

  var availablePacketCount: UInt32 {
    let write = writeIndex.load(ordering: .acquiring)
    let read = readIndex.load(ordering: .acquiring)
    return UInt32(min(write &- read, packetCapacity))
  }

  func write(
    samples source: UnsafePointer<Int16>,
    timestamp: AudioTimeStamp,
    actionFlags: AudioUnitRenderActionFlags,
    busNumber: Int
  ) -> Bool {
    let write = writeIndex.load(ordering: .relaxed)
    let read = readIndex.load(ordering: .acquiring)
    guard write &- read < packetCapacity else { return false }
    let slot = Int(write % packetCapacity)
    let destination = samples.advanced(by: slot * Int(framesPerPacket))
    // SAFETY: each producer-owned slot has exactly `framesPerPacket` Int16
    // elements. Publication happens only after this bounded non-overlapping copy.
    UnsafeMutableRawPointer(destination).copyMemory(
      from: UnsafeRawPointer(source),
      byteCount: Int(framesPerPacket) * MemoryLayout<Int16>.size
    )
    metadata[slot] = MacGridCapturePacketMetadata(
      timestamp: timestamp,
      actionFlags: actionFlags,
      busNumber: busNumber
    )
    writeIndex.store(write &+ 1, ordering: .releasing)
    return true
  }

  func read(
    _ body: (UnsafePointer<Int16>, MacGridCapturePacketMetadata) -> Void
  ) -> Bool {
    let read = readIndex.load(ordering: .relaxed)
    let write = writeIndex.load(ordering: .acquiring)
    guard read != write else { return false }
    let slot = Int(read % packetCapacity)
    let source = UnsafePointer(samples.advanced(by: slot * Int(framesPerPacket)))
    body(source, metadata[slot])
    readIndex.store(read &+ 1, ordering: .releasing)
    return true
  }

  func reset() {
    readIndex.store(0, ordering: .relaxed)
    writeIndex.store(0, ordering: .releasing)
  }
}

/// One persistent render worker produces samples and one physical callback
/// consumes them. Frame counters publish only fully copied interleaved PCM.
final class MacGridPlayoutSampleRing: @unchecked Sendable {
  private let channels: UInt32
  private let capacityFrames: UInt64
  private let samples: UnsafeMutablePointer<Int16>
  private let writeFrame = ManagedAtomic<UInt64>(0)
  private let readFrame = ManagedAtomic<UInt64>(0)

  init(channels: UInt32, capacityFrames: UInt32) {
    self.channels = channels
    self.capacityFrames = UInt64(capacityFrames)
    samples = .allocate(capacity: Int(channels * capacityFrames))
  }

  deinit { samples.deallocate() }

  var availableFrames: UInt32 {
    let write = writeFrame.load(ordering: .acquiring)
    let read = readFrame.load(ordering: .acquiring)
    return UInt32(min(write &- read, capacityFrames))
  }

  var writableFrames: UInt32 {
    UInt32(capacityFrames) - availableFrames
  }

  func write(samples source: UnsafePointer<Int16>, frameCount: UInt32) -> Bool {
    let write = writeFrame.load(ordering: .relaxed)
    let read = readFrame.load(ordering: .acquiring)
    guard write &- read + UInt64(frameCount) <= capacityFrames else { return false }
    copyIntoRing(source: source, startFrame: write, frameCount: frameCount)
    writeFrame.store(write &+ UInt64(frameCount), ordering: .releasing)
    return true
  }

  func read(
    into destination: UnsafeMutablePointer<Int16>,
    maximumFrames: UInt32
  ) -> UInt32 {
    let read = readFrame.load(ordering: .relaxed)
    let write = writeFrame.load(ordering: .acquiring)
    let frameCount = UInt32(min(write &- read, UInt64(maximumFrames)))
    guard frameCount > 0 else { return 0 }
    copyFromRing(destination: destination, startFrame: read, frameCount: frameCount)
    readFrame.store(read &+ UInt64(frameCount), ordering: .releasing)
    return frameCount
  }

  func reset() {
    readFrame.store(0, ordering: .relaxed)
    writeFrame.store(0, ordering: .releasing)
  }

  private func copyIntoRing(
    source: UnsafePointer<Int16>,
    startFrame: UInt64,
    frameCount: UInt32
  ) {
    let firstFrames = min(
      UInt64(frameCount),
      capacityFrames - (startFrame % capacityFrames)
    )
    copy(
      from: source,
      to: samples.advanced(by: Int((startFrame % capacityFrames) * UInt64(channels))),
      frames: UInt32(firstFrames)
    )
    let remaining = frameCount - UInt32(firstFrames)
    if remaining > 0 {
      copy(
        from: source.advanced(by: Int(firstFrames * UInt64(channels))),
        to: samples,
        frames: remaining
      )
    }
  }

  private func copyFromRing(
    destination: UnsafeMutablePointer<Int16>,
    startFrame: UInt64,
    frameCount: UInt32
  ) {
    let firstFrames = min(
      UInt64(frameCount),
      capacityFrames - (startFrame % capacityFrames)
    )
    copy(
      from: UnsafePointer(
        samples.advanced(by: Int((startFrame % capacityFrames) * UInt64(channels)))
      ),
      to: destination,
      frames: UInt32(firstFrames)
    )
    let remaining = frameCount - UInt32(firstFrames)
    if remaining > 0 {
      copy(
        from: UnsafePointer(samples),
        to: destination.advanced(by: Int(firstFrames * UInt64(channels))),
        frames: remaining
      )
    }
  }

  private func copy(
    from source: UnsafePointer<Int16>,
    to destination: UnsafeMutablePointer<Int16>,
    frames: UInt32
  ) {
    // SAFETY: the caller splits wraparound into regions within the preallocated
    // ring and the caller-provided buffer. Producer and consumer own disjoint
    // published regions under the acquire/release frame counters.
    UnsafeMutableRawPointer(destination).copyMemory(
      from: UnsafeRawPointer(source),
      byteCount: Int(frames * channels) * MemoryLayout<Int16>.size
    )
  }
}

enum MacGridWebRTCAudioBridgeError: LocalizedError, Sendable {
  case mach(kern_return_t, operation: String)
  case pthread(Int32, operation: String)

  var errorDescription: String? {
    switch self {
    case let .mach(status, operation):
      "The \(operation) operation failed with Mach status \(status)."
    case let .pthread(status, operation):
      "The \(operation) operation failed with pthread status \(status)."
    }
  }
}
#endif
