import SwiftUI

public enum AvatarColorUtility {
  @MainActor
  public static let colors: [Color] = [
    .pink.adjustLuminosity(by: -0.1),
    .orange,
    .purple,
    .yellow.adjustLuminosity(by: -0.1),
    .teal,
    .blue,
    .teal,
    .green,
    .primary,
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

  @MainActor
  public static func colorFor(name: String) -> Color {
    let hash = name.utf8.reduce(0) { $0 + Int($1) }
    return colors[abs(hash) % colors.count]
  }

  #if os(iOS)
  public static func uiColorFor(name: String) async -> UIColor {
    await MainActor.run {
      UIColor(colorFor(name: name))
    }
  }
  #endif
}
