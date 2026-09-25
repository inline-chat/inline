import SwiftUI
import UIKit

/// A separate presentation surface lets the native sheet cover a live context
/// menu without asking UIKit to dismiss the menu's presentation first.
@MainActor
final class ReactionEmojiPickerPresentation {
  private var overlayWindow: UIWindow?
  private weak var previousKeyWindow: UIWindow?
  private let onDismiss: () -> Void

  init?(
    picker: ReactionEmojiPickerSheet,
    presenter: UIViewController,
    over sourceWindow: UIWindow?,
    tintColor: UIColor,
    onDismiss: @escaping () -> Void
  ) {
    self.onDismiss = onDismiss
    let sheetPresenter: UIViewController
    if let sourceWindow {
      guard let scene = sourceWindow.windowScene else { return nil }
      previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      window.windowLevel = UIWindow.Level(rawValue: sourceWindow.windowLevel.rawValue + 1)
      window.backgroundColor = .clear
      window.overrideUserInterfaceStyle = sourceWindow.traitCollection.userInterfaceStyle
      let root = UIViewController()
      root.view.backgroundColor = .clear
      window.rootViewController = root
      overlayWindow = window
      // Give native search and accessibility focus to the sheet, then restore
      // the menu's key window after dismissal.
      window.makeKeyAndVisible()
      sheetPresenter = root
    } else {
      guard presenter.presentedViewController == nil,
            !presenter.isBeingPresented,
            !presenter.isBeingDismissed else { return nil }
      sheetPresenter = presenter
    }

    let controller = ReactionEmojiPickerHostingController(rootView: picker)
    controller.onDismiss = { [weak self] in self?.finish() }
    controller.modalPresentationStyle = .pageSheet
    controller.view.tintColor = tintColor
    if let sheet = controller.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    sheetPresenter.present(controller, animated: true)
  }

  private func finish() {
    let restoreKeyWindow = overlayWindow?.isKeyWindow == true
    overlayWindow?.isHidden = true
    overlayWindow?.rootViewController = nil
    overlayWindow = nil
    if restoreKeyWindow, previousKeyWindow?.isHidden == false {
      previousKeyWindow?.makeKey()
    }
    onDismiss()
  }
}

private final class ReactionEmojiPickerHostingController: UIHostingController<ReactionEmojiPickerSheet> {
  var onDismiss: (() -> Void)?

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard isBeingDismissed || presentingViewController == nil else { return }
    // Covers the native close button, selection, and interactive swipe dismissal.
    let completion = onDismiss
    onDismiss = nil
    completion?()
  }
}
