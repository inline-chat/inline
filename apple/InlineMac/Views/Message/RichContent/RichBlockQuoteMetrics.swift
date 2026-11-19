import AppKit

/// Quote geometry. Insets come from the chat spacing scale at the message's base
/// font size; the leading inset matches code blocks' padding so quoted and code
/// text start at the same x.
struct RichBlockQuoteMetrics {
  let leadingInset: CGFloat
  /// Room for the quote mark in the trailing top corner.
  let trailingInset: CGFloat
  let verticalInset: CGFloat

  init(baseFontSize: CGFloat) {
    leadingInset = ChatTypography.space(.quoteLeadingInset, at: baseFontSize)
    trailingInset = ChatTypography.space(.quoteTrailingInset, at: baseFontSize)
    verticalInset = ChatTypography.space(.quoteVerticalInset, at: baseFontSize)
  }

  /// Same as code blocks, so the two read as one family of cards.
  static let cornerRadius: CGFloat = 8
  static let railWidth: CGFloat = 2.5
  /// Quote tint at this alpha fills the block, as in Telegram.
  static let fillAlpha: CGFloat = 0.08
  static let iconSize: CGFloat = 9
  static let iconTopInset: CGFloat = 4
  static let iconTrailingInset: CGFloat = 4
}
