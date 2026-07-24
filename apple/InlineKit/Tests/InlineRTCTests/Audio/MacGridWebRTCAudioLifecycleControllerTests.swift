#if os(macOS)
@testable import InlineRTC
import LiveKit
import Testing

@Suite("WebRTC audio lifecycle boundary")
struct MacGridAudioLifecycleControllerTests {
  @Test("active playout is stopped and freshly initialized after a route transition")
  func activePlayoutIsReinitialized() throws {
    let access = RecordingAudioLifecycleAccess(isPlaying: true)
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    let wasPlaying = try controller.beginPlayoutTransition()
    try controller.finishPlayoutTransition(wasPlaying: wasPlaying)

    #expect(wasPlaying)
    #expect(access.operations == ["stopPlayout", "startPlayout"])
    #expect(access.isPlaying)
  }

  @Test("playout that starts during the transition is stopped and rebuilt")
  func newlyActivePlayoutIsReinitialized() throws {
    let access = RecordingAudioLifecycleAccess()
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    let wasPlaying = try controller.beginPlayoutTransition()
    access.isPlaying = true
    try controller.finishPlayoutTransition(wasPlaying: wasPlaying)

    #expect(!wasPlaying)
    #expect(access.operations == ["stopPlayout", "startPlayout"])
  }

  @Test("an already-stopped recording is an idempotent stop")
  func stoppedRecordingIsIdempotent() throws {
    let access = RecordingAudioLifecycleAccess()
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    try controller.stopRecording()

    #expect(access.operations.isEmpty)
  }

  @Test("recording startup must produce observable ADM recording state")
  func recordingStartupRequiresStateChange() {
    let access = RecordingAudioLifecycleAccess()
    access.applyRecordingStateChanges = false
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    #expect(throws: MacGridWebRTCAudioLifecycleError.self) {
      try controller.startRecording(audioProcessingOptions: AudioProcessingOptions())
    }
    #expect(access.operations == ["startRecording"])
  }

  @Test("a partial recording start is stopped before lifecycle ownership returns")
  func partialRecordingStartRollsBack() {
    let access = RecordingAudioLifecycleAccess()
    access.failStartRecordingAfterStateChange = true
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    #expect(throws: TestAudioLifecycleError.self) {
      try controller.startRecording(audioProcessingOptions: AudioProcessingOptions())
    }
    #expect(access.operations == ["startRecording", "stopRecording"])
    #expect(!access.isRecording)
  }

  @Test("a failed partial-start rollback remains a typed non-success")
  func partialRecordingStartRollbackFailureIsTyped() {
    let access = RecordingAudioLifecycleAccess()
    access.failStartRecordingAfterStateChange = true
    access.applyRecordingStopStateChanges = false
    access.failStopRecordingAfterStateChange = true
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    #expect(throws: MacGridWebRTCAudioLifecycleError.self) {
      try controller.startRecording(audioProcessingOptions: AudioProcessingOptions())
    }
    #expect(access.operations == ["startRecording", "stopRecording"])
    #expect(access.isRecording)
  }

  @Test("a partial playout stop is restored before transition ownership returns")
  func partialPlayoutStopRollsBack() {
    let access = RecordingAudioLifecycleAccess(isPlaying: true)
    access.failStopPlayoutAfterStateChange = true
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    #expect(throws: TestAudioLifecycleError.self) {
      _ = try controller.beginPlayoutTransition()
    }
    #expect(access.operations == ["stopPlayout", "startPlayout"])
    #expect(access.isPlaying)
  }

  @Test("a partial stop of playout that became active during transition is restored")
  func newlyActivePartialPlayoutStopRollsBack() {
    let access = RecordingAudioLifecycleAccess()
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    do {
      let wasPlaying = try controller.beginPlayoutTransition()
      access.isPlaying = true
      access.failStopPlayoutAfterStateChange = true
      try controller.finishPlayoutTransition(wasPlaying: wasPlaying)
      Issue.record("Expected the injected playout stop failure")
    } catch is TestAudioLifecycleError {
      // Expected primary failure after successful rollback.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(access.operations == ["stopPlayout", "startPlayout"])
    #expect(access.isPlaying)
  }

  @Test("a failed partial-stop rollback remains a typed non-success")
  func newlyActivePartialPlayoutRollbackFailureIsTyped() {
    let access = RecordingAudioLifecycleAccess()
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    do {
      let wasPlaying = try controller.beginPlayoutTransition()
      access.isPlaying = true
      access.failStopPlayoutAfterStateChange = true
      access.applyPlayoutStateChanges = false
      access.failStartPlayout = true
      try controller.finishPlayoutTransition(wasPlaying: wasPlaying)
      Issue.record("Expected rollback failure")
    } catch is MacGridWebRTCAudioLifecycleError {
      // Expected typed rollback failure.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(access.operations == ["stopPlayout", "startPlayout"])
    #expect(!access.isPlaying)
  }

  @Test("playout startup must produce observable ADM state")
  func playoutStartupRequiresStateChange() {
    let access = RecordingAudioLifecycleAccess()
    access.applyPlayoutStateChanges = false
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    #expect(throws: MacGridWebRTCAudioLifecycleError.self) {
      try controller.ensurePlayoutStarted()
    }
    #expect(access.operations == ["startPlayout"])
    #expect(!access.isPlaying)
  }

  @Test("recording stop must produce observable ADM state before route ownership moves")
  func recordingStopRequiresStateChange() {
    let access = RecordingAudioLifecycleAccess(isRecording: true)
    access.applyRecordingStateChanges = false
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    #expect(throws: MacGridWebRTCAudioLifecycleError.self) {
      try controller.stopRecording()
    }
    #expect(access.operations == ["stopRecording"])
    #expect(access.isRecording)
  }

  @Test("a native recording stop error remains visible after changing state")
  func partialRecordingStopRemainsFailure() {
    let access = RecordingAudioLifecycleAccess(isRecording: true)
    access.failStopRecordingAfterStateChange = true
    let controller = MacGridWebRTCAudioLifecycleController(access: access)

    #expect(throws: TestAudioLifecycleError.self) {
      try controller.stopRecording()
    }
    #expect(access.operations == ["stopRecording"])
    #expect(!access.isRecording)
  }
}

// SwiftLint keeps the opening brace on the declaration's final line while the
// repository SwiftFormat config otherwise wraps it.
// swiftformat:disable wrapMultilineStatementBraces
private final class RecordingAudioLifecycleAccess:
  MacGridWebRTCAudioLifecycleAccess,
  @unchecked Sendable {
  var isPlaying: Bool
  var isRecording: Bool
  var applyPlayoutStateChanges = true
  var applyRecordingStateChanges = true
  var failStopPlayoutAfterStateChange = false
  var failStartPlayout = false
  var failStartRecordingAfterStateChange = false
  var applyRecordingStopStateChanges = true
  var failStopRecordingAfterStateChange = false
  private(set) var operations: [String] = []

  init(isPlaying: Bool = false, isRecording: Bool = false) {
    self.isPlaying = isPlaying
    self.isRecording = isRecording
  }

  func stopPlayout() throws {
    operations.append("stopPlayout")
    isPlaying = false
    if failStopPlayoutAfterStateChange {
      throw TestAudioLifecycleError.injected
    }
  }

  func startPlayout() throws {
    operations.append("startPlayout")
    if applyPlayoutStateChanges {
      isPlaying = true
    }
    if failStartPlayout {
      throw TestAudioLifecycleError.injected
    }
  }

  func stopRecording() throws {
    operations.append("stopRecording")
    if applyRecordingStateChanges, applyRecordingStopStateChanges {
      isRecording = false
    }
    if failStopRecordingAfterStateChange {
      throw TestAudioLifecycleError.injected
    }
  }

  func startRecording(audioProcessingOptions _: AudioProcessingOptions) throws {
    operations.append("startRecording")
    if applyRecordingStateChanges {
      isRecording = true
    }
    if failStartRecordingAfterStateChange {
      throw TestAudioLifecycleError.injected
    }
  }
}

// swiftformat:enable wrapMultilineStatementBraces

private enum TestAudioLifecycleError: Error {
  case injected
}
#endif
