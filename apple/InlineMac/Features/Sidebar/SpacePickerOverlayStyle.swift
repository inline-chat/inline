import Foundation

enum SpacePickerOverlayStyle {
  static let shadowOpacity: CGFloat = 0.2
  static let shadowRadius: CGFloat = 6
  static let shadowYOffset: CGFloat = 4
  // Padding is derived from shadow metrics so we can tweak in one place.
  static let shadowInsetX: CGFloat = shadowRadius + 4
  static let shadowInsetY: CGFloat = shadowRadius + abs(shadowYOffset) + 4
}
