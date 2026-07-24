import Testing

@testable import InlineRTC

#if os(macOS)
@Suite("macOS platform audio capture state")
struct MacGridPlatformAudioCaptureStateTests {
  @Test("a recording rollback failure does not erase the last applied route")
  func recoversAfterRollbackFailure() {
    var state = MacGridPlatformAudioCaptureState()
    state.inputSelected(.automatic, deviceUID: "built-in-uid")
    state.recordingStarted()

    state.recordingStopped()

    #expect(state.appliedInputTarget == .automatic)
    #expect(state.appliedInputDeviceUID == "built-in-uid")
    #expect(state.recoveryTarget(preserving: nil) == .automatic)
    #expect(!state.isPrepared)

    let requested = AudioInputRouteTarget.device(
      id: "stable-usb-uid",
      name: "USB Microphone"
    )
    #expect(state.recoveryTarget(preserving: requested) == requested)

    state.inputSelected(requested, deviceUID: "stable-usb-uid")
    state.recordingStarted()
    #expect(state.appliedInputTarget == requested)
    #expect(state.appliedInputDeviceUID == "stable-usb-uid")
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

  @Test("an unmodified Auto route can recover without quarantining a healthy mic")
  func unchangedAutomaticRouteCanRecover() {
    var state = MacGridPlatformAudioCaptureState()
    state.inputSelected(.automatic, deviceUID: "built-in-uid")

    #expect(state.canCommitUnchangedAutomaticRoute(
      requesting: .automatic,
      selectionWasAttempted: false,
      recordingRestored: true
    ))
    #expect(!state.canCommitUnchangedAutomaticRoute(
      requesting: .automatic,
      selectionWasAttempted: true,
      recordingRestored: true
    ))
    #expect(!state.canCommitUnchangedAutomaticRoute(
      requesting: .device(id: "built-in-uid", name: "Built-in Microphone"),
      selectionWasAttempted: false,
      recordingRestored: true
    ))
  }

  @Test("recovery has a safe default even when no route survived")
  func recoveryDefaultsToAutomatic() {
    let state = MacGridPlatformAudioCaptureState()
    #expect(state.recoveryTarget(preserving: nil) == .automatic)
  }
}
#endif
