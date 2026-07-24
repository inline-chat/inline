#if os(macOS)
import Foundation
import LiveKit

protocol MacGridWebRTCAudioLifecycleAccess: Sendable {
  var isPlaying: Bool { get }
  var isRecording: Bool { get }

  func stopPlayout() throws
  func startPlayout() throws
  func stopRecording() throws
  func startRecording(audioProcessingOptions: AudioProcessingOptions) throws
}

struct LiveKitMacGridWebRTCAudioLifecycleAccess: MacGridWebRTCAudioLifecycleAccess {
  var isPlaying: Bool {
    AudioManager.shared.isPlaying
  }

  var isRecording: Bool {
    AudioManager.shared.isRecording
  }

  func stopPlayout() throws {
    try AudioManager.shared.stopLocalPlayout()
  }

  func startPlayout() throws {
    try AudioManager.shared.startLocalPlayout()
  }

  func stopRecording() throws {
    try AudioManager.shared.stopLocalRecording()
  }

  func startRecording(audioProcessingOptions: AudioProcessingOptions) throws {
    try AudioManager.shared.startLocalRecording(
      audioProcessingOptions: audioProcessingOptions
    )
  }
}

struct MacGridWebRTCAudioLifecycleController {
  private let access: any MacGridWebRTCAudioLifecycleAccess

  init(
    access: any MacGridWebRTCAudioLifecycleAccess =
      LiveKitMacGridWebRTCAudioLifecycleAccess()
  ) {
    self.access = access
  }

  var isPlaying: Bool {
    access.isPlaying
  }

  var isRecording: Bool {
    access.isRecording
  }

  func beginPlayoutTransition() throws -> Bool {
    guard access.isPlaying else { return false }
    do {
      try access.stopPlayout()
    } catch {
      try rethrowAfterRestoringPartiallyStoppedPlayout(error)
    }
    guard !access.isPlaying else {
      throw MacGridWebRTCAudioLifecycleError.playoutDidNotStop
    }
    return true
  }

  func stopPlayout() throws {
    guard access.isPlaying else { return }
    try access.stopPlayout()
    guard !access.isPlaying else {
      throw MacGridWebRTCAudioLifecycleError.playoutDidNotStop
    }
  }

  func ensurePlayoutStarted() throws {
    guard !access.isPlaying else { return }
    try access.startPlayout()
    guard access.isPlaying else {
      throw MacGridWebRTCAudioLifecycleError.playoutDidNotStart
    }
  }

  func finishPlayoutTransition(wasPlaying: Bool) throws {
    let becameActiveDuringTransition = access.isPlaying
    guard wasPlaying || becameActiveDuringTransition else { return }
    if becameActiveDuringTransition {
      do {
        try access.stopPlayout()
      } catch {
        // Playout may become demanded while a route transaction is already in
        // flight. A native stop can then fail after changing state; retain
        // ownership until that newly active direction is restored or return a
        // typed rollback failure.
        try rethrowAfterRestoringPartiallyStoppedPlayout(error)
      }
      guard !access.isPlaying else {
        throw MacGridWebRTCAudioLifecycleError.playoutDidNotStop
      }
    }
    try access.startPlayout()
    guard access.isPlaying else {
      throw MacGridWebRTCAudioLifecycleError.playoutDidNotStart
    }
  }

  func startRecording(audioProcessingOptions: AudioProcessingOptions) throws {
    guard !access.isRecording else { return }
    do {
      try access.startRecording(audioProcessingOptions: audioProcessingOptions)
    } catch {
      try rethrowAfterStoppingPartiallyStartedRecording(error)
    }
    guard access.isRecording else {
      throw MacGridWebRTCAudioLifecycleError.recordingDidNotStart
    }
  }

  func stopRecording() throws {
    guard access.isRecording else { return }
    try access.stopRecording()
    guard !access.isRecording else {
      throw MacGridWebRTCAudioLifecycleError.recordingDidNotStop
    }
  }

  private func rethrowAfterRestoringPartiallyStoppedPlayout(
    _ primaryError: any Error
  ) throws -> Never {
    if !access.isPlaying {
      do {
        try access.startPlayout()
      } catch {
        // Native lifecycle calls may report failure after applying the state.
        // Verified active playout satisfies rollback even though the primary
        // transition still fails.
        if access.isPlaying {
          throw primaryError
        }
        throw MacGridWebRTCAudioLifecycleError.playoutRollbackFailed(
          primary: String(describing: primaryError),
          rollback: String(describing: error)
        )
      }
      guard access.isPlaying else {
        throw MacGridWebRTCAudioLifecycleError.playoutRollbackFailed(
          primary: String(describing: primaryError),
          rollback: MacGridWebRTCAudioLifecycleError.playoutDidNotStart.localizedDescription
        )
      }
    }
    throw primaryError
  }

  private func rethrowAfterStoppingPartiallyStartedRecording(
    _ primaryError: any Error
  ) throws -> Never {
    if access.isRecording {
      do {
        try access.stopRecording()
      } catch {
        // A throwing native stop may still have applied the requested state.
        // Only retain the rollback failure when microphone ownership remains.
        if !access.isRecording {
          throw primaryError
        }
        throw MacGridWebRTCAudioLifecycleError.recordingStartRollbackFailed(
          primary: String(describing: primaryError),
          rollback: String(describing: error)
        )
      }
      guard !access.isRecording else {
        throw MacGridWebRTCAudioLifecycleError.recordingStartRollbackFailed(
          primary: String(describing: primaryError),
          rollback: MacGridWebRTCAudioLifecycleError.recordingDidNotStop.localizedDescription
        )
      }
    }
    throw primaryError
  }
}

enum MacGridWebRTCAudioLifecycleError: LocalizedError {
  case playoutDidNotStop
  case playoutDidNotStart
  case playoutRollbackFailed(primary: String, rollback: String)
  case recordingDidNotStop
  case recordingDidNotStart
  case recordingStartRollbackFailed(primary: String, rollback: String)

  // SwiftLint aligns cases with `switch`; the repository SwiftFormat config
  // otherwise applies the opposite indentation rule here.
  // swiftformat:disable indent
  var errorDescription: String? {
    switch self {
    case .playoutDidNotStop:
      "WebRTC returned without stopping AudioEngine playback."
    case .playoutDidNotStart:
      "WebRTC returned without starting AudioEngine playback."
    case let .playoutRollbackFailed(primary, rollback):
      "WebRTC playback stop failed (\(primary)) and playback rollback failed (\(rollback))."
    case .recordingDidNotStop:
      "WebRTC returned without stopping AudioEngine microphone capture."
    case .recordingDidNotStart:
      "WebRTC returned without starting AudioEngine microphone capture."
    case let .recordingStartRollbackFailed(primary, rollback):
      "WebRTC microphone start failed (\(primary)) and capture rollback failed (\(rollback))."
    }
  }
  // swiftformat:enable indent
}
#endif
