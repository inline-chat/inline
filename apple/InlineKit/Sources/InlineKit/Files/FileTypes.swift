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

public enum FileMediaItem: Codable, Sendable {
  case photo(PhotoInfo)
  case document(DocumentInfo)
  case video(VideoInfo)

  var id: Int64 {
    switch self {
      case let .photo(photo):
        photo.id
      case let .document(document):
        document.id
      case let .video(video):
        video.id
    }
  }

  public func getLocalPath() -> String? {
    switch self {
      case let .photo(photo):
        photo.sizes.first?.localPath
      case let .document(document):
        document.document.localPath
      case let .video(video):
        video.video.localPath
    }
  }

  public func getFilename() -> String? {
    let localPath = getLocalPath()
    return localPath?.components(separatedBy: "/").last
  }
  
  
  // ID helpers
  public func asPhotoLocalId() -> Int64? {
    guard case let .photo(photo) = self else { return nil }
    return photo.photo.id
  }
  public func asVideoLocalId() -> Int64? {
    guard case let .video(video) = self else { return nil }
    return video.video.id
  }
  public func asDocumentLocalId() -> Int64? {
    guard case let .document(document) = self else { return nil }
    return document.document.id
  }
  public func asPhotoId() -> Int64? {
    guard case let .photo(photo) = self else { return nil }
    return photo.photo.photoId
  }
  public func asVideoId() -> Int64? {
    guard case let .video(video) = self else { return nil }
    return video.video.videoId
  }
  public func asDocumentId() -> Int64? {
    guard case let .document(document) = self else { return nil }
    return document.document.documentId
  }
}
