import SwiftUI

extension View {
  func windowTitlebarAppearsTransparent(_ appearsTransparent: Bool = true) -> some View {
    modifier(WindowTitlebarAppearanceModifier(appearsTransparent: appearsTransparent))
  }
}

private struct WindowTitlebarAppearanceModifier: ViewModifier {
  let appearsTransparent: Bool

  @Environment(\.appBridge) private var appBridge

  func body(content: Content) -> some View {
    content
      .onAppear(perform: apply)
      .onChange(of: appearsTransparent) { _, _ in
        apply()
      }
  }

  private func apply() {
    appBridge?.setWindowTitlebarAppearsTransparent(appearsTransparent)
  }
}
