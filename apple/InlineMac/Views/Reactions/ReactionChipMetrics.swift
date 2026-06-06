import AppKit
import InlineKit

enum ReactionChipMetrics {
  static let padding: CGFloat = 4
  static let spacing: CGFloat = 4
  static let countSpacing: CGFloat = spacing / 2
  static let countTrailingPadding: CGFloat = padding + spacing / 2
  static let height: CGFloat = 26
  static let emojiFontSize: CGFloat = 14
  static let textFontSize: CGFloat = 12
  static let countExtraWidth: CGFloat = 2
  static let avatarSize: CGFloat = 20
  static let avatarOverlap: CGFloat = 4
  static let maxAvatars: Int = 3

  static func showsAvatars(for count: Int) -> Bool {
    count > 0 && count <= maxAvatars
  }

  static func countWidth(for count: Int) -> CGFloat {
    let textFont = NSFont.systemFont(ofSize: textFontSize)
    let countWidth = "\(count)".size(withAttributes: [.font: textFont]).width
    return ceil(countWidth) + countExtraWidth
  }

  static func avatarStackWidth(for count: Int) -> CGFloat {
    let avatarCount = min(maxAvatars, count)
    guard avatarCount > 0 else { return 0 }

    return avatarSize + CGFloat(avatarCount - 1) * (avatarSize - avatarOverlap)
  }

  static func size(group: GroupedReaction) -> CGSize {
    let emojiFont = NSFont.systemFont(ofSize: emojiFontSize)
    let emojiWidth = ceil(group.emoji.size(withAttributes: [.font: emojiFont]).width)
    let count = group.reactions.count
    let showAvatars = showsAvatars(for: count)
    let accessoryWidth = showAvatars
      ? avatarStackWidth(for: count)
      : countWidth(for: count)
    let contentSpacing = showAvatars ? spacing : countSpacing
    let trailingPadding = showAvatars ? padding : countTrailingPadding
    let finalWidth = padding + emojiWidth + contentSpacing + accessoryWidth + trailingPadding
    return CGSize(width: ceil(finalWidth), height: height)
  }
}
