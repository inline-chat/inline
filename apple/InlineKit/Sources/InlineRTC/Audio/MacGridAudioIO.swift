#if os(macOS)
import AudioToolbox
@preconcurrency import AVFoundation
import Atomics
import Foundation
import LiveKit
import Logger

/// Archived manual-rendering backend. Grid's macOS production path is the
/// patched AVAudioEngine WebRTC ADM; keeping this implementation unavailable makes
/// a second physical-audio owner a compile-time error while preserving the
/// previous work for reference.
@available(*, unavailable, message: "Grid uses WebRTC's patched AudioEngine ADM on macOS.")
actor MacGridAudioIOController {
  private var catalog: MacGridAudioCatalogSnapshot?
  private var desiredInput: AudioInputRouteTarget = .automatic
  private var input: MacGridHALInputCapture?
  private var output: MacGridRemoteAudioRenderer?
  private var lastOutputDiagnostics = MacGridAudioOutputDiagnostics()
  private var inputProgress = MacGridAudioProgressMonitor(stallTimeout: 1)
  private var outputProgress = MacGridAudioProgressMonitor(stallTimeout: 1)
  private var liveKitCaptureStarted = false
  private var prepared = false
  private let log = Log.scoped("MacGridAudioIOController")

  func updateCatalog(_ snapshot: MacGridAudioCatalogSnapshot) async {
    catalog = snapshot
    guard prepared else { return }
    // Core Audio publishes several intermediate catalogs while a route is
    // changing. A temporarily absent default is not a failed route command:
    // keep the current proven stream until a complete catalog arrives.
    if hasResolvableInput {
      do {
        try replaceInputIfNeeded(force: false)
      } catch {
        log.error("GRID_ENGINE phase=mac_audio_catalog_input_reconcile_failed", error: error)
      }
    }
    if snapshot.defaultOutput != nil {
      do {
        try replaceOutputIfNeeded(force: false)
      } catch {
        log.error("GRID_ENGINE phase=mac_audio_catalog_output_reconcile_failed", error: error)
      }
    }
  }

  func setPrepared(_ value: Bool) async throws {
    guard prepared != value || (!value && liveKitCaptureStarted) else { return }
    if value {
      do {
        if !liveKitCaptureStarted {
          try AudioManager.shared.startLocalRecording()
          liveKitCaptureStarted = true
        }
        try replaceOutputIfNeeded(force: true)
        try replaceInputIfNeeded(force: true)
        prepared = true
      } catch {
        stopPhysicalIO()
        stopLiveKitCaptureIfPossible()
        throw error
      }
    } else {
      prepared = false
      stopPhysicalIO()
      if liveKitCaptureStarted {
        try AudioManager.shared.stopLocalRecording()
        liveKitCaptureStarted = false
      }
    }
  }

  func applyInput(_ target: AudioInputRouteTarget) throws {
    desiredInput = target
    guard prepared else {
      _ = try resolvedInput()
      return
    }
    try replaceInputIfNeeded(force: false)
  }

  func recover() throws {
    guard prepared else { return }
    try replaceOutputIfNeeded(force: true)
    try replaceInputIfNeeded(force: true)
  }

  func health() -> GridAudioRuntimeHealth {
    let snapshot = catalog
    let inputDevice = input?.device
    let outputDevice = output?.device
    let now = ProcessInfo.processInfo.systemUptime
    let inputRunning = inputProgress.observe(
      isStarted: input?.isStarted == true,
      frameCount: input?.deliveredFrameCount ?? 0,
      now: now
    )
    let outputRunning = outputProgress.observe(
      isStarted: output?.isStarted == true,
      frameCount: output?.renderedFrameCount ?? 0,
      now: now
    )
    reportOutputDiagnosticsIfNeeded()
    return GridAudioRuntimeHealth(
      isEngineRunning: inputRunning && outputRunning,
      isRecording: inputRunning,
      isPlaying: outputRunning,
      route: InlineRTCAudioRoute(
        currentInputID: inputDevice?.uid,
        defaultInputID: snapshot?.defaultInput?.uid,
        currentOutputID: outputDevice?.uid,
        defaultOutputID: snapshot?.defaultOutput?.uid,
        inputDeviceCount: snapshot?.inputs.count ?? 0,
        outputDeviceCount: snapshot?.outputs.count ?? 0,
        isInputRouteValid: !prepared || inputRunning,
        isOutputRouteValid: !prepared || outputRunning,
        routeEpoch: snapshot?.epoch ?? 0
      )
    )
  }

  private func replaceInputIfNeeded(force: Bool) throws {
    let device = try resolvedInput()
    guard force || input?.device.uid != device.uid else { return }

    let replacement = MacGridHALInputCapture(device: device) { buffer in
      AudioManager.shared.mixer.capture(appAudio: buffer)
    }
    try replacement.start()
    let previous = input
    // The replacement proves physical PCM before the old route retires, but
    // only one capture is ever allowed to feed LiveKit. Stopping the previous
    // AUHAL before opening this forwarding gate avoids a transient doubled
    // microphone stream during route handoff.
    previous?.stop()
    input = replacement
    inputProgress.reset()
    replacement.setForwarding(true)
    let inputFields = [
      "sample_rate=\(device.inputStreamFormat?.sampleRate ?? device.sampleRate)",
      "channels=\(device.inputStreamFormat?.channelCount ?? 0)",
      "buffer_frames=\(device.bufferFrameSize)",
      "bluetooth=\(device.isBluetooth)",
    ].joined(separator: " ")
    log.info("GRID_ENGINE phase=mac_audio_input_committed \(inputFields)")
  }

  private func replaceOutputIfNeeded(force: Bool) throws {
    guard let device = catalog?.defaultOutput else {
      throw MacGridCoreAudioError.unavailable("No output device is available.")
    }
    guard force || output?.device.uid != device.uid else { return }

    let replacement = MacGridRemoteAudioRenderer(device: device)
    try replacement.start()
    let previous = output
    if let previous {
      previous.setAcceptingAudio(false)
      AudioManager.shared.remove(remoteAudioRenderer: previous)
    }
    AudioManager.shared.add(remoteAudioRenderer: replacement)
    replacement.setAcceptingAudio(true)
    output = replacement
    outputProgress.reset()
    lastOutputDiagnostics = replacement.diagnostics
    previous?.stop()
    let outputFields = [
      "sample_rate=\(device.outputStreamFormat?.sampleRate ?? device.sampleRate)",
      "channels=\(device.outputStreamFormat?.channelCount ?? 0)",
      "buffer_frames=\(device.bufferFrameSize)",
      "bluetooth=\(device.isBluetooth)",
    ].joined(separator: " ")
    log.info("GRID_ENGINE phase=mac_audio_output_committed \(outputFields)")
  }

  private func resolvedInput() throws -> MacGridAudioDevice {
    guard let catalog else {
      throw MacGridCoreAudioError.unavailable("The audio device catalog is not ready.")
    }
    switch desiredInput {
    case .automatic:
      guard let device = catalog.defaultInput else {
        throw MacGridCoreAudioError.unavailable("No default microphone is available.")
      }
      return device
    case let .device(uid, _):
      guard let device = catalog.inputs.first(where: { $0.uid == uid }) else {
        throw MacGridCoreAudioError.unavailable("The selected microphone is no longer connected.")
      }
      return device
    }
  }

  private var hasResolvableInput: Bool {
    guard let catalog else { return false }
    switch desiredInput {
    case .automatic:
      return catalog.defaultInput != nil
    case let .device(uid, _):
      return catalog.inputs.contains { $0.uid == uid }
    }
  }

  private func stopPhysicalIO() {
    input?.stop()
    input = nil
    if let output {
      AudioManager.shared.remove(remoteAudioRenderer: output)
      output.stop()
    }
    output = nil
    inputProgress.reset()
    outputProgress.reset()
    lastOutputDiagnostics = MacGridAudioOutputDiagnostics()
  }

  private func stopLiveKitCaptureIfPossible() {
    guard liveKitCaptureStarted else { return }
    do {
      try AudioManager.shared.stopLocalRecording()
      liveKitCaptureStarted = false
    } catch {
      log.error("GRID_ENGINE phase=livekit_manual_capture_stop_failed", error: error)
    }
  }

  private func reportOutputDiagnosticsIfNeeded() {
    guard let output else { return }
    let diagnostics = output.diagnostics
    let dropped = diagnostics.droppedPackets &- lastOutputDiagnostics.droppedPackets
    let underruns = diagnostics.underflowEvents &- lastOutputDiagnostics.underflowEvents
    if dropped > 0 || underruns > 0 {
      log.warning(
        "GRID_ENGINE phase=mac_audio_output_continuity dropped_packets=\(dropped) underflows=\(underruns) received_samples=\(diagnostics.receivedSamples) rendered_frames=\(diagnostics.renderedFrames)"
      )
    }
    lastOutputDiagnostics = diagnostics
  }
}

private final class MacGridHALInputCapture: @unchecked Sendable {
  let device: MacGridAudioDevice

  var isStarted: Bool {
    running.load(ordering: .acquiring)
  }

  var deliveredFrameCount: UInt64 {
    deliveredFrames.load(ordering: .relaxed)
  }

  private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
  private let deliveredFrames = ManagedAtomic<UInt64>(0)
  private let running = ManagedAtomic<Bool>(false)
  private let forwarding = ManagedAtomic<Bool>(false)
  private let firstFrame = DispatchSemaphore(value: 0)
  private var didSignalFirstFrame = false
  private var audioUnit: AudioUnit?
  private var buffer: AVAudioPCMBuffer?

  init(
    device: MacGridAudioDevice,
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) {
    self.device = device
    self.onBuffer = onBuffer
  }

  deinit { stop() }

  func setForwarding(_ value: Bool) {
    forwarding.store(value, ordering: .releasing)
  }

  func start(firstFrameTimeout: TimeInterval = 2) throws {
    guard audioUnit == nil else { return }
    let unit = try makeAudioUnit()
    audioUnit = unit
    running.store(true, ordering: .releasing)
    do {
      try checkMacGridAudioStatus(AudioOutputUnitStart(unit), "start microphone")
      guard firstFrame.wait(timeout: .now() + firstFrameTimeout) == .success else {
        throw MacGridCoreAudioError.unavailable("The microphone produced no audio frames.")
      }
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    forwarding.store(false, ordering: .releasing)
    running.store(false, ordering: .releasing)
    guard let unit = audioUnit else { return }
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
    audioUnit = nil
    buffer = nil
  }

  private func makeAudioUnit() throws -> AudioUnit {
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
    var maybeUnit: AudioUnit?
    try checkMacGridAudioStatus(AudioComponentInstanceNew(component, &maybeUnit), "create microphone")
    guard let unit = maybeUnit else {
      throw MacGridCoreAudioError.unavailable("The microphone Audio Unit could not be created.")
    }
    do {
      var enabled: UInt32 = 1
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioOutputUnitProperty_EnableIO,
          kAudioUnitScope_Input,
          1,
          &enabled,
          UInt32(MemoryLayout<UInt32>.size)
        ),
        "enable microphone input"
      )
      var disabled: UInt32 = 0
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioOutputUnitProperty_EnableIO,
          kAudioUnitScope_Output,
          0,
          &disabled,
          UInt32(MemoryLayout<UInt32>.size)
        ),
        "disable microphone output"
      )
      var deviceID = device.id
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioOutputUnitProperty_CurrentDevice,
          kAudioUnitScope_Global,
          0,
          &deviceID,
          UInt32(MemoryLayout<AudioDeviceID>.size)
        ),
        "select microphone"
      )
      var format = Self.monoFloatFormat(sampleRate: device.sampleRate)
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioUnitProperty_StreamFormat,
          kAudioUnitScope_Output,
          1,
          &format,
          UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ),
        "set microphone client format"
      )
      guard let avFormat = AVAudioFormat(streamDescription: &format),
            let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: 8192)
      else {
        throw MacGridCoreAudioError.unavailable("The microphone PCM format is unavailable.")
      }
      self.buffer = buffer
      var callback = AURenderCallbackStruct(
        inputProc: Self.inputCallback,
        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
      )
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioOutputUnitProperty_SetInputCallback,
          kAudioUnitScope_Global,
          0,
          &callback,
          UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ),
        "install microphone callback"
      )
      try checkMacGridAudioStatus(AudioUnitInitialize(unit), "initialize microphone")
      return unit
    } catch {
      AudioComponentInstanceDispose(unit)
      throw error
    }
  }

  private static let inputCallback: AURenderCallback = { refCon, flags, timestamp, _, frameCount, _ in
    let owner = Unmanaged<MacGridHALInputCapture>.fromOpaque(refCon).takeUnretainedValue()
    return owner.render(flags: flags, timestamp: timestamp, frameCount: frameCount)
  }

  private func render(
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32
  ) -> OSStatus {
    guard running.load(ordering: .acquiring),
          let unit = audioUnit,
          let buffer,
          frameCount <= buffer.frameCapacity
    else { return noErr }
    buffer.frameLength = frameCount
    let status = AudioUnitRender(
      unit,
      flags,
      timestamp,
      1,
      frameCount,
      buffer.mutableAudioBufferList
    )
    guard status == noErr else { return status }
    deliveredFrames.wrappingIncrement(by: UInt64(frameCount), ordering: .relaxed)
    if !didSignalFirstFrame {
      didSignalFirstFrame = true
      firstFrame.signal()
    }
    if forwarding.load(ordering: .acquiring) {
      onBuffer(buffer)
    }
    return noErr
  }

  private static func monoFloatFormat(sampleRate: Double) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )
  }
}

struct MacGridAudioOutputDiagnostics: Equatable, Sendable {
  var receivedSamples: UInt64 = 0
  var renderedFrames: UInt64 = 0
  var droppedPackets: UInt64 = 0
  var underflowEvents: UInt64 = 0
}

/// Converts monotonically increasing realtime callback counters into a
/// trustworthy liveness fact without reading a clock from the audio callback.
/// A started Audio Unit that produced frames once is not considered healthy
/// forever: progress must remain recent throughout a long-running connection.
struct MacGridAudioProgressMonitor: Equatable, Sendable {
  let stallTimeout: TimeInterval

  private var lastFrameCount: UInt64?
  private var lastProgressAt: TimeInterval?

  init(stallTimeout: TimeInterval) {
    self.stallTimeout = max(stallTimeout, 0)
  }

  mutating func observe(
    isStarted: Bool,
    frameCount: UInt64,
    now: TimeInterval
  ) -> Bool {
    guard isStarted, frameCount > 0 else {
      reset()
      return false
    }
    if lastFrameCount != frameCount || lastProgressAt == nil {
      lastFrameCount = frameCount
      lastProgressAt = now
    }
    guard let lastProgressAt else { return false }
    return now - lastProgressAt <= stallTimeout
  }

  mutating func reset() {
    lastFrameCount = nil
    lastProgressAt = nil
  }
}

private final class MacGridRemoteAudioRenderer: NSObject, AudioRenderer, @unchecked Sendable {
  let device: MacGridAudioDevice

  var isStarted: Bool {
    running.load(ordering: .acquiring)
  }

  var renderedFrameCount: UInt64 {
    renderedFrames.load(ordering: .relaxed)
  }

  var diagnostics: MacGridAudioOutputDiagnostics {
    MacGridAudioOutputDiagnostics(
      receivedSamples: receivedSamples.load(ordering: .relaxed),
      renderedFrames: renderedFrames.load(ordering: .relaxed),
      droppedPackets: droppedPackets.load(ordering: .relaxed),
      underflowEvents: underflowEvents.load(ordering: .relaxed)
    )
  }

  private let acceptingAudio = ManagedAtomic<Bool>(false)
  private let running = ManagedAtomic<Bool>(false)
  private let receivedSamples = ManagedAtomic<UInt64>(0)
  private let renderedFrames = ManagedAtomic<UInt64>(0)
  private let droppedPackets = ManagedAtomic<UInt64>(0)
  private let underflowEvents = ManagedAtomic<UInt64>(0)
  private let firstFrame = DispatchSemaphore(value: 0)
  private let producerLock = NSLock()
  private let playout: MacGridAudioPlayoutBuffer
  private let outputFormat: AVAudioFormat
  private var didSignalFirstFrame = false
  private var audioUnit: AudioUnit?
  private var converter: AVAudioConverter?
  private var converterInputFormat: AVAudioFormat?

  init(device: MacGridAudioDevice) {
    self.device = device
    let sampleRate = max(device.sampleRate, 1)
    outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 2,
      interleaved: true
    )!
    let startupFrames = max(
      Int(device.bufferFrameSize) * 3,
      Int((sampleRate * 0.03).rounded(.up))
    )
    let startupSamples = startupFrames * 2
    playout = MacGridAudioPlayoutBuffer(
      capacity: max(Int(sampleRate.rounded()) * 2, startupSamples * 4),
      startupThreshold: startupSamples
    )
    super.init()
  }

  deinit { stop() }

  func setAcceptingAudio(_ value: Bool) {
    acceptingAudio.store(value, ordering: .releasing)
  }

  func start(firstFrameTimeout: TimeInterval = 2) throws {
    guard audioUnit == nil else { return }
    let unit = try makeAudioUnit()
    audioUnit = unit
    running.store(true, ordering: .releasing)
    do {
      try checkMacGridAudioStatus(AudioOutputUnitStart(unit), "start output")
      guard firstFrame.wait(timeout: .now() + firstFrameTimeout) == .success else {
        throw MacGridCoreAudioError.unavailable("The output device produced no audio callbacks.")
      }
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    acceptingAudio.store(false, ordering: .releasing)
    running.store(false, ordering: .releasing)
    guard let unit = audioUnit else { return }
    audioUnit = nil
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
  }

  func render(pcmBuffer: AVAudioPCMBuffer) {
    enqueue(pcmBuffer)
  }

  private func enqueue(_ pcmBuffer: AVAudioPCMBuffer) {
    guard acceptingAudio.load(ordering: .acquiring),
          running.load(ordering: .acquiring)
    else { return }
    producerLock.withLock {
      guard acceptingAudio.load(ordering: .acquiring),
            running.load(ordering: .acquiring)
      else { return }
      if converter == nil || converterInputFormat != pcmBuffer.format {
        converter = AVAudioConverter(from: pcmBuffer.format, to: outputFormat)
        converterInputFormat = pcmBuffer.format
      }
      guard let converter else { return }
      let ratio = outputFormat.sampleRate / max(pcmBuffer.format.sampleRate, 1)
      let capacity = AVAudioFrameCount(ceil(Double(pcmBuffer.frameLength) * ratio) + 16)
      guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
        return
      }
      var supplied = false
      var conversionError: NSError?
      let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
        if supplied {
          inputStatus.pointee = .noDataNow
          return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return pcmBuffer
      }
      guard status != .error, conversionError == nil, converted.frameLength > 0 else { return }
      let buffers = UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList)
      guard buffers.count == 1, let data = buffers[0].mData else { return }
      let sampleCount = Int(converted.frameLength) * Int(outputFormat.channelCount)
      let pointer = data.assumingMemoryBound(to: Float.self)
      receivedSamples.wrappingIncrement(by: UInt64(sampleCount), ordering: .relaxed)
      let written = playout.write(UnsafeBufferPointer(start: pointer, count: sampleCount))
      if written == 0 {
        droppedPackets.wrappingIncrement(ordering: .relaxed)
      }
    }
  }

  private func makeAudioUnit() throws -> AudioUnit {
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
    var maybeUnit: AudioUnit?
    try checkMacGridAudioStatus(AudioComponentInstanceNew(component, &maybeUnit), "create output")
    guard let unit = maybeUnit else {
      throw MacGridCoreAudioError.unavailable("The output Audio Unit could not be created.")
    }
    do {
      var enabled: UInt32 = 1
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioOutputUnitProperty_EnableIO,
          kAudioUnitScope_Output,
          0,
          &enabled,
          UInt32(MemoryLayout<UInt32>.size)
        ),
        "enable output"
      )
      var disabled: UInt32 = 0
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioOutputUnitProperty_EnableIO,
          kAudioUnitScope_Input,
          1,
          &disabled,
          UInt32(MemoryLayout<UInt32>.size)
        ),
        "disable output-unit input"
      )
      var deviceID = device.id
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioOutputUnitProperty_CurrentDevice,
          kAudioUnitScope_Global,
          0,
          &deviceID,
          UInt32(MemoryLayout<AudioDeviceID>.size)
        ),
        "select output device"
      )
      var format = Self.stereoFloatFormat(sampleRate: outputFormat.sampleRate)
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioUnitProperty_StreamFormat,
          kAudioUnitScope_Input,
          0,
          &format,
          UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ),
        "set output client format"
      )
      var callback = AURenderCallbackStruct(
        inputProc: Self.outputCallback,
        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
      )
      try checkMacGridAudioStatus(
        AudioUnitSetProperty(
          unit,
          kAudioUnitProperty_SetRenderCallback,
          kAudioUnitScope_Input,
          0,
          &callback,
          UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ),
        "install output callback"
      )
      try checkMacGridAudioStatus(AudioUnitInitialize(unit), "initialize output")
      return unit
    } catch {
      AudioComponentInstanceDispose(unit)
      throw error
    }
  }

  private static let outputCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let owner = Unmanaged<MacGridRemoteAudioRenderer>.fromOpaque(refCon).takeUnretainedValue()
    return owner.renderOutput(frameCount: frameCount, ioData: ioData)
  }

  private func renderOutput(
    frameCount: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
  ) -> OSStatus {
    guard running.load(ordering: .acquiring), let ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    for bufferIndex in buffers.indices {
      guard let data = buffers[bufferIndex].mData else { continue }
      let channels = max(Int(buffers[bufferIndex].mNumberChannels), 1)
      let count = Int(frameCount) * channels
      let pointer = data.assumingMemoryBound(to: Float.self)
      if bufferIndex == buffers.startIndex {
        let result = playout.read(
          into: UnsafeMutableBufferPointer(start: pointer, count: count)
        )
        if case .underflow = result {
          underflowEvents.wrappingIncrement(ordering: .relaxed)
        }
      } else {
        pointer.initialize(repeating: 0, count: count)
      }
      buffers[bufferIndex].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
    }
    renderedFrames.wrappingIncrement(by: UInt64(frameCount), ordering: .relaxed)
    if !didSignalFirstFrame {
      didSignalFirstFrame = true
      firstFrame.signal()
    }
    return noErr
  }

  private static func stereoFloatFormat(sampleRate: Double) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(MemoryLayout<Float>.size * 2),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(MemoryLayout<Float>.size * 2),
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )
  }
}
#endif
