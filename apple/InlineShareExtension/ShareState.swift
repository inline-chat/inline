import Auth
import AVFoundation
import Foundation
import InlineKit
import Logger
import MultipartFormDataKit
import SwiftUI
import UniformTypeIdentifiers

/// Represents a file that was shared through the extension.
struct SharedFile: Identifiable {
  let id = UUID()
  let url: URL
  let fileName: String
  let mimeType: MIMEType
  let fileType: MessageFileType
  let fileSize: Int64?
}

/// Aggregated shared content from the extension.
struct SharedContent {
  var files: [SharedFile] = []
  var urls: [URL] = []
  var textParts: [String] = []

  var hasMedia: Bool { !files.isEmpty }
  var hasText: Bool { textParts.contains { !$0.isEmpty } }
  var hasUrls: Bool { !urls.isEmpty }
  var mediaCount: Int { files.count }

  var photoCount: Int { files.filter { $0.fileType == .photo }.count }
  var videoCount: Int { files.filter { $0.fileType == .video }.count }
  var documentCount: Int { files.filter { $0.fileType == .document }.count }

  var totalItemCount: Int {
    var count = mediaCount + urls.count
    if hasText { count += 1 }
    return count
  }

  var combinedText: String? {
    let parts = textParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "\n\n")
  }
}

private final class SharedContentAccumulator {
  private let lock = NSLock()
  private let maxMedia: Int
  private let maxUrls: Int

  private(set) var files: [SharedFile] = []
  private(set) var urls: [URL] = []
  private(set) var textParts: [String] = []
  private var fileDedupKeys: Set<String> = []

  init(maxMedia: Int, maxUrls: Int) {
    self.maxMedia = maxMedia
    self.maxUrls = maxUrls
  }

  func addFile(_ file: SharedFile) {
    lock.lock()
    defer { lock.unlock() }
    guard files.count < maxMedia else { return }
    let sizeKey = file.fileSize.map(String.init) ?? "unknown"
    let key = "\(file.fileType.rawValue)|\(file.fileName)|\(sizeKey)"
    guard !fileDedupKeys.contains(key) else { return }
    fileDedupKeys.insert(key)
    files.append(file)
  }

  func addURL(_ url: URL) {
    lock.lock()
    defer { lock.unlock() }
    guard urls.count < maxUrls else { return }
    guard !urls.contains(where: { $0.absoluteString == url.absoluteString }) else { return }
    urls.append(url)
  }

  func addText(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !textParts.contains(trimmed) else { return }
    textParts.append(trimmed)
  }

  func finalize() -> SharedContent {
    SharedContent(files: files, urls: urls, textParts: textParts)
  }
}

/// Manages the state and operations for the share extension
/// Handles loading shared content, uploading files, and sending messages
@MainActor
class ShareState: ObservableObject {
  private nonisolated static let maxMedia = 10
  private nonisolated static let maxUrls = 10
  private static let imageCompressionQuality: CGFloat = 0.7
  private static let maxFileSizeBytes: Int64 = 100 * 1024 * 1024 // 100MB

  @Published var sharedContent: SharedContent? = nil
  @Published var sharedData: SharedData?
  @Published var isSending: Bool = false
  @Published var isSent: Bool = false
  @Published var uploadProgress: Double = 0
  @Published var errorState: ErrorState?

  private nonisolated let log = Log.scoped("ShareState")
  private nonisolated let shareSessionId = UUID().uuidString

  private nonisolated func tagged(_ message: String) -> String {
    "[share \(shareSessionId)] \(message)"
  }
  
  private nonisolated func resolveMimeType(
    fileURL: URL?,
    suggestedName: String?,
    typeIdentifier: String?
  ) -> MIMEType {
    if let typeIdentifier,
       let utType = UTType(typeIdentifier),
       let mime = utType.preferredMIMEType
    {
      return MIMEType(text: mime)
    }

    if let suggestedName {
      let ext = (suggestedName as NSString).pathExtension.lowercased()
      if !ext.isEmpty,
         let utType = UTType(filenameExtension: ext),
         let mime = utType.preferredMIMEType
      {
        return MIMEType(text: mime)
      }
    }

    if let fileURL {
      return MIMEType(text: FileHelpers.getMimeType(for: fileURL))
    }

    return MIMEType(text: "application/octet-stream")
  }

  private nonisolated func preferredFileType(
    for provider: NSItemProvider
  ) -> (identifier: String, fileType: MessageFileType)? {
    let identifiers = provider.registeredTypeIdentifiers

    if let movieType = identifiers.first(where: { UTType($0)?.conforms(to: .movie) == true }) {
      return (movieType, .video)
    }

    if let imageType = identifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
      return (imageType, .photo)
    }

    if let dataType = identifiers.first(where: {
      guard let utType = UTType($0) else { return false }
      return utType.conforms(to: .data) &&
        !utType.conforms(to: .text) &&
        !utType.conforms(to: .url) &&
        !utType.conforms(to: .image) &&
        !utType.conforms(to: .movie)
    }) {
      return (dataType, .document)
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      return (UTType.fileURL.identifier, .document)
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
       !provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
       !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
    {
      return (UTType.data.identifier, .document)
    }

    return nil
  }

  private nonisolated func inferredFileType(
    for url: URL,
    typeIdentifier: String?
  ) -> MessageFileType {
    if let typeIdentifier, let utType = UTType(typeIdentifier) {
      if utType.conforms(to: .movie) { return .video }
      if utType.conforms(to: .image) { return .photo }
    }

    if let utType = UTType(filenameExtension: url.pathExtension) {
      if utType.conforms(to: .movie) { return .video }
      if utType.conforms(to: .image) { return .photo }
    }

    return .document
  }

  private nonisolated func preferredFileExtension(for typeIdentifier: String?) -> String? {
    guard let typeIdentifier,
          let utType = UTType(typeIdentifier),
          let ext = utType.preferredFilenameExtension,
          !ext.isEmpty
    else {
      return nil
    }
    return ext
  }

  private nonisolated func sanitizedFileName(
    suggestedName: String?,
    fallbackURL: URL?,
    typeIdentifier: String?
  ) -> String {
    let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var fileName = suggested
    if fileName.isEmpty {
      let fallback = fallbackURL?.lastPathComponent ?? ""
      fileName = fallback.isEmpty ? UUID().uuidString : fallback
    }

    let existingExt = (fileName as NSString).pathExtension
    if existingExt.isEmpty, let preferredExt = preferredFileExtension(for: typeIdentifier) {
      fileName += ".\(preferredExt)"
    }

    return fileName
  }

  private nonisolated func copyToTemporaryLocation(
    from sourceURL: URL,
    suggestedName: String?,
    typeIdentifier: String?
  ) throws -> URL {
    let fileManager = FileManager.default
    let fileName = sanitizedFileName(
      suggestedName: suggestedName,
      fallbackURL: sourceURL,
      typeIdentifier: typeIdentifier
    )
    let destinationURL = fileManager.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString)_\(fileName)")
    let needsAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if needsAccess { sourceURL.stopAccessingSecurityScopedResource() }
    }
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private nonisolated func writeDataToTemporaryLocation(
    _ data: Data,
    suggestedName: String?,
    typeIdentifier: String?
  ) throws -> URL {
    let fileManager = FileManager.default
    let fileName = sanitizedFileName(
      suggestedName: suggestedName,
      fallbackURL: nil,
      typeIdentifier: typeIdentifier
    )
    let destinationURL = fileManager.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString)_\(fileName)")
    try data.write(to: destinationURL, options: .atomic)
    return destinationURL
  }

  private nonisolated func addFile(
    from url: URL,
    suggestedName: String?,
    typeIdentifier: String?,
    fileType: MessageFileType,
    accumulator: SharedContentAccumulator
  ) {
    do {
      let tempURL = try copyToTemporaryLocation(
        from: url,
        suggestedName: suggestedName,
        typeIdentifier: typeIdentifier
      )
      let fileName = sanitizedFileName(
        suggestedName: suggestedName,
        fallbackURL: url,
        typeIdentifier: typeIdentifier
      )
      let mimeType = resolveMimeType(
        fileURL: tempURL,
        suggestedName: fileName,
        typeIdentifier: typeIdentifier
      )
      let fileSize = try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
      accumulator.addFile(SharedFile(
        url: tempURL,
        fileName: fileName,
        mimeType: mimeType,
        fileType: fileType,
        fileSize: fileSize.map { Int64($0) }
      ))
    } catch {
      log.error(tagged("Failed to prepare shared file"), error: error)
    }
  }

  private nonisolated func addFile(
    from data: Data,
    suggestedName: String?,
    typeIdentifier: String?,
    fileType: MessageFileType,
    mimeTypeOverride: MIMEType? = nil,
    accumulator: SharedContentAccumulator
  ) {
    do {
      let tempURL = try writeDataToTemporaryLocation(
        data,
        suggestedName: suggestedName,
        typeIdentifier: typeIdentifier
      )
      let fileName = sanitizedFileName(
        suggestedName: suggestedName,
        fallbackURL: tempURL,
        typeIdentifier: typeIdentifier
      )
      let mimeType = mimeTypeOverride ?? resolveMimeType(
        fileURL: tempURL,
        suggestedName: fileName,
        typeIdentifier: typeIdentifier
      )
      accumulator.addFile(SharedFile(
        url: tempURL,
        fileName: fileName,
        mimeType: mimeType,
        fileType: fileType,
        fileSize: Int64(data.count)
      ))
    } catch {
      log.error(tagged("Failed to write shared file"), error: error)
    }
  }

  private nonisolated func handleLoadedFileItem(
    _ item: NSSecureCoding?,
    typeIdentifier: String,
    fileType: MessageFileType,
    suggestedName: String?,
    accumulator: SharedContentAccumulator
  ) {
    if let url = item as? URL {
      let resolvedType = fileType == .document
        ? inferredFileType(for: url, typeIdentifier: typeIdentifier)
        : fileType
      addFile(
        from: url,
        suggestedName: suggestedName,
        typeIdentifier: typeIdentifier,
        fileType: resolvedType,
        accumulator: accumulator
      )
      return
    }

    if let data = item as? Data {
      addFile(
        from: data,
        suggestedName: suggestedName,
        typeIdentifier: typeIdentifier,
        fileType: fileType,
        accumulator: accumulator
      )
      return
    }

    if let image = item as? UIImage, fileType == .photo {
      guard let jpegData = image.jpegData(compressionQuality: Self.imageCompressionQuality) else {
        log.error(tagged("Failed to encode shared image"))
        return
      }

      addFile(
        from: jpegData,
        suggestedName: suggestedName ?? "shared_image.jpg",
        typeIdentifier: UTType.jpeg.identifier,
        fileType: .photo,
        mimeTypeOverride: MIMEType(text: "image/jpeg"),
        accumulator: accumulator
      )
      return
    }

    log.warning(tagged("Unsupported item payload for type \(typeIdentifier)"))
  }

  private nonisolated func handleLoadedURLItem(
    _ item: NSSecureCoding?,
    suggestedName: String?,
    accumulator: SharedContentAccumulator
  ) {
    if let url = item as? URL {
      if url.isFileURL {
        let resolvedType = inferredFileType(for: url, typeIdentifier: nil)
        addFile(
          from: url,
          suggestedName: suggestedName,
          typeIdentifier: UTType.fileURL.identifier,
          fileType: resolvedType,
          accumulator: accumulator
        )
      } else {
        accumulator.addURL(url)
      }
      return
    }

    if let string = item as? String, let url = URL(string: string) {
      if url.isFileURL {
        let resolvedType = inferredFileType(for: url, typeIdentifier: nil)
        addFile(
          from: url,
          suggestedName: suggestedName,
          typeIdentifier: UTType.fileURL.identifier,
          fileType: resolvedType,
          accumulator: accumulator
        )
      } else {
        accumulator.addURL(url)
      }
      return
    }

    if let data = item as? Data,
       let string = String(data: data, encoding: .utf8),
       let url = URL(string: string)
    {
      if url.isFileURL {
        let resolvedType = inferredFileType(for: url, typeIdentifier: nil)
        addFile(
          from: url,
          suggestedName: suggestedName,
          typeIdentifier: UTType.fileURL.identifier,
          fileType: resolvedType,
          accumulator: accumulator
        )
      } else {
        accumulator.addURL(url)
      }
      return
    }

    log.warning(tagged("Unsupported URL payload"))
  }

  private nonisolated func handleLoadedTextItem(
    _ item: NSSecureCoding?,
    accumulator: SharedContentAccumulator
  ) {
    if let text = item as? String {
      accumulator.addText(text)
      return
    }

    if let attributed = item as? NSAttributedString {
      accumulator.addText(attributed.string)
      return
    }

    if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
      accumulator.addText(text)
      return
    }

    log.warning(tagged("Unsupported text payload"))
  }

  private nonisolated func buildVideoMetadata(from url: URL) async throws -> ApiClient.VideoUploadMetadata {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else {
      throw NSError(
        domain: "ShareError",
        code: 6,
        userInfo: [NSLocalizedDescriptionKey: "Unable to read video track."]
      )
    }

    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let transformedSize = naturalSize.applying(transform)
    let width = Int(abs(transformedSize.width.rounded()))
    let height = Int(abs(transformedSize.height.rounded()))

    let durationTime = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(durationTime)
    let duration = seconds.isFinite ? Int(seconds.rounded()) : 0

    guard width > 0, height > 0, duration > 0 else {
      throw NSError(
        domain: "ShareError",
        code: 7,
        userInfo: [NSLocalizedDescriptionKey: "Missing video metadata."]
      )
    }

    let thumbnailPayload = try? generateVideoThumbnail(from: asset, durationSeconds: seconds)

    return ApiClient.VideoUploadMetadata(
      width: width,
      height: height,
      duration: duration,
      thumbnail: thumbnailPayload?.data,
      thumbnailMimeType: thumbnailPayload?.mimeType
    )
  }

  private nonisolated func generateVideoThumbnail(
    from asset: AVAsset,
    durationSeconds: Double
  ) throws -> (data: Data, mimeType: MIMEType)? {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true

    let captureTime = CMTime(seconds: max(0, min(durationSeconds * 0.1, 1.0)), preferredTimescale: 600)
    let cgImage = try generator.copyCGImage(at: captureTime, actualTime: nil)
    let image = UIImage(cgImage: cgImage)
    guard let jpegData = image.jpegData(compressionQuality: 0.7) else {
      return nil
    }

    return (jpegData, MIMEType(text: "image/jpeg"))
  }

  private func sendMessageToChat(
    _ selectedChat: SharedChat,
    text: String?,
    fileUniqueId: String?
  ) async throws {
    _ = try await ApiClient.shared.sendMessage(
      peerUserId: selectedChat.peerUserId != nil ? Int64(selectedChat.peerUserId!) : nil,
      peerThreadId: selectedChat.peerThreadId != nil ? Int64(selectedChat.peerThreadId!) : nil,
      text: text,
      randomId: nil,
      repliedToMessageId: nil,
      date: nil,
      fileUniqueId: fileUniqueId,
      isSticker: nil
    )
  }

  private func combinedMessageText(
    caption: String,
    content: SharedContent
  ) -> String? {
    var parts: [String] = []
    let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedCaption.isEmpty {
      parts.append(trimmedCaption)
    }
    if let contentText = content.combinedText {
      parts.append(contentText)
    }
    if !content.urls.isEmpty {
      let urlText = content.urls.map(\.absoluteString).joined(separator: "\n")
      if !urlText.isEmpty {
        parts.append(urlText)
      }
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "\n\n")
  }

  struct ErrorState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let suggestion: String?
  }

  func loadSharedData() {
    sharedData = BridgeManager.shared.loadSharedData()

    if sharedData == nil {
      log.warning(tagged("No shared data available"))
      errorState = ErrorState(
        title: "No Chats Available",
        message: "Unable to load your chats for sharing.",
        suggestion: "Please open the main Inline app first, then try sharing again."
      )
    } else {
      log.info(tagged("Shared data loaded successfully"))
    }
  }

  func loadSharedContent(from extensionItems: [NSExtensionItem]) {
    log.info(tagged("Loading shared content (\(extensionItems.count) extension items)"))
    let group = DispatchGroup()
    let accumulator = SharedContentAccumulator(
      maxMedia: Self.maxMedia,
      maxUrls: Self.maxUrls
    )
    var totalMediaAttachments = 0
    var totalUrlAttachments = 0
    var totalTextAttachments = 0

    for extensionItem in extensionItems {
      if let attributedText = extensionItem.attributedContentText?.string {
        accumulator.addText(attributedText)
        totalTextAttachments += 1
      }
      guard let attachments = extensionItem.attachments else { continue }

      for attachment in attachments {
        if let fileTypeInfo = preferredFileType(for: attachment) {
          totalMediaAttachments += 1
          let typeIdentifier = fileTypeInfo.identifier
          let fileType = fileTypeInfo.fileType
          group.enter()
          attachment.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            guard let self else {
              group.leave()
              return
            }
            if let error {
              self.log.error(self.tagged("Failed to load file representation"), error: error)
            }
            if let url {
              let resolvedType = fileType == .document
                ? self.inferredFileType(for: url, typeIdentifier: typeIdentifier)
                : fileType
              self.addFile(
                from: url,
                suggestedName: attachment.suggestedName,
                typeIdentifier: typeIdentifier,
                fileType: resolvedType,
                accumulator: accumulator
              )
              group.leave()
              return
            }

            attachment.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
              defer { group.leave() }
              guard let self else { return }
              if let error {
                self.log.error(self.tagged("Failed to load item"), error: error)
              }
              self.handleLoadedFileItem(
                item,
                typeIdentifier: typeIdentifier,
                fileType: fileType,
                suggestedName: attachment.suggestedName,
                accumulator: accumulator
              )
            }
          }
          continue
        }

        if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          totalUrlAttachments += 1
          group.enter()
          attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, error in
            defer { group.leave() }
            guard let self else { return }
            if let error {
              self.log.error(self.tagged("Failed to load URL item"), error: error)
            }
            self.handleLoadedURLItem(
              item,
              suggestedName: attachment.suggestedName,
              accumulator: accumulator
            )
          }
          continue
        }

        if attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier) ||
            attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        {
          totalTextAttachments += 1
          let typeIdentifier = attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier)
            ? UTType.text.identifier
            : UTType.plainText.identifier
          group.enter()
          attachment.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            defer { group.leave() }
            guard let self else { return }
            if let error {
              self.log.error(self.tagged("Failed to load text item"), error: error)
            }
            self.handleLoadedTextItem(item, accumulator: accumulator)
          }
          continue
        }

        log.warning(tagged("Unsupported share attachment types: \(attachment.registeredTypeIdentifiers)"))
      }
    }

    // Wait for all items to load and then process the results
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      let content = accumulator.finalize()
      if content.totalItemCount > 0 {
        self.sharedContent = content
      } else {
        self.sharedContent = nil
      }

      self.log.info(self.tagged(
        "Loaded content: \(content.photoCount) photos, \(content.videoCount) videos, " +
        "\(content.documentCount) documents, \(content.urls.count) urls, text=\(content.hasText)"
      ))

      if totalMediaAttachments > Self.maxMedia {
        self.log.warning(self.tagged("Limited to \(Self.maxMedia) media items out of \(totalMediaAttachments) provided"))
      }
      if totalUrlAttachments > Self.maxUrls {
        self.log.warning(self.tagged("Limited to \(Self.maxUrls) URLs out of \(totalUrlAttachments) provided"))
      }
      if totalTextAttachments == 0, content.totalItemCount == 0 {
        self.log.warning(self.tagged("No usable share content found"))
      }
    }
  }

  func sendMessage(caption: String, selectedChat: SharedChat, completion: @escaping () -> Void) {
    guard let sharedContent else {
      log.error(tagged("No content to share"))
      errorState = ErrorState(
        title: "No Content",
        message: "No content was selected to share.",
        suggestion: "Please select something to share."
      )
      return
    }

    if Auth.shared.getToken() == nil {
      log.warning(tagged("Missing auth token for share"))
      errorState = ErrorState(
        title: "Sign In Required",
        message: "Inline needs to be opened before you can share.",
        suggestion: "Open the Inline app, then try sharing again."
      )
      return
    }

    isSending = true
    uploadProgress = 0

    Task {
      do {
        let apiClient = ApiClient.shared
        let messageText = combinedMessageText(caption: caption, content: sharedContent)
        let totalMediaItems = sharedContent.mediaCount
        let totalItems = max(totalMediaItems, 1)
        var processedItems = 0
        var didSendText = false

        if !sharedContent.files.isEmpty {
          log.info(tagged("Sending \(sharedContent.files.count) attachments"))
        }

        for (index, file) in sharedContent.files.enumerated() {
          if let fileSize = file.fileSize, fileSize > Self.maxFileSizeBytes {
            throw NSError(
              domain: "ShareError",
              code: 3,
              userInfo: [
                NSLocalizedDescriptionKey: "\(file.fileName) is too large. Maximum size is 100MB."
              ]
            )
          }

          let fileData = try Data(contentsOf: file.url, options: .mappedIfSafe)
          guard fileData.count <= Self.maxFileSizeBytes else {
            throw NSError(
              domain: "ShareError",
              code: 3,
              userInfo: [
                NSLocalizedDescriptionKey: "\(file.fileName) is too large. Maximum size is 100MB."
              ]
            )
          }

          let uploadResult: InlineKit.UploadFileResult
          switch file.fileType {
            case .photo:
              uploadResult = try await apiClient.uploadFile(
                type: .photo,
                data: fileData,
                filename: file.fileName,
                mimeType: file.mimeType,
                progress: { progress in
                  Task { @MainActor in
                    let itemProgress = (Double(processedItems) + progress) / Double(totalItems)
                    self.uploadProgress = itemProgress * 0.9
                  }
                }
              )
            case .document:
              uploadResult = try await apiClient.uploadFile(
                type: .document,
                data: fileData,
                filename: file.fileName,
                mimeType: file.mimeType,
                progress: { progress in
                  Task { @MainActor in
                    let itemProgress = (Double(processedItems) + progress) / Double(totalItems)
                    self.uploadProgress = itemProgress * 0.9
                  }
                }
              )
            case .video:
              let videoMetadata = try await buildVideoMetadata(from: file.url)
              uploadResult = try await apiClient.uploadFile(
                type: .video,
                data: fileData,
                filename: file.fileName,
                mimeType: file.mimeType,
                videoMetadata: videoMetadata,
                progress: { progress in
                  Task { @MainActor in
                    let itemProgress = (Double(processedItems) + progress) / Double(totalItems)
                    self.uploadProgress = itemProgress * 0.9
                  }
                }
              )
          }

          let fileText = (!didSendText && messageText != nil) ? messageText : nil
          try await sendMessageToChat(
            selectedChat,
            text: fileText,
            fileUniqueId: uploadResult.fileUniqueId
          )

          didSendText = didSendText || (messageText != nil)
          processedItems += 1
          self.uploadProgress = Double(processedItems) / Double(totalItems) * 0.9
        }

        if totalMediaItems == 0, let messageText {
          try await sendMessageToChat(selectedChat, text: messageText, fileUniqueId: nil)
          self.uploadProgress = 0.9
        } else if totalMediaItems > 0, messageText == nil {
          self.uploadProgress = 0.9
        }

        await MainActor.run {
          self.isSending = false
          self.isSent = true

          // Play haptic feedback
          let impactFeedback = UIImpactFeedbackGenerator(style: .light)
          impactFeedback.impactOccurred()

          // Close after delay
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            completion()
          }
        }
      } catch {
        log.error(tagged("Failed to share content"), error: error)
        
        await MainActor.run {
          // Provide more specific error messages
          let errorMessage: (title: String, message: String, suggestion: String?) = {
            if let apiError = error as? APIError {
              switch apiError {
                case .networkError:
                  return ("Connection Error", "Unable to connect to the server.", "Check your internet connection and try again.")
                case .rateLimited:
                  return ("Rate Limited", "Too many requests. Please wait a moment.", "Try again in a few seconds.")
                case let .httpError(statusCode):
                  if statusCode == 401 || statusCode == 403 {
                    return ("Sign In Required", "Your session has expired.", "Open the Inline app and try again.")
                  }
                  return ("Server Error", "Server returned error code \(statusCode).", "Please try again later.")
                case let .error(error, _, description):
                  return ("Share Failed", description ?? error, "Please try again.")
                default:
                  return ("Share Failed", "Could not share the content.", "Please check your connection and try again.")
              }
            } else {
              return ("Share Failed", "An unexpected error occurred.", "Please try again.")
            }
          }()
          
          self.errorState = ErrorState(
            title: errorMessage.title,
            message: errorMessage.message,
            suggestion: errorMessage.suggestion
          )
          self.isSending = false
        }
      }
    }
  }
}
