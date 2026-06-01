import AppKit

enum ToastPlacement: Equatable {
  case topCenter(offset: CGFloat)
  case bottomCenter(offset: CGFloat)

  static let standard = ToastPlacement.bottomCenter(offset: 120)
}

@MainActor
protocol ToastPresenting: AnyObject {
  func showLoading(
    _ message: String,
    actionTitle: String?,
    action: (@MainActor () -> Void)?,
    placement: ToastPlacement
  )
  func showUndoCountdown(
    _ message: String,
    duration: TimeInterval,
    actionTitle: String,
    action: @escaping @MainActor () -> Void,
    placement: ToastPlacement
  )
  func showInfo(_ message: String, placement: ToastPlacement)
  func showSuccess(
    _ message: String,
    actionTitle: String?,
    action: (@MainActor () -> Void)?,
    placement: ToastPlacement
  )
  func showError(_ message: String, placement: ToastPlacement)
  func dismissToast()
}

extension ToastPresenting {
  func showLoading(_ message: String) {
    showLoading(message, actionTitle: nil, action: nil, placement: .standard)
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

  func showLoading(
    _ message: String,
    actionTitle: String? = nil,
    action: (@MainActor () -> Void)? = nil,
    placement: ToastPlacement = .standard
  ) {
    targetPresenter?.showLoading(message, actionTitle: actionTitle, action: action, placement: placement)
  }

  func showUndoCountdown(
    _ message: String,
    duration: TimeInterval = 5,
    actionTitle: String = "Undo",
    placement: ToastPlacement = .standard,
    action: @escaping @MainActor () -> Void
  ) {
    targetPresenter?.showUndoCountdown(
      message,
      duration: duration,
      actionTitle: actionTitle,
      action: action,
      placement: placement
    )
  }

  func showInfo(_ message: String, placement: ToastPlacement = .standard) {
    targetPresenter?.showInfo(message, placement: placement)
  }

  func showSuccess(
    _ message: String,
    actionTitle: String? = nil,
    action: (@MainActor () -> Void)? = nil,
    placement: ToastPlacement = .standard
  ) {
    targetPresenter?.showSuccess(message, actionTitle: actionTitle, action: action, placement: placement)
  }

  func showError(_ message: String, placement: ToastPlacement = .standard) {
    targetPresenter?.showError(message, placement: placement)
  }

  func dismiss() {
    targetPresenter?.dismissToast()
  }
}
