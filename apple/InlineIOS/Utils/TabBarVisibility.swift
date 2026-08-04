import SwiftUI

private struct InlineHideTabBarPreferenceKey: EnvironmentKey {
  static let defaultValue: Bool = true
}

extension EnvironmentValues {
  /// Whether views should explicitly hide the system tab bar via `.toolbar(.hidden, for: .tabBar)`.
  /// Default is `true` to preserve legacy behavior; experimental UI can disable it.
  var inlineHideTabBar: Bool {
    get { self[InlineHideTabBarPreferenceKey.self] }
    set { self[InlineHideTabBarPreferenceKey.self] = newValue }
  }
}

private struct HideTabBarIfNeededModifier: ViewModifier {
  @Environment(\.inlineHideTabBar) private var inlineHideTabBar
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled, inlineHideTabBar {
      content.toolbar(.hidden, for: .tabBar)
    } else {
      content
    }
  }
}

extension View {
  func hideTabBarIfNeeded(_ isEnabled: Bool = true) -> some View {
    modifier(HideTabBarIfNeededModifier(isEnabled: isEnabled))
  }
}
