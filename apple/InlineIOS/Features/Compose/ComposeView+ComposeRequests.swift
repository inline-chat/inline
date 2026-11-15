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
  /// draft and never sends. Only the composer on screen for that chat takes it, or for the
  /// reply thread whose anchor asked (the anchor message belongs to the parent chat).
  private func acceptComposeRequest(_ request: MessageComposeRequests.Request) {
    guard window != nil, !isHidden, !isVoiceActive else { return }
    guard peerId == request.peer || isAnchoredOn(request) else { return }
    let current = textView.text ?? ""
    let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
    autocompleteManager?.dismissCompletion()
    textView.resetTypingAttributesToDefault()
    textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
    textView.insertText(separator + request.text)
    textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
    textView.becomeFirstResponder()
  }

  /// Whether this composer's chat is the reply thread anchored on the message that asked. One
  /// primary-key read, on a tap.
  private func isAnchoredOn(_ request: MessageComposeRequests.Request) -> Bool {
    guard let chatId, request.messageID != nil else { return false }
    let chat = try? AppDatabase.shared.dbWriter.read { db in try Chat.fetchOne(db, id: chatId) }
    return request.isAnchor(of: chat)
  }
}
