import AppIntents
import Foundation

public enum InlineIntentError: Error, CustomLocalizedStringResourceConvertible {
  case unavailable
  case recipientUnavailable
  case appNotReady
  case locked
  case accountChanged
  case emptyMessage
  case sendNotConfirmed
  case tooManyMessages
  case tooManyConversations
  case unsupportedContent
  case ownMessagesOnly
  case draftInProgress
  case connectionUnavailable
  case operationNotConfirmed
  case outgoingReadStatusUnsupported

  public var localizedStringResource: LocalizedStringResource {
    switch self {
    case .unavailable:
      "This chat is unavailable or you no longer have access to it."
    case .recipientUnavailable:
      "This recipient is no longer available. Choose another person or check their profile in Inline."
    case .appNotReady:
      "Inline is still starting. Open Inline, then try this action again."
    case .locked:
      "Unlock your device, then try the shortcut again."
    case .accountChanged:
      "Your Inline account changed. Choose a chat for the account you are signed in to."
    case .emptyMessage:
      "Enter a message to send."
    case .sendNotConfirmed:
      "Inline couldn’t confirm whether the message was sent. Check the chat before trying again."
    case .tooManyMessages:
      "Request fewer items at a time. Inline returns at most 20 messages per page."
    case .tooManyConversations:
      "Choose messages from at most eight Inline conversations at a time."
    case .unsupportedContent:
      "This Inline action supports plain-text messaging. Open Inline for attachments, scheduled messages, or other destinations."
    case .ownMessagesOnly:
      "You can only edit or unsend your own messages."
    case .draftInProgress:
      "This conversation already has a draft. Open Inline to continue it without replacing your text."
    case .connectionUnavailable:
      "Inline couldn’t finish this request. Check your connection and try again."
    case .operationNotConfirmed:
      "Inline couldn’t confirm whether the change completed. Check the conversation before trying again."
    case .outgoingReadStatusUnsupported:
      "Inline can mark incoming messages read, but cannot change another person's read receipt."
    }
  }
}
