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
}
