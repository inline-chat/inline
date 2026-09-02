import Foundation
import Testing
import UserNotifications
@testable import InlineIntents

@Suite("Communication notification metadata")
struct InlineNotificationContentTests {
  @Test func preservesAnExistingAttachment() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-notification-metadata-\(UUID().uuidString).png")
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8S8AAAAASUVORK5CYII="))
    try png.write(to: url)
    let attachment = try UNNotificationAttachment(identifier: "existing-photo", url: url)
    let original = UNMutableNotificationContent()
    original.attachments = [attachment]
    let result = InlineMessageIntentDonation.preservingNotificationMetadata(
      from: original, in: UNMutableNotificationContent()
    )
    #expect(result.attachments.map(\.identifier) == ["existing-photo"])
    #expect(result.attachments.first?.url == attachment.url)
  }

  @Test func preservesDeliveryAndRoutingWithoutReplacingStyledContent() {
    let original = UNMutableNotificationContent()
    original.title = "Original"
    original.body = "Message"
    original.interruptionLevel = .timeSensitive
    original.sound = .default
    original.badge = 7
    original.threadIdentifier = "chat_42"
    original.categoryIdentifier = "message"
    original.targetContentIdentifier = "message_99"
    original.userInfo = ["threadId": "chat_42", "messageId": "99"]
    original.relevanceScore = 0.75
    original.filterCriteria = "work"
    #if os(iOS)
    original.launchImageName = "Launch"
    #endif
    let enriched = UNMutableNotificationContent()
    enriched.title = "Styled sender"
    enriched.body = "Styled message"
    let result = InlineMessageIntentDonation.preservingNotificationMetadata(from: original, in: enriched)
    #expect(result.title == "Styled sender")
    #expect(result.body == "Styled message")
    #expect(result.interruptionLevel == .timeSensitive)
    #expect(result.sound == original.sound)
    #expect(result.badge == 7)
    #expect(result.threadIdentifier == "chat_42")
    #expect(result.categoryIdentifier == "message")
    #expect(result.targetContentIdentifier == "message_99")
    #expect(result.userInfo["messageId"] as? String == "99")
    #expect(result.relevanceScore == 0.75)
    #expect(result.filterCriteria == "work")
    #if os(iOS)
    #expect(result.launchImageName == "Launch")
    #endif
  }

  @Test func enrichmentCannotAddSoundOrBadgeToSilentNotification() {
    let original = UNMutableNotificationContent()
    let enriched = UNMutableNotificationContent()
    enriched.sound = .default
    enriched.badge = 99
    let result = InlineMessageIntentDonation.preservingNotificationMetadata(from: original, in: enriched)
    #expect(result.sound == nil)
    #expect(result.badge == nil)
  }
}
