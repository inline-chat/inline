import Foundation
import InlineKit
import InlineProtocol

public extension FullMessage {
  var currentTranslation: Translation? {
    translation(for: UserLocale.getCurrentLanguage())
  }

  /// Translation text for the message, without falling back to the original text
  var translationText: String? {
    guard TranslationState.shared.isTranslationEnabled(for: peerId) else { return nil }
    return currentTranslation?.translation
  }

  /// Translation entities for the message, without falling back to the original entities
  var translationEntities: MessageEntities? {
    guard TranslationState.shared.isTranslationEnabled(for: peerId) else { return nil }
    guard let currentTranslation else { return nil }
    return currentTranslation.entities ?? MessageEntities()
  }

  var isTranslated: Bool {
    translationText != nil
  }

  /// Display text for the message
  /// If translation is enabled, use the current translation
  /// Otherwise, use the message text
  var displayText: String? {
    if let serviceDisplayText {
      serviceDisplayText
    } else if let translationText {
      translationText
    } else if let text = message.text {
      text
    } else if message.hasVoice {
      message.stringRepresentationPlain
    } else {
      nil
    }
  }

  var displayTextForLastMessage: String? {
    displayText?.replacingOccurrences(of: "\n", with: " ")
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
    if let serviceDisplayText {
      serviceDisplayText
    } else if let translationText {
      translationText
    } else if let text = message.text {
      text
    } else if message.hasVoice {
      message.stringRepresentationPlain
    } else {
      nil
    }
  }

  var displayTextForLastMessage: String? {
    displayText?.replacingOccurrences(of: "\n", with: " ")
  }
}
