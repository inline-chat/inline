import InlineKit
import Logger
import UIKit

// MARK: - UITextViewDelegate

extension ComposeView: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    // Prevent mention style leakage to new text
    textView.updateTypingAttributesIfNeeded()

    // Process bold text patterns (**text**)
    processBoldTextIfNeeded(in: textView)

    // Height Management
    UIView.animate(withDuration: 0.1) { self.updateHeight() }

    // Placeholder Visibility & Attachment Checks
    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    (textView as? ComposeTextView)?.showPlaceholder(isEmpty)
    updateSendButtonVisibility()

    // Start draft save timer if there's text
    if !isEmpty {
      startDraftSaveTimer()
    } else {
      stopDraftSaveTimer()
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

    Log.shared.debug("🎨 BEFORE: text='\(originalText)', cursor=\(originalCursorPosition)")

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

      Log.shared.debug("🎨 PROCESSING: text='\(processedAttributedText.string)', new cursor=\(newCursorPosition)")

      // Update the text view
      textView.attributedText = processedAttributedText
      textView.selectedRange = NSRange(location: newCursorPosition, length: 0)

      // CRITICAL: Reset typing attributes immediately to prevent bold state from persisting
      textView.resetTypingAttributesToDefault()

      Log.shared.debug("🎨 AFTER RESET: typing attrs = \(textView.typingAttributes)")

      // Additional safety check: ensure typing attributes stay reset
      DispatchQueue.main.async { [weak self] in
        // Double-check and reset if still bold
        if textView.hasTypingAttributesBoldStyling {
          Log.shared.debug("🎨 ASYNC: Still bold! Resetting again...")
          textView.resetTypingAttributesToDefault()
        }

        // Also check cursor position relative to any bold text
        textView.updateTypingAttributesIfNeeded()

        Log.shared.debug("🎨 FINAL: typing attrs = \(textView.typingAttributes)")
      }

      Log.shared
        .debug("🎨 Processed bold text patterns - cursor moved from \(originalCursorPosition) to \(newCursorPosition)")
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

    Log.shared
      .debug(
        "🎯 Cursor calculation: original=\(originalCursor), matches=\(matches.count), removed=\(removedCharacters), new=\(newPosition)"
      )

    return newPosition
  }
}
