import Testing

@testable import InlineKit

@Suite("Dialog Notification Preference Tests")
struct DialogNotificationPreferenceTests {
  @Test("global follows global mode")
  func globalFollowsGlobalMode() {
    #expect(DialogNotificationSettingSelection.global.resolveEffectiveMode(globalMode: .all) == .all)
    #expect(DialogNotificationSettingSelection.global.resolveEffectiveMode(globalMode: .mentions) == .mentions)
    #expect(DialogNotificationSettingSelection.global.resolveEffectiveMode(globalMode: .none) == .none)
    #expect(DialogNotificationSettingSelection.global.resolveEffectiveMode(globalMode: .importantOnly) == .importantOnly)
    #expect(DialogNotificationSettingSelection.global.resolveEffectiveMode(globalMode: .onlyMentions) == .onlyMentions)
  }

  @Test("per-dialog modes override global mode")
  func perDialogOverridesGlobalMode() {
    #expect(DialogNotificationSettingSelection.all.resolveEffectiveMode(globalMode: .none) == .all)
    #expect(DialogNotificationSettingSelection.mentions.resolveEffectiveMode(globalMode: .all) == .mentions)
    #expect(DialogNotificationSettingSelection.none.resolveEffectiveMode(globalMode: .all) == .none)
  }
}
