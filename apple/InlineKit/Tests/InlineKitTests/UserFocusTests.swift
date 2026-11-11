import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("User Focus status")
struct UserFocusTests {
  private func focused(_ value: Bool, at date: Date = Date()) -> InlineProtocol.FocusStatus {
    .with {
      $0.focused = value
      $0.updatedAt = Int64(date.timeIntervalSince1970)
    }
  }

  @Test("a user save without Focus keeps it; an evaluated status replaces it")
  func keepsUnevaluatedFocus() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      _ = try User.save(db, user: .with {
        $0.id = 301
        $0.firstName = "Peer"
        $0.status = .with { $0.online = .online; $0.focus = focused(true) }
      })
      #expect(try User.userInfoQuery().filter(id: 301).fetchOne(db)?.focus?.isActive() == true)

      // A space member list or bot path carries no Focus.
      _ = try User.save(db, user: .with { $0.id = 301; $0.firstName = "Peer"; $0.min = true })
      try InlineProtocol.UpdateUserStatus.with { $0.userID = 301; $0.status = .with { $0.online = .offline } }.apply(db)
      #expect(try User.userInfoQuery().filter(id: 301).fetchOne(db)?.focus?.isActive() == true)

      // Hidden or off reads as an evaluated false.
      try InlineProtocol.UpdateUserStatus.with {
        $0.userID = 301
        $0.status = .with { $0.focus = .with { $0.focused = false } }
      }.apply(db)
      #expect(try User.userInfoQuery().filter(id: 301).fetchOne(db)?.focus?.isActive() == false)
    }
  }

  @Test("a focused report older than a day is not shown")
  func staleFocus() {
    let now = Date()
    #expect(UserFocus(userId: 1, focused: true, updatedAt: now.addingTimeInterval(-3600)).isActive(now: now))
    #expect(!UserFocus(userId: 1, focused: true, updatedAt: now.addingTimeInterval(-25 * 3600)).isActive(now: now))
    #expect(!UserFocus(userId: 1, focused: true, updatedAt: nil).isActive(now: now))
  }

  @Test("the chat notice names the person only while their Focus is active")
  func silencedNotice() {
    var user = User(id: 7, email: nil, firstName: "Sam", lastName: "Kim")
    let now = Date()
    var info = UserInfo(user: user, focus: UserFocus(userId: 7, focused: true, updatedAt: now))
    #expect(info.notificationsSilencedNotice(now: now) == "Sam has notifications silenced")
    info.focus = UserFocus(userId: 7, focused: false, updatedAt: now)
    #expect(info.notificationsSilencedNotice(now: now) == nil)
    user.bot = true
    info = UserInfo(user: user, focus: UserFocus(userId: 7, focused: true, updatedAt: now))
    #expect(info.notificationsSilencedNotice(now: now) == nil)
  }

  @Test("Focus is opt-in and reported only once someone can see it")
  @MainActor
  func focusRuleDefaults() {
    let manager = PrivacySettingsManager()
    #expect(manager.effectiveFocusStatusRule == PrivacyRuleValue(audience: .nobody))
    #expect(!manager.sharesFocusStatus)
    #expect(!manager.toProtocol().hasFocusStatus)

    manager.setFocusStatusRule(PrivacyRuleValue(audience: .nobody, alwaysShare: [8]))
    #expect(manager.sharesFocusStatus)
    #expect(manager.toProtocol().focusStatus.alwaysShare.map(\.userID) == [8])
  }
}
