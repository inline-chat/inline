import InlineIOSUI
import Photos
import SwiftUI
import UIKit

private let attachmentPickerCompactDetentIdentifier = UISheetPresentationController.Detent.Identifier(
  "attachmentPickerCompact"
)

extension ComposeView: UIAdaptivePresentationControllerDelegate {
  @objc func plusTapped() {
    presentAttachmentPicker()
  }

  func presentAttachmentPicker() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.attachmentPickerViewController == nil else { return }
      guard let presenter = self.attachmentPickerPresenter() else { return }

      let rootView = AttachmentPickerSheet(
        actions: AttachmentPickerActions(
          showCommands: { [weak self] in
            self?.showCommandsFromAttachmentPicker()
          },
          isCommandsEnabled: self.commandLaunchState().isEnabled,
          openCamera: { [weak self] in
            self?.presentCamera()
          },
          openLibrary: { [weak self] in
            self?.presentPicker()
          },
          openFiles: { [weak self] in
            self?.presentFileManager()
          },
          openRecentItem: { [weak self] item in
            self?.openRecentAsset(localIdentifier: item.localIdentifier)
          },
          openRecentItems: { [weak self] items in
            self?.openRecentAssets(localIdentifiers: items.map(\.localIdentifier))
          },
          manageLimitedAccess: { [weak self] in
            self?.presentLimitedLibraryManager()
          }
        )
      )

      let controller = UIHostingController(rootView: rootView)
      controller.modalPresentationStyle = .pageSheet
      controller.presentationController?.delegate = self

      if let sheetController = controller.sheetPresentationController {
        sheetController.detents = [
          .custom(identifier: attachmentPickerCompactDetentIdentifier) { context in
            min(context.maximumDetentValue, max(320, context.maximumDetentValue * 0.38))
          },
          .medium(),
          .large(),
        ]
        sheetController.selectedDetentIdentifier = attachmentPickerCompactDetentIdentifier
        sheetController.prefersGrabberVisible = true
        sheetController.preferredCornerRadius = 28
      }

      self.attachmentPickerViewController = controller
      presenter.present(controller, animated: true)
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if presentationController.presentedViewController === attachmentPickerViewController {
      attachmentPickerViewController = nil
    }
  }

  private func dismissAttachmentPicker(animated: Bool, completion: (() -> Void)? = nil) {
    guard let controller = attachmentPickerViewController else {
      completion?()
      return
    }

    attachmentPickerViewController = nil
    controller.dismiss(animated: animated, completion: completion)
  }

  private func showCommandsFromAttachmentPicker() {
    switch commandLaunchState() {
      case .blocked:
        return
      case .empty:
        dismissAttachmentPicker(animated: true) { [weak self] in
          self?.insertSlashAndShowCommands()
        }
      case .text:
        dismissAttachmentPicker(animated: true) { [weak self] in
          guard let self, let presenter = attachmentPickerPresenter() else { return }

          let alert = UIAlertController(
            title: "Clear message to show commands?",
            message: "Commands only work when the message is empty.",
            preferredStyle: .alert
          )
          alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
          alert.addAction(UIAlertAction(title: "Clear and Show Commands", style: .destructive) { [weak self] _ in
            self?.clearInlineCommandText()
            self?.insertSlashAndShowCommands()
          })
          presenter.present(alert, animated: true)
        }
    }
  }

  private func insertSlashAndShowCommands() {
    guard commandLaunchState() == .empty else { return }
    if !(textView.text ?? "").isEmpty {
      clearInlineCommandText()
    }

    textView.attributedText = NSAttributedString(
      string: "/",
      attributes: [
        .font: UIFont.systemFont(ofSize: 17),
        .foregroundColor: UIColor.label,
      ]
    )
    textView.selectedRange = NSRange(location: 1, length: 0)
    resetTextViewState()
    textView.textDidChange()
    _ = textView.becomeFirstResponder()
    textViewDidChange(textView)
  }

  func dismissAttachmentPickerIfPresented(animated: Bool, completion: (() -> Void)? = nil) {
    guard attachmentPickerViewController != nil else {
      completion?()
      return
    }

    dismissAttachmentPicker(animated: animated, completion: completion)
  }

  private func attachmentPickerPresenter() -> UIViewController? {
    guard let windowScene = window?.windowScene,
          let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow })
    else {
      return nil
    }

    return activePresenter(from: keyWindow.rootViewController)
  }

  func attachmentFlowPresenter() -> UIViewController? {
    if let attachmentPickerViewController {
      return activePresenter(from: attachmentPickerViewController)
    }

    return attachmentPickerPresenter()
  }

  private func activePresenter(from controller: UIViewController?) -> UIViewController? {
    if let navigationController = controller as? UINavigationController {
      return activePresenter(from: navigationController.visibleViewController ?? navigationController)
    }

    if let tabBarController = controller as? UITabBarController {
      return activePresenter(from: tabBarController.selectedViewController ?? tabBarController)
    }

    if let presentedController = controller?.presentedViewController {
      return activePresenter(from: presentedController)
    }

    return controller
  }

  private func presentLimitedLibraryManager() {
    guard let presenter = attachmentFlowPresenter() else { return }
    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter) { localIdentifiers in
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: .attachmentPickerRecentMediaDidChange,
          object: nil,
          userInfo: [AttachmentPickerRecentMediaChangeUserInfo.localIdentifiersKey: localIdentifiers]
        )
      }
    }
  }
}
