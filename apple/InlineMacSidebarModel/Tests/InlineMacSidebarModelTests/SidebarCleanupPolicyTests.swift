import Foundation
import Testing
@testable import InlineMacSidebarModel

@Suite("Sidebar cleanup policy")
struct SidebarCleanupPolicyTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("Manual cleanup requires both quiet periods")
  func manualQuietPeriods() {
    let policy = SidebarCleanupPolicy.manual

    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-6 * 60 * 60),
      lastActivityAt: now.addingTimeInterval(-3 * 60 * 60),
      latestOwnMessageAt: nil,
      isEmptyUntitled: false
    ))
    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-(6 * 60 * 60 - 1)),
      lastActivityAt: now.addingTimeInterval(-4 * 60 * 60),
      latestOwnMessageAt: nil,
      isEmptyUntitled: false
    ) == false)
    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-7 * 60 * 60),
      lastActivityAt: now.addingTimeInterval(-(3 * 60 * 60 - 1)),
      latestOwnMessageAt: nil,
      isEmptyUntitled: false
    ) == false)
  }

  @Test("Manual cleanup falls back to opened date without messages")
  func manualNoActivityFallback() {
    #expect(SidebarCleanupPolicy.manual.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-6 * 60 * 60),
      lastActivityAt: nil,
      latestOwnMessageAt: nil,
      isEmptyUntitled: false
    ))
  }

  @Test("Empty untitled threads are immediately eligible")
  func emptyUntitledThread() {
    #expect(SidebarCleanupPolicy.manual.shouldClose(
      now: now,
      openedAt: now,
      lastActivityAt: nil,
      latestOwnMessageAt: nil,
      isEmptyUntitled: true
    ))
  }

  @Test("Automatic cleanup preserves its opened-or-sent timeout")
  func automaticTimeout() {
    let policy = SidebarCleanupPolicy.automatic(timeout: 12 * 60 * 60)

    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-13 * 60 * 60),
      lastActivityAt: now,
      latestOwnMessageAt: now.addingTimeInterval(-12 * 60 * 60),
      isEmptyUntitled: false
    ))
    #expect(policy.shouldClose(
      now: now,
      openedAt: now.addingTimeInterval(-13 * 60 * 60),
      lastActivityAt: nil,
      latestOwnMessageAt: now.addingTimeInterval(-60 * 60),
      isEmptyUntitled: false
    ) == false)
  }
}
