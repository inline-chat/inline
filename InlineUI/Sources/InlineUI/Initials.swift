import SwiftUI

public struct InitialsCircle: View {
  let firstName: String
  let lastName: String?
  let size: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  private enum ColorPalette {
    static let colors: [Color] = [
      // Vibrant Base Colors
      .init(hex: "3B82F6"),  // Bright Blue
      .init(hex: "7C3AED"),  // Bright Purple
      .init(hex: "059669"),  // Bright Emerald
      .init(hex: "E11D48"),  // Bright Rose
      .init(hex: "F97316"),  // Bright Orange

      // Rich Medium Tones
      .init(hex: "1E40AF"),  // Deep Blue
      .init(hex: "4C1D95"),  // Deep Purple
      .init(hex: "064E3B"),  // Deep Emerald
      .init(hex: "BE123C"),  // Deep Rose
      .init(hex: "C2410C"),  // Deep Orange
    ]

    static func color(for name: String) -> Color {
      // Create a stable hash by summing ASCII values
      let stableHash = name.utf8.reduce(0) { $0 + Int($1) }
      return colors[stableHash % colors.count]
    }
  }

  private var initials: String {
    [firstName, lastName]
      .compactMap(\.?.first)
      .prefix(2)
      .map(String.init)
      .joined()
      .uppercased()
  }

  private var backgroundColor: Color {
    let fullName = [firstName, lastName].compactMap { $0 }.joined()
    let baseColor = ColorPalette.color(for: fullName)
    return colorScheme == .dark
      ? baseColor.adjustBrightness(by: 0.25)  // Make colors brighter in dark mode
      : baseColor
  }

  private var foregroundColor: Color {
    colorScheme == .dark ? .white : backgroundColor
  }

  private var backgroundGradient: LinearGradient {
    LinearGradient(
      colors: [
        backgroundColor.opacity(colorScheme == .dark ? 0.8 : 0.1),
        backgroundColor.opacity(colorScheme == .dark ? 1.0 : 0.3),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  public init(firstName: String, lastName: String? = nil, size: CGFloat = 32) {
    self.firstName = firstName
    self.lastName = lastName
    self.size = size
  }

  public var body: some View {
    Circle()
      .fill(backgroundGradient)
      .overlay(
        Text(initials)
          .foregroundColor(foregroundColor.opacity(0.8))
          .font(.system(size: size * 0.5, weight: .medium))
          .minimumScaleFactor(0.5)
          .lineLimit(1)
      )
      .frame(width: size, height: size)
      .drawingGroup()
  }
}

// MARK: - Color Extensions

extension Color {
  fileprivate init(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let a: UInt64
    let r: UInt64
    let g: UInt64
    let b: UInt64
    switch hex.count {
    case 3:  // RGB (12-bit)
      (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
    case 6:  // RGB (24-bit)
      (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
    case 8:  // ARGB (32-bit)
      (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
    default:
      (a, r, g, b) = (255, 0, 0, 0)
    }
    self.init(
      .sRGB,
      red: Double(r) / 255,
      green: Double(g) / 255,
      blue: Double(b) / 255,
      opacity: Double(a) / 255
    )
  }

  fileprivate func adjustBrightness(by amount: Double) -> Color {
    #if os(iOS)
      guard let components = UIColor(self).cgColor.components,
        components.count >= 3
      else { return self }

      let r = components[0]
      let g = components[1]
      let b = components[2]
      let alpha = components.count >= 4 ? components[3] : 1.0

      return Color(
        .sRGB,
        red: min(r + amount, 1.0),
        green: min(g + amount, 1.0),
        blue: min(b + amount, 1.0),
        opacity: alpha
      )
    #else
      guard let components = NSColor(self).cgColor.components,
        components.count >= 3
      else { return self }

      let r = components[0]
      let g = components[1]
      let b = components[2]
      let alpha = components.count >= 4 ? components[3] : 1.0

      return Color(
        .sRGB,
        red: min(r + amount, 1.0),
        green: min(g + amount, 1.0),
        blue: min(b + amount, 1.0),
        opacity: alpha
      )
    #endif
  }
}

#Preview("InitialsCircle Grid") {
  ScrollView {
    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 20) {
      Group {
        // Original names
        InitialsCircle(firstName: "John", lastName: "Doe", size: 60)
        InitialsCircle(firstName: "Alice", lastName: "Smith", size: 60)
        InitialsCircle(firstName: "Bob", lastName: "Johnson", size: 60)
        InitialsCircle(firstName: "Emma", lastName: "Davis", size: 60)
        InitialsCircle(firstName: "Michael", lastName: "Brown", size: 60)
        InitialsCircle(firstName: "Sarah", lastName: "Wilson", size: 60)
        InitialsCircle(firstName: "David", lastName: "Miller", size: 60)
        InitialsCircle(firstName: "Lisa", lastName: "Anderson", size: 60)

        // Tech Industry Names
        InitialsCircle(firstName: "Sam", lastName: "Altman", size: 60)
        InitialsCircle(firstName: "Elon", lastName: "Musk", size: 60)
        InitialsCircle(firstName: "Tim", lastName: "Cook", size: 60)
        InitialsCircle(firstName: "Sundar", lastName: "Pichai", size: 60)

        // International Names
        InitialsCircle(firstName: "Yuki", lastName: "Tanaka", size: 60)
        InitialsCircle(firstName: "Wei", lastName: "Chen", size: 60)
        InitialsCircle(firstName: "Sofia", lastName: "Martinez", size: 60)
        InitialsCircle(firstName: "Ahmed", lastName: "Hassan", size: 60)
      }
      .frame(height: 60)
    }
    .padding()
  }
}
