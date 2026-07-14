import AVFoundation
import Foundation

public enum InlineRTCMicrophonePermission: String, Equatable, Sendable {
  case notDetermined
  case requesting
  case authorized
  case denied
  case restricted

  public var permitsCapture: Bool { self == .authorized }
}

protocol GridMicrophonePermissionDriver: Sendable {
  func status() async -> InlineRTCMicrophonePermission
  func request() async -> InlineRTCMicrophonePermission
}

struct SystemGridMicrophonePermissionDriver: GridMicrophonePermissionDriver {
  func status() async -> InlineRTCMicrophonePermission {
    Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
  }

  func request() async -> InlineRTCMicrophonePermission {
    let current = await status()
    guard current == .notDetermined else { return current }
    let granted = await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
    return granted ? .authorized : await status()
  }

  private static func map(_ status: AVAuthorizationStatus) -> InlineRTCMicrophonePermission {
    switch status {
    case .notDetermined: .notDetermined
    case .restricted: .restricted
    case .denied: .denied
    case .authorized: .authorized
    @unknown default: .restricted
    }
  }
}
