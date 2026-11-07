import Foundation
@testable import InlineKit
import Testing

@Suite("Bot online status")
struct BotOnlineStatusTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private let locale = Locale(identifier: "en_US_POSIX")
  // 2026-11-07 15:00 UTC
  private let now = Date(timeIntervalSince1970: 1_794_063_600)

  private func user(bot: Bool, online: Bool?, lastOnline: Date? = nil) -> User {
    var user = User(id: 7, email: nil, firstName: "Agent")
    user.bot = bot
    user.online = online
    user.lastOnline = lastOnline
    return user
  }

  private func subtitle(_ user: User) -> String? {
    BotOnlineStatus.subtitle(for: user, now: now, calendar: calendar, locale: locale)
  }

  @Test func peopleNeverShowPresence() {
    #expect(subtitle(user(bot: false, online: true)) == nil)
    #expect(BotOnlineStatus.isOnline(user(bot: false, online: true)) == false)
  }

  @Test func unknownStatusShowsNothing() {
    #expect(subtitle(user(bot: true, online: nil)) == nil)
  }

  @Test func onlineAndLastSeen() {
    #expect(subtitle(user(bot: true, online: true)) == "online")
    #expect(BotOnlineStatus.isOnline(user(bot: true, online: true)))
    #expect(subtitle(user(bot: true, online: false)) == "offline")

    let today = now.addingTimeInterval(-2 * 3600)
    #expect(subtitle(user(bot: true, online: false, lastOnline: today))?.hasPrefix("last seen at ") == true)

    let yesterday = now.addingTimeInterval(-20 * 3600)
    #expect(subtitle(user(bot: true, online: false, lastOnline: yesterday))?.hasPrefix("last seen yesterday at ") == true)

    let lastWeek = now.addingTimeInterval(-5 * 86400)
    #expect(subtitle(user(bot: true, online: false, lastOnline: lastWeek)) == "last seen Nov 2")

    let lastYear = now.addingTimeInterval(-400 * 86400)
    #expect(subtitle(user(bot: true, online: false, lastOnline: lastYear))?.contains("2025") == true)
  }
}
