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

    // processBoldTextIfNeeded(in: textView)

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

  // MARK: - Bold Text Processing

  private func processBoldTextIfNeeded(in textView: UITextView) {
    guard let attributedText = textView.attributedText else { return }

    let originalText = attributedText.string
    let originalCursorPosition = textView.selectedRange.location

    // Process **bold** patterns - for now keep existing logic until we have bold pattern processing in ProcessEntities
    let processedAttributedText = AttributedStringHelpers.processBoldText(in: attributedText)

    // Only update if processing changed the text
    if !processedAttributedText.isEqual(to: attributedText) {
      let selectedRange = textView.selectedRange

      // Calculate new cursor position after processing
      let newCursorPosition = calculateNewCursorPosition(
        originalText: originalText,
        processedText: processedAttributedText.string,
        originalCursor: selectedRange.location
      )

      // Update the text view
      textView.attributedText = processedAttributedText
      textView.selectedRange = NSRange(location: newCursorPosition, length: 0)

      // Reset text view state after bold pattern processing
      resetTextViewState()
    }
  }

  private func calculateNewCursorPosition(originalText: String, processedText: String, originalCursor: Int) -> Int {
    // For **text** -> text transformation, cursor position needs adjustment
    // Count how many complete ** pairs were processed before the cursor position

    let textBeforeCursor = String(originalText.prefix(originalCursor))

    // Find all ** patterns that were completed before the cursor
    let pattern = #"\*\*([^*]+?)\*\*"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return originalCursor
    }

    let matches = regex.matches(
      in: textBeforeCursor,
      options: [],
      range: NSRange(location: 0, length: textBeforeCursor.count)
    )

    // Each complete ** pattern removes 4 characters (** at start and end)
    let removedCharacters = matches.count * 4

    let newPosition = max(0, originalCursor - removedCharacters)

    Self.log.trace(
      "Cursor calculation: original=\(originalCursor), matches=\(matches.count), removed=\(removedCharacters), new=\(newPosition)"
    )

    return newPosition
  }
}
