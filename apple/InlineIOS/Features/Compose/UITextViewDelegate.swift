import InlineKit
import Logger
import TextProcessing
import UIKit

// MARK: - UITextViewDelegate

extension ComposeView: UITextViewDelegate {
  private static let log = Log.scoped("ComposeView.UITextViewDelegate")
  func textViewDidChange(_ textView: UITextView) {
    // Prevent mention style leakage to new text
    textView.updateTypingAttributesIfNeeded()

    // Rich text processing is now only applied in message display, not in compose

    // Height Management
    UIView.animate(withDuration: 0.1) { self.updateHeight() }

    // Placeholder Visibility & Attachment Checks
    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    (textView as? ComposeTextView)?.showPlaceholder(isEmpty)
    updateSendButtonVisibility()

    if isEmpty {
      clearDraft()
      stopDraftSaveTimer()
      if let peerId {
        Task {
          await ComposeActions.shared.stoppedTyping(for: peerId)
        }
      }
    } else if !isEmpty {
      if let peerId {
        Task {
          await ComposeActions.shared.startedTyping(for: peerId)
        }
      }
      startDraftSaveTimer()
    }

    // Handle mention detection
    mentionManager?.handleTextChange(in: textView)
  }

  func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    if text.contains("￼") {
      DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
        self?.textView.textDidChange()
      }
    }

    // Check if the change might affect existing mentions or entities
    if let originalEntities = originalDraftEntities, !originalEntities.entities.isEmpty {
      // Check if the change overlaps with any existing entity ranges
      for entity in originalEntities.entities {
        let entityRange = NSRange(location: Int(entity.offset), length: Int(entity.length))
        if NSIntersectionRange(range, entityRange).length > 0 {
          // The change affects an entity, clear original entities to prevent conflicts
          originalDraftEntities = nil
          break
        }
      }
    }

    return true
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    // Reset typing attributes when cursor moves to prevent style leakage
    textView.updateTypingAttributesIfNeeded()

    // Handle mention detection on selection change
    mentionManager?.handleTextChange(in: textView)
  }

}
