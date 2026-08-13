import Foundation
import Testing
@testable import InlineMacSidebarModel

@Suite("Sidebar preference migration")
struct SidebarPreferenceMigrationTests {
  @Test("explicit new mode wins over legacy state", arguments: [true, false])
  func explicitModeWins(storedModeIsInbox: Bool) {
    #expect(SidebarPreferenceMigration.inboxEnabled(
      storedModeIsInbox: storedModeIsInbox,
      legacyInboxEnabled: !storedModeIsInbox,
      accountCreatedAt: .distantPast
    ) == storedModeIsInbox)
  }

  @Test("legacy Inbox users remain in Inbox")
  func legacyInboxIsPreserved() {
    #expect(SidebarPreferenceMigration.inboxEnabled(
      storedModeIsInbox: nil,
      legacyInboxEnabled: true,
      accountCreatedAt: .distantPast
    ))
  }

  @Test("legacy non-Inbox users remain in All Chats")
  func legacyAllChatsIsPreserved() {
    #expect(!SidebarPreferenceMigration.inboxEnabled(
      storedModeIsInbox: nil,
      legacyInboxEnabled: false,
      accountCreatedAt: .distantFuture
    ))
  }

  @Test("an older unset account remains in All Chats")
  func olderUnsetAccountUsesAllChats() {
    #expect(!SidebarPreferenceMigration.inboxEnabled(
      storedModeIsInbox: nil,
      legacyInboxEnabled: nil,
      accountCreatedAt: SidebarPreferenceMigration.inboxDefaultAccountCutoff
        .addingTimeInterval(-1)
    ))
  }

  @Test("a new unset account starts in Inbox")
  func newUnsetAccountUsesInbox() {
    #expect(SidebarPreferenceMigration.inboxEnabled(
      storedModeIsInbox: nil,
      legacyInboxEnabled: nil,
      accountCreatedAt: SidebarPreferenceMigration.inboxDefaultAccountCutoff
    ))
  }

  @Test("an unavailable account date conservatively keeps All Chats")
  func unavailableAccountDateUsesAllChats() {
    #expect(!SidebarPreferenceMigration.inboxEnabled(
      storedModeIsInbox: nil,
      legacyInboxEnabled: nil,
      accountCreatedAt: nil
    ))
  }
}
