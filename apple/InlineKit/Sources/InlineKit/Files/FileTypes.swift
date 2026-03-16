import Foundation
import InlineProtocol

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
  case voice(Client_MessageVoiceContent)

  var id: Int64 {
    switch self {
      case let .photo(photo):
        photo.id
      case let .document(document):
        document.id
      case let .video(video):
        video.id
      case let .voice(voice):
        voice.voiceID
    }
  }

  public func getLocalPath() -> String? {
    switch self {
      case let .photo(photo):
        return photo.sizes.first?.localPath
      case let .document(document):
        return document.document.localPath
      case let .video(video):
        return video.video.localPath
      case let .voice(voice):
        let localPath = voice.localRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return localPath.isEmpty ? nil : localPath
    }
  }

  public func getFilename() -> String? {
    let localPath = getLocalPath()
    return localPath?.components(separatedBy: "/").last
  }

  public func localFileURL() -> URL? {
    switch self {
    case let .photo(photoInfo):
      guard let localPath = photoInfo.bestPhotoSize()?.localPath else { return nil }
      return FileCache.getUrl(for: .photos, localPath: localPath)
    case let .document(documentInfo):
      guard let localPath = documentInfo.document.localPath else { return nil }
      return FileCache.getUrl(for: .documents, localPath: localPath)
    case let .video(videoInfo):
      guard let localPath = videoInfo.video.localPath else { return nil }
      return FileCache.getUrl(for: .videos, localPath: localPath)
    case let .voice(voice):
      let localPath = voice.localRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !localPath.isEmpty else { return nil }
      return FileCache.getUrl(for: .voices, localPath: localPath)
    }
  }

  // Helpers
  public func getItemUniqueId() -> String {
    switch self {
      case let .photo(photo):
        "photo_\(photo.id)"
      case let .document(document):
        "document_\(document.id)"
      case let .video(video):
        "video_\(video.id)"
      case let .voice(voice):
        "voice_\(voice.voiceID)"
    }
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

  public func asVoiceLocalId() -> Int64? {
    guard case let .voice(voice) = self else { return nil }
    return voice.voiceID
  }

  public func asVoiceId() -> Int64? {
    guard case let .voice(voice) = self else { return nil }
    return voice.voiceID
  }

  public func asVoiceContent() -> Client_MessageVoiceContent? {
    guard case let .voice(voice) = self else { return nil }
    return voice
  }
}
