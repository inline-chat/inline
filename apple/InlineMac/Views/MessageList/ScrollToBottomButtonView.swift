import InlineKit
import SwiftUI

/// Shared look of the floating chat buttons (scroll-to-bottom, @, ♥). They match the compose side
/// controls: a 34pt glass circle with a 15pt medium glyph, centered on the same axis.
enum ChatFloatingButtonMetrics {
  static let size: CGFloat = Theme.scrollButtonSize
  static let iconPointSize: CGFloat = 15
  /// Gap between stacked buttons, and between the bottom one and compose.
  static let spacing: CGFloat = 10
  /// Center distance from the message column's trailing edge, mirroring the avatar and compose axis.
  static let centerInset: CGFloat = ChatLayoutMetrics.leadingControlCenterX
  static let hiddenScale: CGFloat = 0.8
  static let hiddenOffset: CGFloat = 6

  static let visibility = Animation.spring(duration: 0.3, bounce: 0.15)
  static let reducedVisibility = Animation.easeInOut(duration: 0.15)
  static let count = Animation.snappy(duration: 0.2)
}

/// Count capsule on a floating button's top trailing edge.
struct ChatFloatingButtonCountBadge: View {
  let count: Int
  let tint: Color

  var body: some View {
    Text(ChatUnreadBadgeCount.format(count))
      .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
      .foregroundStyle(.white)
      .lineLimit(1)
      .contentTransition(.numericText(value: Double(count)))
      .padding(.horizontal, 4.5)
      .frame(minWidth: 17, minHeight: 17)
      .fixedSize()
      .background(Capsule().fill(tint))
      .alignmentGuide(.top) { $0.height / 2 - 2 }
      .alignmentGuide(.trailing) { $0.width / 2 + 3 }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// Glass circle, hover tint, count badge and show/hide motion shared by the floating buttons.
struct ChatFloatingButtonChrome<Label: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var isHovered: Bool
  var isVisible: Bool
  var count: Int
  var badgeTint: Color
  var onClick: (() -> Void)?
  @ViewBuilder var label: () -> Label

  private var size: CGFloat { ChatFloatingButtonMetrics.size }

  var body: some View {
    let button = Button(action: { onClick?() }) {
      label()
        .frame(width: size, height: size)
        .contentShape(.interaction, Circle())
    }
    .focusable(false)

    styled(button)
      .overlay(alignment: .topTrailing) {
        if count > 0 {
          ChatFloatingButtonCountBadge(count: count, tint: badgeTint)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
      }
      .animation(ChatFloatingButtonMetrics.count, value: count)
      .opacity(isVisible ? 1 : 0)
      .scaleEffect(isVisible || reduceMotion ? 1 : ChatFloatingButtonMetrics.hiddenScale, anchor: .bottom)
      .offset(y: isVisible || reduceMotion ? 0 : ChatFloatingButtonMetrics.hiddenOffset)
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .animation(
        reduceMotion ? ChatFloatingButtonMetrics.reducedVisibility : ChatFloatingButtonMetrics.visibility,
        value: isVisible
      )
      .allowsHitTesting(isVisible)
  }

  @ViewBuilder
  private func styled(_ button: some View) -> some View {
    let hoverTint = colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
    if #available(macOS 26.0, *) {
      button
        .buttonStyle(.plain)
        .glassEffect(Glass.regular.tint(isHovered ? hoverTint : nil).interactive(), in: .circle)
    } else {
      let edge = colorScheme == .dark ? Color.white : Color.black
      button
        .buttonStyle(ScrollToBottomButtonStyle())
        .background(
          Circle()
            .fill(.regularMaterial)
            .overlay(Circle().fill(isHovered ? hoverTint : .clear))
            .overlay(Circle().strokeBorder(edge.opacity(isHovered ? 0.18 : 0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.12), radius: 3, x: 0, y: 1)
        )
    }
  }
}

struct ScrollToBottomButtonView: View {
  var isHovered: Bool = false
  var isVisible: Bool = true
  var count = 0
  var themeRevision = 0
  var onClick: (() -> Void)?

  var body: some View {
    ChatFloatingButtonChrome(
      isHovered: isHovered,
      isVisible: isVisible,
      count: count,
      badgeTint: Color(nsColor: Theme.prominentColor),
      onClick: onClick
    ) {
      Image(systemName: "chevron.down")
        .font(.system(size: ChatFloatingButtonMetrics.iconPointSize, weight: .medium))
        .foregroundStyle(.primary)
        // The chevron's ink sits high in its box; nudge it to the optical center.
        .offset(y: 1)
    }
  }
}

struct ScrollToBottomButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.75 : 1.0)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

#Preview {
  VStack(spacing: 24) {
    ScrollToBottomButtonView()
    ScrollToBottomButtonView(count: 8)
    ScrollToBottomButtonView(count: 800)
  }
  .padding(30)
}
