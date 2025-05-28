import SwiftUI

struct CircleButtonStyle: ButtonStyle {
  let size: CGFloat
  let backgroundColor: Color
  let hoveredBackground: Color

  @State private var isHovering = false

  init(
    size: CGFloat = 32,
    backgroundColor: Color = .blue,
    hoveredBackgroundColor: Color = .blue.opacity(0.8)
  ) {
    self.size = size
    self.backgroundColor = backgroundColor
    hoveredBackground = hoveredBackgroundColor
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(5)
      .frame(width: size, height: size)
      .background(
        Circle()
          .fill(isHovering ? hoveredBackground : backgroundColor)
      )
      .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
      .onHover { hovering in
        withAnimation(.easeInOut(duration: 0.2)) {
          isHovering = hovering
        }
      }
  }
}
