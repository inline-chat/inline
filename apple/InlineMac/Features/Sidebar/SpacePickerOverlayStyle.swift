import Foundation

enum SpacePickerOverlayStyle {
  static let cornerRadius: CGFloat = 12
  static let preferredWidth: CGFloat = 240
  // Match menu/popover feel: softer + less contrast than the old panel shadow.
  static let shadowOpacity: CGFloat = 0.10
  static let shadowRadius: CGFloat = 8
  static let shadowYOffset: CGFloat = 6
  // Padding is derived from shadow metrics so we can tweak in one place.
  static let shadowInsetX: CGFloat = shadowRadius + 4
  static let shadowInsetY: CGFloat = shadowRadius + abs(shadowYOffset) + 4
}
