import InlineKit
import Logger
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ComposeView: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  // MARK: - UIImagePickerControllerDelegate

  func presentPicker() {
    guard let windowScene = window?.windowScene, !isPickerPresented else { return }

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 30

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    isPickerPresented = true

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
    // For dropped single images, use single photo preview
    selectedImage = image
    previewViewModel.isPresented = true

    let previewView = SwiftUIPhotoPreviewView(
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
      },
      onAddMorePhotos: { [weak self] in
        self?.presentPicker()
      }
    )

    let previewVC = UIHostingController(rootView: previewView)
    previewVC.modalPresentationStyle = UIModalPresentationStyle.fullScreen
    previewVC.modalTransitionStyle = UIModalTransitionStyle.crossDissolve

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(previewVC, animated: true)
    }
  }

  func handleMultipleDroppedImages(_ images: [UIImage]) {
    guard !images.isEmpty else { return }

    if images.count == 1 {
      handleDroppedImage(images[0])
      return
    }

    // Set up multi-photo preview for multiple dropped images
    multiPhotoPreviewViewModel.setPhotos(images)
    multiPhotoPreviewViewModel.isPresented = true

    let multiPreviewView = SwiftUIPhotoPreviewView(
      viewModel: multiPhotoPreviewViewModel,
      isPresented: Binding(
        get: { [weak self] in self?.multiPhotoPreviewViewModel.isPresented ?? false },
        set: { [weak self] newValue in
          self?.multiPhotoPreviewViewModel.isPresented = newValue
          if !newValue {
            self?.dismissMultiPreview()
          }
        }
      ),
      onSend: { [weak self] photoItems in
        self?.sendMultipleImages(photoItems)
      },
      onAddMorePhotos: { [weak self] in
        self?.presentPicker()
      }
    )

    let previewVC = UIHostingController(rootView: multiPreviewView)
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
      picker?.dismiss(animated: true) {
        self?.isPickerPresented = false
      }
      self?.selectedImage = nil
      self?.previewViewModel.caption = ""
      self?.previewViewModel.isPresented = false
    }
  }

  func dismissMultiPreview() {
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
      picker?.dismiss(animated: true) {
        self?.isPickerPresented = false
      }
      self?.multiPhotoPreviewViewModel.photoItems.removeAll()
      self?.multiPhotoPreviewViewModel.currentIndex = 0
      self?.multiPhotoPreviewViewModel.isPresented = false
    }
  }

  func sendImage(_ image: UIImage, caption: String) {
    guard let peerId else { return }

    sendButton.configuration?.showsActivityIndicator = true
    attachmentItems.removeAll()

    do {
      let photoInfo = try FileCache.savePhoto(image: image)
      let mediaItem = FileMediaItem.photo(photoInfo)
      let uniqueId = mediaItem.getItemUniqueId()
      attachmentItems[uniqueId] = mediaItem
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

  func sendMultipleImages(_ photoItems: [PhotoItem]) {
    guard let peerId else { return }

    sendButton.configuration?.showsActivityIndicator = true
    let replyToMessageId = ChatState.shared.getState(peer: peerId).replyingMessageId

    for (index, photoItem) in photoItems.enumerated() {
      do {
        let photoInfo = try FileCache.savePhoto(image: photoItem.image, optimize: true)
        let mediaItem = FileMediaItem.photo(photoInfo)

        // Include caption for each photo if it has one
        let isFirst = index == 0
        let captionText = photoItem.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageText = captionText?.isEmpty == false ? captionText : nil

        Transactions.shared.mutate(
          transaction: .sendMessage(
            .init(
              text: messageText,
              peerId: peerId,
              chatId: chatId ?? 0,
              mediaItems: [mediaItem],
              replyToMsgId: isFirst ? replyToMessageId : nil,
              isSticker: nil,
              entities: nil
            )
          )
        )

        Log.shared
          .debug(
            "Sent image \(index + 1)/\(photoItems.count) with caption: '\(String(describing: captionText))'"
          )
      } catch {
        Log.shared.error("Failed to save and send photo \(index + 1)", error: error)
      }
    }

    // Clear state and dismiss
    dismissMultiPreview()
    sendButton.configuration?.showsActivityIndicator = false
    ChatState.shared.clearReplyingMessageId(peer: peerId)
    // sendMessageHaptic()
  }

  func handlePastedImage() {
    guard let image = UIPasteboard.general.image else { return }

    selectedImage = image
    previewViewModel.isPresented = true

    let previewView = SwiftUIPhotoPreviewView(
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
      },
      onAddMorePhotos: { [weak self] in
        self?.presentPicker()
      }
    )

    let previewVC = UIHostingController(rootView: previewView)
    previewVC.modalPresentationStyle = UIModalPresentationStyle.fullScreen
    previewVC.modalTransitionStyle = UIModalTransitionStyle.crossDissolve

    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        viewController.present(previewVC, animated: true)
        break
      }
      responder = nextResponder
    }
  }

  func addImage(_ image: UIImage) {
    do {
      let photoInfo = try FileCache.savePhoto(image: image, optimize: true)
      let mediaItem = FileMediaItem.photo(photoInfo)
      let uniqueId = mediaItem.getItemUniqueId()

      // Update state
      attachmentItems[uniqueId] = mediaItem
      updateSendButtonVisibility()

      Log.shared.debug("Added image attachment with uniqueId: \(uniqueId)")
    } catch {
      Log.shared.error("Failed to save photo in attachments", error: error)
    }
  }
}

// MARK: - PHPickerViewControllerDelegate

extension ComposeView: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard !results.isEmpty else {
      picker.dismiss(animated: true) { [weak self] in
        self?.isPickerPresented = false
      }
      return
    }
    
    isPickerPresented = false

    // If only one photo selected, use the original single preview
    if results.count == 1 {
      let result = results.first!
      result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self, weak picker] object, error in
        guard let self, let picker else { return }

        if let error {
          Log.shared.debug("Failed to load image:", file: error.localizedDescription)
          DispatchQueue.main.async {
            picker.dismiss(animated: true) { [weak self] in
              self?.isPickerPresented = false
            }
          }
          return
        }

        guard let image = object as? UIImage else {
          DispatchQueue.main.async {
            picker.dismiss(animated: true) { [weak self] in
              self?.isPickerPresented = false
            }
          }
          return
        }

        DispatchQueue.main.async {
          self.selectedImage = image
          self.previewViewModel.isPresented = true

          let previewView = SwiftUIPhotoPreviewView(
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
            },
            onAddMorePhotos: { [weak self] in
              self?.presentPicker()
            }
          )

          let previewVC = UIHostingController(rootView: previewView)
          previewVC.modalPresentationStyle = .fullScreen
          previewVC.modalTransitionStyle = .crossDissolve

          picker.present(previewVC, animated: true)
        }
      }
    } else {
      // Multiple photos selected, use multi-photo preview
      loadMultipleImages(from: results, picker: picker)
    }
  }

  private func loadMultipleImages(from results: [PHPickerResult], picker: PHPickerViewController) {
    let dispatchGroup = DispatchGroup()
    var loadedImages: [(index: Int, image: UIImage)] = []
    let loadQueue = DispatchQueue(label: "com.inline.imageLoading", qos: .userInitiated, attributes: .concurrent)

    for (index, result) in results.enumerated() {
      dispatchGroup.enter()

      loadQueue.async {
        result.itemProvider.loadObject(ofClass: UIImage.self) { object, error in
          defer { dispatchGroup.leave() }

          if let error {
            Log.shared.debug("Failed to load image at index \(index):", file: error.localizedDescription)
            return
          }

          guard let image = object as? UIImage else { return }

          // Thread-safe array update
          DispatchQueue.main.sync {
            loadedImages.append((index: index, image: image))
          }
        }
      }
    }

    dispatchGroup.notify(queue: .main) { [weak self, weak picker] in
      guard let self, let picker else { return }

      // Sort images by original order
      let sortedImages = loadedImages.sorted { $0.index < $1.index }.map(\.image)

      guard !sortedImages.isEmpty else {
        picker.dismiss(animated: true) { [weak self] in
          self?.isPickerPresented = false
        }
        return
      }

      // Set up multi-photo preview
      multiPhotoPreviewViewModel.setPhotos(sortedImages)
      multiPhotoPreviewViewModel.isPresented = true

      let multiPreviewView = SwiftUIPhotoPreviewView(
        viewModel: multiPhotoPreviewViewModel,
        isPresented: Binding(
          get: { [weak self] in self?.multiPhotoPreviewViewModel.isPresented ?? false },
          set: { [weak self] newValue in
            self?.multiPhotoPreviewViewModel.isPresented = newValue
            if !newValue {
              self?.dismissMultiPreview()
            }
          }
        ),
        onSend: { [weak self] photoItems in
          self?.sendMultipleImages(photoItems)
        },
        onAddMorePhotos: { [weak self] in
          self?.presentPicker()
        }
      )

      let previewVC = UIHostingController(rootView: multiPreviewView)
      previewVC.modalPresentationStyle = UIModalPresentationStyle.fullScreen
      previewVC.modalTransitionStyle = UIModalTransitionStyle.crossDissolve

      picker.present(previewVC, animated: true)
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
    let dispatchGroup = DispatchGroup()
    var droppedImages: [(index: Int, image: UIImage)] = []
    let loadQueue = DispatchQueue(label: "com.inline.dropImageLoading", qos: .userInitiated, attributes: .concurrent)

    for (index, provider) in session.items.enumerated() {
      dispatchGroup.enter()

      loadQueue.async {
        provider.itemProvider.loadObject(ofClass: UIImage.self) { (
          image: NSItemProviderReading?,
          _: Error?
        ) in
          defer { dispatchGroup.leave() }

          guard let image = image as? UIImage else { return }

          // Thread-safe array update
          DispatchQueue.main.sync {
            droppedImages.append((index: index, image: image))
          }
        }
      }
    }

    dispatchGroup.notify(queue: .main) { [weak self] in
      guard let self else { return }

      // Sort images by original drop order
      let sortedImages = droppedImages.sorted { $0.index < $1.index }.map(\.image)

      guard !sortedImages.isEmpty else { return }

      if sortedImages.count == 1 {
        handleDroppedImage(sortedImages[0])
      } else {
        handleMultipleDroppedImages(sortedImages)
      }
    }
  }
}
