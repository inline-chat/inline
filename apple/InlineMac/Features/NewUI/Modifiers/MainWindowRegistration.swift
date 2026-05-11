import AppKit
import SwiftUI

extension View {
  func registerMainWindow(
    id: UUID,
    toastPresenter: (any ToastPresenting)?,
    route: @escaping (MainWindowDestination) -> Void,
    openCommandBar: @escaping () -> Void,
    toggleSidebar: @escaping () -> Void
  ) -> some View {
    onHostingWindowChange { window in
      Task { @MainActor in
        MainWindowOpenCoordinator.shared.registerWindow(
          id: id,
          window: window,
          toastPresenter: toastPresenter,
          route: route,
          openCommandBar: openCommandBar,
          toggleSidebar: toggleSidebar
        )
      }
    }
  }
}
