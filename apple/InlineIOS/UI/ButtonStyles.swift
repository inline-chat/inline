import SwiftUI

struct SimpleWhiteButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundColor(.black)
      .font(.body)
      .fontWeight(.semibold)
      .frame(height: 52)
      .frame(maxWidth: .infinity)
      .background(.white.opacity(0.96))
      .cornerRadius(12)
      .opacity(configuration.isPressed ? 0.8 : 1)
      .scaleEffect(configuration.isPressed ? 0.9 : 1)
      .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
  }
}

struct SimpleButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundColor(.white)
      .font(.body)
      .fontWeight(.medium)
      .frame(height: 52)
      .frame(maxWidth: .infinity)
      .background(Color(hex: "#3974F7"))
      .cornerRadius(16)
      .opacity(configuration.isPressed ? 0.8 : 1)
      .scaleEffect(configuration.isPressed ? 0.9 : 1)
      .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
  }
}

#Preview {
  Button("Text") {}
    .buttonStyle(SimpleButtonStyle())
}

extension Color {
  init(hex: String) {
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
      (a, r, g, b) = (1, 1, 1, 0)
    }

    self.init(
      .sRGB,
      red: Double(r) / 255,
      green: Double(g) / 255,
      blue: Double(b) / 255,
      opacity: Double(a) / 255
    )
  }
}
