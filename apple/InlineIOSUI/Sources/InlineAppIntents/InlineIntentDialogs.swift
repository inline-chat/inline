import AppIntents

enum InlineIntentDialogs {
  static func confirmSend(to chat: InlineIntentChat) -> IntentDialog {
    "Send this message to \(chat.title), \(chat.subtitle)?"
  }

  static func confirmSend(toPersonNamed name: String) -> IntentDialog {
    "Send this message to \(name) on Inline?"
  }

  static func confirmReply(in chat: InlineIntentChat) -> IntentDialog {
    "Send this reply in \(chat.title), \(chat.subtitle)?"
  }

  static func confirmEdit(in chat: InlineIntentChat) -> IntentDialog {
    "Replace your message in \(chat.title), \(chat.subtitle)?"
  }

  static var confirmDraft: IntentDialog {
    "Open this draft in Inline?"
  }

  static func messagePage(_ page: InlineIntentMessagePage, chatTitle: String) -> IntentDialog {
    let chatTitle = page.messages.first?.conversation.chat.title ?? chatTitle
    if page.messages.isEmpty {
      return page.nextCursor == nil
        ? "There are no matching messages in \(chatTitle)."
        : "This page has no incoming messages in \(chatTitle). More may be available."
    }
    return page.nextCursor == nil
      ? "Found \(page.messages.count) messages in \(chatTitle)."
      : "Found \(page.messages.count) messages in \(chatTitle). More may be available."
  }
}
