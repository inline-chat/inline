import AppKit

@MainActor
protocol ToastPresenting: AnyObject {
  func showLoading(_ message: String)
  func showSuccess(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?)
  func showError(_ message: String)
  func dismissToast()
}

/// Global access point for showing toasts on the active window.
/// The window root attaches a presenter (OverlayManager) at runtime.
@MainActor
final class ToastCenter {
  static let shared = ToastCenter()
  private init() {}

  weak var presenter: (any ToastPresenting)?

  func showLoading(_ message: String) {
    presenter?.showLoading(message)
  }

  func showSuccess(_ message: String, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
    presenter?.showSuccess(message, actionTitle: actionTitle, action: action)
  }

  func showError(_ message: String) {
    presenter?.showError(message)
  }

  func dismiss() {
    presenter?.dismissToast()
  }
}

