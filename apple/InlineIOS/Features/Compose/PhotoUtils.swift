import InlineKit
import Logger
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ComposeView: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private func resetComposeStateAfterPreviewSend() {
    if let attributed = textView.attributedText?.mutableCopy() as? NSMutableAttributedString {
      let marker = "\u{FFFC}" as NSString
      var range = (attributed.string as NSString).range(of: marker as String)
      while range.location != NSNotFound {
        attributed.replaceCharacters(in: range, with: "")
        range = (attributed.string as NSString).range(of: marker as String)
      }
      textView.attributedText = attributed
    }

    textView.resetTypingAttributesToDefault()
    textView.font = .systemFont(ofSize: 17)
    textView.typingAttributes[.font] = UIFont.systemFont(ofSize: 17)

    let normalizedText = (textView.text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "")
    let isEmpty = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    (textView as? ComposeTextView)?.showPlaceholder(isEmpty)
    updateSendButtonVisibility()
  }

  // MARK: - UIImagePickerControllerDelegate

  func presentPicker() {
    guard let windowScene = window?.windowScene, !isPickerPresented else { return }

    activePickerMode = .photos

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

  func presentVideoPicker() {
    guard let windowScene = window?.windowScene, !isPickerPresented else { return }

    activePickerMode = .videos

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .videos
    configuration.selectionLimit = 10

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
    picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
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
    guard !previewViewModel.isPresented, !multiPhotoPreviewViewModel.isPresented else { return }

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
    guard !previewViewModel.isPresented, !multiPhotoPreviewViewModel.isPresented else { return }

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
    clearAttachments()

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
            replyToMsgId: ChatState.shared.getState(peer: peerId).replyingMessageId,
            isSticker: nil,
            entities: nil
          )
        )
      )
    }

    resetComposeStateAfterPreviewSend()
    dismissPreview()
    sendButton.configuration?.showsActivityIndicator = false
    clearAttachments()
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
    resetComposeStateAfterPreviewSend()
    dismissMultiPreview()
    sendButton.configuration?.showsActivityIndicator = false
    clearAttachments()
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

  func addVideo(_ url: URL) {
    sendButton.configuration?.showsActivityIndicator = true

    Task { [weak self] in
      do {
        let videoInfo = try await FileCache.saveVideo(url: url)
        let mediaItem = FileMediaItem.video(videoInfo)
        let uniqueId = mediaItem.getItemUniqueId()

        await MainActor.run { [weak self] in
          guard let self else { return }
          attachmentItems[uniqueId] = mediaItem
          updateSendButtonVisibility()
          sendButton.configuration?.showsActivityIndicator = false
          sendMessage()
        }
      } catch {
        Log.shared.error("Failed to save video", error: error)
        await MainActor.run { [weak self] in
          self?.sendButton.configuration?.showsActivityIndicator = false
          self?.showVideoError(error)
        }
      }
    }
  }

  private func showVideoError(_ error: Error) {
    let alert = UIAlertController(
      title: "Video Error",
      message: "Failed to add video: \(error.localizedDescription)",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(alert, animated: true)
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

    if activePickerMode == .videos {
      handleVideoPickerResults(results, picker: picker)
      return
    }

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

  private func handleVideoPickerResults(_ results: [PHPickerResult], picker: PHPickerViewController) {
    Task { [weak self, weak picker] in
      guard let self, let picker else { return }

      var loadedItems: [(index: Int, item: FileMediaItem)] = []

      await withTaskGroup(of: (Int, FileMediaItem?).self) { group in
        for (index, result) in results.enumerated() {
          group.addTask { [weak self] in
            guard let self else { return (index, nil) }
            let item = await self.loadVideoItem(from: result)
            return (index, item)
          }
        }

        for await (index, item) in group {
          if let item {
            loadedItems.append((index: index, item: item))
          }
        }
      }

      await MainActor.run { [weak self, weak picker] in
        guard let self, let picker else { return }

        let sortedItems = loadedItems.sorted { $0.index < $1.index }.map(\.item)
        guard !sortedItems.isEmpty else {
          picker.dismiss(animated: true) { [weak self] in
            self?.isPickerPresented = false
          }
          return
        }

        for item in sortedItems {
          let uniqueId = item.getItemUniqueId()
          attachmentItems[uniqueId] = item
        }

        updateSendButtonVisibility()

        picker.dismiss(animated: true) { [weak self] in
          guard let self else { return }
          isPickerPresented = false
          sendMessage()
        }
      }
    }
  }

  private func loadVideoItem(from result: PHPickerResult) async -> FileMediaItem? {
    let provider = result.itemProvider
    let typeIdentifier = [UTType.movie.identifier, UTType.video.identifier]
      .first(where: { provider.hasItemConformingToTypeIdentifier($0) })

    guard let typeIdentifier else { return nil }

    return await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
        if let error {
          Log.shared.error("Failed to load video file from picker", error: error)
          continuation.resume(returning: nil)
          return
        }

        guard let url else {
          continuation.resume(returning: nil)
          return
        }

        let tempDirectory = FileManager.default.temporaryDirectory
        let fileExtension = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let tempUrl = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)

        do {
          try FileManager.default.copyItem(at: url, to: tempUrl)
        } catch {
          Log.shared.error("Failed to copy video file from picker", error: error)
          continuation.resume(returning: nil)
          return
        }

        Task {
          defer { try? FileManager.default.removeItem(at: tempUrl) }
          do {
            let videoInfo = try await FileCache.saveVideo(url: tempUrl)
            continuation.resume(returning: .video(videoInfo))
          } catch {
            Log.shared.error("Failed to save video from picker", error: error)
            continuation.resume(returning: nil)
          }
        }
      }
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
    let mediaType = info[.mediaType] as? String

    if mediaType == UTType.image.identifier {
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
    } else if mediaType == UTType.movie.identifier {
      guard let url = info[.mediaURL] as? URL else {
        picker.dismiss(animated: true)
        return
      }

      if picker.sourceType == .camera {
        UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
      }

      picker.dismiss(animated: true) { [weak self] in
        self?.addVideo(url)
      }
    } else {
      picker.dismiss(animated: true)
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
