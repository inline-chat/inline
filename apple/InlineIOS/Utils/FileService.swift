import InlineKit
import Logger
import MultipartFormDataKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File Service

enum FileError: LocalizedError {
  case permissionDenied(String)
  case invalidFile(String)
  case unknown(Error)

  var errorDescription: String? {
    switch self {
      case let .permissionDenied(filename):
        "Cannot access '\(filename)'. Make sure you have permission to view this file."
      case let .invalidFile(filename):
        "'\(filename)' could not be opened. The file might be corrupted or in an unsupported format."
      case let .unknown(error):
        error.localizedDescription
    }
  }

  var recoverySuggestion: String? {
    switch self {
      case .permissionDenied:
        "Try selecting a different file or check the file permissions in Finder."
      case .invalidFile:
        "Please select a valid image file."
      case .unknown:
        "Please try again or select a different file."
    }
  }
}

final class FileService {
  static let shared = FileService()
    
  private let maxFileSize = 10 * 1_024 * 1_024 // 10MB
  private let supportedImageTypes: Set<UTType> = [.jpeg, .png, .heic]
    
  private init() {}
    
  func uploadImage(from url: URL) async throws {
    guard url.startAccessingSecurityScopedResource() else {
      throw FileError.permissionDenied(url.lastPathComponent)
    }
        
    defer {
      url.stopAccessingSecurityScopedResource()
    }
        
    // Verify file type
    guard let fileType = UTType(filenameExtension: url.pathExtension),
          supportedImageTypes.contains(fileType)
    else {
      throw FileError.invalidFile(url.lastPathComponent)
    }
        
    // Verify file exists and get attributes
    let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
    guard let fileSize = resourceValues.fileSize,
          fileSize <= maxFileSize
    else {
      throw FileError.invalidFile("\(url.lastPathComponent) exceeds maximum size of 10MB")
    }
        
    // Read file data
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw FileError.permissionDenied(url.lastPathComponent)
    }
        
    try await uploadImageToServer(data, fileType: fileType)
  }
    
  func uploadImage(_ data: Data, fileType: UTType) async throws {
    guard data.count <= maxFileSize else {
      throw FileError.invalidFile("File exceeds maximum size of 10MB")
    }
        
    try await uploadImageToServer(data, fileType: fileType)
  }
    
  private func uploadImageToServer(_ data: Data, fileType: UTType) async throws {
    let mimeType = switch fileType {
      case .jpeg: MIMEType.imageJpeg
      case .png: MIMEType.imagePng
      default: MIMEType.imageJpeg
    }
        
    let fileName = "profile_photo.\(fileType.preferredFilenameExtension ?? "png")"
        
    let result = try await ApiClient.shared
      .uploadFile(
        type: .photo,
        data: data,
        filename: fileName,
        mimeType: mimeType,
        progress: { _ in }
      )
        
    let result2 = try await ApiClient.shared.updateProfilePhoto(fileUniqueId: result.fileUniqueId)
        
    _ = try await AppDatabase.shared.dbWriter.write { db in
      try result2.user.saveFull(db)
    }
  }
}

// MARK: - File Upload ViewModel

@MainActor
final class FileUploadViewModel: ObservableObject {
  @Published private(set) var isUploading = false
  @Published var errorState: ErrorState?
  @Published var showImagePicker = false
    
  struct ErrorState {
    let title: String
    let message: String
    let suggestion: String?
  }
    
  func uploadImage(from url: URL) async {
    guard !isUploading else { return }
    isUploading = true
        
    do {
      try await FileService.shared.uploadImage(from: url)
    } catch let error as FileError {
      Log.shared.error("Failed to upload image", error: error)
      showError(error)
    } catch {
      Log.shared.error("Failed to upload image", error: error)
      showError(FileError.unknown(error))
    }
        
    isUploading = false
  }
    
  func uploadImage(_ data: Data, fileType: UTType) async {
    guard !isUploading else { return }
    isUploading = true
        
    do {
      try await FileService.shared.uploadImage(data, fileType: fileType)
    } catch let error as FileError {
      Log.shared.error("Failed to upload image", error: error)
      showError(error)
    } catch {
      Log.shared.error("Failed to upload image", error: error)
      showError(FileError.unknown(error))
    }
        
    isUploading = false
  }
    
  private func showError(_ error: FileError) {
    errorState = ErrorState(
      title: "Upload Error",
      message: error.errorDescription ?? "An unknown error occurred",
      suggestion: error.recoverySuggestion
    )
  }
}
