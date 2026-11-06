import AppKit

enum RichBlockQuoteMetrics {
  static let leadingInset: CGFloat = 8
  /// Room for the quote mark in the trailing top corner.
  static let trailingInset: CGFloat = 15
  /// Kept tight so a quote reads as part of the message, not a separate card.
  static let verticalInset: CGFloat = 3
  /// Between a quote and the block before or after it, tighter than other blocks.
  static let adjacentSpacing: CGFloat = 4
  static let cornerRadius: CGFloat = 4
  static let railWidth: CGFloat = 3
  /// Quote tint at this alpha fills the block, as in Telegram.
  static let fillAlpha: CGFloat = 0.1
  static let iconSize: CGFloat = 9
  static let iconTopInset: CGFloat = 4
  static let iconTrailingInset: CGFloat = 4
}
