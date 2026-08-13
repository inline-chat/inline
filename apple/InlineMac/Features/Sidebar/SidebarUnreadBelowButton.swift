import InlineMacUI
import SwiftUI

struct SidebarUnreadBelowButton: View {
  enum Direction: Equatable {
    case above
    case below

    var systemImage: String {
      switch self {
      case .above: "arrow.up"
      case .below: "arrow.down"
      }
    }

    var help: String {
      switch self {
      case .above: "Jump to unread chats above"
      case .below: "Jump to unread chats below"
      }
    }

    var transitionOffset: CGFloat {
      switch self {
      case .above: -12
      case .below: 12
      }
    }
  }

  static let bottomBarTopOffset: CGFloat = -38
  static func transition(for direction: Direction) -> AnyTransition {
    .modifier(
      active: SidebarUnreadBelowTransition(
        opacity: 0,
        y: direction.transitionOffset,
        scale: 0.96
      ),
      identity: SidebarUnreadBelowTransition(opacity: 1, y: 0, scale: 1)
    )
  }

  static var visibilityAnimation: Animation {
    .easeInOut(duration: 0.16)
  }

  let count: Int
  var direction: Direction = .below
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  private static let buttonSize: CGFloat = 28
  private static let badgeHeight: CGFloat = 15
  private static let badgeTopInset: CGFloat = 8

  private var countText: String {
    count > 99 ? "99+" : "\(count)"
  }

  private var iconColor: Color {
    colorScheme == .dark
      ? Color.white.opacity(0.74)
      : Color.black.opacity(0.58)
  }

  var body: some View {
    ZStack(alignment: .top) {
      button
        .padding(.top, Self.badgeTopInset)

      badge
    }
    .fixedSize()
  }

  @ViewBuilder
  private var button: some View {
    let content = Button(action: action) {
      Image(systemName: direction.systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(iconColor)
        .frame(width: Self.buttonSize, height: Self.buttonSize)
        .contentShape(.interaction, Circle())
    }
    .focusable(false)
    .help(direction.help)
    .accessibilityLabel(direction.help)
    .accessibilityValue(Text("\(count)"))

    if #available(macOS 26.0, *) {
      content
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      content
        .buttonStyle(SidebarUnreadBelowButtonStyle())
        .background(materialBackground)
    }
  }

  private var badge: some View {
    Text(countText)
      .font(.system(size: 10, weight: .bold))
      .monospacedDigit()
      .lineLimit(1)
      .minimumScaleFactor(0.72)
      .foregroundStyle(Color.white)
      .padding(.horizontal, countText.count > 1 ? 5 : 0)
      .frame(minWidth: Self.badgeHeight, minHeight: Self.badgeHeight)
      .background(Capsule().fill(Color(nsColor: Theme.prominentColor)))
      .contentTransition(.numericText())
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var materialBackground: some View {
    Circle()
      .fill(.ultraThinMaterial)
  }
}

private struct SidebarUnreadBelowTransition: ViewModifier {
  let opacity: Double
  let y: CGFloat
  let scale: CGFloat

  func body(content: Content) -> some View {
    content
      .opacity(opacity)
      .offset(y: y)
      .scaleEffect(scale)
  }
}

private struct SidebarUnreadBelowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.9 : 1)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
  }
}

#Preview {
  SidebarUnreadBelowButton(count: 12) {}
    .padding()
}
