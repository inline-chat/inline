import InlineKit
import UIKit

extension ComposeView {
  /// Listens for text a message asks to put here (`MessageComposeRequests`): compose actions and
  /// prompt suggestions.
  func setupComposeRequestObserver() {
    composeRequestObserver = MessageComposeRequests.shared.requests
      .sink { [weak self] request in
        self?.acceptComposeRequest(request)
      }
  }

  /// Adds the text after the draft, on its own line, and focuses the editor. Never replaces the
  /// draft and never sends. Only the composer on screen for that chat takes it.
  private func acceptComposeRequest(_ request: MessageComposeRequests.Request) {
    guard peerId == request.peer, window != nil, !isHidden, !isVoiceActive else { return }
    let current = textView.text ?? ""
    let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
    autocompleteManager?.dismissCompletion()
    textView.resetTypingAttributesToDefault()
    textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
    textView.insertText(separator + request.text)
    textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
    textView.becomeFirstResponder()
  }
}
