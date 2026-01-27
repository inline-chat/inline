import SwiftUI

struct ToolbarButtonStyle: SwiftUI.ButtonStyle {
  func makeBody(configuration: SwiftUI.ButtonStyleConfiguration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .semibold))
      .imageScale(.medium)
      .foregroundStyle(.secondary)
      .frame(width: 28, height: 28)
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}
