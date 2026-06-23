import SwiftUI

struct MainContentView: View {
  @Environment(\.nav) private var nav

  var body: some View {
    RouteView(route: nav.currentRoute)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentScrollEdgeEffect()
  }
}

private extension View {
  @ViewBuilder
  func contentScrollEdgeEffect() -> some View {
    if #available(macOS 27.0, *) {
      // Disabled on macOS 27 while investigating AppKit/SwiftUI stack overflows on app open.
      self
    } else if #available(macOS 26.0, *) {
      scrollEdgeEffectStyle(.soft, for: .all)
    } else {
      self
    }
  }
}

#Preview {
  MainContentView()
    .environment(\.nav, {
      let nav = Nav3()
      nav.open(.chat(peer: .thread(id: 1)))
      return nav
    }())
    .appDatabase(.populated())
    .environment(dependencies: AppDependencies())
}
