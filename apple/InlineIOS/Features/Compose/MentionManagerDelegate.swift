import InlineKit
import Logger
import UIKit

// MARK: - MentionManagerDelegate

extension ComposeView: MentionManagerDelegate {
  func mentionManager(_ manager: MentionManager, didSelectMention text: String, userId: Int64, for range: NSRange) {
    // Update height if needed after mention replacement
    updateHeight()

    draftManager.invalidateLoadedEntities()
  }

  func mentionManagerDidDismiss(_ manager: MentionManager) {
    // Handle mention menu dismissal if needed
  }
}
