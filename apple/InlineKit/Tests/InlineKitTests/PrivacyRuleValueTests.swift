import Foundation
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Privacy rules")
struct PrivacyRuleValueTests {
  @Test("a server rule round-trips and keeps both lists across audience changes")
  func roundTrip() {
    var rule = PrivacyRuleValue(audience: .nobody, alwaysShare: [2, 3], neverShare: [9])
    #expect(PrivacyRuleValue(from: rule.toProtocol()) == rule)
    #expect(rule.exceptions == [2, 3])

    rule.audience = .everyone
    #expect(rule.exceptions == [9])
    rule.exceptions = []
    rule.audience = .nobody
    #expect(rule.exceptions == [2, 3])
  }

  @Test("saves omit the rule until the server sent one")
  @MainActor
  func legacyFallback() {
    let manager = PrivacySettingsManager(shareTimeZone: false)
    #expect(manager.effectiveTimeZoneRule == .legacy(share: false))
    #expect(!manager.toProtocol().hasTimeZone)

    manager.setTimeZoneRule(PrivacyRuleValue(audience: .everyone, neverShare: [4]))
    #expect(manager.shareTimeZone)
    #expect(manager.toProtocol().timeZone.neverShare.map(\.userID) == [4])
  }
}
