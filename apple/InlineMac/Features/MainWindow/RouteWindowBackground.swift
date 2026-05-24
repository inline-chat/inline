import SwiftUI

struct RouteWindowAppearance {
  var windowBackground: AppWindowBackgroundAppearance
  var titlebarAppearsTransparent: Bool

  static let standard = Self(
    windowBackground: .standard,
    titlebarAppearsTransparent: false
  )

  static let emptyPage = Self(
    windowBackground: .clear,
    titlebarAppearsTransparent: true
  )
}

enum RouteContentBackgroundStyle: Equatable {
  case standard
  case translucentPage
}

extension View {
  @ViewBuilder
  func routeContentBackground(_ style: RouteContentBackgroundStyle) -> some View {
    switch style {
    case .standard:
      self

    case .translucentPage:
      modifier(TranslucentPageWindowBackground())
    }
  }
}

extension Nav3Route {
  var routeWindowAppearance: RouteWindowAppearance {
    switch self {
    case .empty:
      .emptyPage
    default:
      .standard
    }
  }
}

private struct TranslucentPageWindowBackground: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.appearsActive) private var appearsActive

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

          windowOverlayColor
            .opacity(appearsActive ? 0.7 : 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
      }
  }

  private var windowOverlayColor: Color {
    colorScheme == .dark ? Color.black : Color.white
  }
}
