import InlineKit
import SwiftUI

public enum SpaceAvatarContent {
  public static func text(for space: Space) -> String {
    if let leadingEmoji = leadingEmoji(for: space) {
      return leadingEmoji
    }

    let trimmed = space.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.first.map { String($0).uppercased() } ?? "·"
  }

  public static func fontScale(for text: String) -> CGFloat {
    text.isAllEmojis ? 0.6 : 0.55
  }

  private static func leadingEmoji(for space: Space) -> String? {
    let rawName = space.name
    let nameWithoutEmoji = space.nameWithoutEmoji
    guard rawName != nameWithoutEmoji else { return nil }
    let emojiPart = nameWithoutEmoji.isEmpty
      ? rawName
      : String(rawName.dropLast(nameWithoutEmoji.count))
    let trimmed = emojiPart.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public struct MonochromeSpaceAvatar: View {
  let space: Space
  let size: CGFloat

  public init(space: Space, size: CGFloat = 32) {
    self.space = space
    self.size = size
  }

  public var body: some View {
    SpaceAvatar(space: space, size: size)
  }
}

private extension String {
  var isAllEmojis: Bool {
    !isEmpty && allSatisfy(\.isEmoji)
  }
}

private extension Character {
  var isEmoji: Bool {
    guard let scalar = unicodeScalars.first else { return false }
    return scalar.properties.isEmoji && (scalar.value > 0x238C || unicodeScalars.count > 1)
  }
}
