import AVFoundation

/// Microphone permission across `AVAudioApplication` (iOS 17) and `AVAudioSession` (earlier).
enum MicrophonePermission {
  enum State { case granted, denied, undetermined }

  static var state: State {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return .granted
      case .denied: return .denied
      case .undetermined: return .undetermined
      @unknown default: return .undetermined
      }
    }
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted: return .granted
    case .denied: return .denied
    case .undetermined: return .undetermined
    @unknown default: return .undetermined
    }
  }

  static var isGranted: Bool { state == .granted }

  static func request() async -> Bool {
    await withCheckedContinuation { continuation in
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
      }
    }
  }

  /// Input mute state (iOS 17+); unknown (false) before.
  static var isInputMuted: Bool {
    if #available(iOS 17.0, *) { return AVAudioApplication.shared.isInputMuted }
    return false
  }
}
