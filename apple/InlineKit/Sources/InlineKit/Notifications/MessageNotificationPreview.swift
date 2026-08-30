import Foundation
import InlineProtocol

/// Notification-only projection; chat bubbles and history retain their original text.
/// Keep the content contract aligned with server/modules/notifications/messagePreview.ts.
public enum MessageNotificationPreview {
  public static func singleLine(_ text: String, maxBytes: Int = 256) -> String {
    preview(normalizedSingleLine(text), maxBytes: maxBytes)
  }

  public static func body(for message: InlineProtocol.Message) -> String {
    if message.hasServiceMessage, let text = message.serviceMessage.fallbackText {
      return preview(text)
    }

    let text = normalizedBody(message.hasMessage ? message.message : "")
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
      let fileName = singleLine(media.document.fileName, maxBytes: 240)
      fallback = fileName.isEmpty ? "Document" : fileName
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
      return preview((message.isSticker ? "🖼️ " : prefix) + text)
    }
    if message.isSticker { return "🖼️ Sticker" }
    return preview(prefix + fallback)
  }

  static func preview(_ text: String, maxBytes: Int = 960) -> String {
    guard maxBytes >= "…".utf8.count else { return "" }
    let text = normalizedBody(text)
    var result = ""
    var byteCount = 0
    var characterCount = 0
    for character in text {
      let bytes = String(character).utf8.count
      guard characterCount < 240, byteCount + bytes <= maxBytes else {
        while result.utf8.count > maxBytes - "…".utf8.count {
          result.removeLast()
        }
        while let scalar = result.unicodeScalars.last,
              isInlineWhitespace(scalar) || isNotificationNewline(scalar) {
          result.unicodeScalars.removeLast()
        }
        return result + "…"
      }
      result.append(character)
      byteCount += bytes
      characterCount += 1
    }
    return result
  }

  private static func normalizedSingleLine(_ text: String) -> String {
    canonicalNewlines(text)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { normalizedLine(String($0)) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func normalizedBody(_ text: String) -> String {
    let lines = canonicalNewlines(text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { normalizedLine(String($0)) }
    guard let firstContent = lines.firstIndex(where: { !$0.isEmpty }),
          let lastContent = lines.lastIndex(where: { !$0.isEmpty })
    else {
      return ""
    }

    var result: [String] = []
    for line in lines[firstContent ... lastContent] {
      if line.isEmpty, result.last?.isEmpty == true { continue }
      result.append(line)
    }
    return result.joined(separator: "\n")
  }

  private static func canonicalNewlines(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\u{0085}", with: "\n")
      .replacingOccurrences(of: "\u{2028}", with: "\n")
      .replacingOccurrences(of: "\u{2029}", with: "\n")
  }

  private static func normalizedLine(_ line: String) -> String {
    var scalars = String.UnicodeScalarView()
    var pendingSpace = false

    for scalar in line.unicodeScalars {
      if isInlineWhitespace(scalar) {
        pendingSpace = !scalars.isEmpty
      } else {
        if pendingSpace { scalars.append(" ") }
        scalars.append(scalar)
        pendingSpace = false
      }
    }
    return String(scalars)
  }

  private static func isNotificationNewline(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x000A, 0x000D, 0x0085, 0x2028, 0x2029:
      true
    default:
      false
    }
  }

  private static func isInlineWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0009, 0x000B, 0x000C, 0x0020, 0x00A0, 0x1680,
         0x2000 ... 0x200A, 0x202F, 0x205F, 0x3000, 0xFEFF:
      true
    default:
      false
    }
  }
}
