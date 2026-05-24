import AppKit
import SwiftUI

struct EmptyRouteView: View {
  @Environment(\.nav) private var nav

  var body: some View {
    EmptyRouteLogoButton {
      nav.openCommandBar()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .routeContentBackground(.translucentPage)
    .emptyRouteWindowDragArea()
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
  }
}

private struct EmptyRouteLogoButton: View {
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  private let size: CGFloat = 44

  var body: some View {
    Image("InlineLogoSymbol")
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .offset(y: -(size / 2)) // half the height
      .opacity(isHovered ? 0.112 : 0.07)
      .blendMode(blendMode)
      .contentShape(Rectangle())
      .onHover { hovering in
        withAnimation(.easeOut(duration: 0.3)) {
          isHovered = hovering
        }
      }
      .simultaneousGesture(WindowDragGesture())
      .onTapGesture(perform: action)
      .help("Open search")
      .accessibilityElement()
      .accessibilityLabel("Open search")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        action()
      }
  }

  private var blendMode: BlendMode {
    colorScheme == .dark ? .screen : .multiply
  }
}

private extension View {
  func emptyRouteWindowDragArea() -> some View {
    background {
      Color.clear
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
      }
  }
}
