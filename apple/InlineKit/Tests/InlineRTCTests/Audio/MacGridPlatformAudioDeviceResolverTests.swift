#if os(macOS)
import CoreAudio
import Testing

@testable import InlineRTC

@Suite("WebRTC audio device identity")
struct MacGridPlatformAudioDeviceResolverTests {
  @Test("automatic input uses WebRTC's policy identifier")
  func automaticInputUsesDefaultPolicyIdentifier() throws {
    #expect(
      try MacGridPlatformAudioDeviceResolver.platformInputDeviceID(
        for: .automatic,
        in: snapshot
      ) == "default"
    )
  }

  @Test("explicit input resolves its current ephemeral Core Audio ID")
  func explicitInputResolvesCurrentCoreAudioID() throws {
    #expect(
      try MacGridPlatformAudioDeviceResolver.platformInputDeviceID(
        for: .device(id: "usb-uid", name: "USB Microphone"),
        in: snapshot
      ) == "202"
    )
  }

  @Test("platform readback maps back to stable UIDs")
  func platformReadbackMapsToStableUIDs() {
    #expect(
      MacGridPlatformAudioDeviceResolver.stableInputUID(
        forPlatformDeviceID: "default",
        in: snapshot
      ) == "built-in-input-uid"
    )
    #expect(
      MacGridPlatformAudioDeviceResolver.stableInputUID(
        forPlatformDeviceID: "202",
        in: snapshot
      ) == "usb-uid"
    )
    #expect(
      MacGridPlatformAudioDeviceResolver.stableOutputUID(
        forPlatformDeviceID: "default",
        in: snapshot
      ) == "built-in-output-uid"
    )
  }

  @Test("a stale ephemeral ID is never treated as a durable route")
  func staleEphemeralIDDoesNotResolve() {
    #expect(
      MacGridPlatformAudioDeviceResolver.stableInputUID(
        forPlatformDeviceID: "999",
        in: snapshot
      ) == nil
    )
  }

  @Test("automatic input fails when the system has no default microphone")
  func automaticInputRequiresDefaultMicrophone() {
    let snapshot = MacGridAudioCatalogSnapshot(
      devices: [],
      defaultInputID: 0,
      defaultOutputID: 0,
      epoch: 8
    )

    #expect(throws: MacGridCoreAudioError.self) {
      try MacGridPlatformAudioDeviceResolver.platformInputDeviceID(
        for: .automatic,
        in: snapshot
      )
    }
  }

  @Test("an unavailable explicit input is never resolved by its old numeric ID")
  func unavailableExplicitInputDoesNotResolve() {
    #expect(throws: MacGridCoreAudioError.self) {
      try MacGridPlatformAudioDeviceResolver.platformInputDeviceID(
        for: .device(id: "missing-uid", name: "Disconnected Microphone"),
        in: snapshot
      )
    }
  }

  private var snapshot: MacGridAudioCatalogSnapshot {
    MacGridAudioCatalogSnapshot(
      devices: [
        device(id: 101, uid: "built-in-input-uid", name: "Built-in Microphone", input: true),
        device(id: 202, uid: "usb-uid", name: "USB Microphone", input: true),
        device(id: 303, uid: "built-in-output-uid", name: "Built-in Output", output: true),
      ],
      defaultInputID: 101,
      defaultOutputID: 303,
      epoch: 7
    )
  }

  private func device(
    id: AudioDeviceID,
    uid: String,
    name: String,
    input: Bool = false,
    output: Bool = false
  ) -> MacGridAudioDevice {
    let format = MacGridAudioStreamFormat(
      AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
      )
    )
    return MacGridAudioDevice(
      id: id,
      uid: uid,
      name: name,
      hasInput: input,
      hasOutput: output,
      sampleRate: 48_000,
      bufferFrameSize: 512,
      transport: 0,
      inputStreamFormat: input ? format : nil,
      outputStreamFormat: output ? format : nil
    )
  }
}
#endif
