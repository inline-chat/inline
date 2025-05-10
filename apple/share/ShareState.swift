import Foundation
import InlineKit
import Logger
import MultipartFormDataKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

class ShareState: ObservableObject {
  @Published var sharedImages: [UIImage] = []
  @Published var sharedData: SharedData?
  @Published var isSending: Bool = false
  @Published var uploadProgress: Double = 0

  private let log = Log.scoped("ShareState")

  func loadSharedData() {
    log.info("Loading shared data...")
    let sharedContainerIdentifier = "group.chat.inline"

    guard let containerURL = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: sharedContainerIdentifier)
    else {
      log.error("Failed to get container URL - check app group entitlements")
      return
    }

    let sharedDataURL = containerURL.appendingPathComponent("SharedData.json")

    if !FileManager.default.fileExists(atPath: sharedDataURL.path) {
      log.warning("SharedData.json doesn't exist - has it been created yet?")
      return
    }

    do {
      let data = try Data(contentsOf: sharedDataURL)
      let decoder = JSONDecoder()
      sharedData = try decoder.decode(SharedData.self, from: data)
      log.info("Shared data loaded successfully")
    } catch {
      log.error("Error loading shared data", error: error)
    }
  }

  func sendMessage(caption: String, selectedChat: SharedChat, completion: @escaping () -> Void) {
    guard !sharedImages.isEmpty,
          let image = sharedImages.first
    else {
      log.error("No image to share")
      completion()
      return
    }

    isSending = true
    uploadProgress = 0

    Task {
      do {
        autoreleasepool {
          // Save image to temporary file for compression
          let tempDir = FileManager.default.temporaryDirectory
          let tempImageURL = tempDir.appendingPathComponent("temp_\(UUID().uuidString).jpg")

          guard let imageData = image.jpegData(compressionQuality: 1.0),
                (try? imageData.write(to: tempImageURL)) != nil
          else {
            log.error("Failed to save temporary image")
            DispatchQueue.main.async {
              self.isSending = false
              completion()
            }
            return
          }

          // Clear the original image from memory
          self.sharedImages.removeAll()

          // Compress image using ImageCompressor
          Task {
            do {
              let compressedURL = try await ImageCompressor.shared.compressImage(
                at: tempImageURL,
                options: .defaultPhoto
              )

              // Read compressed data
              guard let compressedData = try? Data(contentsOf: compressedURL) else {
                log.error("Failed to read compressed image data")
                DispatchQueue.main.async {
                  self.isSending = false
                  completion()
                }
                return
              }

              // Clean up temporary files
              try? FileManager.default.removeItem(at: tempImageURL)
              try? FileManager.default.removeItem(at: compressedURL)

              let fileName = "shared_image_\(Date().timeIntervalSince1970).jpg"
              let mimeType = MIMEType.imageJpeg

              log.info("Preparing to upload image: \(fileName) with size: \(compressedData.count) bytes")

              let apiClient = SharedApiClient.shared

              // Upload file
              log.info("Starting file upload...")
              do {
                let uploadResult = try await apiClient.uploadFile(
                  data: compressedData,
                  filename: fileName,
                  mimeType: mimeType,
                  progress: { [weak self] progress in
                    self?.log.info("Upload progress: \(Int(progress * 100))%")
                    DispatchQueue.main.async {
                      self?.uploadProgress = progress
                    }
                  }
                )

                log.info("File upload successful, fileUniqueId: \(uploadResult.fileUniqueId)")
                uploadProgress = 1.0

                // Send message
                log.info("Sending message with uploaded file...")
                _ = try await apiClient.sendMessage(
                  peerUserId: selectedChat.peerUserId != nil ? Int64(selectedChat.peerUserId!) : nil,
                  peerThreadId: selectedChat.peerThreadId != nil ? Int64(selectedChat.peerThreadId!) : nil,
                  text: caption,
                  randomId: nil,
                  repliedToMessageId: nil,
                  date: nil,
                  fileUniqueId: uploadResult.fileUniqueId,
                  isSticker: false
                )

                log.info("Message sent successfully")
                DispatchQueue.main.async {
                  self.isSending = false
                  completion()
                }
              } catch {
                log.error("Failed to share image", error: error)
                DispatchQueue.main.async {
                  self.isSending = false
                  completion()
                }
              }
            } catch {
              log.error("Failed to compress image", error: error)
              DispatchQueue.main.async {
                self.isSending = false
                completion()
              }
            }
          }
        }
      } catch {
        log.error("Failed to share image", error: error)
        DispatchQueue.main.async {
          self.isSending = false
          completion()
        }
      }
    }
  }
}
