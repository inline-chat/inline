import AppKit
import SwiftUI

struct RouteWindowAppearance {
  var windowBackground: AppWindowBackgroundAppearance
  var titlebarAppearsTransparent: Bool

  static let standard = Self(
    windowBackground: .standard,
    titlebarAppearsTransparent: false
  )

  static let transparentTitlebar = Self(
    windowBackground: .standard,
    titlebarAppearsTransparent: true
  )

  static var chat: Self {
    if #available(macOS 27.0, *) {
      return .transparentTitlebar
    }
    return .standard
  }

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
    case .chat:
      .chat
    default:
      .standard
    }
  }
}

private struct TranslucentPageWindowBackground: ViewModifier {
  @Environment(\.appearsActive) private var appearsActive
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var settings = AppSettings.shared

  func body(content: Content) -> some View {
    content
      .background {
        background
      }
  }

  @ViewBuilder
  private var background: some View {
    if #available(macOS 27.0, *) {
      windowBackground
    } else if #available(macOS 26.0, *) {
      hudBackground
    } else {
      windowBackground
    }
  }

  private var hudBackground: some View {
    ZStack {
      VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

      surfaceOverlay
        .opacity(surfaceOverlayOpacity)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  private var windowBackground: some View {
    surfaceBackground
      .ignoresSafeArea()
      .allowsHitTesting(false)
  }

  private var usesNativeSurfaces: Bool {
    settings.appTheme == .system
  }

  private var surfaceBackground: Color {
    usesNativeSurfaces ? Color(nsColor: .windowBackgroundColor) : themeBackground
  }

  private var surfaceOverlay: Color {
    if usesNativeSurfaces {
      return colorScheme == .dark ? .black : .white
    }
    return themeBackground
  }

  private var surfaceOverlayOpacity: Double {
    if usesNativeSurfaces {
      return appearsActive ? 0.7 : 0
    }
    return appearsActive ? 0.84 : 0.72
  }

  private var themeBackground: Color {
    _ = settings.themeRevision
    return Color(nsColor: Theme.windowContentBackgroundColor)
  }
}
