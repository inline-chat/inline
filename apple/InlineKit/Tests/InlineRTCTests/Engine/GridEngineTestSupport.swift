import Foundation

@testable import InlineRTC

struct TestGridMicrophonePermissionDriver: GridMicrophonePermissionDriver {
  var current: InlineRTCMicrophonePermission = .authorized
  var requested: InlineRTCMicrophonePermission = .authorized

  func status() async -> InlineRTCMicrophonePermission { current }
  func request() async -> InlineRTCMicrophonePermission { requested }
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
