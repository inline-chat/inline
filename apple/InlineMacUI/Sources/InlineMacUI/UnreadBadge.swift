import SwiftUI

public enum UnreadBadgeStyle: String, CaseIterable, Hashable, Identifiable, Sendable {
  case dot
  case numbered

  public static let defaultValue: Self = .dot

  public var id: String { rawValue }
}

public struct UnreadBadge: View {
  private let unreadCount: Int
  private let hasUnreadMark: Bool
  private let prominent: Bool
  private let style: UnreadBadgeStyle
  private let dotSize: CGFloat

  public init(
    unreadCount: Int,
    hasUnreadMark: Bool = false,
    prominent: Bool,
    style: UnreadBadgeStyle,
    dotSize: CGFloat = 6
  ) {
    self.unreadCount = max(unreadCount, 0)
    self.hasUnreadMark = hasUnreadMark
    self.prominent = prominent
    self.style = style
    self.dotSize = max(dotSize, 0)
  }

  public var body: some View {
    ZStack {
      if isVisible {
        badge
          .id(badgeVariant)
          .transition(Self.badgeTransition)
      }
    }
    .animation(Self.badgeAnimation, value: isVisible)
    .animation(Self.badgeAnimation, value: unreadCount)
    .animation(Self.badgeAnimation, value: hasUnreadMark)
    .animation(Self.badgeAnimation, value: prominent)
    .animation(Self.badgeAnimation, value: style)
  }

  private var isVisible: Bool {
    unreadCount > 0 || hasUnreadMark
  }

  private var badgeVariant: BadgeVariant {
    if style == .numbered, unreadCount > 0 {
      return .numbered
    }

    return .dot
  }

  @ViewBuilder
  private var badge: some View {
    switch badgeVariant {
    case .dot:
      UnreadDotBadge(prominent: prominent, size: dotSize)
    case .numbered:
      UnreadCountBadge(count: unreadCount, prominent: prominent)
    }
  }

  private static let badgeAnimation = Animation.snappy(duration: 0.18)
  private static let badgeTransition = AnyTransition.scale(scale: 0.86).combined(with: .opacity)

  private enum BadgeVariant: Hashable {
    case dot
    case numbered
  }
}

public struct UnreadDotBadge: View {
  private let prominent: Bool
  private let size: CGFloat

  public init(prominent: Bool, size: CGFloat = 6) {
    self.prominent = prominent
    self.size = size
  }

  public var body: some View {
    Circle()
      .fill(prominent ? Color.accentColor : mutedColor)
      .overlay {
        if prominent == false {
          Circle()
            .fill(Color.primary.opacity(Self.mutedEmphasisOpacity))
        }
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }

  private var mutedColor: Color {
    .secondary
  }

  private static let mutedEmphasisOpacity = 0.1
}

public struct UnreadCountBadge: View {
  private let count: Int
  private let prominent: Bool
  private let height: CGFloat

  @Environment(\.colorScheme) private var colorScheme

  public init(count: Int, prominent: Bool, height: CGFloat = 16) {
    self.count = max(count, 0)
    self.prominent = prominent
    self.height = height
  }

  public var body: some View {
    Text(String(count))
      .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
      .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.76))
      .lineLimit(1)
      .contentTransition(.numericText())
      .padding(.horizontal, 5)
      .frame(minWidth: height)
      .frame(height: height)
      .fixedSize(horizontal: true, vertical: false)
      .background(Capsule().fill(backgroundColor))
      .accessibilityHidden(true)
  }

  private var backgroundColor: Color {
    if prominent {
      return .accentColor
    }

    if colorScheme == .dark {
      return .white.opacity(0.16)
    }

    return .black.opacity(0.09)
  }
}
