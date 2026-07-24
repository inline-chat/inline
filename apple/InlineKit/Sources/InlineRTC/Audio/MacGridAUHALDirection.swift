#if os(macOS)
import Atomics
import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Foundation
import LiveKit

enum MacGridAUHALFormat {
  static let sampleRate = 48_000.0
  static let inputChannels: UInt32 = 1
  static let outputChannels: UInt32 = 2
  static let maximumFramesPerSlice: UInt32 = 16_384

  static func signedInt16(channels: UInt32) -> AudioStreamBasicDescription {
    let bytesPerFrame = channels * UInt32(MemoryLayout<Int16>.size)
    return AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: channels,
      mBitsPerChannel: 16,
      mReserved: 0
    )
  }

  static func float32(
    sampleRate: Double,
    channels: UInt32
  ) -> AudioStreamBasicDescription {
    let bytesPerFrame = channels * UInt32(MemoryLayout<Float>.size)
    return AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: channels,
      mBitsPerChannel: 32,
      mReserved: 0
    )
  }
}

enum MacGridAUHALInputStartFailurePolicy {
  static func isRetryableTransitionFailure(
    callbackCount: UInt64,
    frameCount: UInt64,
    physicalRenderErrorCount: UInt64,
    physicalCannotDoCount: UInt64,
    lastStatus: OSStatus
  ) -> Bool {
    callbackCount > 0
      && frameCount == 0
      && physicalRenderErrorCount == callbackCount
      && physicalCannotDoCount == callbackCount
      && lastStatus == kAudioUnitErr_CannotDoInCurrentContext
  }
}

struct MacGridAUHALDirectionHealth: Equatable, Sendable {
  let device: MacGridAudioDevice
  /// Direct readback from this direction's
  /// `kAudioOutputUnitProperty_CurrentDevice`. This is the authoritative
  /// physical route for the AUHAL instance; process-wide Core Audio device
  /// projections are retained only as corroborating diagnostics.
  let audioUnitDeviceID: AudioDeviceID?
  let isStarted: Bool
  let callbackCount: UInt64
  let frameCount: UInt64
  let lastCallbackFrameCount: UInt32
  let callbackAgeMilliseconds: UInt64?
  let hostTimestampCallbackCount: UInt64
  let hostTimestampMissingCount: UInt64
  let hostTimestampRegressionCount: UInt64
  let latestPhysicalHostTime: UInt64?
  let callbackErrorCount: UInt64
  let cannotDoInCurrentContextCount: UInt64
  let parameterErrorCount: UInt64
  let otherCallbackErrorCount: UInt64
  /// Input-only failures returned directly by `AudioUnitRender`. These are
  /// separate from a successful physical render whose downstream WebRTC
  /// delivery later fails with the same OSStatus.
  let physicalRenderErrorCount: UInt64?
  let physicalCannotDoCount: UInt64?
  /// Failures publishing rendered physical PCM into the stable bridge. Actual
  /// worker-to-WebRTC delivery has an independent bridge counter.
  let bridgePublicationErrorCount: UInt64?
  /// Frames currently retained before WebRTC in the bounded 10 ms capture
  /// packetizer. `nil` for playout directions.
  let packetizerPendingFrameCount: UInt32?
  let packetizerTimestampDiscontinuityCount: UInt64?
  /// Frames observed since the most recent packetizer timestamp anomaly.
  /// `nil` for playout directions.
  let packetizerContinuousFrameCount: UInt64?
  /// The output-silence action flag is asserted by native WebRTC while its
  /// playout gate is closed, and by this direction after a failed PCM pull.
  /// Both values are `nil` for capture directions.
  let outputSilenceFlagCallbackCount: UInt64?
  let latestOutputCallbackWasSilence: Bool?
  let latencyMilliseconds: UInt16
  let lastStatus: OSStatus

  var hasFreshCallbacks: Bool {
    isStarted
      && callbackCount > 0
      && lastStatus == noErr
      && callbackAgeMilliseconds.map { $0 <= 500 } == true
  }

  /// WebRTC's custom-device adapter derives capture timestamps exclusively
  /// from Core Audio host time. Missing or regressing host time therefore
  /// means PCM callbacks alone cannot prove an AEC-safe capture route.
  var hasContinuousPhysicalHostTime: Bool {
    callbackCount > 0
      && hostTimestampCallbackCount > 0
      && packetizerPendingFrameCount.map {
        $0 < MacGridAudioCapturePacketizer.framesPerPacket
      } != false
      && packetizerContinuousFrameCount.map {
        $0 >= UInt64(MacGridAudioCapturePacketizer.framesPerPacket)
      } != false
      && latestPhysicalHostTime != nil
  }

  var hasVerifiedDeviceReadback: Bool {
    audioUnitDeviceID == device.id
  }

  var hasActivePlayoutCallbacks: Bool {
    hasFreshCallbacks && latestOutputCallbackWasSilence != true
  }
}

protocol MacGridAUHALDirectionControlling: AnyObject, Sendable {
  var device: MacGridAudioDevice { get }
  var latencyNanoseconds: UInt64 { get }
  var isRunning: Bool { get }

  func start(operation: String, timeout: TimeInterval) throws
  func stop(operation: String) throws
  func health() -> MacGridAUHALDirectionHealth
}

struct MacGridAUHALDirectionFactory: Sendable {
  let makeInput: @Sendable (
    MacGridAudioDevice,
    any CustomAudioDeviceDelegate
  ) throws -> any MacGridAUHALDirectionControlling
  let makeOutput: @Sendable (
    MacGridAudioDevice,
    any CustomAudioDeviceDelegate
  ) throws -> any MacGridAUHALDirectionControlling

  static let live = MacGridAUHALDirectionFactory(
    makeInput: { device, delegate in
      try MacGridAUHALInput(device: device, delegate: delegate)
    },
    makeOutput: { device, delegate in
      try MacGridAUHALOutput(device: device, delegate: delegate)
    }
  )
}

class MacGridAUHALDirectionBase: MacGridAUHALDirectionControlling, @unchecked Sendable {
  let device: MacGridAudioDevice
  let delegate: any CustomAudioDeviceDelegate
  let firstCallback = DispatchSemaphore(value: 0)
  let firstCallbackPending = ManagedAtomic(false)
  let running = ManagedAtomic(false)
  let callbackCount = ManagedAtomic<UInt64>(0)
  let frameCount = ManagedAtomic<UInt64>(0)
  let lastCallbackFrameCount = ManagedAtomic<UInt32>(0)
  let latestCallbackHostTime = ManagedAtomic<UInt64>(0)
  let hostTimestampCallbackCount = ManagedAtomic<UInt64>(0)
  let hostTimestampMissingCount = ManagedAtomic<UInt64>(0)
  let hostTimestampRegressionCount = ManagedAtomic<UInt64>(0)
  let latestPhysicalHostTime = ManagedAtomic<UInt64>(0)
  let callbackErrorCount = ManagedAtomic<UInt64>(0)
  let cannotDoInCurrentContextCount = ManagedAtomic<UInt64>(0)
  let parameterErrorCount = ManagedAtomic<UInt64>(0)
  let otherCallbackErrorCount = ManagedAtomic<UInt64>(0)
  let lastStatus = ManagedAtomic<OSStatus>(noErr)
  private let callbacksInFlight = ManagedAtomic<UInt32>(0)
  private(set) var latencyNanoseconds: UInt64
  var audioUnit: AudioUnit!

  var isRunning: Bool { running.load(ordering: .acquiring) }

  init(
    device: MacGridAudioDevice,
    delegate: any CustomAudioDeviceDelegate,
    direction: MacGridAUHALLatency.Direction,
    packetizationLatency: TimeInterval = 0
  ) {
    self.device = device
    self.delegate = delegate
    latencyNanoseconds = UInt64(
      max(
        MacGridAUHALLatency.measure(
          device: device,
          direction: direction,
          packetizationLatency: packetizationLatency
        ),
        0
      ) * 1_000_000_000
    )
  }

  deinit {
    running.store(false, ordering: .releasing)
    if let audioUnit {
      AudioOutputUnitStop(audioUnit)
      _ = waitForCallbacksToDrain()
      AudioUnitUninitialize(audioUnit)
      AudioComponentInstanceDispose(audioUnit)
    }
  }

  func start(operation: String, timeout: TimeInterval = 2) throws {
    let alreadyOwned = running.exchange(true, ordering: .acquiringAndReleasing)
    // A callback can win the timeout race after the previous waiter returns.
    // Drain that signal before establishing the counter baseline for this
    // start; semaphore wakeup alone and an old `running` ownership bit are
    // never accepted as current physical progress.
    while firstCallback.wait(timeout: .now()) == .success {}
    let startingCallbackCount = callbackCount.load(ordering: .relaxed)
    firstCallbackPending.store(true, ordering: .releasing)
    if !alreadyOwned {
      let status = AudioOutputUnitStart(audioUnit)
      guard status == noErr else {
        firstCallbackPending.store(false, ordering: .releasing)
        running.store(false, ordering: .releasing)
        lastStatus.store(status, ordering: .relaxed)
        throw MacGridCoreAudioError.status(status, operation: operation)
      }
    }
    let deadline = DispatchTime.now() + timeout
    var producedFreshSuccessfulCallback = false
    while DispatchTime.now() < deadline {
      // Arm before checking the counter. If a callback lands between the
      // counter check and the semaphore wait, it either advances the counter
      // before this read or consumes `firstCallbackPending` and signals the
      // waiter. This closes the classic missed-wakeup window without putting
      // a lock or allocation on the Core Audio thread.
      firstCallbackPending.store(true, ordering: .releasing)
      let callbacks = callbackCount.load(ordering: .relaxed)
      let callbackStatus = lastStatus.load(ordering: .relaxed)
      let callbackFrames = lastCallbackFrameCount.load(ordering: .relaxed)
      if callbacks > startingCallbackCount,
         callbackStatus == noErr,
         callbackFrames > 0 {
        firstCallbackPending.store(false, ordering: .releasing)
        producedFreshSuccessfulCallback = true
        break
      }
      guard firstCallback.wait(timeout: deadline) == .success else { break }
      // A stale notification or failed callback cannot start the direction.
      // Re-arm and re-check for a later successful callback within the same
      // absolute deadline.
    }
    guard producedFreshSuccessfulCallback else {
      firstCallbackPending.store(false, ordering: .releasing)
      let stopStatus: OSStatus?
      if alreadyOwned {
        // This call did not acquire the existing physical owner, so it cannot
        // discard it merely because progress could not be reproved. Keep the
        // direction visible for explicit recovery or terminal cleanup.
        running.store(true, ordering: .releasing)
        stopStatus = nil
      } else {
        running.store(false, ordering: .releasing)
        let status = AudioOutputUnitStop(audioUnit)
        stopStatus = status
        if status != noErr {
          // A failed stop cannot release physical ownership. Keep the direction
          // retryable and visible to terminal shutdown/readback.
          running.store(true, ordering: .releasing)
        }
      }
      let observedCallbacks = callbackCount.load(ordering: .relaxed)
        &- startingCallbackCount
      let stopDescription = stopStatus.map(String.init)
        ?? "retained_existing_owner"
      throw MacGridCoreAudioError.unavailable(
        "The \(operation) Audio Unit produced no fresh successful callbacks "
          + "(callbacks=\(observedCallbacks) "
          + "frames=\(lastCallbackFrameCount.load(ordering: .relaxed)) "
          + "status=\(lastStatus.load(ordering: .relaxed)) "
          + "stop_status=\(stopDescription))."
      )
    }
  }

  func stop(operation: String) throws {
    firstCallbackPending.store(false, ordering: .releasing)
    guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
    let status = AudioOutputUnitStop(audioUnit)
    lastStatus.store(status, ordering: .relaxed)
    if status != noErr {
      // Core Audio did not acknowledge release of the physical direction.
      // Preserve ownership so route rollback or terminal cleanup can retry.
      running.store(true, ordering: .releasing)
    }
    try checkMacGridAudioStatus(status, operation)
    guard waitForCallbacksToDrain(timeout: 1) else {
      // The Audio Unit is stopped, but its unretained callback context cannot
      // be released until every callback that already entered has returned.
      // Retain ownership so route/terminal cleanup can retry instead of
      // converting a drain timeout into a use-after-free risk.
      running.store(true, ordering: .releasing)
      throw MacGridCoreAudioError.unavailable(
        "The \(operation) Audio Unit did not drain its in-flight callbacks."
      )
    }
  }

  /// Called only by the installed Core Audio callback thunk. These atomics are
  /// allocated with the direction, so callback entry and exit never allocate
  /// or acquire a lock.
  final func enterCallback() {
    callbacksInFlight.wrappingIncrement(ordering: .acquiringAndReleasing)
  }

  final func leaveCallback() {
    callbacksInFlight.wrappingDecrement(ordering: .acquiringAndReleasing)
  }

  private func waitForCallbacksToDrain(timeout: TimeInterval? = nil) -> Bool {
    let deadline = timeout.map { DispatchTime.now() + $0 }
    while callbacksInFlight.load(ordering: .acquiring) > 0 {
      if let deadline, DispatchTime.now() >= deadline { return false }
      sched_yield()
    }
    return true
  }

  func observeCallback(
    frameCount newFrames: UInt32,
    status: OSStatus,
    timestamp: AudioTimeStamp
  ) {
    latestCallbackHostTime.store(AudioGetCurrentHostTime(), ordering: .relaxed)
    callbackCount.wrappingIncrement(ordering: .relaxed)
    lastCallbackFrameCount.store(newFrames, ordering: .relaxed)
    if timestamp.mFlags.contains(.hostTimeValid), timestamp.mHostTime > 0 {
      hostTimestampCallbackCount.wrappingIncrement(ordering: .relaxed)
      let previous = latestPhysicalHostTime.exchange(
        timestamp.mHostTime,
        ordering: .acquiringAndReleasing
      )
      if previous > 0, timestamp.mHostTime <= previous {
        hostTimestampRegressionCount.wrappingIncrement(ordering: .relaxed)
      }
    } else {
      hostTimestampMissingCount.wrappingIncrement(ordering: .relaxed)
    }
    if status == noErr {
      frameCount.wrappingIncrement(by: UInt64(newFrames), ordering: .relaxed)
    } else {
      callbackErrorCount.wrappingIncrement(ordering: .relaxed)
      switch status {
      case kAudioUnitErr_CannotDoInCurrentContext:
        cannotDoInCurrentContextCount.wrappingIncrement(ordering: .relaxed)
      case kAudio_ParamError:
        parameterErrorCount.wrappingIncrement(ordering: .relaxed)
      default:
        otherCallbackErrorCount.wrappingIncrement(ordering: .relaxed)
      }
    }
    lastStatus.store(status, ordering: .relaxed)
    if firstCallbackPending.exchange(false, ordering: .acquiringAndReleasing) {
      firstCallback.signal()
    }
  }

  func health() -> MacGridAUHALDirectionHealth {
    let latest = latestCallbackHostTime.load(ordering: .relaxed)
    return MacGridAUHALDirectionHealth(
      device: device,
      audioUnitDeviceID: currentAudioUnitDeviceID(),
      isStarted: running.load(ordering: .acquiring),
      callbackCount: callbackCount.load(ordering: .relaxed),
      frameCount: frameCount.load(ordering: .relaxed),
      lastCallbackFrameCount: lastCallbackFrameCount.load(ordering: .relaxed),
      callbackAgeMilliseconds: Self.callbackAgeMilliseconds(latestHostTime: latest),
      hostTimestampCallbackCount: hostTimestampCallbackCount.load(ordering: .relaxed),
      hostTimestampMissingCount: hostTimestampMissingCount.load(ordering: .relaxed),
      hostTimestampRegressionCount: hostTimestampRegressionCount.load(ordering: .relaxed),
      latestPhysicalHostTime: Self.optionalHostTime(
        latestPhysicalHostTime.load(ordering: .relaxed)
      ),
      callbackErrorCount: callbackErrorCount.load(ordering: .relaxed),
      cannotDoInCurrentContextCount: cannotDoInCurrentContextCount.load(ordering: .relaxed),
      parameterErrorCount: parameterErrorCount.load(ordering: .relaxed),
      otherCallbackErrorCount: otherCallbackErrorCount.load(ordering: .relaxed),
      physicalRenderErrorCount: currentPhysicalRenderErrorCount(),
      physicalCannotDoCount: currentPhysicalCannotDoCount(),
      bridgePublicationErrorCount: currentBridgePublicationErrorCount(),
      packetizerPendingFrameCount: currentPacketizerPendingFrameCount(),
      packetizerTimestampDiscontinuityCount:
        currentPacketizerTimestampDiscontinuityCount(),
      packetizerContinuousFrameCount: currentPacketizerContinuousFrameCount(),
      outputSilenceFlagCallbackCount: currentOutputSilenceFlagCallbackCount(),
      latestOutputCallbackWasSilence: currentLatestOutputCallbackWasSilence(),
      latencyMilliseconds: UInt16(
        min(latencyNanoseconds / 1_000_000, UInt64(UInt16.max))
      ),
      lastStatus: lastStatus.load(ordering: .relaxed)
    )
  }

  private func currentAudioUnitDeviceID() -> AudioDeviceID? {
    guard let audioUnit else { return nil }
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitGetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &deviceID,
      &size
    )
    guard status == noErr,
          size == UInt32(MemoryLayout<AudioDeviceID>.size),
          deviceID != kAudioObjectUnknown
    else { return nil }
    return deviceID
  }

  func includeAudioUnitLatency() {
    var latency: TimeInterval = 0
    var size = UInt32(MemoryLayout<TimeInterval>.size)
    guard AudioUnitGetProperty(
      audioUnit,
      kAudioUnitProperty_Latency,
      kAudioUnitScope_Global,
      0,
      &latency,
      &size
    ) == noErr, latency.isFinite, latency > 0 else { return }
    latencyNanoseconds &+= UInt64(latency * 1_000_000_000)
  }

  func currentPacketizerPendingFrameCount() -> UInt32? { nil }

  func currentPacketizerTimestampDiscontinuityCount() -> UInt64? { nil }

  func currentPacketizerContinuousFrameCount() -> UInt64? { nil }

  func currentOutputSilenceFlagCallbackCount() -> UInt64? { nil }

  func currentLatestOutputCallbackWasSilence() -> Bool? { nil }

  func currentPhysicalRenderErrorCount() -> UInt64? { nil }

  func currentPhysicalCannotDoCount() -> UInt64? { nil }

  func currentBridgePublicationErrorCount() -> UInt64? { nil }

  private static func callbackAgeMilliseconds(latestHostTime: UInt64) -> UInt64? {
    guard latestHostTime > 0 else { return nil }
    let now = AudioGetCurrentHostTime()
    guard now >= latestHostTime else { return 0 }
    return AudioConvertHostTimeToNanos(now - latestHostTime) / 1_000_000
  }

  private static func optionalHostTime(_ hostTime: UInt64) -> UInt64? {
    hostTime == 0 ? nil : hostTime
  }
}

final class MacGridAUHALInput: MacGridAUHALDirectionBase, @unchecked Sendable {
  private let renderBuffer: AVAudioPCMBuffer
  private let renderData: UnsafeMutablePointer<Float>
  private let captureBridge: MacGridWebRTCAudioBridge
  private let nativeSampleRate: Double
  private let physicalRenderErrorCount = ManagedAtomic<UInt64>(0)
  private let physicalCannotDoCount = ManagedAtomic<UInt64>(0)
  private let bridgePublicationErrorCount = ManagedAtomic<UInt64>(0)

  init(device: MacGridAudioDevice, delegate: any CustomAudioDeviceDelegate) throws {
    guard let bridge = delegate as? MacGridWebRTCAudioBridge else {
      throw MacGridCoreAudioError.unavailable(
        "The stable WebRTC capture bridge is unavailable."
      )
    }
    let sampleRate = device.inputStreamFormat?.sampleRate ?? device.sampleRate
    guard sampleRate.isFinite, sampleRate > 0 else {
      throw MacGridCoreAudioError.unavailable(
        "The AUHAL microphone native sample rate is unavailable."
      )
    }
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: AVAudioChannelCount(MacGridAUHALFormat.inputChannels),
      interleaved: true
    ), let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(MacGridAUHALFormat.maximumFramesPerSlice)
    ), let data = buffer.mutableAudioBufferList.pointee.mBuffers.mData
    else {
      throw MacGridCoreAudioError.unavailable(
        "The AUHAL microphone render buffer is unavailable."
      )
    }
    captureBridge = bridge
    nativeSampleRate = sampleRate
    renderBuffer = buffer
    // SAFETY: `buffer` is interleaved Float32 PCM with the declared
    // maximum capacity. It strongly owns `mData` while this input direction is
    // alive, and the callback rejects frame counts beyond that capacity.
    renderData = data.assumingMemoryBound(to: Float.self)
    super.init(
      device: device,
      delegate: delegate,
      direction: .input,
      packetizationLatency: 0.010
    )
    audioUnit = try makeAudioUnit()
    includeAudioUnitLatency()
  }

  override func currentPhysicalRenderErrorCount() -> UInt64? {
    physicalRenderErrorCount.load(ordering: .relaxed)
  }

  override func currentPhysicalCannotDoCount() -> UInt64? {
    physicalCannotDoCount.load(ordering: .relaxed)
  }

  override func currentBridgePublicationErrorCount() -> UInt64? {
    bridgePublicationErrorCount.load(ordering: .relaxed)
  }

  override func currentPacketizerPendingFrameCount() -> UInt32? {
    captureBridge.capturePacketizerPendingFrameCount
  }

  override func currentPacketizerTimestampDiscontinuityCount() -> UInt64? {
    captureBridge.captureTimestampDiscontinuityCount
  }

  override func currentPacketizerContinuousFrameCount() -> UInt64? {
    captureBridge.capturePacketizerContinuousFrameCount
  }

  private func makeAudioUnit() throws -> AudioUnit {
    let unit = try Self.makeHALOutputUnit(operation: "create AUHAL microphone")
    do {
      var enabled: UInt32 = 1
      try Self.setProperty(
        unit,
        property: kAudioOutputUnitProperty_EnableIO,
        scope: kAudioUnitScope_Input,
        element: 1,
        value: &enabled,
        operation: "enable AUHAL microphone input"
      )
      var disabled: UInt32 = 0
      try Self.setProperty(
        unit,
        property: kAudioOutputUnitProperty_EnableIO,
        scope: kAudioUnitScope_Output,
        element: 0,
        value: &disabled,
        operation: "disable AUHAL microphone output"
      )
      var deviceID = device.id
      try Self.setProperty(
        unit,
        property: kAudioOutputUnitProperty_CurrentDevice,
        scope: kAudioUnitScope_Global,
        element: 0,
        value: &deviceID,
        operation: "select AUHAL microphone"
      )
      var maximumFrames = MacGridAUHALFormat.maximumFramesPerSlice
      try Self.setProperty(
        unit,
        property: kAudioUnitProperty_MaximumFramesPerSlice,
        scope: kAudioUnitScope_Global,
        element: 0,
        value: &maximumFrames,
        operation: "set AUHAL microphone maximum slice"
      )
      var format = MacGridAUHALFormat.float32(
        sampleRate: nativeSampleRate,
        channels: MacGridAUHALFormat.inputChannels
      )
      try Self.setProperty(
        unit,
        property: kAudioUnitProperty_StreamFormat,
        scope: kAudioUnitScope_Output,
        element: 1,
        value: &format,
        operation: "set AUHAL microphone client format"
      )
      // SAFETY: this direction owns `unit`, and its deinitializer stops,
      // uninitializes, and disposes the unit before `self` can die. Core Audio
      // therefore uses this unretained refcon only while `self` is alive.
      var callback = AURenderCallbackStruct(
        inputProc: Self.inputCallback,
        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
      )
      try Self.setProperty(
        unit,
        property: kAudioOutputUnitProperty_SetInputCallback,
        scope: kAudioUnitScope_Global,
        element: 0,
        value: &callback,
        operation: "install AUHAL microphone callback"
      )
      try checkMacGridAudioStatus(
        AudioUnitInitialize(unit),
        "initialize AUHAL microphone"
      )
      return unit
    } catch {
      AudioComponentInstanceDispose(unit)
      throw error
    }
  }

  private static let inputCallback: AURenderCallback = { refCon, flags, timestamp, _, frameCount, _ in
    // SAFETY: `refCon` was installed from this live direction, whose ownership
    // invariant is documented where the callback is registered.
    let owner = Unmanaged<MacGridAUHALInput>.fromOpaque(refCon).takeUnretainedValue()
    owner.enterCallback()
    defer { owner.leaveCallback() }
    return owner.render(
      flags: flags,
      timestamp: timestamp,
      frameCount: frameCount
    )
  }

  private func render(
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32
  ) -> OSStatus {
    guard running.load(ordering: .acquiring) else { return noErr }
    guard frameCount <= MacGridAUHALFormat.maximumFramesPerSlice else {
      observeCallback(
        frameCount: 0,
        status: kAudio_ParamError,
        timestamp: timestamp.pointee
      )
      // Keep Core Audio's callback thread alive. The typed failure remains in
      // health and forces recovery if successful callbacks do not resume.
      return noErr
    }
    renderBuffer.frameLength = AVAudioFrameCount(frameCount)
    let renderStatus = AudioUnitRender(
      audioUnit,
      flags,
      timestamp,
      1,
      frameCount,
      renderBuffer.mutableAudioBufferList
    )
    guard renderStatus == noErr else {
      physicalRenderErrorCount.wrappingIncrement(ordering: .relaxed)
      if renderStatus == kAudioUnitErr_CannotDoInCurrentContext {
        physicalCannotDoCount.wrappingIncrement(ordering: .relaxed)
      }
      observeCallback(
        frameCount: 0,
        status: renderStatus,
        timestamp: timestamp.pointee
      )
      // Device/profile transitions may temporarily reject AudioUnitRender.
      // Returning the transient status asks Core Audio to tear down the stream;
      // recording it while returning noErr lets the supervisor rebuild the
      // route directionally if the following callbacks do not recover.
      return noErr
    }
    // The callback performs one bounded copy into bridge-owned SPSC storage.
    // Conversion, packetization, and the WebRTC call all run later on the
    // persistent capture worker.
    let deliveryStatus = captureBridge.deliverNativeRecordedData(
      samples: UnsafePointer(renderData),
      frameCount: frameCount,
      timestamp: timestamp.pointee,
      actionFlags: flags.pointee,
      busNumber: 1
    )
    if deliveryStatus != noErr {
      bridgePublicationErrorCount.wrappingIncrement(ordering: .relaxed)
    }
    observeCallback(
      frameCount: frameCount,
      status: deliveryStatus,
      timestamp: timestamp.pointee
    )
    // A full capture bridge or transient timestamp rejection is a current
    // health failure, not a reason for Core Audio to kill the physical stream.
    // A following successful callback clears `lastStatus`.
    return noErr
  }
}

final class MacGridAUHALOutput: MacGridAUHALDirectionBase, @unchecked Sendable {
  private let silenceFlagCallbackCount = ManagedAtomic<UInt64>(0)
  private let latestCallbackWasSilence = ManagedAtomic(false)

  init(device: MacGridAudioDevice, delegate: any CustomAudioDeviceDelegate) throws {
    super.init(device: device, delegate: delegate, direction: .output)
    audioUnit = try makeAudioUnit()
    includeAudioUnitLatency()
  }

  override func start(operation: String = "start AUHAL output", timeout: TimeInterval = 2) throws {
    silenceFlagCallbackCount.store(0, ordering: .relaxed)
    latestCallbackWasSilence.store(false, ordering: .relaxed)
    try super.start(operation: operation, timeout: timeout)
  }

  override func currentOutputSilenceFlagCallbackCount() -> UInt64? {
    silenceFlagCallbackCount.load(ordering: .relaxed)
  }

  override func currentLatestOutputCallbackWasSilence() -> Bool? {
    latestCallbackWasSilence.load(ordering: .relaxed)
  }

  private func makeAudioUnit() throws -> AudioUnit {
    let unit = try Self.makeHALOutputUnit(operation: "create AUHAL output")
    do {
      var enabled: UInt32 = 1
      try Self.setProperty(
        unit,
        property: kAudioOutputUnitProperty_EnableIO,
        scope: kAudioUnitScope_Output,
        element: 0,
        value: &enabled,
        operation: "enable AUHAL output"
      )
      var disabled: UInt32 = 0
      try Self.setProperty(
        unit,
        property: kAudioOutputUnitProperty_EnableIO,
        scope: kAudioUnitScope_Input,
        element: 1,
        value: &disabled,
        operation: "disable AUHAL output input"
      )
      var deviceID = device.id
      try Self.setProperty(
        unit,
        property: kAudioOutputUnitProperty_CurrentDevice,
        scope: kAudioUnitScope_Global,
        element: 0,
        value: &deviceID,
        operation: "select AUHAL output"
      )
      var maximumFrames = MacGridAUHALFormat.maximumFramesPerSlice
      try Self.setProperty(
        unit,
        property: kAudioUnitProperty_MaximumFramesPerSlice,
        scope: kAudioUnitScope_Global,
        element: 0,
        value: &maximumFrames,
        operation: "set AUHAL output maximum slice"
      )
      var format = MacGridAUHALFormat.signedInt16(
        channels: MacGridAUHALFormat.outputChannels
      )
      try Self.setProperty(
        unit,
        property: kAudioUnitProperty_StreamFormat,
        scope: kAudioUnitScope_Input,
        element: 0,
        value: &format,
        operation: "set AUHAL output client format"
      )
      // SAFETY: this direction owns `unit`, and its deinitializer stops,
      // uninitializes, and disposes the unit before `self` can die. Core Audio
      // therefore uses this unretained refcon only while `self` is alive.
      var callback = AURenderCallbackStruct(
        inputProc: Self.outputCallback,
        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
      )
      try Self.setProperty(
        unit,
        property: kAudioUnitProperty_SetRenderCallback,
        scope: kAudioUnitScope_Input,
        element: 0,
        value: &callback,
        operation: "install AUHAL output callback"
      )
      try checkMacGridAudioStatus(
        AudioUnitInitialize(unit),
        "initialize AUHAL output"
      )
      return unit
    } catch {
      AudioComponentInstanceDispose(unit)
      throw error
    }
  }

  private static let outputCallback: AURenderCallback = { refCon, flags, timestamp, busNumber, frameCount, ioData in
    // SAFETY: `refCon` was installed from this live direction, whose ownership
    // invariant is documented where the callback is registered.
    let owner = Unmanaged<MacGridAUHALOutput>.fromOpaque(refCon).takeUnretainedValue()
    owner.enterCallback()
    defer { owner.leaveCallback() }
    return owner.render(
      flags: flags,
      timestamp: timestamp,
      busNumber: busNumber,
      frameCount: frameCount,
      ioData: ioData
    )
  }

  private func render(
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frameCount: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
  ) -> OSStatus {
    guard let ioData else { return kAudio_ParamError }
    guard running.load(ordering: .acquiring) else {
      Self.fillSilence(ioData, flags: flags)
      return noErr
    }
    guard frameCount <= MacGridAUHALFormat.maximumFramesPerSlice else {
      Self.fillSilence(ioData, flags: flags)
      observeCallback(
        frameCount: 0,
        status: kAudio_ParamError,
        timestamp: timestamp.pointee
      )
      return noErr
    }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let requiredByteCount = frameCount
      * MacGridAUHALFormat.outputChannels
      * UInt32(MemoryLayout<Int16>.size)
    guard buffers.count == 1,
          buffers[0].mNumberChannels == MacGridAUHALFormat.outputChannels,
          buffers[0].mData != nil,
          buffers[0].mDataByteSize >= requiredByteCount
    else {
      Self.fillSilence(ioData, flags: flags)
      observeCallback(
        frameCount: 0,
        status: kAudio_ParamError,
        timestamp: timestamp.pointee
      )
      return noErr
    }
    buffers[0].mDataByteSize = requiredByteCount
    // Measure only the result of this pull; no action flag from the HAL's
    // callback entry may masquerade as WebRTC declaring the rendered buffer
    // silent.
    flags.pointee.remove(.unitRenderAction_OutputIsSilence)
    let status = delegate.getPlayoutData(
      CustomAudioDeviceIOContext(
        actionFlags: flags,
        timestamp: timestamp,
        inputBusNumber: Int(busNumber),
        frameCount: frameCount
      ),
      outputData: ioData
    )
    if status != noErr {
      Self.fillSilence(ioData, flags: flags)
    }
    let renderedSilence = flags.pointee.contains(.unitRenderAction_OutputIsSilence)
    latestCallbackWasSilence.store(renderedSilence, ordering: .relaxed)
    if renderedSilence {
      silenceFlagCallbackCount.wrappingIncrement(ordering: .relaxed)
    }
    observeCallback(
      frameCount: frameCount,
      status: status,
      timestamp: timestamp.pointee
    )
    // Keep the physical stream alive; health reports a failed WebRTC pull and
    // the recovery loop can rebuild this direction without Core Audio also
    // tearing down the callback thread underneath it.
    return noErr
  }

  private static func fillSilence(
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>
  ) {
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for buffer in buffers {
      guard let data = buffer.mData else { continue }
      memset(data, 0, Int(buffer.mDataByteSize))
    }
  }
}

private extension MacGridAUHALDirectionBase {
  static func makeHALOutputUnit(operation: String) throws -> AudioUnit {
    var description = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else {
      throw MacGridCoreAudioError.unavailable("The AUHAL component is unavailable.")
    }
    var unit: AudioUnit?
    try checkMacGridAudioStatus(
      AudioComponentInstanceNew(component, &unit),
      operation
    )
    guard let unit else {
      throw MacGridCoreAudioError.unavailable("The AUHAL instance is unavailable.")
    }
    return unit
  }

  static func setProperty<T: BitwiseCopyable>(
    _ unit: AudioUnit,
    property: AudioUnitPropertyID,
    scope: AudioUnitScope,
    element: AudioUnitElement,
    value: inout T,
    operation: String
  ) throws {
    // `BitwiseCopyable` excludes values whose representation contains owned
    // references. Core Audio copies these bytes synchronously before this
    // temporary view ends.
    let status = withUnsafeBytes(of: &value) { bytes in
      AudioUnitSetProperty(
        unit,
        property,
        scope,
        element,
        bytes.baseAddress,
        UInt32(bytes.count)
      )
    }
    try checkMacGridAudioStatus(status, operation)
  }
}

enum MacGridAUHALLatency {
  enum Direction {
    case input
    case output

    var scope: AudioObjectPropertyScope {
      switch self {
      case .input: kAudioDevicePropertyScopeInput
      case .output: kAudioDevicePropertyScopeOutput
      }
    }
  }

  static func measure(
    device: MacGridAudioDevice,
    direction: Direction,
    packetizationLatency: TimeInterval
  ) -> TimeInterval {
    let sampleRate = max(
      direction == .input
        ? device.inputStreamFormat?.sampleRate ?? device.sampleRate
        : device.outputStreamFormat?.sampleRate ?? device.sampleRate,
      1
    )
    let deviceLatency = property(
      object: device.id,
      selector: kAudioDevicePropertyLatency,
      scope: direction.scope
    )
    let safetyOffset = property(
      object: device.id,
      selector: kAudioDevicePropertySafetyOffset,
      scope: direction.scope
    )
    let streamLatency = firstStreamLatency(device: device, direction: direction)
    let bufferedFrames = UInt64(device.bufferFrameSize)
    let totalFrames = UInt64(deviceLatency)
      + UInt64(safetyOffset)
      + UInt64(streamLatency)
      + bufferedFrames
    return Double(totalFrames) / sampleRate + packetizationLatency
  }

  private static func firstStreamLatency(
    device: MacGridAudioDevice,
    direction: Direction
  ) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: direction.scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let streamStride = UInt32(MemoryLayout<AudioStreamID>.stride)
    guard AudioObjectGetPropertyDataSize(
      device.id,
      &address,
      0,
      nil,
      &size
    ) == noErr,
      size >= streamStride,
      size.isMultiple(of: streamStride)
    else { return 0 }
    let streamCount = Int(size / streamStride)
    var streams = [AudioStreamID](
      repeating: AudioStreamID(kAudioObjectUnknown),
      count: streamCount
    )
    let status = streams.withUnsafeMutableBytes { storage in
      guard let baseAddress = storage.baseAddress else {
        return kAudio_ParamError
      }
      // SAFETY: `size` was proven to be an exact multiple of AudioStreamID's
      // stride, and `streams` owns exactly that many writable bytes for this
      // synchronous Core Audio property read.
      return AudioObjectGetPropertyData(
        device.id,
        &address,
        0,
        nil,
        &size,
        baseAddress
      )
    }
    guard status == noErr,
          let stream = streams.first,
          stream != kAudioObjectUnknown
    else { return 0 }
    return property(
      object: stream,
      selector: kAudioStreamPropertyLatency,
      scope: kAudioObjectPropertyScopeGlobal
    )
  }

  private static func property(
    object: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(
      object,
      &address,
      0,
      nil,
      &size,
      &value
    ) == noErr else { return 0 }
    return value
  }
}
#endif
