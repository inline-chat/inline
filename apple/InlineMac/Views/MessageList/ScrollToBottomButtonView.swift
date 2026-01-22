import SwiftUI

struct ScrollToBottomButtonView: View {
  @Environment(\.colorScheme) private var colorScheme
  var isHovered: Bool = false

  let buttonSize: CGFloat = Theme.scrollButtonSize
  var hasUnread: Bool = false
  var onClick: (() -> Void)?

  var body: some View {
    let iconColor = colorScheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.5)

    let button = Button(action: {
      onClick?()
    }) {
      Image(systemName: "chevron.down")
        .font(.system(size: 12, weight: .regular))
        .foregroundColor(iconColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: buttonSize, height: buttonSize)
    .contentShape(.interaction, Circle())
    .focusable(false)

    let content = button
      .overlay(alignment: .topTrailing) {
        if hasUnread {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .offset(x: 1, y: -1)
        }
      }

    if #available(macOS 26.0, *) {
      let hoverTint = colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
      let glass = Glass.regular
        .tint(isHovered ? hoverTint : nil)
        .interactive()
      return content
        .buttonStyle(.plain)
        .glassEffect(glass, in: .circle)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    } else {
      return content
        .buttonStyle(ScrollToBottomButtonStyle())
        .background(
          Circle()
            .fill(.ultraThinMaterial)
            .overlay(
              Circle()
                .strokeBorder(
                  (colorScheme == .dark ? Color.white : Color.black)
                    .opacity(isHovered ? 0.22 : 0.1),
                  lineWidth: 0.5
                )
            )
            .shadow(
              color: (colorScheme == .dark ? Color.white : Color.black)
                .opacity(colorScheme == .dark ? (isHovered ? 0.2 : 0.1) : (isHovered ? 0.25 : 0.15)),
              radius: isHovered ? 3 : 2,
              x: 0,
              y: -1
          )
        )
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
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
