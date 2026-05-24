import AppKit
import SwiftUI

extension View {
  func registerMainWindow(
    id: UUID,
    toastPresenter: (any ToastPresenting)?,
    route: @escaping @MainActor (MainWindowDestination) -> Void,
    openCommandBar: @escaping @MainActor () -> Void,
    toggleCommandBar: @escaping @MainActor () -> Void,
    toggleSidebar: @escaping @MainActor () -> Void,
    goBack: @escaping @MainActor () -> Void,
    goForward: @escaping @MainActor () -> Void,
    canGoBack: @escaping @MainActor () -> Bool,
    canGoForward: @escaping @MainActor () -> Bool
  ) -> some View {
    modifier(MainWindowRegistrationModifier(
      id: id,
      toastPresenter: toastPresenter,
      route: route,
      openCommandBar: openCommandBar,
      toggleCommandBar: toggleCommandBar,
      toggleSidebar: toggleSidebar,
      goBack: goBack,
      goForward: goForward,
      canGoBack: canGoBack,
      canGoForward: canGoForward
    ))
  }
}

private struct MainWindowRegistrationModifier: ViewModifier {
  let id: UUID
  let toastPresenter: (any ToastPresenting)?
  let route: @MainActor (MainWindowDestination) -> Void
  let openCommandBar: @MainActor () -> Void
  let toggleCommandBar: @MainActor () -> Void
  let toggleSidebar: @MainActor () -> Void
  let goBack: @MainActor () -> Void
  let goForward: @MainActor () -> Void
  let canGoBack: @MainActor () -> Bool
  let canGoForward: @MainActor () -> Bool

  @Environment(\.appBridge) private var appBridge

  func body(content: Content) -> some View {
    content
      .onAppear {
        Task { @MainActor in
          register()
        }
      }
      .onDisappear {
        Task { @MainActor in
          MainWindowOpenCoordinator.shared.unregisterWindow(id: id)
        }
      }
  }

  @MainActor
  private func register() {
    MainWindowOpenCoordinator.shared.registerWindow(
      id: id,
      window: appBridge?.currentWindow(),
      toastPresenter: toastPresenter,
      route: route,
      openCommandBar: openCommandBar,
      toggleCommandBar: toggleCommandBar,
      toggleSidebar: toggleSidebar,
      goBack: goBack,
      goForward: goForward,
      canGoBack: canGoBack,
      canGoForward: canGoForward
    )
  }
}
