import InlineProtocol

public extension InlineProtocol.Photo.Format {
  func toExtension() -> String {
    switch self {
      case .jpeg: ".jpeg"
      case .png: ".png"
      default: ".jpeg"
    }
  }

  func toMimeType() -> String {
    switch self {
      case .jpeg: "image/jpeg"
      case .png: "image/png"
      default: "image/jpeg"
    }
  }
  
  func toImageFormat() -> ImageFormat {
    switch self {
      case .jpeg: .jpeg
      case .png: .png
      default: .jpeg
    }
  }
}

public extension InputMedia {
  /// From photo server ID received from the server after upload
  static func fromPhotoId(_ photoId: Int64) -> InputMedia {
    InputMedia.with {
      $0.media = .photo(.with {
        $0.photoID = photoId
      })
    }
  }
  
  static func fromVideoId(_ videoId: Int64) -> InputMedia {
    InputMedia.with {
      $0.media = .video(.with {
        $0.videoID = videoId
      })
    }
  }
  
  static func fromDocumentId(_ documentId: Int64) -> InputMedia {
    InputMedia.with {
      $0.media = .document(.with {
        $0.documentID = documentId
      })
    }
  }
}
