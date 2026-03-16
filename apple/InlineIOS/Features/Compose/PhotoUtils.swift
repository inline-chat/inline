import AVFoundation
import InlineKit
import Photos
import Logger
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private func immediateVideoThumbnail(from url: URL) -> UIImage? {
  let hasAccess = url.startAccessingSecurityScopedResource()
  defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

  let asset = AVURLAsset(url: url)
  let generator = AVAssetImageGenerator(asset: asset)
  generator.appliesPreferredTrackTransform = true

  let durationSeconds = CMTimeGetSeconds(asset.duration)
  let sampleSecond: Double = if durationSeconds.isFinite, durationSeconds > 0 {
    min(max(durationSeconds * 0.1, 0.1), 1.0)
  } else {
    0.5
  }
  let time = CMTime(seconds: sampleSecond, preferredTimescale: 600)

  guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
    return nil
  }

  return UIImage(cgImage: cgImage)
}

extension ComposeView: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private func shouldSendAsFile(_ image: UIImage) -> Bool {
    let width = max(image.size.width, 1)
    let height = max(image.size.height, 1)
    let ratio = max(width / height, height / width)
    return ratio > 20 || (width < 50 && height < 50)
  }

  private func makeImageAttachment(_ image: UIImage, optimizePhoto: Bool) throws -> FileMediaItem {
    if shouldSendAsFile(image) {
      let tempDirectory = FileHelpers.getTrueTemporaryDirectory()
      let fileName = "image-\(UUID().uuidString).jpg"
      let (_, tempURL) = try image.save(to: tempDirectory, withName: fileName, format: .jpeg)
      defer { try? FileManager.default.removeItem(at: tempURL) }
      return .document(try FileCache.saveDocument(url: tempURL))
    }

    return .photo(try FileCache.savePhoto(image: image, optimize: optimizePhoto))
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

  private func presentSingleImagePreview(_ image: UIImage, presenter: UIViewController? = nil) {
    guard !previewViewModel.isPresented, !multiPhotoPreviewViewModel.isPresented else { return }
    guard let resolvedPresenter = presenter ?? attachmentFlowPresenter() else { return }

    selectedImage = image
    previewViewModel.isPresented = true
    currentPreviewUsesAttachmentPicker = attachmentPickerViewController != nil

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

    resolvedPresenter.present(previewVC, animated: true)
  }

  private func presentMultiImagePreview(_ images: [UIImage], presenter: UIViewController? = nil) {
    guard !images.isEmpty else { return }
    guard !previewViewModel.isPresented, !multiPhotoPreviewViewModel.isPresented else { return }
    guard let resolvedPresenter = presenter ?? attachmentFlowPresenter() else { return }

    multiPhotoPreviewViewModel.setPhotos(images)
    multiPhotoPreviewViewModel.isPresented = true
    currentPreviewUsesAttachmentPicker = attachmentPickerViewController != nil

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

    resolvedPresenter.present(previewVC, animated: true)
  }

  // MARK: - UIImagePickerControllerDelegate

  func presentPicker() {
    guard !isPickerPresented, let presenter = attachmentFlowPresenter() else { return }

    activePickerMode = .photos

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .any(of: [.images, .videos])
    configuration.selectionLimit = 30

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    isPickerPresented = true

    presenter.present(picker, animated: true)
  }

  func presentVideoPicker() {
    guard !isPickerPresented, let presenter = attachmentFlowPresenter() else { return }

    activePickerMode = .videos

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .videos
    configuration.selectionLimit = 10

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    isPickerPresented = true

    presenter.present(picker, animated: true)
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
    guard let presenter = attachmentFlowPresenter() else { return }

    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
    picker.videoQuality = .typeHigh
    picker.videoExportPreset = AVAssetExportPresetPassthrough
    picker.delegate = self
    picker.allowsEditing = false

    presenter.present(picker, animated: true)
  }

  func handleDroppedImage(_ image: UIImage) {
    addImages([image])
  }

  func handleMultipleDroppedImages(_ images: [UIImage]) {
    guard !images.isEmpty else { return }
    addImages(images)
  }

  func dismissPreview(dismissAttachmentPicker: Bool = false) {
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

    let finalizeDismissal: () -> Void = { [weak self] in
      guard let self else { return }
      self.selectedImage = nil
      self.previewViewModel.caption = ""
      self.previewViewModel.isPresented = false
      self.currentPreviewUsesAttachmentPicker = false

      if dismissAttachmentPicker {
        self.dismissAttachmentPickerIfPresented(animated: true)
      }
    }

    topmostVC.dismiss(animated: true) { [weak self] in
      if let picker {
        picker.dismiss(animated: true) { [weak self] in
          self?.isPickerPresented = false
          finalizeDismissal()
        }
      } else {
        finalizeDismissal()
      }
    }
  }

  func dismissMultiPreview(dismissAttachmentPicker: Bool = false) {
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

    let finalizeDismissal: () -> Void = { [weak self] in
      guard let self else { return }
      self.multiPhotoPreviewViewModel.photoItems.removeAll()
      self.multiPhotoPreviewViewModel.currentIndex = 0
      self.multiPhotoPreviewViewModel.isPresented = false
      self.currentPreviewUsesAttachmentPicker = false

      if dismissAttachmentPicker {
        self.dismissAttachmentPickerIfPresented(animated: true)
      }
    }

    topmostVC.dismiss(animated: true) { [weak self] in
      if let picker {
        picker.dismiss(animated: true) { [weak self] in
          self?.isPickerPresented = false
          finalizeDismissal()
        }
      } else {
        finalizeDismissal()
      }
    }
  }

  func sendImage(_ image: UIImage, caption: String) {
    guard let peerId else { return }

    sendButton.configuration?.showsActivityIndicator = true
    clearAttachments()

    do {
      let mediaItem = try makeImageAttachment(image, optimizePhoto: false)
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
    dismissPreview(dismissAttachmentPicker: currentPreviewUsesAttachmentPicker)
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
        let mediaItem = try makeImageAttachment(photoItem.image, optimizePhoto: true)

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
    dismissMultiPreview(dismissAttachmentPicker: currentPreviewUsesAttachmentPicker)
    sendButton.configuration?.showsActivityIndicator = false
    clearAttachments()
    ChatState.shared.clearReplyingMessageId(peer: peerId)
    // sendMessageHaptic()
  }

  func handlePastedImage() {
    guard let image = UIPasteboard.general.image else { return }
    addImages([image])
  }

  func addImage(_ image: UIImage) {
    addImages([image])
  }

  func addImages(_ images: [UIImage]) {
    guard !images.isEmpty else { return }

    var didAddAny = false
    for image in images {
      do {
        let mediaItem = try makeImageAttachment(image, optimizePhoto: true)
        let uniqueId = mediaItem.getItemUniqueId()
        attachmentItems[uniqueId] = mediaItem
        didAddAny = true
        Log.shared.debug("Added image attachment with uniqueId: \(uniqueId)")
      } catch {
        Log.shared.error("Failed to save photo in attachments", error: error)
      }
    }

    if didAddAny {
      handleAttachmentItemsChanged()
    }
  }

  func addVideo(_ url: URL, removeSourceAfterProcessing: Bool = false) {
    sendButton.configuration?.showsActivityIndicator = true
    let pendingId = addPendingVideoAttachment()
    Task {
      defer {
        if removeSourceAfterProcessing {
          try? FileManager.default.removeItem(at: url)
        }
      }

      do {
        let immediateThumbnail = immediateVideoThumbnail(from: url)
        if let immediateThumbnail {
          await MainActor.run { [weak self] in
            self?.updatePendingVideoAttachmentThumbnail(pendingId, image: immediateThumbnail)
          }
        }

        let videoInfo = try await FileCache.saveVideo(url: url, thumbnail: immediateThumbnail)
        let mediaItem = FileMediaItem.video(videoInfo)

        await MainActor.run { [weak self] in
          guard let self else { return }
          let isCanceled = isPendingVideoAttachmentCanceled(pendingId)
          removePendingVideoAttachment(pendingId, animated: false)
          guard !isCanceled else {
            sendButton.configuration?.showsActivityIndicator = false
            return
          }
          _ = addAttachmentItem(mediaItem)
          sendButton.configuration?.showsActivityIndicator = false
          dismissAttachmentPickerIfPresented(animated: true)
        }
      } catch {
        Log.shared.error("Failed to save video", error: error)
        await MainActor.run { [weak self] in
          self?.removePendingVideoAttachment(pendingId, animated: false)
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

    attachmentFlowPresenter()?.present(alert, animated: true)
  }

  func openRecentAsset(localIdentifier: String) {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = assets.firstObject else {
      showRecentAssetError(message: "Couldn't load that recent media.")
      return
    }

    if asset.mediaType == .video {
      loadRecentVideoAsset(asset)
      return
    }

    guard asset.mediaType == .image else {
      showRecentAssetError(message: "Unsupported recent media type.")
      return
    }

    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .none
    options.isNetworkAccessAllowed = true
    options.version = .current

    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { [weak self] data, _, _, info in
      if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
        return
      }

      guard let data, let image = UIImage(data: data) else {
        DispatchQueue.main.async {
          self?.showRecentAssetError(message: "Couldn't open that recent photo.")
        }
        return
      }

      DispatchQueue.main.async {
        self?.addImages([image])
        self?.dismissAttachmentPickerIfPresented(animated: true)
      }
    }
  }

  private func loadRecentVideoAsset(_ asset: PHAsset) {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource = resources.first(where: { [.fullSizeVideo, .video, .pairedVideo].contains($0.type) }) else {
      showRecentAssetError(message: "Couldn't open that recent video.")
      return
    }

    let fileExtension = URL(fileURLWithPath: resource.originalFilename).pathExtension
    let resolvedExtension = fileExtension.isEmpty ? "mov" : fileExtension
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(resolvedExtension)

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true

    PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: options) { [weak self] error in
      if let error {
        try? FileManager.default.removeItem(at: tempURL)
        DispatchQueue.main.async {
          self?.showRecentAssetError(message: "Couldn't open that recent video: \(error.localizedDescription)")
        }
        return
      }

      DispatchQueue.main.async {
        self?.addVideo(tempURL, removeSourceAfterProcessing: true)
        self?.dismissAttachmentPickerIfPresented(animated: true)
      }
    }
  }

  private func showRecentAssetError(message: String) {
    let alert = UIAlertController(
      title: "Media Error",
      message: message,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))

    attachmentFlowPresenter()?.present(alert, animated: true)
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

    handleLibraryPickerResults(results, picker: picker)
  }

  private enum LibraryPickerItem {
    case image(UIImage)
    case video(FileMediaItem)
  }

  private func handleLibraryPickerResults(_ results: [PHPickerResult], picker: PHPickerViewController) {
    var pendingVideoIdsByIndex: [Int: String] = [:]
    for (index, result) in results.enumerated() where isVideoResult(result) {
      let pendingId = addPendingVideoAttachment()
      pendingVideoIdsByIndex[index] = pendingId
      requestPendingVideoThumbnail(for: result, pendingId: pendingId)
    }

    Task { [weak self, weak picker] in
      guard let self, let picker else { return }

      var loadedItems: [(index: Int, item: LibraryPickerItem)] = []

      await withTaskGroup(of: (Int, LibraryPickerItem?).self) { group in
        for (index, result) in results.enumerated() {
          group.addTask { [weak self] in
            guard let self else { return (index, nil) }
            let item = await self.loadLibraryItem(from: result)
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

        for pendingId in pendingVideoIdsByIndex.values {
          removePendingVideoAttachment(pendingId, animated: false)
        }

        let sortedEntries = loadedItems.sorted { $0.index < $1.index }
        guard !sortedEntries.isEmpty else {
          picker.dismiss(animated: true) { [weak self] in
            self?.isPickerPresented = false
          }
          return
        }

        var didAddAny = false
        for entry in sortedEntries {
          let item = entry.item
          switch item {
            case let .image(image):
              do {
                let mediaItem = try makeImageAttachment(image, optimizePhoto: true)
                let uniqueId = mediaItem.getItemUniqueId()
                attachmentItems[uniqueId] = mediaItem
                didAddAny = true
              } catch {
                Log.shared.error("Failed to save photo in attachments", error: error)
              }
            case let .video(videoItem):
              if let pendingId = pendingVideoIdsByIndex[entry.index], isPendingVideoAttachmentCanceled(pendingId) {
                continue
              }
              let uniqueId = videoItem.getItemUniqueId()
              attachmentItems[uniqueId] = videoItem
              didAddAny = true
          }
        }

        if didAddAny {
          handleAttachmentItemsChanged(animated: false)
        }

        picker.dismiss(animated: true) { [weak self] in
          guard let self else { return }
          isPickerPresented = false
          dismissAttachmentPickerIfPresented(animated: true)
        }
      }
    }
  }

  private func handleVideoPickerResults(_ results: [PHPickerResult], picker: PHPickerViewController) {
    var pendingVideoIdsByIndex: [Int: String] = [:]
    for (index, result) in results.enumerated() {
      let pendingId = addPendingVideoAttachment()
      pendingVideoIdsByIndex[index] = pendingId
      requestPendingVideoThumbnail(for: result, pendingId: pendingId)
    }

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

        for pendingId in pendingVideoIdsByIndex.values {
          removePendingVideoAttachment(pendingId, animated: false)
        }

        let sortedEntries = loadedItems.sorted { $0.index < $1.index }
        guard !sortedEntries.isEmpty else {
          picker.dismiss(animated: true) { [weak self] in
            self?.isPickerPresented = false
          }
          return
        }

        for entry in sortedEntries {
          if let pendingId = pendingVideoIdsByIndex[entry.index], isPendingVideoAttachmentCanceled(pendingId) {
            continue
          }
          let item = entry.item
          let uniqueId = item.getItemUniqueId()
          attachmentItems[uniqueId] = item
        }
        handleAttachmentItemsChanged(animated: false)

        picker.dismiss(animated: true) { [weak self] in
          guard let self else { return }
          isPickerPresented = false
          dismissAttachmentPickerIfPresented(animated: true)
        }
      }
    }
  }

  private func loadLibraryItem(from result: PHPickerResult) async -> LibraryPickerItem? {
    switch pickerAssetMediaType(for: result) {
      case .video:
        if let item = await loadVideoItem(from: result) {
          return .video(item)
        }
      case .image:
        if let image = await loadImageItem(from: result) {
          return .image(image)
        }
      case .none, .some(.unknown):
        break
      @unknown default:
        break
    }

    if let image = await loadImageItem(from: result) {
      return .image(image)
    }

    if let item = await loadVideoItem(from: result) {
      return .video(item)
    }

    return nil
  }

  private func pickerAssetMediaType(for result: PHPickerResult) -> PHAssetMediaType? {
    guard let assetIdentifier = result.assetIdentifier else { return nil }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
    return assets.firstObject?.mediaType
  }

  private func isVideoResult(_ result: PHPickerResult) -> Bool {
    let provider = result.itemProvider
    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ||
        provider.hasItemConformingToTypeIdentifier(UTType.video.identifier)
    {
      return true
    }

    return pickerAssetMediaType(for: result) == .video
  }

  private func requestPendingVideoThumbnail(for result: PHPickerResult, pendingId: String) {
    let provider = result.itemProvider
    _ = provider.loadPreviewImage(options: nil) { [weak self] object, _ in
      let image: UIImage?
      if let previewImage = object as? UIImage {
        image = previewImage
      } else if let url = object as? URL {
        image = UIImage(contentsOfFile: url.path)
      } else if let nsUrl = object as? NSURL, let path = nsUrl.path {
        image = UIImage(contentsOfFile: path)
      } else {
        image = nil
      }

      guard let image else { return }
      DispatchQueue.main.async {
        self?.updatePendingVideoAttachmentThumbnail(pendingId, image: image)
      }
    }

    guard let assetIdentifier = result.assetIdentifier else { return }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
    guard let asset = assets.firstObject, asset.mediaType == .video else { return }

    let requestOptions = PHImageRequestOptions()
    requestOptions.deliveryMode = .opportunistic
    requestOptions.resizeMode = .fast
    requestOptions.isNetworkAccessAllowed = true

    PHImageManager.default().requestImage(
      for: asset,
      targetSize: CGSize(width: 220, height: 220),
      contentMode: .aspectFill,
      options: requestOptions
    ) { [weak self] image, _ in
      guard let image else { return }
      DispatchQueue.main.async {
        self?.updatePendingVideoAttachmentThumbnail(pendingId, image: image)
      }
    }
  }

  private func loadImageItem(from result: PHPickerResult) async -> UIImage? {
    await withCheckedContinuation { continuation in
      result.itemProvider.loadObject(ofClass: UIImage.self) { object, error in
        if let error {
          Log.shared.error("Failed to load image from picker", error: error)
          continuation.resume(returning: nil)
          return
        }

        continuation.resume(returning: object as? UIImage)
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
            let immediateThumbnail = immediateVideoThumbnail(from: tempUrl)
            let videoInfo = try await FileCache.saveVideo(url: tempUrl, thumbnail: immediateThumbnail)
            continuation.resume(returning: .video(videoInfo))
          } catch {
            Log.shared.error("Failed to save video from picker", error: error)
            continuation.resume(returning: nil)
          }
        }
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
        self?.addImages([image])
        self?.dismissAttachmentPickerIfPresented(animated: true)
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
