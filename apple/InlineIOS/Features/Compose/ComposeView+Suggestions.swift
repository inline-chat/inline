import InlineKit
import UIKit

extension ComposeView {
  /// Shows the bot's suggested next message (`ComposeSuggestions`) as the placeholder. Tapping it,
  /// or Tab on a hardware keyboard, puts it in the editor to edit and send.
  func setupSuggestionObserver() {
    suggestionObserver = ComposeSuggestions.shared.changes
      .sink { [weak self] peer in
        guard let self, peer == peerId else { return }
        refreshSuggestion()
      }
  }

  func refreshSuggestion() {
    let isEditing = peerId.map { ChatState.shared.getState(peer: $0).editingMessageId != nil } ?? true
    textView.suggestionText = isEditing ? nil : peerId.flatMap { ComposeSuggestions.shared.suggestion(for: $0)?.text }
  }

  /// Typing ends the suggestion.
  func suggestionTextDidChange(isEmpty: Bool) {
    guard !isEmpty, textView.suggestionText != nil, let peerId else { return }
    ComposeSuggestions.shared.dismiss(peer: peerId)
  }

  /// Puts the suggestion in the empty editor. Never sends.
  @discardableResult
  func acceptSuggestion() -> Bool {
    guard let peerId, let text = textView.suggestionText, (textView.text ?? "").isEmpty, !isVoiceActive else {
      return false
    }
    ComposeSuggestions.shared.dismiss(peer: peerId)
    autocompleteManager?.dismissCompletion()
    textView.resetTypingAttributesToDefault()
    textView.insertText(text)
    textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
    textView.becomeFirstResponder()
    return true
  }
}
