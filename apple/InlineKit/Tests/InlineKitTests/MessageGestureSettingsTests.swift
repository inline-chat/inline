import Foundation
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Message gesture settings")
@MainActor
struct MessageGestureSettingsTests {
  @Test("local opt-out survives relaunch and stays isolated by account")
  func localOverridesAndAccounts() throws {
    let suite = "MessageGestures.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = MessageGestureSettingsManager(defaults: defaults, legacyDefaults: defaults)
    manager.configure(for: 1)
    #expect(manager.syncEnabled)
    manager.doubleTapAction = .reply
    manager.syncEnabled = false
    manager.holdAction = .toggleHeart
    manager.swipeToReplyDirection = .leftToRight
    var remote = MessageGestureValues()
    remote.doubleTapAction = .toggleThumbsUp
    manager.accountValues = remote
    #expect(manager.doubleTapAction == .reply)

    let relaunched = MessageGestureSettingsManager(defaults: defaults, legacyDefaults: defaults)
    relaunched.configure(for: 1)
    #expect(!relaunched.syncEnabled)
    #expect(relaunched.doubleTapAction == .reply)
    #expect(relaunched.holdAction == .toggleHeart)
    #expect(relaunched.swipeToReplyDirection == .leftToRight)
    relaunched.accountValues = remote
    relaunched.syncEnabled = true
    #expect(relaunched.doubleTapAction == .toggleThumbsUp)
    relaunched.configure(for: 2)
    #expect(relaunched.syncEnabled)
    #expect(relaunched.doubleTapAction == .toggleAck)
    relaunched.configure(for: nil)
    #expect(relaunched.doubleTapAction == .toggleAck)
  }

  @Test("legacy choices migrate only to their first account")
  func legacyMigration() throws {
    let suite = "MessageGestures.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("none", forKey: "messageDoubleTapAction")
    defaults.set("leftToRight", forKey: MessageSwipeToReplyDirection.storageKey)
    let manager = MessageGestureSettingsManager(defaults: defaults, legacyDefaults: defaults)
    manager.configure(for: 1)
    #expect(manager.doubleTapAction == .none)
    #expect(manager.swipeToReplyDirection == .leftToRight)
    manager.configure(for: 2)
    #expect(manager.doubleTapAction == .toggleAck)
    #expect(manager.swipeToReplyDirection == .rightToLeft)
  }

  @Test("unknown protocol values use safe defaults and every action round trips")
  func protocolCompatibility() throws {
    let unknown = MessageGestureValues(.with {
      $0.doubleTapAction = "future"
      $0.holdAction = "future"
      $0.swipeToReplyDirection = "future"
    })
    #expect(unknown == MessageGestureValues())
    for action in MessageGestureAction.allCases {
      var values = MessageGestureValues()
      values.doubleTapAction = action
      values.holdAction = action
      #expect(MessageGestureValues(values.toProtocol()) == values)
      #expect(try JSONDecoder().decode(MessageGestureValues.self, from: JSONEncoder().encode(values)) == values)
    }
  }
}
