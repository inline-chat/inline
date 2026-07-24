#if os(macOS)
import CoreAudio
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
    #expect(
      !MacGridAudioDeviceVisibility.isUserSelectable(
        uid: "org.webrtc.audioengine.aggregate.1234.7",
        name: "WebRTC AudioEngine I/O"
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

  @Test("process route readback retains aggregates and expands physical children")
  func expandsAggregateProcessRoutes() {
    let aggregate = AudioDeviceID(700)
    let output = AudioDeviceID(701)
    let input = AudioDeviceID(702)

    let expanded = MacGridAudioProcessDeviceExpansion.expand(
      [aggregate, output]
    ) { deviceID in
      deviceID == aggregate ? [output, input] : []
    }

    #expect(expanded == [aggregate, output, input])
  }

  @Test("current-process HAL route readback is safely queryable without active IO")
  func readsCurrentProcessRoutes() async throws {
    let catalog = MacGridAudioDeviceCatalog()

    let route = try await catalog.processRouteSnapshot()

    #expect(route.inputDeviceIDs.allSatisfy { $0 != kAudioObjectUnknown })
    #expect(route.outputDeviceIDs.allSatisfy { $0 != kAudioObjectUnknown })
  }

  @Test("device catalog safely consumes retained Core Audio strings")
  func readsRetainedDeviceStrings() async throws {
    let catalog = MacGridAudioDeviceCatalog()

    let snapshot = try await catalog.snapshot()

    #expect(snapshot.devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
  }
}
#endif
