import Testing
import UserNotifications

@testable import InlineKit

@Suite("Urgent notification presentation")
struct UrgentNotificationPresentationTests {
  @Test("Time-sensitive notifications interrupt in the foreground")
  func timeSensitiveForegroundOptions() {
    let content = UNMutableNotificationContent()
    content.interruptionLevel = .timeSensitive

    let options = UrgentNotificationPresentation.foregroundOptions(for: content)

    #expect(options.contains(.banner))
    #expect(options.contains(.list))
    #expect(options.contains(.sound))
  }

  @Test("Ordinary notifications preserve foreground suppression")
  func ordinaryForegroundOptions() {
    let content = UNMutableNotificationContent()

    #expect(UrgentNotificationPresentation.foregroundOptions(for: content).isEmpty)
  }
}
