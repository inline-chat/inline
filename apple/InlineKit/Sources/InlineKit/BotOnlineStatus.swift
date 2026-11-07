import Foundation

/// Online status for bots. The server derives it from the bot's connection and
/// API activity; people's presence is not shown, so these return nil for them.
public enum BotOnlineStatus {
  /// Whether to show an online dot on this user's avatar.
  public static func isOnline(_ user: User) -> Bool {
    user.bot && user.online == true
  }

  /// "online", "last seen at 3:04 PM", "last seen yesterday at 3:04 PM", or
  /// "last seen Nov 3". Absolute times stay correct without a refresh timer.
  public static func subtitle(
    for user: User,
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> String? {
    guard user.bot, let online = user.online else { return nil }
    if online { return "online" }
    guard let lastOnline = user.lastOnline else { return "offline" }
    return "last seen \(lastSeen(lastOnline, now: now, calendar: calendar, locale: locale))"
  }

  static func lastSeen(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
    let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    let time = date.formatted(base.hour().minute())
    if calendar.isDate(date, inSameDayAs: now) {
      return "at \(time)"
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
      return "yesterday at \(time)"
    }
    var day = base.month(.abbreviated).day()
    if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
      day = day.year()
    }
    return date.formatted(day)
  }

  @MainActor private static var lastRefresh: [Int64: Date] = [:]

  /// Refetches a bot's status when its DM opens. Live changes only reach a
  /// connected app, so a cached "online" can be stale after time away.
  @MainActor
  public static func refreshIfBot(_ user: User?) {
    guard let user, user.bot else { return }
    let now = Date()
    if let last = lastRefresh[user.id], now.timeIntervalSince(last) < 30 { return }
    lastRefresh[user.id] = now
    Task {
      _ = try? await DataManager.shared.getUsers(ids: [user.id])
    }
  }
}
