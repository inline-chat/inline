import InlineKit
@testable import InlineUI
import Testing

@Suite("Compose action animation inventory")
struct ComposeActionAnimationInventoryTests {
  @Test("every current compose action has a standard animation")
  func currentComposeActionsHaveAnimations() {
    #expect(ComposeActionAnimationInventory.animation(for: .typing) == .typing)
    #expect(ComposeActionAnimationInventory.animation(for: .recordingVoice) == .recordingVoice)
    #expect(ComposeActionAnimationInventory.animation(for: .uploadingPhoto) == .upload)
    #expect(ComposeActionAnimationInventory.animation(for: .uploadingDocument) == .upload)
    #expect(ComposeActionAnimationInventory.animation(for: .uploadingVideo) == .upload)
  }
}
