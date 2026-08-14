import UserNotifications

public enum UrgentNotificationPresentation {
  public static func foregroundOptions(
    for content: UNNotificationContent
  ) -> UNNotificationPresentationOptions {
    guard content.interruptionLevel == .timeSensitive else { return [] }
    return [.banner, .list, .sound]
  }
}
