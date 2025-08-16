import Logger
import MultipartFormDataKit
import SwiftUI
import UniformTypeIdentifiers

/// Represents different types of content that can be shared through the extension
enum SharedContentType {
  /// Multiple images (up to 5) to be shared
  case images([UIImage])
  /// Plain text content
  case text(String)
  /// URL to be shared
  case url(URL)
  /// File with its filename
  case file(URL, String)
}

// Helper functions for SharedContentType pattern matching
private func isFileContent(_ content: SharedContentType) -> Bool {
  if case .file = content { return true }
  return false
}

private func isImagesContent(_ content: SharedContentType) -> Bool {
  if case .images = content { return true }
  return false
}

/// Manages the state and operations for the share extension
/// Handles loading shared content, uploading files, and sending messages
@MainActor
class ShareState: ObservableObject {
  private nonisolated static let maxImages = 5
  private static let imageCompressionQuality: CGFloat = 0.7
  private static let progressCompletionValue = 1.0
  private static let maxFileSizeBytes: Int64 = 100 * 1024 * 1024 // 100MB

  @Published var sharedContent: SharedContentType? = nil
  @Published var sharedData: SharedData?
  @Published var isSending: Bool = false
  @Published var isSent: Bool = false
  @Published var uploadProgress: Double = 0
  @Published var errorState: ErrorState?

  private let log = Log.scoped("ShareState")
  
  private func detectMIMEType(for fileName: String) -> MIMEType {
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
      case "mp4":
        return MIMEType(text: "video/mp4")
      case "mp3":
        return MIMEType(text: "audio/mpeg")
      case "zip":
        return MIMEType(text: "application/zip")
      default:
        return MIMEType(text: "application/octet-stream")
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
    var loadedImages: [UIImage] = []
    let imageQueue = DispatchQueue(label: "com.inline.shareext.images", attributes: .concurrent)

    for extensionItem in extensionItems {
      guard let attachments = extensionItem.attachments else { continue }

      for attachment in attachments {
        // Check for images
        if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
          group.enter()
          attachment.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { data, _ in
            defer { group.leave() }

            var image: UIImage?
            if let imageURL = data as? URL,
               let imageData = try? Data(contentsOf: imageURL)
            {
              image = UIImage(data: imageData)
            } else if let loadedImage = data as? UIImage {
              image = loadedImage
            }

            if let image {
              imageQueue.async(flags: .barrier) {
                if loadedImages.count < Self.maxImages {
                  loadedImages.append(image)
                }
              }
            }
          }
        }
        // Check for URLs
        else if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
          group.enter()
          attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, _ in
            defer { group.leave() }

            if let url = data as? URL {
              Task { @MainActor in
                self?.sharedContent = .url(url)
              }
            }
          }
        }
        // Check for plain text
        else if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
          group.enter()
          attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, _ in
            defer { group.leave() }

            if let text = data as? String {
              Task { @MainActor in
                self?.sharedContent = .text(text)
              }
            }
          }
        }
        // Check for files (documents)
        else if attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
          group.enter()
          attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] data, _ in
            defer { group.leave() }

            if let fileURL = data as? URL {
              let fileName = fileURL.lastPathComponent
              Task { @MainActor in
                self?.sharedContent = .file(fileURL, fileName)
              }
            }
          }
        }
      }
    }

    // Wait for all items to load and then process the results
    group.notify(queue: .main) { [weak self] in
      imageQueue.sync {
        if !loadedImages.isEmpty {
          self?.sharedContent = .images(loadedImages)
          if loadedImages.count == Self.maxImages {
            self?.log.info("Loaded maximum \(Self.maxImages) images")
          } else {
            self?.log.info("Loaded \(loadedImages.count) images")
          }

          // Check if we had to limit the images
          let totalImageAttachments = extensionItems.compactMap(\.attachments).joined().filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
          }.count

          if totalImageAttachments > Self.maxImages {
            self?.log.warning("Limited to \(Self.maxImages) images out of \(totalImageAttachments) provided")
            // Note: We could show a user-facing warning here in the future
          }
        }
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
        let messageText = caption

        // Handle different content types
        var processedItems = 0
        var totalItems = 1 // Default to 1 for simple progress
        
        switch sharedContent {
          case let .images(images):
            totalItems = images.count
          case .text, .url, .file:
            totalItems = 1
        }

        switch sharedContent {
          case let .images(images):
            // Validate image count
            guard images.count <= Self.maxImages else {
              throw NSError(
                domain: "ShareError",
                code: 2,
                userInfo: [
                  NSLocalizedDescriptionKey: "Too many images. Maximum \(Self.maxImages) images are supported.",
                ]
              )
            }

            log.info("Sending \(images.count) images")

            // Send each image as a separate message
            for (index, image) in images.enumerated() {
              guard let imageData = image.jpegData(compressionQuality: Self.imageCompressionQuality) else {
                throw NSError(
                  domain: "ShareError",
                  code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Failed to prepare image \(index + 1)"]
                )
              }
              
              // Validate image size
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
                    self.uploadProgress = itemProgress * 0.9 // Reserve 10% for sending
                  }
                }
              )

              // Send message with this image
              let imageText = index == 0 && !messageText.isEmpty ? messageText : nil
              try await sendMessageToChat(
                selectedChat,
                text: imageText,
                photoId: uploadResult.photoId,
                documentId: nil
              )

              processedItems += 1
              self.uploadProgress = Double(processedItems) / Double(totalItems) * 0.9
            }

          case let .text(text):
            // Send text as separate message
            let combinedText = messageText.isEmpty ? text : messageText + "\n\n" + text
            try await sendMessageToChat(selectedChat, text: combinedText, photoId: nil, documentId: nil)

            self.uploadProgress = 0.9

          case let .url(url):
            // Send URL as separate message
            let urlText = url.absoluteString
            let combinedText = messageText.isEmpty ? urlText : messageText + "\n\n" + urlText
            try await sendMessageToChat(selectedChat, text: combinedText, photoId: nil, documentId: nil)

            self.uploadProgress = 0.9

          case let .file(fileURL, fileName):
            // Upload and send file
            let fileData = try Data(contentsOf: fileURL)
            
            // Validate file size
            guard fileData.count <= Self.maxFileSizeBytes else {
              throw NSError(
                domain: "ShareError",
                code: 3,
                userInfo: [
                  NSLocalizedDescriptionKey: "File is too large. Maximum size is 100MB."
                ]
              )
            }
            let mimeType = self.detectMIMEType(for: fileName)
            let uploadResult = try await apiClient.uploadFile(
              type: .document,
              data: fileData,
              filename: fileName,
              mimeType: mimeType,
              progress: { progress in
                Task { @MainActor in
                  self.uploadProgress = progress * 0.9 // Reserve 10% for sending
                }
              }
            )

            try await sendMessageToChat(
              selectedChat,
              text: messageText.isEmpty ? nil : messageText,
              photoId: nil,
              documentId: uploadResult.documentId
            )

            self.uploadProgress = 0.9
        }

        // Send caption-only message if no media was shared and we have text
        if case .text = sharedContent, messageText.isEmpty {
          // Text content was already sent above
        } else if case .url = sharedContent, messageText.isEmpty {
          // URL content was already sent above  
        } else if !messageText.isEmpty && !isFileContent(sharedContent) && !isImagesContent(sharedContent) {
          // Send standalone caption if no media was shared
          try await sendMessageToChat(selectedChat, text: messageText, photoId: nil, documentId: nil)
        }

        await MainActor.run {
          self.uploadProgress = Self.progressCompletionValue
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
