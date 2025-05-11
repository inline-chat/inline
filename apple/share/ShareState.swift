import Logger
import MultipartFormDataKit
import SwiftUI

class ShareState: ObservableObject {
  @Published var sharedImages: [UIImage] = []
  @Published var sharedData: SharedData?
  @Published var isSending: Bool = false
  @Published var uploadProgress: Double = 0
  @Published var errorState: ErrorState?

  private let log = Log.scoped("ShareState")

  struct ErrorState: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let suggestion: String?
  }

  func loadSharedData() {
    let sharedContainerIdentifier = "group.chat.inline"

    guard let containerURL = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: sharedContainerIdentifier)
    else {
      log.error("Failed to get container URL - check app group entitlements")
      errorState = ErrorState(
        title: "Configuration Error",
        message: "Failed to access shared container. Please check app group entitlements.",
        suggestion: "Try reinstalling the app."
      )
      return
    }

    let sharedDataURL = containerURL.appendingPathComponent("SharedData.json")

    if !FileManager.default.fileExists(atPath: sharedDataURL.path) {
      log.warning("SharedData.json doesn't exist - has it been created yet?")
      errorState = ErrorState(
        title: "No Data Available",
        message: "No chats available to share with.",
        suggestion: "Open the main app first to load your chats."
      )
      return
    }

    do {
      let data = try Data(contentsOf: sharedDataURL)
      let decoder = JSONDecoder()
      sharedData = try decoder.decode(SharedData.self, from: data)
      log.info("Shared data loaded successfully")
    } catch {
      log.error("Error loading shared data", error: error)
      errorState = ErrorState(
        title: "Failed to Load Data",
        message: "Could not load your chats.",
        suggestion: "Try opening the main app first."
      )
    }
  }

  func sendMessage(caption: String, selectedChat: SharedChat, completion: @escaping () -> Void) {
    guard !sharedImages.isEmpty,
          let image = sharedImages.first,
          let imageData = image.jpegData(compressionQuality: 0.7)
    else {
      log.error("Failed to prepare image data for upload")
      errorState = ErrorState(
        title: "Image Error",
        message: "Failed to prepare image for upload.",
        suggestion: "Try selecting a different image."
      )
      isSending = false
      return
    }

    let fileName = "shared_image_\(Date().timeIntervalSince1970).jpg"
    let mimeType = MIMEType.imageJpeg

    isSending = true
    uploadProgress = 0

    Task {
      do {
        let apiClient = SharedApiClient.shared

        // Upload file
        log.info("Starting file upload...")
        let uploadResult = try await apiClient.uploadFile(
          data: imageData,
          filename: fileName,
          mimeType: mimeType,
          progress: { [weak self] progress in
            self?.log.info("Upload progress: \(Int(progress * 100))%")
            DispatchQueue.main.async {
              self?.uploadProgress = progress
            }
          }
        )

        log.info("File upload successful, photoId: \(uploadResult.photoId)")
        uploadProgress = 1.0

        // Send message
        log.info("Sending message with uploaded file...")
        _ = try await apiClient.sendMessage(
          peerUserId: selectedChat.peerUserId != nil ? Int64(selectedChat.peerUserId!) : nil,
          peerThreadId: selectedChat.peerThreadId != nil ? Int64(selectedChat.peerThreadId!) : nil,
          text: caption,
          photoId: uploadResult.photoId,
        )

        log.info("Message sent successfully")
        DispatchQueue.main.async {
          self.isSending = false
          completion()
        }
      } catch {
        log.error("Failed to share image", error: error)
        DispatchQueue.main.async {
          self.errorState = ErrorState(
            title: "Failed to Share",
            message: "Could not share the image.",
            suggestion: "Please check your internet connection and try again."
          )
          self.isSending = false
        }
      }
    }
  }
}
