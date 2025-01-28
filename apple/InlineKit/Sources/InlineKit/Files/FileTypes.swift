import Foundation

public enum UploadState {
  case idle
  case preparing
  case uploading(progress: Double)
  case completed(url: URL)
  case failed(Error)
}

public enum UploadError: LocalizedError {
  case fileTooLarge(size: Int)
  case invalidFileType(extension: String)
  case preparationFailed
  case uploadFailed

  public var errorDescription: String? {
    switch self {
      case let .fileTooLarge(size):
        "File size \(size)MB exceeds maximum allowed size"
      case let .invalidFileType(ext):
        "File type .\(ext) is not supported"
      case .preparationFailed:
        "Failed to prepare file for upload"
      case .uploadFailed:
        "Failed to upload file"
    }
  }
}
