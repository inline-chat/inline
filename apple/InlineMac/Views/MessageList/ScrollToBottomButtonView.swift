import SwiftUI

struct ScrollToBottomButtonView: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false
  @State private var isPressed = false

  let buttonSize: CGFloat = Theme.scrollButtonSize
  var onClick: (() -> Void)?

  var body: some View {
    Button(action: {
      onClick?()
    }) {
      Image(systemName: "chevron.down")
        .font(.system(size: 12, weight: .regular))
        .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.5))
        .frame(width: buttonSize, height: buttonSize)
        .contentShape(.interaction, Circle())
    }
    .buttonStyle(ScrollToBottomButtonStyle())
    .focusable(false)
    .background(
      Circle()
        .fill(.ultraThinMaterial)
        .overlay(
          Circle()
            .strokeBorder(
              (colorScheme == .dark ? Color.white : Color.black).opacity(0.1),
              lineWidth: 0.5
            )
        )
        .shadow(
          color: (colorScheme == .dark ? Color.white : Color.black)
            .opacity(colorScheme == .dark ? 0.1 : 0.15),
          radius: 2,
          x: 0,
          y: -1
        )
    )
  }
}

struct ScrollToBottomButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.9 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}

#Preview {
  ScrollToBottomButtonView()
    .padding()
}
