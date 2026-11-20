import AVFoundation
import Auth
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
  private enum RecentAssetLoadError: Error {
    case message(String)

    var message: String {
      switch self {
      case let .message(message):
        return message
      }
    }
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

  func handlePastedImage() {
    if let gifData = UIPasteboard.general.data(forPasteboardType: UTType.gif.identifier) ??
      UIPasteboard.general.data(forPasteboardType: "com.compuserve.gif") ??
      UIPasteboard.general.data(forPasteboardType: "image/gif")
    {
      let tempUrl = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("gif")
      do {
        try gifData.write(to: tempUrl)
        addAnimatedImageAsVideo(tempUrl, removeSourceAfterProcessing: true)
        return
      } catch {
        Log.shared.error("Failed to write pasted GIF data", error: error)
      }
    }

    // Encoded bytes keep the camera details that pick the size, and serve as the original.
    let pasteboard = UIPasteboard.general
    for type in [UTType.heic, UTType.jpeg, UTType.png, UTType.webP, UTType.tiff] {
      if let data = pasteboard.data(forPasteboardType: type.identifier) {
        addPhotos([(.data(data), nil)])
        return
      }
    }
    guard let image = pasteboard.image else { return }
    addImages([image])
  }

  func addImage(_ image: UIImage) {
    addImages([image])
  }

  func addImages(_ images: [UIImage], content: MediaSendPreparation.PhotoContent? = nil) {
    addPhotos(images.map { (MediaSendPreparation.PhotoSource.platformImage($0), nil) }, content: content)
  }

  /// Prepares photos off the main thread (resized for their content, no metadata) and adds them
  /// in the order given.
  func addPhotos(
    _ sources: [(source: MediaSendPreparation.PhotoSource, fileName: String?)],
    content: MediaSendPreparation.PhotoContent? = nil
  ) {
    guard !sources.isEmpty else { return }
    Task { [weak self] in
      let items = await Self.preparePhotos(sources, content: content)
      guard let self, !items.isEmpty else { return }
      for item in items {
        attachmentItems[item.getItemUniqueId()] = item
      }
      handleAttachmentItemsChanged(animated: false)
    }
  }

  nonisolated static func preparePhotos(
    _ sources: [(source: MediaSendPreparation.PhotoSource, fileName: String?)],
    content: MediaSendPreparation.PhotoContent? = nil
  ) async -> [FileMediaItem] {
    await withTaskGroup(of: (Int, FileMediaItem?).self) { group in
      for (index, entry) in sources.enumerated() {
        group.addTask {
          do {
            let item = try await AttachmentMediaMaterializer.photo(
              entry.source,
              originalFileName: entry.fileName,
              content: content
            )
            return (index, item)
          } catch {
            Log.shared.error("Failed to save photo in attachments", error: error)
            return (index, nil)
          }
        }
      }
      var prepared: [(Int, FileMediaItem)] = []
      for await (index, item) in group {
        if let item { prepared.append((index, item)) }
      }
      return prepared.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  func addVideo(
    _ url: URL,
    removeSourceAfterProcessing: Bool = false,
    dismissAttachmentPickerOnSuccess: Bool = true
  ) {
    guard canAttachFileToCurrentMessage() else { return }
    guard let destinationPeer = peerId, let destinationChat = chatId,
          let account = try? Auth.shared.handle.beginAccountMutation() else { return }
    stageVideoAttachment(
      url,
      removeSourceAfterProcessing: removeSourceAfterProcessing,
      dismissAttachmentPickerOnSuccess: dismissAttachmentPickerOnSuccess
    ) { [weak self] in
      self?.peerId == destinationPeer && self?.chatId == destinationChat &&
        (try? Auth.shared.handle.validateAccountMutation(account)) != nil
    }
  }

  @discardableResult
  func stageVideoAttachment(
    _ url: URL,
    removeSourceAfterProcessing: Bool = false,
    dismissAttachmentPickerOnSuccess: Bool = true,
    loadVideo: @escaping @MainActor (URL, UIImage?) async throws -> VideoInfo = {
      try await FileCache.saveVideo(url: $0, thumbnail: $1)
    },
    isCurrentDestination: @escaping @MainActor () -> Bool
  ) -> Task<Void, Never> {
    guard canAttachFileToCurrentMessage() else { return Task {} }
    let pendingId = addPendingVideoAttachment()
    let hasAccess = url.startAccessingSecurityScopedResource()
    return Task { @MainActor [weak self] in
      defer {
        if hasAccess { url.stopAccessingSecurityScopedResource() }
        if removeSourceAfterProcessing {
          try? FileManager.default.removeItem(at: url)
        }
      }

      guard let self else { return }
      do {
        let immediateThumbnail = immediateVideoThumbnail(from: url)
        if let immediateThumbnail, isCurrentDestination() {
          updatePendingVideoAttachmentThumbnail(pendingId, image: immediateThumbnail)
        }

        let videoInfo = try await loadVideo(url, immediateThumbnail)
        let mediaItem = FileMediaItem.video(videoInfo)

        guard !isPendingVideoAttachmentCanceled(pendingId) else {
          finishPendingVideoAttachmentProcessing(pendingId)
          return
        }
        guard isCurrentDestination() else {
          cancelQueuedPendingVideoSend()
          completePendingVideoAttachments([pendingId])
          return
        }
        guard canAttachFileToCurrentMessage() else {
          cancelQueuedPendingVideoSend()
          completePendingVideoAttachments([pendingId])
          return
        }
        addAttachmentItem(mediaItem)
        completePendingVideoAttachments([pendingId])

        if dismissAttachmentPickerOnSuccess {
          dismissAttachmentPickerIfPresented(animated: true)
        }
      } catch {
        Log.shared.error("Failed to save video", error: error)
        guard !isPendingVideoAttachmentCanceled(pendingId) else {
          finishPendingVideoAttachmentProcessing(pendingId)
          return
        }
        cancelQueuedPendingVideoSend()
        completePendingVideoAttachments([pendingId])
        guard isCurrentDestination() else { return }
        showVideoError(error)
      }
    }
  }

  func addAnimatedImageAsVideo(
    _ url: URL,
    removeSourceAfterProcessing: Bool = false,
    dismissAttachmentPickerOnSuccess: Bool = true
  ) {
    let pendingId = addPendingVideoAttachment()
    Task {
      defer {
        if removeSourceAfterProcessing {
          try? FileManager.default.removeItem(at: url)
        }
      }

      do {
        let videoInfo = try await FileCache.saveAnimatedImageAsVideo(url: url)
        let mediaItem = FileMediaItem.video(videoInfo)

        await MainActor.run { [weak self] in
          guard let self else { return }
          let isCanceled = isPendingVideoAttachmentCanceled(pendingId)
          guard !isCanceled else {
            finishPendingVideoAttachmentProcessing(pendingId)
            return
          }

          let uniqueId = mediaItem.getItemUniqueId()
          attachmentItems[uniqueId] = mediaItem
          completePendingVideoAttachments([pendingId])
          if dismissAttachmentPickerOnSuccess {
            dismissAttachmentPickerIfPresented(animated: true)
          }
        }
      } catch AnimatedImageVideoConversionError.notAnimated {
        // A still image after all: send it as a photo, prepared from the file.
        let mediaItem = try? await AttachmentMediaMaterializer.photo(.file(url), originalFileName: url.lastPathComponent)
        await MainActor.run { [weak self] in
          guard let self else { return }
          guard !isPendingVideoAttachmentCanceled(pendingId) else {
            finishPendingVideoAttachmentProcessing(pendingId)
            if case let .photo(photoInfo)? = mediaItem {
              Task { await FileCache.discardLocalPhoto(photoInfo) }
            }
            return
          }
          guard let mediaItem else {
            Log.shared.error("Failed to save animated image fallback")
            cancelQueuedPendingVideoSend()
            completePendingVideoAttachments([pendingId])
            return
          }
          attachmentItems[mediaItem.getItemUniqueId()] = mediaItem
          completePendingVideoAttachments([pendingId])
        }
      } catch {
        Log.shared.error("Failed to save animated image as video", error: error)
        await MainActor.run { [weak self] in
          self?.cancelQueuedPendingVideoSend()
          self?.completePendingVideoAttachments([pendingId])
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
    guard localIdentifier.isEmpty == false else { return }

    Task { [weak self] in
      guard let self else { return }

      let result = await self.loadRecentAssetMediaItem(localIdentifier: localIdentifier)

      await MainActor.run { [weak self] in
        guard let self else { return }

        switch result {
        case let .success(mediaItem):
          let uniqueId = mediaItem.getItemUniqueId()
          attachmentItems[uniqueId] = mediaItem
          handleAttachmentItemsChanged(animated: false)
          dismissAttachmentPickerIfPresented(animated: true)
        case let .failure(error):
          showRecentAssetError(message: error.message)
        }
      }
    }
  }

  func openRecentAssets(localIdentifiers: [String]) {
    let validIdentifiers = localIdentifiers.filter { $0.isEmpty == false }
    guard validIdentifiers.isEmpty == false else { return }

    dismissAttachmentPickerIfPresented(animated: true)

    Task { [weak self] in
      guard let self else { return }

      var orderedMediaItems: [FileMediaItem] = []
      var firstErrorMessage: String?

      for identifier in validIdentifiers {
        let result = await self.loadRecentAssetMediaItem(localIdentifier: identifier)
        switch result {
        case let .success(mediaItem):
          orderedMediaItems.append(mediaItem)
        case let .failure(error):
          let message = error.message
          if firstErrorMessage == nil {
            firstErrorMessage = message
          }
        }
      }

      await MainActor.run { [weak self] in
        guard let self else { return }

        if orderedMediaItems.isEmpty == false {
          for mediaItem in orderedMediaItems {
            let uniqueId = mediaItem.getItemUniqueId()
            attachmentItems[uniqueId] = mediaItem
          }
          handleAttachmentItemsChanged(animated: false)
        }

        if let firstErrorMessage {
          showRecentAssetError(message: firstErrorMessage)
        }
      }
    }
  }

  private func loadRecentAssetMediaItem(localIdentifier: String) async -> Result<FileMediaItem, RecentAssetLoadError> {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = assets.firstObject else {
      return .failure(.message("Couldn't load that recent media."))
    }

    if asset.mediaType == .video {
      return await loadRecentVideoMediaItem(from: asset)
    }

    guard asset.mediaType == .image else {
      return .failure(.message("Unsupported recent media type."))
    }

    guard let data = await loadRecentImageData(from: asset) else {
      return .failure(.message("Couldn't open that recent photo."))
    }

    do {
      let fileName = PHAssetResource.assetResources(for: asset)
        .first { $0.type == .photo || $0.type == .fullSizePhoto }?.originalFilename
      let mediaItem = try await AttachmentMediaMaterializer.photo(.data(data), originalFileName: fileName)
      return .success(mediaItem)
    } catch {
      Log.shared.error("Failed to save photo in attachments", error: error)
      return .failure(.message("Couldn't open that recent photo."))
    }
  }

  private func loadRecentImageData(from asset: PHAsset) async -> Data? {
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .none
    options.isNetworkAccessAllowed = true
    options.version = .current

    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
        if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
          continuation.resume(returning: nil)
          return
        }

        continuation.resume(returning: data)
      }
    }
  }

  private func loadRecentVideoMediaItem(from asset: PHAsset) async -> Result<FileMediaItem, RecentAssetLoadError> {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource = resources.first(where: { [.fullSizeVideo, .video, .pairedVideo].contains($0.type) }) else {
      return .failure(.message("Couldn't open that recent video."))
    }

    let fileExtension = URL(fileURLWithPath: resource.originalFilename).pathExtension
    let resolvedExtension = fileExtension.isEmpty ? "mov" : fileExtension
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(resolvedExtension)

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true

    let writeError: Error? = await withCheckedContinuation { continuation in
      PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: options) { error in
        continuation.resume(returning: error)
      }
    }

    if let writeError {
      try? FileManager.default.removeItem(at: tempURL)
      return .failure(.message("Couldn't open that recent video: \(writeError.localizedDescription)"))
    }

    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }

    do {
      let immediateThumbnail = immediateVideoThumbnail(from: tempURL)
      let videoInfo = try await FileCache.saveVideo(url: tempURL, thumbnail: immediateThumbnail)
      return .success(.video(videoInfo))
    } catch {
      Log.shared.error("Failed to save video", error: error)
      return .failure(.message("Couldn't open that recent video: \(error.localizedDescription)"))
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
    case photo(FileMediaItem)
    case video(FileMediaItem)
  }

  private func handleLibraryPickerResults(_ results: [PHPickerResult], picker: PHPickerViewController) {
    var pendingVideoIdsByIndex: [Int: String] = [:]
    for (index, result) in results.enumerated() where isVideoResult(result) || isGIFResult(result) {
      let pendingId = addPendingVideoAttachment()
      pendingVideoIdsByIndex[index] = pendingId
      requestPendingVideoThumbnail(for: result, pendingId: pendingId)
    }

    Task { [weak self, weak picker] in
      guard let self else { return }

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
        guard let self else { return }

        if loadedItems.count != results.count {
          cancelQueuedPendingVideoSend()
        }

        let sortedEntries = loadedItems.sorted { $0.index < $1.index }
        guard !sortedEntries.isEmpty else {
          completePendingVideoAttachments(Array(pendingVideoIdsByIndex.values))
          if let picker {
            picker.dismiss(animated: true) { [weak self] in
              self?.isPickerPresented = false
            }
          } else {
            isPickerPresented = false
          }
          return
        }

        for entry in sortedEntries {
          let item = entry.item
          switch item {
          case let .photo(mediaItem):
            attachmentItems[mediaItem.getItemUniqueId()] = mediaItem
          case let .video(videoItem):
            if let pendingId = pendingVideoIdsByIndex[entry.index], isPendingVideoAttachmentCanceled(pendingId) {
              continue
            }
            let uniqueId = videoItem.getItemUniqueId()
            attachmentItems[uniqueId] = videoItem
          }
        }

        completePendingVideoAttachments(Array(pendingVideoIdsByIndex.values))

        guard let picker else {
          isPickerPresented = false
          dismissAttachmentPickerIfPresented(animated: true)
          return
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
      guard let self else { return }

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
        guard let self else { return }

        if loadedItems.count != results.count {
          cancelQueuedPendingVideoSend()
        }

        let sortedEntries = loadedItems.sorted { $0.index < $1.index }
        guard !sortedEntries.isEmpty else {
          completePendingVideoAttachments(Array(pendingVideoIdsByIndex.values))
          if let picker {
            picker.dismiss(animated: true) { [weak self] in
              self?.isPickerPresented = false
            }
          } else {
            isPickerPresented = false
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

        completePendingVideoAttachments(Array(pendingVideoIdsByIndex.values))

        guard let picker else {
          isPickerPresented = false
          dismissAttachmentPickerIfPresented(animated: true)
          return
        }
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
        if let item = await loadAnimatedImageVideoItem(from: result) {
          return .video(item)
        }
        if let item = await loadPhotoItem(from: result) {
          return .photo(item)
        }
      case .none, .some(.unknown):
        break
      @unknown default:
        break
    }

    if let item = await loadPhotoItem(from: result) {
      return .photo(item)
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

  private func isGIFResult(_ result: PHPickerResult) -> Bool {
    gifTypeIdentifier(for: result.itemProvider) != nil
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

  /// Loads the picked file itself (HEIC, JPEG, PNG…): its camera details pick the size it's
  /// sent at, and it is kept as the original. Falls back to a decoded image.
  private nonisolated func loadPhotoItem(from result: PHPickerResult) async -> FileMediaItem? {
    let provider = result.itemProvider
    if let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
      UTType($0)?.conforms(to: .image) == true
    }),
      let file = await loadPhotoFileRepresentation(provider, typeIdentifier: typeIdentifier)
    {
      defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
      do {
        return try await AttachmentMediaMaterializer.photo(.file(file), originalFileName: file.lastPathComponent)
      } catch {
        Log.shared.error("Failed to prepare picked photo file", error: error)
      }
    }

    let image: UIImage? = await withCheckedContinuation { continuation in
      provider.loadObject(ofClass: UIImage.self) { object, error in
        if let error {
          Log.shared.error("Failed to load image from picker", error: error)
        }
        continuation.resume(returning: object as? UIImage)
      }
    }
    guard let image else { return nil }
    return try? await AttachmentMediaMaterializer.photo(.platformImage(image))
  }

  /// Copies the provider's file before its callback returns, when the system deletes it.
  private nonisolated func loadPhotoFileRepresentation(_ provider: NSItemProvider, typeIdentifier: String) async -> URL? {
    await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
        guard let url else {
          if let error { Log.shared.error("Failed to load picked photo file", error: error) }
          continuation.resume(returning: nil)
          return
        }
        let folder = FileHelpers.getTrueTemporaryDirectory()
          .appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
        do {
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let copy = folder.appendingPathComponent(url.lastPathComponent)
          try FileManager.default.copyItem(at: url, to: copy)
          continuation.resume(returning: copy)
        } catch {
          Log.shared.error("Failed to copy picked photo file", error: error)
          try? FileManager.default.removeItem(at: folder)
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private func loadAnimatedImageVideoItem(from result: PHPickerResult) async -> FileMediaItem? {
    let provider = result.itemProvider
    guard let typeIdentifier = gifTypeIdentifier(for: provider) else { return nil }

    if let item = await loadAnimatedImageVideoFileRepresentation(from: provider, typeIdentifier: typeIdentifier) {
      return item
    }

    return await loadAnimatedImageVideoDataRepresentation(from: provider, typeIdentifier: typeIdentifier)
  }

  private func loadAnimatedImageVideoFileRepresentation(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async -> FileMediaItem? {
    await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
        if let error {
          Log.shared.error("Failed to load GIF file from picker", error: error)
          continuation.resume(returning: nil)
          return
        }

        guard let url else {
          continuation.resume(returning: nil)
          return
        }

        let tempUrl = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension("gif")

        do {
          try FileManager.default.copyItem(at: url, to: tempUrl)
        } catch {
          Log.shared.error("Failed to copy GIF file from picker", error: error)
          continuation.resume(returning: nil)
          return
        }

        Task {
          defer { try? FileManager.default.removeItem(at: tempUrl) }
          do {
            let videoInfo = try await FileCache.saveAnimatedImageAsVideo(url: tempUrl)
            continuation.resume(returning: .video(videoInfo))
          } catch AnimatedImageVideoConversionError.notAnimated {
            continuation.resume(returning: nil)
          } catch {
            Log.shared.error("Failed to convert GIF from picker", error: error)
            continuation.resume(returning: nil)
          }
        }
      }
    }
  }

  private func loadAnimatedImageVideoDataRepresentation(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async -> FileMediaItem? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
        if let error {
          Log.shared.error("Failed to load GIF data from picker", error: error)
          continuation.resume(returning: nil)
          return
        }

        guard let data else {
          continuation.resume(returning: nil)
          return
        }

        let tempUrl = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension("gif")

        do {
          try data.write(to: tempUrl)
        } catch {
          Log.shared.error("Failed to write GIF data from picker", error: error)
          continuation.resume(returning: nil)
          return
        }

        Task {
          defer { try? FileManager.default.removeItem(at: tempUrl) }
          do {
            let videoInfo = try await FileCache.saveAnimatedImageAsVideo(url: tempUrl)
            continuation.resume(returning: .video(videoInfo))
          } catch AnimatedImageVideoConversionError.notAnimated {
            continuation.resume(returning: nil)
          } catch {
            Log.shared.error("Failed to convert GIF data from picker", error: error)
            continuation.resume(returning: nil)
          }
        }
      }
    }
  }

  private func gifTypeIdentifier(for provider: NSItemProvider) -> String? {
    let candidates = [
      UTType.gif.identifier,
      "com.compuserve.gif",
      "image/gif",
    ]
    return candidates.first { provider.hasItemConformingToTypeIdentifier($0) }
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
        self?.addImages([image], content: .camera)
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
