import Foundation
import InlineProtocol

/// Notification-only projection; chat bubbles and history retain their original text.
/// Keep the content contract aligned with server/modules/notifications/messagePreview.ts.
public enum MessageNotificationPreview {
  public static func body(for message: InlineProtocol.Message) -> String {
    if message.hasServiceMessage, let text = message.serviceMessage.fallbackText {
      return preview(text)
    }

    let text = normalized(message.hasMessage ? message.message : "")
    let prefix: String
    let fallback: String
    switch message.media.media {
    case .nudge:
      return text == "🚨" ? "🚨 Urgent nudge" : "👋 Nudge"
    case .photo:
      prefix = "🖼️ "
      fallback = "Photo"
    case let .video(media):
      prefix = media.video.isAnimated ? "🎞️ " : "🎥 "
      fallback = media.video.isAnimated ? "GIF" : "Video"
    case let .document(media):
      prefix = "📄 "
      let fileName = normalized(media.document.fileName)
      fallback = fileName.isEmpty ? "Document" : preview(fileName, maxBytes: 240)
    case let .voice(media):
      prefix = "🎤 "
      let seconds = media.voice.duration
      fallback = seconds > 0
        ? "Voice message (\(seconds / 60):\(String(format: "%02d", seconds % 60)))"
        : "Voice message"
    case nil:
      prefix = ""
      fallback = "New message"
    }
    if !text.isEmpty {
      return (message.isSticker ? "🖼️ " : prefix) + preview(text)
    }
    if message.isSticker { return "🖼️ Sticker" }
    return prefix + fallback
  }

  static func preview(_ text: String, maxBytes: Int = 960) -> String {
    let text = normalized(text)
    var result = ""
    var byteCount = 0
    var characterCount = 0
    for character in text {
      let bytes = String(character).utf8.count
      guard characterCount < 240, byteCount + bytes <= maxBytes else {
        while result.utf8.count > maxBytes - "…".utf8.count {
          result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
      }
      result.append(character)
      byteCount += bytes
      characterCount += 1
    }
    return result
  }

  private static func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
