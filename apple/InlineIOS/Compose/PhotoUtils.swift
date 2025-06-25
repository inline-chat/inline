import InlineKit
import Logger
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ComposeView: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  // MARK: - UIImagePickerControllerDelegate

  func presentPicker() {
    guard let windowScene = window?.windowScene else { return }

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 1

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self

    let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow })
    let rootVC = keyWindow?.rootViewController
    rootVC?.present(picker, animated: true)
  }

  func presentCamera() {
    let status = AVCaptureDevice.authorizationStatus(for: .video)

    switch status {
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
          if granted {
            DispatchQueue.main.async {
              self?.showCameraPicker()
            }
          }
        }
      case .authorized:
        showCameraPicker()
      default:
        Log.shared.error("Failed to presentCamera")
    }
  }

  func showCameraPicker() {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = self
    picker.allowsEditing = false

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(picker, animated: true)
    }
  }

  func handleDroppedImage(_ image: UIImage) {
    selectedImage = image
    previewViewModel.isPresented = true

    let previewView = PhotoPreviewView(
      image: image,
      caption: Binding(
        get: { [weak self] in self?.previewViewModel.caption ?? "" },
        set: { [weak self] newValue in self?.previewViewModel.caption = newValue }
      ),
      isPresented: Binding(
        get: { [weak self] in self?.previewViewModel.isPresented ?? false },
        set: { [weak self] newValue in
          self?.previewViewModel.isPresented = newValue
          if !newValue {
            self?.dismissPreview()
          }
        }
      ),
      onSend: { [weak self] image, caption in
        self?.sendImage(image, caption: caption)
      }
    )

    let previewVC = UIHostingController(rootView: previewView)
    previewVC.modalPresentationStyle = .fullScreen
    previewVC.modalTransitionStyle = .crossDissolve

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(previewVC, animated: true)
    }
  }

  func dismissPreview() {
    var responder: UIResponder? = self
    var currentVC: UIViewController?

    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        currentVC = viewController
        break
      }
      responder = nextResponder
    }

    guard let currentVC else { return }

    var topmostVC = currentVC
    while let presentedVC = topmostVC.presentedViewController {
      topmostVC = presentedVC
    }

    let picker = topmostVC.presentingViewController as? PHPickerViewController

    topmostVC.dismiss(animated: true) { [weak self] in
      picker?.dismiss(animated: true)
      self?.selectedImage = nil
      self?.previewViewModel.caption = ""
      self?.previewViewModel.isPresented = false
    }
  }

  func sendImage(_ image: UIImage, caption: String) {
    guard let peerId else { return }

    sendButton.configuration?.showsActivityIndicator = true
    attachmentItems.removeAll()

    do {
      let photoInfo = try FileCache.savePhoto(image: image)
      attachmentItems[image] = .photo(photoInfo)
    } catch {
      Log.shared.error("Failed to save photo", error: error)
    }

    for (_, attachment) in attachmentItems {
      Transactions.shared.mutate(
        transaction: .sendMessage(
          .init(
            text: caption,
            peerId: peerId,
            chatId: chatId ?? 0,
            mediaItems: [attachment],
            replyToMsgId: ChatState.shared.getState(peer: peerId).replyingMessageId
          )
        )
      )
    }

    dismissPreview()
    sendButton.configuration?.showsActivityIndicator = false
    attachmentItems.removeAll()
    // sendMessageHaptic()
  }

  func handlePastedImage() {
    guard let image = UIPasteboard.general.image else { return }

    selectedImage = image
    previewViewModel.isPresented = true

    let previewView = PhotoPreviewView(
      image: image,
      caption: Binding(
        get: { [weak self] in self?.previewViewModel.caption ?? "" },
        set: { [weak self] newValue in self?.previewViewModel.caption = newValue }
      ),
      isPresented: Binding(
        get: { [weak self] in self?.previewViewModel.isPresented ?? false },
        set: { [weak self] newValue in
          self?.previewViewModel.isPresented = newValue
          if !newValue {
            self?.dismissPreview()
          }
        }
      ),
      onSend: { [weak self] image, caption in
        self?.sendImage(image, caption: caption)
      }
    )

    let previewVC = UIHostingController(rootView: previewView)
    previewVC.modalPresentationStyle = .fullScreen
    previewVC.modalTransitionStyle = .crossDissolve

    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        viewController.present(previewVC, animated: true)
        break
      }
      responder = nextResponder
    }
  }
}

// MARK: - PHPickerViewControllerDelegate

extension ComposeView: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard let result = results.first else {
      picker.dismiss(animated: true)
      return
    }

    result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self, weak picker] object, error in
      guard let self, let picker else { return }

      if let error {
        Log.shared.debug("Failed to load image:", file: error.localizedDescription)
        DispatchQueue.main.async {
          picker.dismiss(animated: true)
        }
        return
      }

      guard let image = object as? UIImage else {
        DispatchQueue.main.async {
          picker.dismiss(animated: true)
        }
        return
      }

      DispatchQueue.main.async {
        self.selectedImage = image
        self.previewViewModel.isPresented = true

        let previewView = PhotoPreviewView(
          image: image,
          caption: Binding(
            get: { [weak self] in self?.previewViewModel.caption ?? "" },
            set: { [weak self] newValue in self?.previewViewModel.caption = newValue }
          ),
          isPresented: Binding(
            get: { [weak self] in self?.previewViewModel.isPresented ?? false },
            set: { [weak self] newValue in
              self?.previewViewModel.isPresented = newValue
              if !newValue {
                self?.dismissPreview()
              }
            }
          ),
          onSend: { [weak self] image, caption in
            self?.sendImage(image, caption: caption)
          }
        )

        let previewVC = UIHostingController(rootView: previewView)
        previewVC.modalPresentationStyle = .fullScreen
        previewVC.modalTransitionStyle = .crossDissolve

        picker.present(previewVC, animated: true)
      }
    }
  }
}

// MARK: - UIImagePickerControllerDelegate

extension ComposeView {
  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    guard let image = info[.originalImage] as? UIImage else {
      picker.dismiss(animated: true)
      return
    }

    // Save the captured photo to the photo library
    if picker.sourceType == .camera {
      UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    picker.dismiss(animated: true) { [weak self] in
      self?.handleDroppedImage(image)
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }
}

// MARK: - UIDropInteractionDelegate

extension ComposeView: UIDropInteractionDelegate {
  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
    UIDropProposal(operation: .copy)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    for provider in session.items {
      provider.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] (
        image: NSItemProviderReading?,
        _: Error?
      ) in
        guard let image = image as? UIImage else { return }

        DispatchQueue.main.async {
          self?.handleDroppedImage(image)
        }
      }
    }
  }
}
