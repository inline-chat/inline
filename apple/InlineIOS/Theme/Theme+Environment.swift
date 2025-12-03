import SwiftUI

// MARK: - Environment Key

private struct ThemeKey: EnvironmentKey {
  static let defaultValue: AppTheme = .default
}

extension EnvironmentValues {
  var theme: AppTheme {
    get { self[ThemeKey.self] }
    set { self[ThemeKey.self] = newValue }
  }
}

// MARK: - View Modifiers

extension View {
  func themed(_ theme: AppTheme) -> some View {
    environment(\.theme, theme)
  }

  func themedFromStore() -> some View {
    environment(\.theme, ThemeStore.shared.current)
  }
}

// MARK: - Bindable Store Access

struct ThemedView<Content: View>: View {
  @Bindable var store = ThemeStore.shared
  let content: (AppTheme) -> Content

  init(@ViewBuilder content: @escaping (AppTheme) -> Content) {
    self.content = content
  }

  var body: some View {
    content(store.current)
      .environment(\.theme, store.current)
  }
}
