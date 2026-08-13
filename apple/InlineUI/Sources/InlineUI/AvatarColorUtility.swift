import InlineAvatarCore
import SwiftUI

@MainActor
public enum AvatarColorUtility {
  public static let colors = InlineAvatarStyle.palette.map(Color.init(avatarColor:))

  public static func formatNameForHashing(firstName: String?, lastName: String?, email: String?) -> String {
    InlineAvatarPresentation.nameSeed(firstName: firstName, lastName: lastName, email: email)
  }

  static func paletteIndex(for name: String, paletteCount: Int) -> Int {
    InlineAvatarStyle.paletteIndex(for: name, paletteCount: paletteCount)
  }

  public static func colorFor(name: String) -> Color {
    let index = InlineAvatarStyle.paletteIndex(for: name)
    return Color(avatarColor: InlineAvatarStyle.palette[index])
  }

  #if os(iOS)
  public static func uiColorFor(name: String) -> UIColor {
    UIColor(colorFor(name: name))
  }
  #endif
}

extension Color {
  init(avatarColor: InlineAvatarColor) {
    self.init(
      .sRGB,
      red: avatarColor.red,
      green: avatarColor.green,
      blue: avatarColor.blue,
      opacity: avatarColor.alpha
    )
  }
}
