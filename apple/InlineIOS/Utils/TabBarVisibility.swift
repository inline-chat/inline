import SwiftUI

@available(iOS 17.0, *)
private struct InlineHideTabBarPreferenceKey: EnvironmentKey {
  static let defaultValue: Bool = true
}

@available(iOS 17.0, *)
extension EnvironmentValues {
  /// Whether views should explicitly hide the system tab bar via `.toolbar(.hidden, for: .tabBar)`.
  /// Default is `true` to preserve legacy behavior; experimental UI can disable it.
  var inlineHideTabBar: Bool {
    get { self[InlineHideTabBarPreferenceKey.self] }
    set { self[InlineHideTabBarPreferenceKey.self] = newValue }
  }
}

@available(iOS 17.0, *)
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

@available(iOS 17.0, *)
extension View {
  func hideTabBarIfNeeded(_ isEnabled: Bool = true) -> some View {
    modifier(HideTabBarIfNeededModifier(isEnabled: isEnabled))
  }
}
