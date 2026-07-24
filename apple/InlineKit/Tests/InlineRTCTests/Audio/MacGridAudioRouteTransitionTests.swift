#if os(macOS)
import AudioToolbox
import CoreAudio
@testable import InlineRTC
import Testing

@Suite("macOS directional AUHAL route transitions")
struct MacGridAudioRouteTransitionTests {
  @Test("physical callback health requires recent realtime progress")
  func physicalCallbackHealthRequiresRecentProgress() {
    #expect(!MacGridAudioCallbackHealth.isFresh(seen: false, ageMilliseconds: nil))
    #expect(MacGridAudioCallbackHealth.isFresh(seen: true, ageMilliseconds: 500))
    #expect(!MacGridAudioCallbackHealth.isFresh(seen: true, ageMilliseconds: 501))
  }

  @Test("route settlement requires two actual callback counter advances")
  func routeSettlementRequiresCallbackProgress() {
    var monitor = MacGridAudioCallbackProgressMonitor(
      baselineCallbackCount: 10
    )

    let stalledAtBaseline = monitor.observe(callbackCount: 10, isRouteValid: true)
    let firstAdvance = monitor.observe(callbackCount: 11, isRouteValid: true)
    let stalledAfterAdvance = monitor.observe(callbackCount: 11, isRouteValid: true)
    let firstAdvanceAfterStall = monitor.observe(callbackCount: 12, isRouteValid: true)
    let settled = monitor.observe(callbackCount: 13, isRouteValid: true)
    let invalidRoute = monitor.observe(callbackCount: 14, isRouteValid: false)
    let firstAdvanceAfterInvalid = monitor.observe(callbackCount: 15, isRouteValid: true)
    let resettled = monitor.observe(callbackCount: 16, isRouteValid: true)

    #expect(!stalledAtBaseline)
    #expect(!firstAdvance)
    #expect(!stalledAfterAdvance)
    #expect(!firstAdvanceAfterStall)
    #expect(settled)
    #expect(!invalidRoute)
    #expect(!firstAdvanceAfterInvalid)
    #expect(resettled)
  }

  @Test("unreadable input format cannot be treated as a usable physical route")
  func unreadableInputFormatIsNotUsable() {
    let input = MacGridAudioDevice(
      id: 101,
      uid: "input",
      name: "Input",
      hasInput: true,
      hasOutput: false,
      sampleRate: 48_000,
      bufferFrameSize: 512,
      transport: kAudioDeviceTransportTypeBuiltIn,
      inputStreamFormat: nil
    )

    #expect(!MacGridAudioRouteTransitionPolicy.inputIsUsable(input))
  }

  @Test("stopped native capture is healthy when its selected route remains usable")
  func stoppedNativeCaptureIsHealthyIdle() {
    let input = inputDevice(uid: "built-in", sampleRate: 48_000)

    #expect(MacGridAUHALIdleInputRouteHealthPolicy.isValid(
      idleInputState(expectedUID: input.uid, selectedUID: input.uid),
      catalogInput: input
    ))
  }

  @Test("idle input health rejects native demand and unavailable routes")
  func idleInputHealthRejectsDemandAndUnavailableRoutes() {
    let input = inputDevice(uid: "built-in", sampleRate: 48_000)

    #expect(!MacGridAUHALIdleInputRouteHealthPolicy.isValid(
      idleInputState(
        nativeRecordingDemanded: true,
        expectedUID: input.uid,
        selectedUID: input.uid
      ),
      catalogInput: input
    ))
    #expect(!MacGridAUHALIdleInputRouteHealthPolicy.isValid(
      idleInputState(expectedUID: input.uid, selectedUID: input.uid),
      catalogInput: nil
    ))
  }

  @Test("idle input health rejects stale retained physical readback")
  func idleInputHealthRejectsStaleRetainedReadback() {
    let current = inputDevice(uid: "airpods", sampleRate: 48_000)
    let catalog = inputDevice(uid: "airpods", sampleRate: 24_000)

    #expect(!MacGridAUHALIdleInputRouteHealthPolicy.isValid(
      idleInputState(
        expectedUID: catalog.uid,
        selectedUID: catalog.uid,
        activeUID: current.uid,
        activeSignature: current.inputRouteSignature,
        activeDeviceReadbackVerified: true
      ),
      catalogInput: catalog
    ))
  }

  @Test("Bluetooth voice output remains usable when another process owns capture")
  func bluetoothVoiceOutputFromAnotherProcessIsUsable() {
    var monitor = MacGridAudioOutputSettleMonitor()

    let voice1 = monitor.observe(snapshot(outputRate: 24_000, outputChannels: 2))
    let voice2 = monitor.observe(snapshot(outputRate: 24_000, outputChannels: 2))
    let voice3 = monitor.observe(snapshot(outputRate: 24_000, outputChannels: 2))

    #expect(!voice1)
    #expect(!voice2)
    #expect(voice3)
  }

  @Test("Bluetooth profile transition resets output stability")
  func bluetoothProfileTransitionResetsStability() {
    var monitor = MacGridAudioOutputSettleMonitor()

    let highFidelity = monitor.observe(snapshot(outputRate: 48_000, outputChannels: 2))
    // The affected AirPods exposed HFP as two-channel 24 kHz audio. Do not
    // assume that a Bluetooth voice profile must be mono.
    let voice1 = monitor.observe(snapshot(outputRate: 24_000, outputChannels: 2))
    let voice2 = monitor.observe(snapshot(outputRate: 24_000, outputChannels: 2))
    let voice3 = monitor.observe(snapshot(outputRate: 24_000, outputChannels: 2))

    #expect(!highFidelity)
    #expect(!voice1)
    #expect(!voice2)
    #expect(voice3)
  }

  @Test("input settlement resets across Bluetooth profile changes")
  func inputProfileTransitionResetsStability() {
    var monitor = MacGridAudioInputSettleMonitor(
      target: .automatic,
      expectedUID: "input"
    )

    let highFidelity = monitor.observe(snapshot(inputRate: 48_000))
    let voice1 = monitor.observe(snapshot(inputRate: 24_000))
    let voice2 = monitor.observe(snapshot(inputRate: 24_000))
    let voice3 = monitor.observe(snapshot(inputRate: 24_000))

    #expect(!highFidelity)
    #expect(!voice1)
    #expect(!voice2)
    #expect(voice3)
  }

  @Test("input settlement rejects a changed automatic UID")
  func inputSettlementRejectsChangedUID() {
    var monitor = MacGridAudioInputSettleMonitor(
      target: .automatic,
      expectedUID: "input"
    )
    let changedDefault = snapshot(inputUID: "other-input")
    let first = monitor.observe(changedDefault)
    let second = monitor.observe(changedDefault)
    let third = monitor.observe(changedDefault)

    #expect(!first)
    #expect(!second)
    #expect(!third)
  }

  @Test("only callback-only cannot-do-in-context input starts are retryable")
  func classifiesRetryableInputStartFailure() {
    #expect(MacGridAUHALInputStartFailurePolicy.isRetryableTransitionFailure(
      callbackCount: 100,
      frameCount: 0,
      physicalRenderErrorCount: 100,
      physicalCannotDoCount: 100,
      lastStatus: kAudioUnitErr_CannotDoInCurrentContext
    ))
    #expect(!MacGridAUHALInputStartFailurePolicy.isRetryableTransitionFailure(
      callbackCount: 0,
      frameCount: 0,
      physicalRenderErrorCount: 0,
      physicalCannotDoCount: 0,
      lastStatus: kAudioUnitErr_CannotDoInCurrentContext
    ))
    #expect(!MacGridAUHALInputStartFailurePolicy.isRetryableTransitionFailure(
      callbackCount: 100,
      frameCount: 512,
      physicalRenderErrorCount: 100,
      physicalCannotDoCount: 100,
      lastStatus: kAudioUnitErr_CannotDoInCurrentContext
    ))
    #expect(!MacGridAUHALInputStartFailurePolicy.isRetryableTransitionFailure(
      callbackCount: 100,
      frameCount: 0,
      physicalRenderErrorCount: 100,
      physicalCannotDoCount: 0,
      lastStatus: kAudio_ParamError
    ))
    #expect(!MacGridAUHALInputStartFailurePolicy.isRetryableTransitionFailure(
      callbackCount: 100,
      frameCount: 0,
      physicalRenderErrorCount: 100,
      physicalCannotDoCount: 99,
      lastStatus: kAudioUnitErr_CannotDoInCurrentContext
    ))
    // The WebRTC bridge can return the same OSStatus after a successful
    // AudioUnitRender. That is downstream congestion, not a hardware-profile
    // transition, and must never replace the selected physical device.
    #expect(!MacGridAUHALInputStartFailurePolicy.isRetryableTransitionFailure(
      callbackCount: 100,
      frameCount: 0,
      physicalRenderErrorCount: 0,
      physicalCannotDoCount: 0,
      lastStatus: kAudioUnitErr_CannotDoInCurrentContext
    ))
  }

  @Test("stopping local capture does not require a Bluetooth profile promotion")
  func stoppingCaptureAcceptsStableVoiceOutput() {
    var monitor = MacGridAudioOutputSettleMonitor()

    let voice1 = monitor.observe(snapshot(outputRate: 24_000, outputChannels: 1))
    let voice2 = monitor.observe(snapshot(outputRate: 24_000, outputChannels: 1))
    let voice3 = monitor.observe(snapshot(outputRate: 24_000, outputChannels: 1))

    #expect(!voice1)
    #expect(!voice2)
    #expect(voice3)
  }

  @Test("non-Bluetooth output needs only a stable live format")
  func nonBluetoothOutputSettlesWithoutProfileHeuristics() {
    var monitor = MacGridAudioOutputSettleMonitor()
    let builtInOutput = snapshot(
      outputRate: 48_000,
      outputChannels: 2,
      outputTransport: kAudioDeviceTransportTypeBuiltIn
    )

    let stable1 = monitor.observe(builtInOutput)
    let stable2 = monitor.observe(builtInOutput)
    let stable3 = monitor.observe(builtInOutput)

    #expect(!stable1)
    #expect(!stable2)
    #expect(stable3)
  }

  @Test("Bluetooth LE output does not inherit classic HFP sample-rate assumptions")
  func bluetoothLEOutputDoesNotUseClassicProfileHeuristics() {
    var monitor = MacGridAudioOutputSettleMonitor()
    let bluetoothLEOutput = snapshot(
      outputRate: 48_000,
      outputChannels: 2,
      outputTransport: kAudioDeviceTransportTypeBluetoothLE
    )

    let stable1 = monitor.observe(bluetoothLEOutput)
    let stable2 = monitor.observe(bluetoothLEOutput)
    let stable3 = monitor.observe(bluetoothLEOutput)

    #expect(!stable1)
    #expect(!stable2)
    #expect(stable3)
  }

  @Test("directional AUHAL keeps playout independent across input changes")
  func inputChangesDoNotCoordinatePlayout() {
    let catalog = snapshot(outputRate: 48_000, outputChannels: 2)

    #expect(!MacGridAudioRouteTransitionPolicy.requiresCoordinatedPlayout(
      previousInputUID: "airpods:input",
      nextInputUID: "built-in:input",
      in: catalog
    ))
    #expect(!MacGridAudioRouteTransitionPolicy.requiresCoordinatedPlayout(
      previousInputUID: "built-in:input",
      nextInputUID: "airpods:input",
      in: catalog
    ))
    #expect(!MacGridAudioRouteTransitionPolicy.requiresCoordinatedPlayout(
      previousInputUID: "built-in:input",
      nextInputUID: "usb:input",
      in: catalog
    ))
    #expect(!MacGridAudioRouteTransitionPolicy.requiresCoordinatedPlayout(
      previousInputUID: "airpods:input",
      nextInputUID: "airpods:input",
      in: catalog
    ))
    #expect(!MacGridAudioRouteTransitionPolicy.requiresCoordinatedPlayout(
      previousInputUID: nil,
      nextInputUID: "built-in:input",
      in: catalog
    ))

    let builtInOutputCatalog = snapshot(
      outputRate: 48_000,
      outputChannels: 2,
      outputTransport: kAudioDeviceTransportTypeBuiltIn
    )
    #expect(!MacGridAudioRouteTransitionPolicy.requiresCoordinatedPlayout(
      previousInputUID: "built-in:input",
      nextInputUID: "usb:input",
      in: builtInOutputCatalog
    ))
    #expect(!MacGridAudioRouteTransitionPolicy.requiresCoordinatedPlayout(
      previousInputUID: "airpods:input",
      nextInputUID: "built-in:input",
      in: builtInOutputCatalog
    ))
  }

  @Test("output settlement timeout cannot commit a route transaction")
  func outputSettleTimeoutIsFailure() {
    let result = MacGridAudioOutputSettleResult(
      snapshot: snapshot(outputRate: 24_000, outputChannels: 1),
      timedOut: true
    )

    #expect(throws: MacGridAudioOutputSettleError.self) {
      try result.requireCompatibleOutput()
    }
  }

  @Test("same UID input profile changes require a fresh physical direction")
  func sameUIDInputProfileChangeInvalidatesSignature() {
    let original = device(
      id: 303,
      uid: "airpods:input",
      name: "AirPods",
      input: true,
      transport: kAudioDeviceTransportTypeBluetooth,
      rate: 48_000,
      channels: 1
    )
    let voiceProfile = device(
      id: 303,
      uid: "airpods:input",
      name: "AirPods",
      input: true,
      transport: kAudioDeviceTransportTypeBluetooth,
      rate: 24_000,
      channels: 1
    )

    #expect(original.inputRouteSignature != voiceProfile.inputRouteSignature)
  }

  @Test("reconnected device ID requires a fresh direction despite a stable UID")
  func reconnectedDeviceIDInvalidatesSignatures() {
    let original = device(
      id: 304,
      uid: "airpods:output",
      name: "AirPods",
      output: true,
      transport: kAudioDeviceTransportTypeBluetooth,
      rate: 48_000,
      channels: 2
    )
    let reconnected = device(
      id: 404,
      uid: "airpods:output",
      name: "AirPods",
      output: true,
      transport: kAudioDeviceTransportTypeBluetooth,
      rate: 48_000,
      channels: 2
    )

    #expect(original.outputRouteSignature != reconnected.outputRouteSignature)
  }

  @Test("same-size PCM bit-depth changes invalidate a stable UID profile")
  func bitDepthChangeInvalidatesSignature() {
    let original = device(
      id: 303,
      uid: "usb:input",
      name: "USB Microphone",
      input: true,
      transport: kAudioDeviceTransportTypeUSB,
      rate: 48_000,
      channels: 1,
      bitsPerChannel: 24
    )
    let changed = device(
      id: 303,
      uid: "usb:input",
      name: "USB Microphone",
      input: true,
      transport: kAudioDeviceTransportTypeUSB,
      rate: 48_000,
      channels: 1,
      bitsPerChannel: 32
    )

    #expect(original.inputRouteSignature != changed.inputRouteSignature)
  }

  @Test("renaming a device does not rebuild an unchanged physical route")
  func displayNameChangeDoesNotInvalidateSignature() {
    let original = device(
      id: 304,
      uid: "airpods:output",
      name: "AirPods",
      output: true,
      transport: kAudioDeviceTransportTypeBluetooth,
      rate: 48_000,
      channels: 2
    )
    let renamed = device(
      id: 304,
      uid: "airpods:output",
      name: "Mo's AirPods",
      output: true,
      transport: kAudioDeviceTransportTypeBluetooth,
      rate: 48_000,
      channels: 2
    )

    #expect(original.outputRouteSignature == renamed.outputRouteSignature)
  }

  private func snapshot(
    inputRate: Double = 48_000,
    inputUID: String = "input",
    outputRate: Double = 48_000,
    outputChannels: UInt32 = 2,
    outputTransport: UInt32 = kAudioDeviceTransportTypeBluetooth
  ) -> MacGridAudioCatalogSnapshot {
    MacGridAudioCatalogSnapshot(
      devices: [
        device(
          id: 101,
          uid: inputUID,
          name: "Built-in Microphone",
          input: true,
          transport: kAudioDeviceTransportTypeBuiltIn,
          rate: inputRate,
          channels: 1
        ),
        device(
          id: 202,
          uid: "usb:input",
          name: "USB Microphone",
          input: true,
          transport: kAudioDeviceTransportTypeUSB,
          rate: 48_000,
          channels: 1
        ),
        device(
          id: 303,
          uid: "airpods:input",
          name: "AirPods",
          input: true,
          transport: kAudioDeviceTransportTypeBluetooth,
          rate: 24_000,
          channels: 1
        ),
        device(
          id: 304,
          uid: "airpods:output",
          name: "AirPods",
          output: true,
          transport: outputTransport,
          rate: outputRate,
          channels: outputChannels
        ),
      ],
      defaultInputID: 101,
      defaultOutputID: 304,
      epoch: 1
    )
  }

  private func inputDevice(
    uid: String,
    sampleRate: Double
  ) -> MacGridAudioDevice {
    device(
      id: 101,
      uid: uid,
      name: "Input",
      input: true,
      transport: kAudioDeviceTransportTypeBuiltIn,
      rate: sampleRate,
      channels: 1
    )
  }

  private func idleInputState(
    nativeRecordingDemanded: Bool = false,
    expectedUID: String?,
    selectedUID: String?,
    activeUID: String? = nil,
    activeSignature: MacGridAudioInputRouteSignature? = nil,
    activeDeviceReadbackVerified: Bool? = nil
  ) -> MacGridAUHALIdleInputRouteHealthState {
    MacGridAUHALIdleInputRouteHealthState(
      nativeRecordingDemanded: nativeRecordingDemanded,
      isRecording: false,
      expectedUID: expectedUID,
      selectedUID: selectedUID,
      activeUID: activeUID,
      activeSignature: activeSignature,
      activeDeviceReadbackVerified: activeDeviceReadbackVerified,
      lastControlFailure: nil
    )
  }

  private func device(
    id: AudioDeviceID,
    uid: String,
    name: String,
    input: Bool = false,
    output: Bool = false,
    transport: UInt32,
    rate: Double,
    channels: UInt32,
    bitsPerChannel: UInt32 = 32
  ) -> MacGridAudioDevice {
    let format = MacGridAudioStreamFormat(
      AudioStreamBasicDescription(
        mSampleRate: rate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat,
        mBytesPerPacket: channels * 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: channels * 4,
        mChannelsPerFrame: channels,
        mBitsPerChannel: bitsPerChannel,
        mReserved: 0
      )
    )
    return MacGridAudioDevice(
      id: id,
      uid: uid,
      name: name,
      hasInput: input,
      hasOutput: output,
      sampleRate: rate,
      bufferFrameSize: 512,
      transport: transport,
      inputStreamFormat: input ? format : nil,
      outputStreamFormat: output ? format : nil
    )
  }
}
#endif
