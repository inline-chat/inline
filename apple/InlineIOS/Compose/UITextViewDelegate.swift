import InlineKit
import Logger
import UIKit

// MARK: - UITextViewDelegate

extension ComposeView: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    // Prevent mention style leakage to new text
    textView.updateTypingAttributesIfNeeded()

    // Height Management
    UIView.animate(withDuration: 0.1) { self.updateHeight() }

    // Placeholder Visibility & Attachment Checks
    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    (textView as? ComposeTextView)?.showPlaceholder(isEmpty)
    // (textView as? ComposeTextView)?.checkForNewAttachments()

    // Handle mention detection
    mentionManager?.handleTextChange(in: textView)

    if isEmpty {
      clearDraft()
      stopDraftSaveTimer()
      buttonDisappear()
      if let peerId {
        Task {
          await ComposeActions.shared.stoppedTyping(for: peerId)
        }
      }
    } else {
      startDraftSaveTimer()
      if let peerId {
        Task {
          await ComposeActions.shared.startedTyping(for: peerId)
        }
      }
      buttonAppear()
    }
  }

  func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    if text.contains("￼") {
      DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
        self?.textView.textDidChange()
      }
    }

    // Check if the change might affect existing mentions
    if let originalEntities = originalDraftEntities, !originalEntities.entities.isEmpty {
      // Check if the change overlaps with any existing mention ranges
      for entity in originalEntities.entities {
        let entityRange = NSRange(location: Int(entity.offset), length: Int(entity.length))
        if NSIntersectionRange(range, entityRange).length > 0 {
          // The change affects a mention, clear original entities
          originalDraftEntities = nil
          break
        }
      }
    }

    return true
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    // Reset typing attributes when cursor moves to prevent mention style leakage
    textView.updateTypingAttributesIfNeeded()
  }
}
