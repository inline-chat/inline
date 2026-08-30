import UserNotifications

public extension InlineMessageIntentDonation {
  /// Communication styling must not change the server's delivery or routing contract.
  static func preservingNotificationMetadata(
    from original: UNNotificationContent,
    in enriched: UNNotificationContent
  ) -> UNNotificationContent {
    guard let content = enriched.mutableCopy() as? UNMutableNotificationContent else { return original }
    content.interruptionLevel = original.interruptionLevel
    content.sound = original.sound
    content.badge = original.badge
    content.threadIdentifier = original.threadIdentifier
    content.categoryIdentifier = original.categoryIdentifier
    content.targetContentIdentifier = original.targetContentIdentifier
    content.userInfo = original.userInfo
    content.attachments = original.attachments
    content.relevanceScore = original.relevanceScore
    content.filterCriteria = original.filterCriteria
    #if os(iOS)
    content.launchImageName = original.launchImageName
    #endif
    return content
  }
}
