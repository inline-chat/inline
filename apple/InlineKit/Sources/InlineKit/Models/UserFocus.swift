import Foundation
import GRDB
import InlineProtocol

/// Whether a Focus silences another person's notifications, as this viewer was
/// told. Kept apart from `User` so user saves that carry no Focus never erase it.
public struct UserFocus: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
  public static let databaseTableName = "userFocus"

  /// The server treats a focused report older than this as off; so do clients.
  public static let staleInterval: TimeInterval = 24 * 60 * 60

  public var userId: Int64
  public var focused: Bool
  public var updatedAt: Date?

  public init(userId: Int64, focused: Bool, updatedAt: Date?) {
    self.userId = userId
    self.focused = focused
    self.updatedAt = updatedAt
  }

  /// True while the last report says focused and is recent enough to show.
  public func isActive(now: Date = Date()) -> Bool {
    guard focused, let updatedAt else { return false }
    return now.timeIntervalSince(updatedAt) < Self.staleInterval
  }

  /// Stores the server's authoritative value for one person.
  static func save(_ db: Database, userID: Int64, status: InlineProtocol.FocusStatus) throws {
    let updatedAt = status.hasUpdatedAt ? User.lastOnlineDate(from: status.updatedAt) : nil
    try UserFocus(userId: userID, focused: status.focused, updatedAt: updatedAt).save(db)
  }
}

public extension User {
  static let focusStatus = hasOne(UserFocus.self, using: ForeignKey(["userId"]))
}

public extension UserInfo {
  /// The line a DM shows under its newest message while this person's Focus
  /// silences notifications, or nil when there is nothing to say.
  func notificationsSilencedNotice(now: Date = Date()) -> String? {
    guard !user.bot, focus?.isActive(now: now) == true else { return nil }
    return "\(user.shortDisplayName) has notifications silenced"
  }
}
