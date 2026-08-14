import InlineKit
@testable import InlineUI
import SwiftUI
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

  #if os(macOS)
  @MainActor
  @Test("compact accessory can collapse its inactive layout slot")
  func compactAccessoryCanCollapseInactiveLayoutSlot() {
    let peer = Peer.thread(id: -9_223_372_036_854_775_000)

    let reserved = NSHostingView(rootView: HStack(spacing: 8) {
      Color.clear.frame(width: 10, height: 12)
      ComposeActionCompactAccessory(peer: peer)
    })
    let collapsed = NSHostingView(rootView: HStack(spacing: 8) {
      Color.clear.frame(width: 10, height: 12)
      ComposeActionCompactAccessory(
        peer: peer,
        reservesSpaceWhenInactive: false
      )
    })

    #expect(reserved.fittingSize == CGSize(width: 34, height: 12))
    #expect(collapsed.fittingSize == CGSize(width: 10, height: 12))
  }
  #endif
}
