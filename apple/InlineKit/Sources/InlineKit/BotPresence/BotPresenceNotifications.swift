import Foundation
import InlineProtocol

public enum BotPresenceNotifications {
  public static let update = Notification.Name("inline.botPresence.update")
  public static let updateKey = "update"

  public static func post(_ update: InlineProtocol.UpdateBotPresence) {
    NotificationCenter.default.post(
      name: Self.update,
      object: nil,
      userInfo: [Self.updateKey: update]
    )
  }

  public static func update(from notification: Notification) -> InlineProtocol.UpdateBotPresence? {
    notification.userInfo?[Self.updateKey] as? InlineProtocol.UpdateBotPresence
  }
}
