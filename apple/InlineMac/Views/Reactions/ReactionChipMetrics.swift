import AppKit
import InlineKit

enum ReactionChipMetrics {
  static let padding: CGFloat = 6
  static let spacing: CGFloat = 4
  static let height: CGFloat = 28
  static let emojiFontSize: CGFloat = 14
  static let textFontSize: CGFloat = 12
  static let avatarSize: CGFloat = 20
  static let avatarOverlap: CGFloat = 4
  static let maxAvatars: Int = 3

  static func size(group: GroupedReaction) -> CGSize {
    let emojiFont = NSFont.systemFont(ofSize: emojiFontSize)
    let textFont = NSFont.systemFont(ofSize: textFontSize)

    let emojiWidth = group.emoji.size(withAttributes: [.font: emojiFont]).width

    let countWidth = "\(group.reactions.count)".size(withAttributes: [.font: textFont]).width
    let widthCount = emojiWidth + countWidth + spacing + padding * 2

    let avatarCount = min(maxAvatars, group.reactions.count)
    let avatarsWidth = avatarCount > 0
      ? avatarSize + CGFloat(avatarCount - 1) * (avatarSize - avatarOverlap)
      : 0
    let widthAvatar = emojiWidth + spacing + avatarsWidth + padding * 2

    let finalWidth = max(widthCount, widthAvatar)
    return CGSize(width: ceil(finalWidth), height: height)
  }
}
