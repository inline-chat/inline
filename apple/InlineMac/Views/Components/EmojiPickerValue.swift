import Foundation
import InlineKit

enum EmojiPickerValue {
  static func normalizedEmoji(from text: String) -> String? {
    let placeholder = "\u{FFFC}"
    let cleaned = text
      .replacingOccurrences(of: placeholder, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let emoji = cleaned.first(where: \.isEmoji) else { return nil }
    return String(emoji)
  }
}
