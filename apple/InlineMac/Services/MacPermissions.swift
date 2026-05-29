import AppKit
import AVFoundation
import UserNotifications

enum MacPermissions {
  @MainActor private static var didStartNotificationAuthorizationRequest = false

  enum SystemSettingsPanel {
    case notifications
    case camera
    case microphone

    var urls: [String] {
      switch self {
        case .notifications:
          [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
          ]
        case .camera:
          [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
          ]
        case .microphone:
          [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
          ]
      }
    }
  }

  static func notificationSettings() async -> UNNotificationSettings {
    await UNUserNotificationCenter.current().notificationSettings()
  }

  @discardableResult
  static func requestNotifications() async throws -> Bool {
    try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
  }

  @MainActor
  static func ensureNotificationAuthorizationIfNeeded() {
    guard !didStartNotificationAuthorizationRequest else { return }
    didStartNotificationAuthorizationRequest = true

    Task {
      let settings = await notificationSettings()
      guard settings.authorizationStatus == .notDetermined else { return }
      _ = try? await requestNotifications()
    }
  }

  static func mediaStatus(for type: AVMediaType) -> AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: type)
  }

  @discardableResult
  static func requestMediaAccess(for type: AVMediaType) async -> Bool {
    await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: type) { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  @MainActor
  static func openSystemSettings(_ panel: SystemSettingsPanel) {
    for rawURL in panel.urls {
      guard let url = URL(string: rawURL) else { continue }
      if NSWorkspace.shared.open(url) {
        return
      }
    }
  }
}
