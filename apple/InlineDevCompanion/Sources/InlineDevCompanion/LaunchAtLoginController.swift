import OSLog
import ServiceManagement

@MainActor
enum LaunchAtLoginController {
  private static let logger = Logger(
    subsystem: "chat.inline.InlineDevCompanion",
    category: "LaunchAtLogin"
  )

  static func enable() {
    let service = SMAppService.mainApp
    switch service.status {
    case .enabled, .requiresApproval:
      return
    case .notRegistered, .notFound:
      do {
        try service.register()
      } catch {
        logger.error("Unable to enable launch at login: \(error)")
      }
    @unknown default:
      logger.error("Unable to enable launch at login because the app service status is unknown.")
    }
  }
}
