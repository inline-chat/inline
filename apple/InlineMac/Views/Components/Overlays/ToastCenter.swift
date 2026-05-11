import AppKit

@MainActor
protocol ToastPresenting: AnyObject {
  func showLoading(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?)
  func showInfo(_ message: String)
  func showSuccess(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?)
  func showError(_ message: String)
  func dismissToast()
}

extension ToastPresenting {
  func showLoading(_ message: String) {
    showLoading(message, actionTitle: nil, action: nil)
  }
}

/// Global access point for showing toasts on the active window.
/// The window root attaches a presenter (OverlayManager) at runtime.
@MainActor
final class ToastCenter {
  static let shared = ToastCenter()
  private init() {}

  weak var presenter: (any ToastPresenting)?

  private var targetPresenter: (any ToastPresenting)? {
    MainWindowOpenCoordinator.shared.activeToastPresenter ?? presenter
  }

  func showLoading(_ message: String, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
    targetPresenter?.showLoading(message, actionTitle: actionTitle, action: action)
  }

  func showInfo(_ message: String) {
    targetPresenter?.showInfo(message)
  }

  func showSuccess(_ message: String, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
    targetPresenter?.showSuccess(message, actionTitle: actionTitle, action: action)
  }

  func showError(_ message: String) {
    targetPresenter?.showError(message)
  }

  func dismiss() {
    targetPresenter?.dismissToast()
  }
}
