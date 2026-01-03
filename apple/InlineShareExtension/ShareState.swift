import Logger
import MultipartFormDataKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Represents a file that was shared through the extension.
struct SharedFile: Identifiable {
  let id = UUID()
  let url: URL
  let fileName: String
  let mimeType: MIMEType
}

/// Aggregated shared content from the extension.
struct SharedContent {
  var images: [UIImage] = []
  var files: [SharedFile] = []
  var urls: [URL] = []
  var textParts: [String] = []

  var hasMedia: Bool { !images.isEmpty || !files.isEmpty }
  var hasText: Bool { textParts.contains { !$0.isEmpty } }
  var hasUrls: Bool { !urls.isEmpty }
  var mediaCount: Int { images.count + files.count }

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
  private let maxImages: Int
  private let maxFiles: Int
  private let maxUrls: Int

  private(set) var images: [UIImage] = []
  private(set) var files: [SharedFile] = []
  private(set) var urls: [URL] = []
  private(set) var textParts: [String] = []

  init(maxImages: Int, maxFiles: Int, maxUrls: Int) {
    self.maxImages = maxImages
    self.maxFiles = maxFiles
    self.maxUrls = maxUrls
  }

  func addImage(_ image: UIImage) {
    lock.lock()
    defer { lock.unlock() }
    guard images.count < maxImages else { return }
    images.append(image)
  }

  func addFile(_ file: SharedFile) {
    lock.lock()
    defer { lock.unlock() }
    guard files.count < maxFiles else { return }
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
    SharedContent(images: images, files: files, urls: urls, textParts: textParts)
  }
}

/// Manages the state and operations for the share extension
/// Handles loading shared content, uploading files, and sending messages
@MainActor
class ShareState: ObservableObject {
  private nonisolated static let maxImages = 10
  private nonisolated static let maxFiles = 10
  private nonisolated static let maxUrls = 10
  private static let imageCompressionQuality: CGFloat = 0.7
  private static let progressCompletionValue = 1.0
  private static let maxFileSizeBytes: Int64 = 100 * 1024 * 1024 // 100MB

  @Published var sharedContent: SharedContent? = nil
  @Published var sharedData: SharedData?
  @Published var isSending: Bool = false
  @Published var isSent: Bool = false
  @Published var uploadProgress: Double = 0
  @Published var errorState: ErrorState?

  private nonisolated let log = Log.scoped("ShareState")
  
  private nonisolated func detectMIMEType(for fileName: String) -> MIMEType {
    let fileExtension = (fileName as NSString).pathExtension.lowercased()
    
    switch fileExtension {
      case "pdf":
        return MIMEType(text: "application/pdf")
      case "doc", "docx":
        return MIMEType(text: "application/msword")
      case "xls", "xlsx":
        return MIMEType(text: "application/vnd.ms-excel")
      case "ppt", "pptx":
        return MIMEType(text: "application/vnd.ms-powerpoint")
      case "txt":
        return MIMEType(text: "text/plain")
      case "jpg", "jpeg":
        return MIMEType(text: "image/jpeg")
      case "png":
        return MIMEType(text: "image/png")
      case "gif":
        return MIMEType(text: "image/gif")
      case "mp4", "m4v":
        return MIMEType(text: "video/mp4")
      case "mov":
        return MIMEType(text: "video/quicktime")
      case "avi":
        return MIMEType(text: "video/x-msvideo")
      case "mkv":
        return MIMEType(text: "video/x-matroska")
      case "webm":
        return MIMEType(text: "video/webm")
      case "mp3":
        return MIMEType(text: "audio/mpeg")
      case "zip":
        return MIMEType(text: "application/zip")
      default:
        return MIMEType(text: "application/octet-stream")
    }
  }

  private nonisolated func preferredFileTypeIdentifier(
    for provider: NSItemProvider,
    hasImage: Bool,
    hasText: Bool
  ) -> String? {
    if hasImage { return nil }
    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      return UTType.movie.identifier
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      return UTType.fileURL.identifier
    }
    if !hasText, provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
      return UTType.data.identifier
    }
    return nil
  }

  private nonisolated func sanitizedFileName(
    suggestedName: String?,
    fallbackURL: URL?
  ) -> String {
    let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !suggested.isEmpty { return suggested }
    let fallback = fallbackURL?.lastPathComponent ?? ""
    return fallback.isEmpty ? UUID().uuidString : fallback
  }

  private nonisolated func copyToTemporaryLocation(
    from sourceURL: URL,
    suggestedName: String?
  ) throws -> URL {
    let fileManager = FileManager.default
    let fileName = sanitizedFileName(suggestedName: suggestedName, fallbackURL: sourceURL)
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
    suggestedName: String?
  ) throws -> URL {
    let fileManager = FileManager.default
    let fileName = sanitizedFileName(suggestedName: suggestedName, fallbackURL: nil)
    let destinationURL = fileManager.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString)_\(fileName)")
    try data.write(to: destinationURL, options: .atomic)
    return destinationURL
  }

  private nonisolated func loadData(from url: URL) -> Data? {
    let needsAccess = url.startAccessingSecurityScopedResource()
    defer {
      if needsAccess { url.stopAccessingSecurityScopedResource() }
    }
    return try? Data(contentsOf: url)
  }

  private nonisolated func addFile(
    from url: URL,
    suggestedName: String?,
    accumulator: SharedContentAccumulator
  ) {
    do {
      let tempURL = try copyToTemporaryLocation(from: url, suggestedName: suggestedName)
      let fileName = sanitizedFileName(suggestedName: suggestedName, fallbackURL: url)
      let mimeType = detectMIMEType(for: fileName)
      accumulator.addFile(SharedFile(url: tempURL, fileName: fileName, mimeType: mimeType))
    } catch {
      log.error("Failed to prepare shared file", error: error)
    }
  }

  private nonisolated func addFile(
    from data: Data,
    suggestedName: String?,
    accumulator: SharedContentAccumulator
  ) {
    do {
      let tempURL = try writeDataToTemporaryLocation(data, suggestedName: suggestedName)
      let fileName = sanitizedFileName(suggestedName: suggestedName, fallbackURL: tempURL)
      let mimeType = detectMIMEType(for: fileName)
      accumulator.addFile(SharedFile(url: tempURL, fileName: fileName, mimeType: mimeType))
    } catch {
      log.error("Failed to write shared file", error: error)
    }
  }

  private func sendMessageToChat(
    _ selectedChat: SharedChat,
    text: String?,
    photoId: Int64?,
    documentId: Int64?
  ) async throws {
    _ = try await SharedApiClient.shared.sendMessage(
      peerUserId: selectedChat.peerUserId != nil ? Int64(selectedChat.peerUserId!) : nil,
      peerThreadId: selectedChat.peerThreadId != nil ? Int64(selectedChat.peerThreadId!) : nil,
      text: text,
      photoId: photoId,
      documentId: documentId
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
      log.warning("No shared data available")
      errorState = ErrorState(
        title: "No Chats Available",
        message: "Unable to load your chats for sharing.",
        suggestion: "Please open the main Inline app first, then try sharing again."
      )
    } else {
      log.info("Shared data loaded successfully")
    }
  }

  func loadSharedContent(from extensionItems: [NSExtensionItem]) {
    let group = DispatchGroup()
    let accumulator = SharedContentAccumulator(
      maxImages: Self.maxImages,
      maxFiles: Self.maxFiles,
      maxUrls: Self.maxUrls
    )
    var totalImageAttachments = 0
    var totalFileAttachments = 0
    var totalUrlAttachments = 0

    for extensionItem in extensionItems {
      if let attributedText = extensionItem.attributedContentText?.string {
        accumulator.addText(attributedText)
      }
      guard let attachments = extensionItem.attachments else { continue }

      for attachment in attachments {
        let hasImage = attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        let hasText = attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier) ||
          attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        let fileTypeIdentifier = preferredFileTypeIdentifier(
          for: attachment,
          hasImage: hasImage,
          hasText: hasText
        )
        if hasImage {
          totalImageAttachments += 1
          group.enter()
          attachment.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] data, _ in
            defer { group.leave() }
            guard let self else { return }

            if let image = data as? UIImage {
              accumulator.addImage(image)
              return
            }
            if let imageURL = data as? URL, let imageData = self.loadData(from: imageURL) {
              if let image = UIImage(data: imageData) {
                accumulator.addImage(image)
              }
              return
            }
            if let imageData = data as? Data, let image = UIImage(data: imageData) {
              accumulator.addImage(image)
            }
          }
        }

        if let fileTypeIdentifier {
          totalFileAttachments += 1
          group.enter()
          attachment.loadFileRepresentation(forTypeIdentifier: fileTypeIdentifier) { [weak self] url, _ in
            guard let self else {
              group.leave()
              return
            }
            if let url {
              self.addFile(from: url, suggestedName: attachment.suggestedName, accumulator: accumulator)
              group.leave()
              return
            }

            attachment.loadItem(forTypeIdentifier: fileTypeIdentifier, options: nil) { [weak self] item, _ in
              defer { group.leave() }
              guard let self else { return }
              if let url = item as? URL {
                self.addFile(from: url, suggestedName: attachment.suggestedName, accumulator: accumulator)
              } else if let data = item as? Data {
                self.addFile(from: data, suggestedName: attachment.suggestedName, accumulator: accumulator)
              }
            }
          }
        }

        if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          totalUrlAttachments += 1
          let allowFileURL = fileTypeIdentifier == nil
          group.enter()
          attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
            defer { group.leave() }
            guard let self else { return }

            if let url = item as? URL {
              if url.isFileURL {
                if allowFileURL {
                  self.addFile(from: url, suggestedName: attachment.suggestedName, accumulator: accumulator)
                }
              } else {
                accumulator.addURL(url)
              }
              return
            }
            if let string = item as? String, let url = URL(string: string) {
              if url.isFileURL {
                if allowFileURL {
                  self.addFile(from: url, suggestedName: attachment.suggestedName, accumulator: accumulator)
                }
              } else {
                accumulator.addURL(url)
              }
              return
            }
            if let data = item as? Data, let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
              if url.isFileURL {
                if allowFileURL {
                  self.addFile(from: url, suggestedName: attachment.suggestedName, accumulator: accumulator)
                }
              } else {
                accumulator.addURL(url)
              }
            }
          }
        }

        if hasText {
          let typeIdentifier = attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier)
            ? UTType.text.identifier
            : UTType.plainText.identifier
          group.enter()
          attachment.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            defer { group.leave() }
            if let text = item as? String {
              accumulator.addText(text)
            } else if let attributed = item as? NSAttributedString {
              accumulator.addText(attributed.string)
            } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
              accumulator.addText(text)
            }
          }
        }
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

      if totalImageAttachments > Self.maxImages {
        self.log.warning("Limited to \(Self.maxImages) images out of \(totalImageAttachments) provided")
      }
      if totalFileAttachments > Self.maxFiles {
        self.log.warning("Limited to \(Self.maxFiles) files out of \(totalFileAttachments) provided")
      }
      if totalUrlAttachments > Self.maxUrls {
        self.log.warning("Limited to \(Self.maxUrls) URLs out of \(totalUrlAttachments) provided")
      }
    }
  }

  func sendMessage(caption: String, selectedChat: SharedChat, completion: @escaping () -> Void) {
    guard let sharedContent else {
      log.error("No content to share")
      errorState = ErrorState(
        title: "No Content",
        message: "No content was selected to share.",
        suggestion: "Please select something to share."
      )
      return
    }

    isSending = true
    uploadProgress = 0

    Task {
      do {
        let apiClient = SharedApiClient.shared
        let messageText = combinedMessageText(caption: caption, content: sharedContent)
        let totalMediaItems = sharedContent.mediaCount
        let totalItems = max(totalMediaItems, 1)
        var processedItems = 0
        var didSendText = false

        if !sharedContent.images.isEmpty {
          log.info("Sending \(sharedContent.images.count) images")
        }

        for (index, image) in sharedContent.images.enumerated() {
          guard let imageData = image.jpegData(compressionQuality: Self.imageCompressionQuality) else {
            throw NSError(
              domain: "ShareError",
              code: 1,
              userInfo: [NSLocalizedDescriptionKey: "Failed to prepare image \(index + 1)"]
            )
          }

          guard imageData.count <= Self.maxFileSizeBytes else {
            throw NSError(
              domain: "ShareError",
              code: 4,
              userInfo: [
                NSLocalizedDescriptionKey: "Image \(index + 1) is too large. Maximum size is 100MB."
              ]
            )
          }

          let fileName = "shared_image_\(Date().timeIntervalSince1970)_\(index + 1).jpg"
          let uploadResult = try await apiClient.uploadFile(
            data: imageData,
            filename: fileName,
            mimeType: MIMEType(text: "image/jpeg"),
            progress: { progress in
              Task { @MainActor in
                let itemProgress = (Double(processedItems) + progress) / Double(totalItems)
                self.uploadProgress = itemProgress * 0.9
              }
            }
          )

          let imageText = (!didSendText && messageText != nil) ? messageText : nil
          try await sendMessageToChat(
            selectedChat,
            text: imageText,
            photoId: uploadResult.photoId,
            documentId: nil
          )

          didSendText = didSendText || (messageText != nil)
          processedItems += 1
          self.uploadProgress = Double(processedItems) / Double(totalItems) * 0.9
        }

        for (index, file) in sharedContent.files.enumerated() {
          if let fileSize = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            if Int64(fileSize) > Self.maxFileSizeBytes {
              throw NSError(
                domain: "ShareError",
                code: 3,
                userInfo: [
                  NSLocalizedDescriptionKey: "File \(index + 1) is too large. Maximum size is 100MB."
                ]
              )
            }
          }

          let fileData = try Data(contentsOf: file.url, options: .mappedIfSafe)
          guard fileData.count <= Self.maxFileSizeBytes else {
            throw NSError(
              domain: "ShareError",
              code: 3,
              userInfo: [
                NSLocalizedDescriptionKey: "File \(index + 1) is too large. Maximum size is 100MB."
              ]
            )
          }

          let uploadResult = try await apiClient.uploadFile(
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

          let fileText = (!didSendText && messageText != nil) ? messageText : nil
          try await sendMessageToChat(
            selectedChat,
            text: fileText,
            photoId: nil,
            documentId: uploadResult.documentId
          )

          didSendText = didSendText || (messageText != nil)
          processedItems += 1
          self.uploadProgress = Double(processedItems) / Double(totalItems) * 0.9
        }

        if totalMediaItems == 0, let messageText {
          try await sendMessageToChat(selectedChat, text: messageText, photoId: nil, documentId: nil)
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
        log.error("Failed to share content", error: error)
        
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
