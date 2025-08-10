import Foundation
import InlineKit
import InlineProtocol

public extension FullMessage {
  var currentTranslation: Translation? {
    translation(for: UserLocale.getCurrentLanguage())
  }
  
  /// Translation text for the message, without falling back to the original text
  var translationText: String? {
    if TranslationState.shared.isTranslationEnabled(for: peerId) {
      currentTranslation?.translation
    } else {
      message.text ?? nil
    }
  }

  var translationEntities: MessageEntities? {
    if TranslationState.shared.isTranslationEnabled(for: peerId) {
      currentTranslation?.entities
    } else {
      message.entities
    }
  }

  var isTranslated: Bool {
    translationText != nil
  }

  /// Display text for the message
  /// If translation is enabled, use the current translation
  /// Otherwise, use the message text
  var displayText: String? {
    if let translationText {
      translationText
    } else {
      message.text
    }
  }
}

public extension EmbeddedMessage {
  var currentTranslation: Translation? {
    translation(for: UserLocale.getCurrentLanguage())
  }

  /// Translation text for the message, without falling back to the original text
  var translationText: String? {
    if TranslationState.shared.isTranslationEnabled(for: message.peerId) {
      currentTranslation?.translation
    } else {
      nil
    }
  }

  var isTranslated: Bool {
    translationText != nil
  }

  /// Display text for the message
  /// If translation is enabled, use the current translation
  /// Otherwise, use the message text
  var displayText: String? {
    if let translationText {
      translationText
    } else {
      message.text
    }
  }
}
