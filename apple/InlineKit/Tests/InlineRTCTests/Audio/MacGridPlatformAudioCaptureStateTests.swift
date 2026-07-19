import Testing

@testable import InlineRTC

#if os(macOS)
@Suite("macOS platform audio capture state")
struct MacGridPlatformAudioCaptureStateTests {
  @Test("recovery preserves requested input after route and recording rollback fail")
  func recoversAfterRollbackFailure() {
    var state = MacGridPlatformAudioCaptureState()
    state.inputSelected(.automatic)
    state.recordingStarted()

    state.recordingStopped()
    state.inputSelectionLost()
    state.recordingStopped()

    let requested = AudioInputRouteTarget.device(
      id: "stable-usb-uid",
      name: "USB Microphone"
    )
    #expect(state.recoveryTarget(preserving: requested) == requested)

    state.inputSelected(requested)
    state.recordingStarted()
    #expect(state.appliedInputTarget == requested)
    #expect(state.isPrepared)
  }

  @Test("recovery can restart an applied route after a later start failure")
  func recoversAfterStartFailure() {
    var state = MacGridPlatformAudioCaptureState()
    let requested = AudioInputRouteTarget.device(
      id: "stable-usb-uid",
      name: "USB Microphone"
    )
    state.inputSelected(requested)
    state.recordingStopped()

    #expect(state.recoveryTarget(preserving: nil) == requested)

    state.recordingStarted()
    #expect(state.isPrepared)
  }

  @Test("recovery has a safe default even when no route survived")
  func recoveryDefaultsToAutomatic() {
    let state = MacGridPlatformAudioCaptureState()
    #expect(state.recoveryTarget(preserving: nil) == .automatic)
  }
}
#endif
