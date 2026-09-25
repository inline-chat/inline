import UIKit

/// Chat fonts retain their default sizes while following the user's Dynamic Type setting.
enum ChatTypography {
  static func font(
    _ size: CGFloat,
    weight: UIFont.Weight = .regular,
    style: UIFont.TextStyle = .body,
    compatibleWith traits: UITraitCollection? = nil
  ) -> UIFont {
    UIFontMetrics(forTextStyle: style).scaledFont(
      for: .systemFont(ofSize: size, weight: weight),
      compatibleWith: traits
    )
  }

  static func codeLanguageFont(baseFontSize: CGFloat) -> UIFont {
    .systemFont(ofSize: baseFontSize * 10 / 17, weight: .medium)
  }

  static func codeHeaderHeight(baseFontSize: CGFloat) -> CGFloat {
    max(21, ceil(codeLanguageFont(baseFontSize: baseFontSize).lineHeight) + 7)
  }
}
