import Foundation
import GRDB
import InlineProtocol

/// Manages media database operations for the application
final class MediaHelpers: Sendable {
  public static let shared = MediaHelpers()
  private let database: AppDatabase

  init(database: AppDatabase = AppDatabase.shared) {
    self.database = database
  }

  // MARK: - Photo Methods

  /// Creates a local photo with a temporary ID
  /// - Parameters:
  ///   - format: Photo format (jpeg, png, etc.)
  ///   - data: Optional image data
  ///   - width: Image width
  ///   - height: Image height
  /// - Returns: The created photo with its local ID and a temporary negative server ID
  func createLocalPhoto(
    format: ImageFormat = .jpeg,
    localPath: String? = nil,
    fileSize: Int? = nil,
    width: Int? = nil,
    height: Int? = nil
  ) throws -> PhotoInfo {
    try database.dbWriter.write { db in
      // Create a temporary negative ID to avoid conflicts with server IDs
      let tempId = Int64(bitPattern: UInt64(arc4random()) | (UInt64(arc4random()) << 32)) * -1

      // Create and save the photo
      var photo_ = Photo(
        photoId: tempId,
        date: Date(),
        format: format
      )
      let photo = try photo_.inserted(db)

      // If we have dimensions, create a photoSize

      let photoSize_ = PhotoSize(
        photoId: photo.id!,
        type: "f",
        width: width ?? 0,
        height: height ?? 0,
        size: fileSize,
        bytes: nil,
        cdnUrl: nil,
        localPath: localPath
      )
      let photoSize = try photoSize_.inserted(db)

      return PhotoInfo(photo: photo, sizes: [photoSize_])
    }
  }

  /// Adds a size to an existing photo
  /// - Parameters:
  ///   - photo: The photo to add the size to
  ///   - type: Size type (b, c, d, f, s, etc.)
  ///   - width: Width in pixels
  ///   - height: Height in pixels
  ///   - data: Optional image data
  ///   - localPath: Optional local file path
  /// - Returns: The created PhotoSize
  func addPhotoSize(
    photo: Photo,
    type: String,
    width: Int?,
    height: Int?,
    data: Data? = nil,
    localPath: String? = nil
  ) throws -> PhotoSize {
    try database.dbWriter.write { db in
      guard let photoId = photo.id else {
        throw NSError(
          domain: "MediaManager",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Photo has no local ID"]
        )
      }

      let photoSize = PhotoSize(
        photoId: photoId,
        type: type,
        width: width,
        height: height,
        size: data?.count,
        bytes: data,
        cdnUrl: nil,
        localPath: localPath
      )
      try photoSize.insert(db)
      return photoSize
    }
  }

  /// Updates a photo with a server ID and other server data
  /// - Parameters:
  ///   - photo: The local photo to update
  ///   - serverId: The server-provided ID
  ///   - fileUniqueId: Optional file unique ID from server
  /// - Returns: The updated photo
  func updatePhotoWithServerData(
    photo: Photo,
    serverId: Int64,
    fileUniqueId: String? = nil
  ) throws -> Photo {
    try database.dbWriter.write { db in
      guard let localId = photo.id else {
        throw NSError(
          domain: "MediaManager",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Photo has no local ID"]
        )
      }

      // Get the old photoId for updating message references
      let oldPhotoId = photo.photoId

      // Update the photo
      var updatedPhoto = photo
      updatedPhoto.photoId = serverId
      try updatedPhoto.update(db)

      // Update any messages that reference the old temporary ID
      try Message
        .filter(Message.Columns.photoId == oldPhotoId)
        .updateAll(db, Message.Columns.photoId.set(to: serverId))

      return updatedPhoto
    }
  }

  /// Saves a photo from a protocol buffer
  /// - Parameter proto: The protocol buffer photo
  /// - Returns: The saved photo
  func savePhotoFromProto(_ proto: InlineProtocol.Photo) throws -> Photo {
    try database.dbWriter.write { db in
      // Check if we already have this photo by server ID
      if let existingPhoto = try Photo.filter(Photo.Columns.photoId == proto.id).fetchOne(db) {
        return existingPhoto
      }

      // Create the photo
      var photo = Photo(
        photoId: proto.id,
        date: Date(timeIntervalSince1970: TimeInterval(proto.date)),
        format: proto.format.toImageFormat()
      )
      try photo.insert(db)

      // Add photo sizes
      for protoSize in proto.sizes {
        let photoSize = PhotoSize(
          photoId: photo.id!,
          type: protoSize.type,
          width: protoSize.w > 0 ? Int(protoSize.w) : nil,
          height: protoSize.h > 0 ? Int(protoSize.h) : nil,
          size: protoSize.size > 0 ? Int(protoSize.size) : nil,
          bytes: protoSize.hasBytes ? protoSize.bytes : nil,
          cdnUrl: protoSize.hasCdnURL ? protoSize.cdnURL : nil
        )
        try photoSize.insert(db)
      }

      return photo
    }
  }

  // MARK: - Video Methods

  /// Creates a local video with a temporary ID
  /// - Parameters:
  ///   - width: Video width
  ///   - height: Video height
  ///   - duration: Video duration in seconds
  ///   - thumbnail: Optional thumbnail photo
  /// - Returns: The created video
  func createLocalVideo(
    width: Int? = nil,
    height: Int? = nil,
    duration: Int? = nil,
    thumbnail: Photo? = nil
  ) throws -> Video {
    try database.dbWriter.write { db in
      // Create a temporary negative ID
      let tempId = Int64(bitPattern: UInt64(arc4random()) | (UInt64(arc4random()) << 32)) * -1

      // Create and save the video
      var video = Video(
        videoId: tempId,
        date: Date(),
        width: width,
        height: height,
        duration: duration,
        size: nil,
        thumbnailPhotoId: thumbnail?.id,
        cdnUrl: nil,
        localPath: nil
      )
      try video.insert(db)

      return video
    }
  }

  /// Updates a video with server data
  /// - Parameters:
  ///   - video: The local video to update
  ///   - serverId: The server-provided ID
  ///   - size: Optional file size
  ///   - cdnUrl: Optional CDN URL
  /// - Returns: The updated video
  func updateVideoWithServerData(
    video: Video,
    serverId: Int64,
    size: Int? = nil,
    cdnUrl: String? = nil
  ) throws -> Video {
    try database.dbWriter.write { db in
      guard let localId = video.id else {
        throw NSError(
          domain: "MediaManager",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Video has no local ID"]
        )
      }

      // Get the old videoId for updating message references
      let oldVideoId = video.videoId

      // Update the video
      var updatedVideo = video
      updatedVideo.videoId = serverId
      if let size {
        updatedVideo.size = size
      }
      if let cdnUrl {
        updatedVideo.cdnUrl = cdnUrl
      }
      try updatedVideo.update(db)

      // Update any messages that reference the old temporary ID
      try Message
        .filter(Message.Columns.videoId == oldVideoId)
        .updateAll(db, Message.Columns.videoId.set(to: serverId))

      return updatedVideo
    }
  }

  /// Sets a thumbnail for a video
  /// - Parameters:
  ///   - video: The video to update
  ///   - thumbnail: The thumbnail photo
  func setVideoThumbnail(video: Video, thumbnail: Photo) throws {
    try database.dbWriter.write { db in
      guard let videoId = video.id, let thumbnailId = thumbnail.id else {
        throw NSError(
          domain: "MediaManager",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Missing local IDs"]
        )
      }

      var updatedVideo = video
      updatedVideo.thumbnailPhotoId = thumbnailId
      try updatedVideo.update(db)
    }
  }

  /// Saves a video from a protocol buffer
  /// - Parameter proto: The protocol buffer video
  /// - Returns: The saved video
  func saveVideoFromProto(_ proto: InlineProtocol.Video) throws -> Video {
    try database.dbWriter.write { db in
      // Check if we already have this video by server ID
      if let existingVideo = try Video.filter(Video.Columns.videoId == proto.id).fetchOne(db) {
        return existingVideo
      }

      // If the video has a thumbnail photo, save it first
      var thumbnailPhotoId: Int64? = nil
      if proto.hasPhoto {
        let thumbnail = try savePhotoFromProto(proto.photo)
        thumbnailPhotoId = thumbnail.id
      }

      // Create the video
      var video = Video.from(proto: proto, localPhotoId: thumbnailPhotoId)
      try video.insert(db)

      return video
    }
  }

  // MARK: - Document Methods

  /// Creates a local document with a temporary ID
  /// - Parameters:
  ///   - fileName: Document file name
  ///   - mimeType: Document MIME type
  ///   - size: File size in bytes
  ///   - thumbnail: Optional thumbnail photo
  /// - Returns: The created document
  func createLocalDocument(
    fileName: String? = nil,
    mimeType: String? = nil,
    size: Int? = nil,
    thumbnail: Photo? = nil
  ) throws -> Document {
    try database.dbWriter.write { db in
      // Create a temporary negative ID
      let tempId = Int64(bitPattern: UInt64(arc4random()) | (UInt64(arc4random()) << 32)) * -1

      // Create and save the document
      var document = Document(
        documentId: tempId,
        date: Date(),
        fileName: fileName,
        mimeType: mimeType,
        size: size,
        cdnUrl: nil,
        localPath: nil,
        thumbnailPhotoId: thumbnail?.id
      )
      try document.insert(db)

      return document
    }
  }

  /// Updates a document with server data
  /// - Parameters:
  ///   - document: The local document to update
  ///   - serverId: The server-provided ID
  ///   - fileUniqueId: Optional file unique ID
  ///   - cdnUrl: Optional CDN URL
  /// - Returns: The updated document
  func updateDocumentWithServerData(
    document: Document,
    serverId: Int64,
    fileUniqueId: String? = nil,
    cdnUrl: String? = nil
  ) throws -> Document {
    try database.dbWriter.write { db in
      guard let localId = document.id else {
        throw NSError(
          domain: "MediaManager",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Document has no local ID"]
        )
      }

      // Get the old documentId for updating message references
      let oldDocumentId = document.documentId

      // Update the document
      var updatedDocument = document
      updatedDocument.documentId = serverId
      updatedDocument.fileUniqueId = fileUniqueId
      if let cdnUrl {
        updatedDocument.cdnUrl = cdnUrl
      }
      try updatedDocument.update(db)

      // Update any messages that reference the old temporary ID
      try Message
        .filter(Message.Columns.documentId == oldDocumentId)
        .updateAll(db, Message.Columns.documentId.set(to: serverId))

      return updatedDocument
    }
  }

  /// Sets a thumbnail for a document
  /// - Parameters:
  ///   - document: The document to update
  ///   - thumbnail: The thumbnail photo
  func setDocumentThumbnail(document: Document, thumbnail: Photo) throws {
    try database.dbWriter.write { db in
      guard let documentId = document.id, let thumbnailId = thumbnail.id else {
        throw NSError(
          domain: "MediaManager",
          code: 400,
          userInfo: [NSLocalizedDescriptionKey: "Missing local IDs"]
        )
      }

      var updatedDocument = document
      updatedDocument.thumbnailPhotoId = thumbnailId
      try updatedDocument.update(db)
    }
  }

  /// Saves a document from a protocol buffer
  /// - Parameter proto: The protocol buffer document
  /// - Returns: The saved document
  func saveDocumentFromProto(_ proto: InlineProtocol.Document) throws -> Document {
    try database.dbWriter.write { db in
      // Check if we already have this document by server ID
      if let existingDocument = try Document.filter(Document.Columns.documentId == proto.id).fetchOne(db) {
        return existingDocument
      }

      // Create the document
      var document = Document.from(proto: proto)

      try document.insert(db)

      return document
    }
  }

  // MARK: - Message Media Methods

  /// Attaches a photo to a message
  /// - Parameters:
  ///   - photo: The photo to attach
  ///   - message: The message to update
  func attachPhotoToMessage(photo: Photo, message: inout Message) throws {
    try database.dbWriter.write { db in
      message.photoId = photo.photoId
      try message.update(db)
    }
  }

  /// Attaches a video to a message
  /// - Parameters:
  ///   - video: The video to attach
  ///   - message: The message to update
  func attachVideoToMessage(video: Video, message: inout Message) throws {
    try database.dbWriter.write { db in
      message.videoId = video.videoId
      try message.update(db)
    }
  }

  /// Attaches a document to a message
  /// - Parameters:
  ///   - document: The document to attach
  ///   - message: The message to update
  func attachDocumentToMessage(document: Document, message: inout Message) throws {
    try database.dbWriter.write { db in
      message.documentId = document.documentId
      try message.update(db)
    }
  }

  // MARK: - Utility Methods

  /// Gets the best available photo size for a photo
  /// - Parameters:
  ///   - photo: The photo to get a size for
  ///   - maxWidth: Maximum desired width
  ///   - maxHeight: Maximum desired height
  /// - Returns: The best matching photo size or nil if none found
  func getBestPhotoSize(photo: Photo, maxWidth: Int, maxHeight: Int) throws -> PhotoSize? {
    try database.dbWriter.read { db in
      guard let photoId = photo.id else { return nil }

      // Get all sizes for this photo
      let sizes = try PhotoSize
        .filter(PhotoSize.Columns.photoId == photoId)
        .filter(PhotoSize.Columns.width != nil && PhotoSize.Columns.height != nil)
        .fetchAll(db)

      if sizes.isEmpty { return nil }

      // Sort by area, largest first
      let sortedSizes = sizes.sorted {
        (($0.width ?? 0) * ($0.height ?? 0)) > (($1.width ?? 0) * ($1.height ?? 0))
      }

      // Find the first size that fits within our constraints
      for size in sortedSizes {
        if let width = size.width, let height = size.height,
           width <= maxWidth, height <= maxHeight
        {
          return size
        }
      }

      // If no perfect match, return the smallest size
      return sortedSizes.last
    }
  }

  /// Updates the local path for a media item
  /// - Parameters:
  ///   - mediaType: The type of media (photo, video, document)
  ///   - id: The ID of the media (local or server ID)
  ///   - isLocalId: Whether the ID is a local ID or server ID
  ///   - path: The local file path
  func updateLocalPath(
    mediaType: MediaType,
    id: Int64,
    isLocalId: Bool = true,
    path: String
  ) throws {
    try database.dbWriter.write { db in
      switch mediaType {
        case .photo:
          if isLocalId {
            try Photo
              .filter(Photo.Columns.id == id)
              .updateAll(db, [Column("localPath").set(to: path)])
          } else {
            try Photo
              .filter(Photo.Columns.photoId == id)
              .updateAll(db, [Column("localPath").set(to: path)])
          }

        case .photoSize:
          try PhotoSize
            .filter(PhotoSize.Columns.id == id)
            .updateAll(db, PhotoSize.Columns.localPath.set(to: path))

        case .video:
          if isLocalId {
            try Video
              .filter(Video.Columns.id == id)
              .updateAll(db, Video.Columns.localPath.set(to: path))
          } else {
            try Video
              .filter(Video.Columns.videoId == id)
              .updateAll(db, Video.Columns.localPath.set(to: path))
          }

        case .document:
          if isLocalId {
            try Document
              .filter(Document.Columns.id == id)
              .updateAll(db, Document.Columns.localPath.set(to: path))
          } else {
            try Document
              .filter(Document.Columns.documentId == id)
              .updateAll(db, Document.Columns.localPath.set(to: path))
          }
      }
    }
  }

  // MARK: - Private Helpers

  enum MediaType {
    case photo
    case photoSize
    case video
    case document
  }
}
