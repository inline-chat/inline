import AVFoundation
import InlineKit
import Logger
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ComposeView: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  @objc func attachmentButtonTapped() {
    presentAttachmentOptionsSheet()
  }

  private func presentAttachmentOptionsSheet() {
    guard let windowScene = window?.windowScene,
          let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
          let rootVC = keyWindow.rootViewController
    else { return }

    let sheet = UIHostingController(
      rootView: AttachmentOptionsSheet { [weak self] option in
        guard let self else { return }
        rootVC.dismiss(animated: true) { [weak self] in
          guard let self else { return }
          switch option {
            case .library:
              presentPicker()
            case .camera:
              presentCamera()
            case .file:
              presentFileManager()
          }
        }
      }
    )
    sheet.modalPresentationStyle = .pageSheet

    if let presentation = sheet.sheetPresentationController {
      if #available(iOS 16.0, *) {
        presentation.detents = [.medium()]
      } else {
        presentation.detents = [.medium()]
      }
      presentation.prefersGrabberVisible = true
      presentation.preferredCornerRadius = 20
    }

    rootVC.present(sheet, animated: true)
  }

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

    activePickerMode = .library

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .any(of: [.images, .videos])
    configuration.selectionLimit = 30

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    isPickerPresented = true

    let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow })
    let rootVC = keyWindow?.rootViewController
    rootVC?.present(picker, animated: true)
  }

  func presentVideoPicker() {
    presentPicker()
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
    guard
      !previewViewModel.isPresented,
      !multiPhotoPreviewViewModel.isPresented,
      !videoPreviewViewModel.isPresented,
      !mixedMediaPreviewViewModel.isPresented
    else { return }

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
    guard
      !previewViewModel.isPresented,
      !multiPhotoPreviewViewModel.isPresented,
      !videoPreviewViewModel.isPresented,
      !mixedMediaPreviewViewModel.isPresented
    else { return }

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

  private func presentVideoPreview(with videoURLs: [URL], presenter: UIViewController? = nil) {
    guard let firstVideoURL = videoURLs.first else { return }

    cleanupPendingVideoURLs()
    pendingVideoURLs = videoURLs
    videoPreviewViewModel.caption = ""
    videoPreviewViewModel.isPresented = true

    let previewView = SwiftUIVideoPreviewView(
      videoURL: firstVideoURL,
      totalVideos: videoURLs.count,
      caption: Binding(
        get: { [weak self] in self?.videoPreviewViewModel.caption ?? "" },
        set: { [weak self] newValue in self?.videoPreviewViewModel.caption = newValue }
      ),
      isPresented: Binding(
        get: { [weak self] in self?.videoPreviewViewModel.isPresented ?? false },
        set: { [weak self] newValue in
          self?.videoPreviewViewModel.isPresented = newValue
          if !newValue {
            self?.dismissVideoPreview()
          }
        }
      ),
      onSend: { [weak self] caption in
        self?.sendVideos(caption: caption)
      }
    )

    let previewVC = UIHostingController(rootView: previewView)
    previewVC.modalPresentationStyle = .fullScreen
    previewVC.modalTransitionStyle = .crossDissolve

    if let presenter {
      presenter.present(previewVC, animated: true)
      return
    }

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(previewVC, animated: true)
    }
  }

  func dismissVideoPreview() {
    var responder: UIResponder? = self
    var currentVC: UIViewController?

    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        currentVC = viewController
        break
      }
      responder = nextResponder
    }

    guard let currentVC else {
      cleanupPendingVideoURLs()
      videoPreviewViewModel.caption = ""
      videoPreviewViewModel.isPresented = false
      return
    }

    var topmostVC = currentVC
    while let presentedVC = topmostVC.presentedViewController {
      topmostVC = presentedVC
    }

    let picker = topmostVC.presentingViewController as? PHPickerViewController

    topmostVC.dismiss(animated: true) { [weak self] in
      picker?.dismiss(animated: true) {
        self?.isPickerPresented = false
      }

      self?.cleanupPendingVideoURLs()
      self?.videoPreviewViewModel.caption = ""
      self?.videoPreviewViewModel.isPresented = false
    }
  }

  private func cleanupPendingVideoURLs() {
    cleanupTemporaryVideoURLs(in: pendingVideoURLs)
    pendingVideoURLs.removeAll()
  }

  private func presentMixedMediaPreview(
    with items: [MixedMediaPreviewItem],
    presenter: UIViewController? = nil
  ) {
    guard !items.isEmpty else { return }

    cleanupPendingMixedMediaItems()
    pendingMixedMediaItems = items
    mixedMediaPreviewViewModel.caption = ""
    mixedMediaPreviewViewModel.isPresented = true

    let previewView = SwiftUIMixedMediaPreviewView(
      items: items,
      caption: Binding(
        get: { [weak self] in self?.mixedMediaPreviewViewModel.caption ?? "" },
        set: { [weak self] newValue in self?.mixedMediaPreviewViewModel.caption = newValue }
      ),
      isPresented: Binding(
        get: { [weak self] in self?.mixedMediaPreviewViewModel.isPresented ?? false },
        set: { [weak self] newValue in
          self?.mixedMediaPreviewViewModel.isPresented = newValue
          if !newValue {
            self?.dismissMixedMediaPreview()
          }
        }
      ),
      onSend: { [weak self] caption in
        self?.sendMixedMedia(caption: caption)
      }
    )

    let previewVC = UIHostingController(rootView: previewView)
    previewVC.modalPresentationStyle = .fullScreen
    previewVC.modalTransitionStyle = .crossDissolve

    if let presenter {
      presenter.present(previewVC, animated: true)
      return
    }

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(previewVC, animated: true)
    }
  }

  private func dismissMixedMediaPreview() {
    var responder: UIResponder? = self
    var currentVC: UIViewController?

    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        currentVC = viewController
        break
      }
      responder = nextResponder
    }

    guard let currentVC else {
      cleanupPendingMixedMediaItems()
      mixedMediaPreviewViewModel.caption = ""
      mixedMediaPreviewViewModel.isPresented = false
      return
    }

    var topmostVC = currentVC
    while let presentedVC = topmostVC.presentedViewController {
      topmostVC = presentedVC
    }

    let picker = topmostVC.presentingViewController as? PHPickerViewController

    topmostVC.dismiss(animated: true) { [weak self] in
      picker?.dismiss(animated: true) {
        self?.isPickerPresented = false
      }

      self?.cleanupPendingMixedMediaItems()
      self?.mixedMediaPreviewViewModel.caption = ""
      self?.mixedMediaPreviewViewModel.isPresented = false
    }
  }

  private func cleanupPendingMixedMediaItems() {
    let videoURLs = pendingMixedMediaItems.compactMap(\.videoURL)
    cleanupTemporaryVideoURLs(in: videoURLs)
    pendingMixedMediaItems.removeAll()
  }

  private func cleanupTemporaryVideoURLs(in urls: [URL]) {
    for url in urls where url.lastPathComponent.hasPrefix("inline-video-preview-") {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func copyVideoToTemporaryPreviewURL(from sourceURL: URL) throws -> URL {
    let fileExtension = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-video-preview-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)

    if FileManager.default.fileExists(atPath: temporaryURL.path) {
      try FileManager.default.removeItem(at: temporaryURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
    return temporaryURL
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

  private func sendVideos(caption: String) {
    guard let peerId else { return }
    let videoURLs = pendingVideoURLs
    guard !videoURLs.isEmpty else { return }

    sendButton.configuration?.showsActivityIndicator = true
    clearAttachments()

    let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    let messageCaption = trimmedCaption.isEmpty ? nil : trimmedCaption
    let replyToMessageId = ChatState.shared.getState(peer: peerId).replyingMessageId

    Task { [weak self] in
      guard let self else { return }

      for (index, url) in videoURLs.enumerated() {
        do {
          let videoInfo = try await FileCache.saveVideo(url: url)
          let mediaItem = FileMediaItem.video(videoInfo)
          let isFirst = index == 0

          await MainActor.run {
            Transactions.shared.mutate(
              transaction: .sendMessage(
                .init(
                  text: isFirst ? messageCaption : nil,
                  peerId: peerId,
                  chatId: chatId ?? 0,
                  mediaItems: [mediaItem],
                  replyToMsgId: isFirst ? replyToMessageId : nil,
                  isSticker: nil,
                  entities: nil
                )
              )
            )
          }
        } catch {
          Log.shared.error("Failed to save and send video \(index + 1)", error: error)
        }
      }

      await MainActor.run { [weak self] in
        guard let self else { return }
        resetComposeStateAfterPreviewSend()
        dismissVideoPreview()
        sendButton.configuration?.showsActivityIndicator = false
        clearAttachments()
        ChatState.shared.clearReplyingMessageId(peer: peerId)
      }
    }
  }

  private func sendMixedMedia(caption: String) {
    guard let peerId else { return }
    let mediaItems = pendingMixedMediaItems
    guard !mediaItems.isEmpty else { return }

    sendButton.configuration?.showsActivityIndicator = true
    clearAttachments()

    let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    let messageCaption = trimmedCaption.isEmpty ? nil : trimmedCaption
    let replyToMessageId = ChatState.shared.getState(peer: peerId).replyingMessageId

    Task { [weak self] in
      guard let self else { return }

      for (index, item) in mediaItems.enumerated() {
        do {
          let mediaItem: FileMediaItem
          switch item {
            case let .photo(id: _, image: image):
              let photoInfo = try FileCache.savePhoto(image: image, optimize: true)
              mediaItem = .photo(photoInfo)
            case let .video(id: _, url: url):
              let videoInfo = try await FileCache.saveVideo(url: url)
              mediaItem = .video(videoInfo)
          }

          let isFirst = index == 0
          await MainActor.run {
            Transactions.shared.mutate(
              transaction: .sendMessage(
                .init(
                  text: isFirst ? messageCaption : nil,
                  peerId: peerId,
                  chatId: chatId ?? 0,
                  mediaItems: [mediaItem],
                  replyToMsgId: isFirst ? replyToMessageId : nil,
                  isSticker: nil,
                  entities: nil
                )
              )
            )
          }
        } catch {
          Log.shared.error("Failed to save and send mixed media item \(index + 1)", error: error)
        }
      }

      await MainActor.run { [weak self] in
        guard let self else { return }
        resetComposeStateAfterPreviewSend()
        dismissMixedMediaPreview()
        sendButton.configuration?.showsActivityIndicator = false
        clearAttachments()
        ChatState.shared.clearReplyingMessageId(peer: peerId)
      }
    }
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
    do {
      let previewURL = try copyVideoToTemporaryPreviewURL(from: url)
      presentVideoPreview(with: [previewURL])
    } catch {
      Log.shared.error("Failed to prepare video preview", error: error)
      showVideoError(error)
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

    Task { [weak self, weak picker] in
      guard let self, let picker else { return }

      let loadedItems = await loadUnifiedPickerSelections(results)

      await MainActor.run { [weak self, weak picker] in
        guard let self, let picker else { return }

        guard !loadedItems.isEmpty else {
          picker.dismiss(animated: true) { [weak self] in
            self?.isPickerPresented = false
          }
          return
        }

        let photoItems = loadedItems.compactMap(\.image)
        let videoItems = loadedItems.compactMap(\.videoURL)

        if videoItems.isEmpty {
          if photoItems.count == 1, let image = photoItems.first {
            presentSinglePhotoPreview(image, picker: picker)
          } else {
            presentPhotoBatchPreview(photoItems, picker: picker)
          }
          return
        }

        if photoItems.isEmpty, videoItems.count == 1, let url = videoItems.first {
          presentVideoPreview(with: [url], presenter: picker)
          return
        }

        presentMixedMediaPreview(
          with: loadedItems.map(\.previewItem),
          presenter: picker
        )
      }
    }
  }

  private struct LoadedLibraryItem {
    let index: Int
    let payload: Payload

    enum Payload {
      case photo(UIImage)
      case video(URL)
    }

    var image: UIImage? {
      guard case let .photo(image) = payload else { return nil }
      return image
    }

    var videoURL: URL? {
      guard case let .video(url) = payload else { return nil }
      return url
    }

    var previewItem: MixedMediaPreviewItem {
      switch payload {
        case let .photo(image):
          .photo(id: UUID(), image: image)
        case let .video(url):
          .video(id: UUID(), url: url)
      }
    }
  }

  private func loadUnifiedPickerSelections(_ results: [PHPickerResult]) async -> [LoadedLibraryItem] {
    var loadedItems: [LoadedLibraryItem] = []

    await withTaskGroup(of: LoadedLibraryItem?.self) { group in
      for (index, result) in results.enumerated() {
        group.addTask { [weak self] in
          guard let self else { return nil }
          return await self.loadUnifiedPickerSelection(result, index: index)
        }
      }

      for await item in group {
        if let item {
          loadedItems.append(item)
        }
      }
    }

    return loadedItems.sorted { $0.index < $1.index }
  }

  private func loadUnifiedPickerSelection(
    _ result: PHPickerResult,
    index: Int
  ) async -> LoadedLibraryItem? {
    if let videoURL = await loadVideoPreviewURL(from: result) {
      return LoadedLibraryItem(index: index, payload: .video(videoURL))
    }

    let provider = result.itemProvider
    if provider.canLoadObject(ofClass: UIImage.self),
       let image = await loadUIImage(from: provider) {
      return LoadedLibraryItem(index: index, payload: .photo(image))
    }

    return nil
  }

  private func loadUIImage(from provider: NSItemProvider) async -> UIImage? {
    await withCheckedContinuation { continuation in
      provider.loadObject(ofClass: UIImage.self) { object, error in
        if let error {
          Log.shared.error("Failed to load image from picker", error: error)
          continuation.resume(returning: nil)
          return
        }

        continuation.resume(returning: object as? UIImage)
      }
    }
  }

  private func presentSinglePhotoPreview(_ image: UIImage, picker: PHPickerViewController) {
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
    previewVC.modalPresentationStyle = .fullScreen
    previewVC.modalTransitionStyle = .crossDissolve
    picker.present(previewVC, animated: true)
  }

  private func presentPhotoBatchPreview(_ images: [UIImage], picker: PHPickerViewController) {
    guard !images.isEmpty else {
      picker.dismiss(animated: true) { [weak self] in
        self?.isPickerPresented = false
      }
      return
    }

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
    picker.present(previewVC, animated: true)
  }

  private func loadVideoPreviewURL(from result: PHPickerResult) async -> URL? {
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

        do {
          let temporaryURL = try self.copyVideoToTemporaryPreviewURL(from: url)
          continuation.resume(returning: temporaryURL)
        } catch {
          Log.shared.error("Failed to copy video file from picker", error: error)
          continuation.resume(returning: nil)
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
