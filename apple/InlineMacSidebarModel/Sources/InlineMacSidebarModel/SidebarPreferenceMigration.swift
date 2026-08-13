import Foundation

public enum SidebarPreferenceMigration {
  /// The macOS source default changed to Inbox on June 17, 2026. Account
  /// creation is the durable signal that distinguishes an older unset user
  /// from a new user on any install.
  public static let inboxDefaultAccountCutoff = Date(
    timeIntervalSince1970: 1_781_695_103
  )

  /// A new explicit mode always wins. Otherwise preserve an explicit legacy
  /// choice. An unset older account keeps All Chats while an unset account
  /// created after the product cutoff starts in Inbox.
  public static func inboxEnabled(
    storedModeIsInbox: Bool?,
    legacyInboxEnabled: Bool?,
    accountCreatedAt: Date?
  ) -> Bool {
    storedModeIsInbox
      ?? legacyInboxEnabled
      ?? accountCreatedAt.map { $0 >= inboxDefaultAccountCutoff }
      ?? false
  }
}
