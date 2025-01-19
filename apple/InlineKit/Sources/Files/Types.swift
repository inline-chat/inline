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
    case .fileTooLarge(let size):
      return "File size \(size)MB exceeds maximum allowed size"
    case .invalidFileType(let ext):
      return "File type .\(ext) is not supported"
    case .preparationFailed:
      return "Failed to prepare file for upload"
    case .uploadFailed:
      return "Failed to upload file"
    }
  }
}
