#if os(macOS)
import Testing

@testable import InlineRTC

@Suite("macOS audio hardware boundary")
struct MacGridAudioHardwareTests {
  @Test("AVFAudio process-private aggregates never enter the picker")
  func hidesProcessPrivateAggregates() {
    #expect(
      !MacGridAudioDeviceVisibility.isUserSelectable(
        uid: "CADefaultDeviceAggregate-73493-6",
        name: "CADefaultDeviceAggregate-73493-6"
      )
    )
    #expect(
      !MacGridAudioDeviceVisibility.isUserSelectable(
        uid: "unexpected-uid",
        name: "CADefaultDeviceAggregate-73521-4"
      )
    )
  }

  @Test("real and user-created aggregate devices remain selectable")
  func retainsUserDevices() {
    #expect(
      MacGridAudioDeviceVisibility.isUserSelectable(
        uid: "BuiltInMicrophoneDevice",
        name: "MacBook Pro Microphone"
      )
    )
    #expect(
      MacGridAudioDeviceVisibility.isUserSelectable(
        uid: "com.example.podcast-aggregate",
        name: "Podcast Aggregate Device"
      )
    )
  }
}
#endif
