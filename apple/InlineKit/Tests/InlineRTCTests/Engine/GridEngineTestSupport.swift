import Foundation

@testable import InlineRTC

struct TestGridMicrophonePermissionDriver: GridMicrophonePermissionDriver {
  var current: InlineRTCMicrophonePermission = .authorized
  var requested: InlineRTCMicrophonePermission = .authorized

  func status() async -> InlineRTCMicrophonePermission { current }
  func request() async -> InlineRTCMicrophonePermission { requested }
}

/// Holds the audio engine's first permission read, which suspends the first
/// capture lease acquisition while later acquisitions complete.
actor BlockingStatusGridMicrophonePermissionDriver: GridMicrophonePermissionDriver {
  private var statusStarted = false
  private var released = false
  private var continuation: CheckedContinuation<InlineRTCMicrophonePermission, Never>?

  func status() async -> InlineRTCMicrophonePermission {
    guard !released else { return .authorized }
    statusStarted = true
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func request() async -> InlineRTCMicrophonePermission { .authorized }

  func hasStartedStatus() -> Bool { statusStarted }

  func releaseStatus() {
    released = true
    continuation?.resume(returning: .authorized)
    continuation = nil
  }
}

actor BlockingGridMicrophonePermissionDriver: GridMicrophonePermissionDriver {
  private var current: InlineRTCMicrophonePermission = .notDetermined
  private var requestStarted = false
  private var continuation: CheckedContinuation<InlineRTCMicrophonePermission, Never>?

  func status() -> InlineRTCMicrophonePermission { current }

  func request() async -> InlineRTCMicrophonePermission {
    requestStarted = true
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func hasStartedRequest() -> Bool { requestStarted }

  func resolve(_ permission: InlineRTCMicrophonePermission) {
    current = permission
    continuation?.resume(returning: permission)
    continuation = nil
  }
}
