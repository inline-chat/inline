import SwiftUI

@MainActor
public enum AvatarColorUtility {
  public static let colors: [Color] = [
    .pink.adjustLuminosity(by: -0.1),
    .orange,
    .purple,
    .yellow.adjustLuminosity(by: -0.1),
    .teal,
    .blue,
    .teal,
    .green,
//    .primary,
    .red,
    .indigo,
    .mint,
    .cyan,
  ]

  public static func formatNameForHashing(firstName: String?, lastName: String?, email: String?) -> String {
    let formattedFirstName = firstName ?? email?.components(separatedBy: "@").first ?? "User"
    let name = "\(formattedFirstName)\(lastName != nil ? " \(lastName!)" : "")"
    return name
  }

  static func paletteIndex(for name: String, paletteCount: Int) -> Int {
    let hash = name.utf8.reduce(0) { $0 + Int($1) }
    return abs(hash) % paletteCount
  }

  public static func colorFor(name: String) -> Color {
    colors[paletteIndex(for: name, paletteCount: colors.count)]
  }

  #if os(iOS)
  public static func uiColorFor(name: String) -> UIColor {
    UIColor(colorFor(name: name))
  }
  #endif
}
