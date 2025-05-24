import Foundation
import GRDB
import InlineProtocol
import Logger

// MARK: - Photo

public struct Photo: Codable, Equatable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
  // Local auto-incremented ID
  public var id: Int64?

  // Server-provided ID (or temporary ID before upload)
  public var photoId: Int64

  public var date: Date
  public var format: ImageFormat

  public enum Columns {
    static let id = Column(CodingKeys.id)
    static let photoId = Column(CodingKeys.photoId)
    static let date = Column(CodingKeys.date)
    static let format = Column(CodingKeys.format)
  }

  public init(
    id: Int64? = nil,
    photoId: Int64,
    date: Date = Date(),
    format: ImageFormat
  ) {
    self.id = id
    self.photoId = photoId
    self.date = date
    self.format = format
  }
}

// MARK: - PhotoSize

public struct PhotoSize: Codable, Sendable, Equatable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
  public var id: Int64?
  public var photoId: Int64
  public var type: String // "b", "c", "d", "f", "s", etc.
  public var width: Int?
  public var height: Int?
  public var size: Int?
  public var bytes: Data?
  public var cdnUrl: String?
  public var localPath: String?

  public enum Columns {
    static let id = Column(CodingKeys.id)
    static let photoId = Column(CodingKeys.photoId)
    static let type = Column(CodingKeys.type)
    static let width = Column(CodingKeys.width)
    static let height = Column(CodingKeys.height)
    static let size = Column(CodingKeys.size)
    static let bytes = Column(CodingKeys.bytes)
    static let cdnUrl = Column(CodingKeys.cdnUrl)
    static let localPath = Column(CodingKeys.localPath)
  }

  public init(
    id: Int64? = nil,
    photoId: Int64,
    type: String = "f",
    width: Int? = nil,
    height: Int? = nil,
    size: Int? = nil,
    bytes: Data? = nil,
    cdnUrl: String? = nil,
    localPath: String? = nil
  ) {
    self.id = id
    self.photoId = photoId
    self.type = type
    self.width = width
    self.height = height
    self.size = size
    self.bytes = bytes
    self.cdnUrl = cdnUrl
    self.localPath = localPath
  }
}

// MARK: - Video

public struct Video: Codable, Sendable, Equatable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
  // Local auto-incremented ID
  public var id: Int64?

  // Server-provided ID (or temporary ID before upload)
  public var videoId: Int64

  public var date: Date
  public var width: Int?
  public var height: Int?
  public var duration: Int?
  public var size: Int?
  public var thumbnailPhotoId: Int64?
  public var cdnUrl: String?
  public var localPath: String?

  public enum Columns {
    static let id = Column(CodingKeys.id)
    static let videoId = Column(CodingKeys.videoId)
    static let date = Column(CodingKeys.date)
    static let width = Column(CodingKeys.width)
    static let height = Column(CodingKeys.height)
    static let duration = Column(CodingKeys.duration)
    static let size = Column(CodingKeys.size)
    static let thumbnailPhotoId = Column(CodingKeys.thumbnailPhotoId)
    static let cdnUrl = Column(CodingKeys.cdnUrl)
    static let localPath = Column(CodingKeys.localPath)
  }
}

// MARK: - Document

public struct Document: Codable, Sendable, Equatable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
  // Local auto-incremented ID
  public var id: Int64?

  // Server-provided ID (or temporary ID before upload)
  public var documentId: Int64

  public var date: Date
  public var fileName: String?
  public var mimeType: String?
  public var size: Int?
  public var cdnUrl: String?
  public var localPath: String?
  public var thumbnailPhotoId: Int64?

  public enum Columns {
    static let id = Column(CodingKeys.id)
    static let documentId = Column(CodingKeys.documentId)
    static let date = Column(CodingKeys.date)
    static let fileName = Column(CodingKeys.fileName)
    static let mimeType = Column(CodingKeys.mimeType)
    static let size = Column(CodingKeys.size)
    static let cdnUrl = Column(CodingKeys.cdnUrl)
    static let localPath = Column(CodingKeys.localPath)
    static let thumbnailPhotoId = Column(CodingKeys.thumbnailPhotoId)
  }
}

// MARK: - Photo Relationships

public extension Photo {
  static let sizes = hasMany(PhotoSize.self)

  var sizes: QueryInterfaceRequest<PhotoSize> {
    request(for: Photo.sizes)
  }
}

// MARK: - PhotoSize Relationships

public extension PhotoSize {
  // Relationship to photo using the local ID
  static let photo = belongsTo(Photo.self, using: ForeignKey(["photoId"], to: ["id"]))

  var photo: QueryInterfaceRequest<Photo> {
    request(for: PhotoSize.photo)
  }
}

// MARK: - Video Relationships

public extension Video {
  static let thumbnail = belongsTo(Photo.self, using: ForeignKey(["thumbnailPhotoId"], to: ["id"]))

  var thumbnail: QueryInterfaceRequest<Photo> {
    request(for: Video.thumbnail)
  }
}

// MARK: - Document Relationships

public extension Document {
  static let thumbnail = belongsTo(Photo.self, using: ForeignKey(["thumbnailPhotoId"], to: ["id"]))

  var thumbnail: QueryInterfaceRequest<Photo> {
    request(for: Document.thumbnail)
  }
}

// MARK: - Conversion From Protocol

public extension Photo {
  static func from(proto: InlineProtocol.Photo) -> Photo {
    Photo(
      photoId: proto.id,
      date: Date(timeIntervalSince1970: TimeInterval(proto.date)),
      format: proto.format.toImageFormat()
    )
  }

  /// Saves an InlineProtocol.Photo and its associated PhotoSize objects into the database.
  /// - Parameters:
  ///   - db: The database connection
  ///   - photo: The InlineProtocol.Photo to save
  /// - Returns: The saved Photo object (with local id and server photoId)
  @discardableResult
  static func savePhotoFromProtocol(_ db: Database, photo protoPhoto: InlineProtocol.Photo) throws -> Photo {
    // Create the Photo from protocol and insert or update
    var photo = Photo.from(proto: protoPhoto)
    // Try to find existing photo by server photoId
    if let existing = try Photo.filter(Photo.Columns.photoId == protoPhoto.id).fetchOne(db) {
      photo.id = existing.id
      try photo.update(db)
    } else {
      photo = try photo.insertAndFetch(db)
    }
    // Save associated PhotoSize objects, referencing Photo.id
    for protoSize in protoPhoto.sizes {
      var size = PhotoSize.from(proto: protoSize, photoId: photo.id!)
      // Try to find existing size by photoId (local) and type
      if let existingSize = try PhotoSize.filter(PhotoSize.Columns.photoId == photo.id!)
        .filter(PhotoSize.Columns.type == protoSize.type).fetchOne(db)
      {
        size.id = existingSize.id
        try size.update(db)
      } else {
        try size.insert(db)
      }
    }
    return photo
  }
}

public extension PhotoSize {
  static func from(proto: InlineProtocol.PhotoSize, photoId: Int64) -> PhotoSize {
    PhotoSize(
      photoId: photoId,
      type: proto.type,
      width: proto.w > 0 ? Int(proto.w) : nil,
      height: proto.h > 0 ? Int(proto.h) : nil,
      size: proto.size > 0 ? Int(proto.size) : nil,
      bytes: proto.bytes.isEmpty ? nil : proto.bytes,
      cdnUrl: proto.cdnURL.isEmpty ? nil : proto.cdnURL
    )
  }
}

public extension Video {
  static func from(proto: InlineProtocol.Video, localPhotoId: Int64?) -> Video {
    Video(
      videoId: proto.id,
      date: Date(timeIntervalSince1970: TimeInterval(proto.date)),
      width: proto.w > 0 ? Int(proto.w) : nil,
      height: proto.h > 0 ? Int(proto.h) : nil,
      duration: proto.duration > 0 ? Int(proto.duration) : nil,
      size: proto.size > 0 ? Int(proto.size) : nil,
      thumbnailPhotoId: localPhotoId,
      cdnUrl: proto.cdnURL.isEmpty ? nil : proto.cdnURL
    )
  }
}

public extension Document {
  static func from(proto: InlineProtocol.Document) -> Document {
    Document(
      documentId: proto.id,
      date: Date(timeIntervalSince1970: TimeInterval(proto.date)),
      fileName: proto.fileName.isEmpty ? nil : proto.fileName,
      mimeType: proto.mimeType.isEmpty ? nil : proto.mimeType,
      size: proto.size > 0 ? Int(proto.size) : nil,
      cdnUrl: proto.cdnURL.isEmpty ? nil : proto.cdnURL
    )
  }
}

// MARK: - Helpers

public extension AppDatabase {
  // Update a photo with the server-provided ID
  static func updatePhotoWithServerId(_ db: Database, localPhoto: Photo, serverId: Int64) throws {
    Log.shared.debug("Updating photo with server ID \(localPhoto) \(serverId)")
    // Get the old photoId
    let oldPhotoId = localPhoto.photoId

    // Nil first to avoid constraint violation
    var msg = try Message.filter(
      Column("photoId") == oldPhotoId
    ).fetchOne(db)
    msg?.photoId = nil
    try msg?.save(db)

    // Update the photo with the server ID
    var updatedPhoto = localPhoto
    updatedPhoto.photoId = serverId
    try updatedPhoto.update(db)

    // Update any messages that reference the old temporary ID
//    try db.execute(sql: """
//        UPDATE message
//        SET photoId = ?
//        WHERE photoId = ?
//    """, arguments: [serverId, oldPhotoId])
    msg?.photoId = serverId
    try msg?.save(db)
  }

  // Update a video with the server-provided ID
  static func updateVideoWithServerId(_ db: Database, localVideo: Video, serverId: Int64) throws {
    // Get the old videoId
    let oldVideoId = localVideo.videoId

    // Nil first to avoid constraint violation
    var msg = try Message.filter(
      Column("videoId") == oldVideoId
    ).fetchOne(db)
    msg?.videoId = nil
    try msg?.save(db)

    // Update the video with the server ID
    var updatedVideo = localVideo
    updatedVideo.videoId = serverId
    try updatedVideo.update(db)

    // Update any messages that reference the old temporary ID
//    try db.execute(sql: """
//        UPDATE message
//        SET videoId = ?
//        WHERE videoId = ?
//    """, arguments: [serverId, oldVideoId])

    msg?.videoId = serverId
    try msg?.save(db)
  }

  // Update a document with the server-provided ID
  static func updateDocumentWithServerId(_ db: Database, localDocument: Document, serverId: Int64) throws {
    // Get the old documentId
    let oldDocumentId = localDocument.documentId

    // Nil first to avoid constraint violation
    var msg = try Message.filter(
      Column("documentId") == oldDocumentId
    ).fetchOne(db)
    msg?.documentId = nil
    try msg?.save(db)

    // Update the document with the server ID
    var updatedDocument = localDocument
    updatedDocument.documentId = serverId
    try updatedDocument.update(db)

    // Update any messages that reference the old temporary ID
//    try db.execute(sql: """
//        UPDATE message
//        SET documentId = ?
//        WHERE documentId = ?
//    """, arguments: [serverId, oldDocumentId])

    msg?.documentId = serverId
    try msg?.save(db)

    Log.shared.debug("Updated document with server ID \(serverId) \(updatedDocument)")
  }

  // Find a photo by its server ID
  static func findPhotoByServerId(_ db: Database, _ photoId: Int64) throws -> Photo? {
    try Photo.filter(Photo.Columns.photoId == photoId).fetchOne(db)
  }

  // Find a video by its server ID
  static func findVideoByServerId(_ db: Database, _ videoId: Int64) throws -> Video? {
    try Video.filter(Video.Columns.videoId == videoId).fetchOne(db)
  }

  // Find a document by its server ID
  static func findDocumentByServerId(_ db: Database, _ documentId: Int64) throws -> Document? {
    try Document.filter(Document.Columns.documentId == documentId).fetchOne(db)
  }
}

// MARK: - Full Types

public struct PhotoInfo: Codable, Equatable, FetchableRecord, Hashable, PersistableRecord, Sendable, Identifiable {
  public var id: Int64 { photo.id ?? photo.photoId }
  public var photo: Photo
  public var sizes: [PhotoSize]

  // coding keys
  public enum CodingKeys: String, CodingKey {
    case photo
    case sizes
  }

  public init(photo: Photo, sizes: [PhotoSize] = []) {
    self.photo = photo
    self.sizes = sizes
  }

  // helpers
  public func bestPhotoSize() -> PhotoSize? {
    sizes.first { $0.type == "f" } ?? sizes.first
  }
}

public struct VideoInfo: Codable, Equatable, FetchableRecord, Hashable, PersistableRecord, Sendable, Identifiable {
  public var id: Int64 { video.id ?? video.videoId }
  public var video: Video
  public var thumbnail: PhotoInfo?

  // coding keys
  public enum CodingKeys: String, CodingKey {
    case video
    case thumbnail
  }

  public init(video: Video, photoInfo: PhotoInfo? = nil) {
    self.video = video
    thumbnail = photoInfo
  }
}

public struct DocumentInfo: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
  public var id: Int64 { document.id ?? document.documentId }
  public var document: Document
  public var thumbnail: PhotoInfo?

  // coding keys
  public enum CodingKeys: String, CodingKey {
    case document
    case thumbnail
  }

  public init(document: Document, photoInfo: PhotoInfo? = nil) {
    self.document = document
    thumbnail = photoInfo
  }
}

// MARK: - Local Creators

public extension Photo {
  static func createLocalPhoto(
    _ db: Database,
    format: ImageFormat = .jpeg,
    localPath: String? = nil,
    fileSize: Int? = nil,
    width: Int? = nil,
    height: Int? = nil
  ) throws -> PhotoInfo {
    // Create a temporary negative ID to avoid conflicts with server IDs
    let tempId = Int64(bitPattern: UInt64(arc4random()) | (UInt64(arc4random()) << 32)) * -1

    // Create and save the photo
    var photo_ = Photo(
      photoId: tempId,
      date: Date(),
      format: format
    )
    let photo = try photo_.insertAndFetch(db)

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
    let photoSize = try photoSize_.insertAndFetch(db)

    return PhotoInfo(photo: photo, sizes: [photoSize])
  }
}

extension Document {
  /// Creates a local document with a temporary ID
  /// - Parameters:
  ///   - fileName: Document file name
  ///   - mimeType: Document MIME type
  ///   - size: File size in bytes
  ///   - thumbnail: Optional thumbnail photo
  /// - Returns: The created document
  static func createLocalDocument(
    _ db: Database,
    fileName: String? = nil,
    mimeType: String? = nil,
    size: Int? = nil,
    localPath: String? = nil,
    thumbnail: Photo? = nil
  ) throws -> DocumentInfo {
    // Create a temporary negative ID
    let tempId = Int64(bitPattern: UInt64(arc4random()) | (UInt64(arc4random()) << 32)) * -1

    // Create and save the document
    let document_ = Document(
      documentId: tempId,
      date: Date(),
      fileName: fileName,
      mimeType: mimeType,
      size: size,
      cdnUrl: nil,
      localPath: localPath,
      thumbnailPhotoId: thumbnail?.id
    )
    let document = try document_.saveAndFetch(db)

    // TODO: support thumbnails
    return DocumentInfo(document: document)
  }
}

// MARK: - Update from protocol

public extension Document {
  // Add this method to update from protocol while preserving local path
  static func updateFromProtocol(_ db: Database, protoDocument: InlineProtocol.Document) throws -> Document {
    // Try to find existing document
    if let existingDocument = try Document.filter(Column("documentId") == protoDocument.id).fetchOne(db) {
      // Create updated document with preserved local path
      var updatedDocument = Document(
        id: existingDocument.id,
        documentId: protoDocument.id,
        date: Date(timeIntervalSince1970: TimeInterval(protoDocument.date)),
        fileName: protoDocument.fileName,
        mimeType: protoDocument.mimeType,
        size: protoDocument.size > 0 ? Int(protoDocument.size) : nil,
        cdnUrl: protoDocument.hasCdnURL ? protoDocument.cdnURL : nil,
        localPath: existingDocument.localPath // Preserve local path
      )
      Log.shared.debug("Updating document with ID \(protoDocument.id) \(protoDocument.fileName) \(updatedDocument)")

      // Save the updated document
      try updatedDocument.save(db, onConflict: .replace)
      return updatedDocument
    } else {
      // Create new document if it doesn't exist
      let newDocument = Document(
        documentId: protoDocument.id,
        date: Date(timeIntervalSince1970: TimeInterval(protoDocument.date)),
        fileName: protoDocument.fileName,
        mimeType: protoDocument.mimeType,
        size: protoDocument.size > 0 ? Int(protoDocument.size) : nil,
        cdnUrl: protoDocument.hasCdnURL ? protoDocument.cdnURL : nil,
        localPath: nil
      )

      let document = try newDocument.saveAndFetch(db)
      return document
    }
  }
}

public extension Video {
  // Add this method to update from protocol while preserving local path
  static func updateFromProtocol(
    _ db: Database,
    protoVideo: InlineProtocol.Video,
    thumbnailPhotoId: Int64?
  ) throws -> Video {
    // Try to find existing video
    if let existingVideo = try Video.filter(Column("videoId") == protoVideo.id).fetchOne(db) {
      // Create updated video with preserved local path
      var updatedVideo = Video(
        id: existingVideo.id,
        videoId: protoVideo.id,
        date: Date(timeIntervalSince1970: TimeInterval(protoVideo.date)),
        width: Int(protoVideo.w),
        height: Int(protoVideo.h),
        duration: Int(protoVideo.duration),
        size: protoVideo.size > 0 ? Int(protoVideo.size) : nil,
        thumbnailPhotoId: thumbnailPhotoId ?? existingVideo.thumbnailPhotoId,
        cdnUrl: protoVideo.hasCdnURL ? protoVideo.cdnURL : nil,
        localPath: existingVideo.localPath // Preserve local path
      )

      // Save the updated video
      try updatedVideo.save(db, onConflict: .replace)
      return updatedVideo
    } else {
      // Create new video if it doesn't exist
      let newVideo = Video.from(proto: protoVideo, localPhotoId: thumbnailPhotoId)
      let video = try newVideo.saveAndFetch(db)
      return video
    }
  }
}

public extension Photo {
  // Add this method to update from protocol while preserving local paths in photo sizes
  static func updateFromProtocol(_ db: Database, protoPhoto: InlineProtocol.Photo) throws -> Photo {
    // Try to find existing photo
    if let existingPhoto = try Photo.filter(Column("photoId") == protoPhoto.id).fetchOne(db) {
      // Create updated photo
      var updatedPhoto = Photo(
        id: existingPhoto.id,
        photoId: protoPhoto.id,
        date: Date(timeIntervalSince1970: TimeInterval(protoPhoto.date)),
        format: protoPhoto.format.toImageFormat()
      )

      // Save the updated photo
      try updatedPhoto.save(db, onConflict: .replace)

      // Update photo sizes while preserving local paths
      for protoSize in protoPhoto.sizes {
        try PhotoSize.updateFromProtocol(db, protoSize: protoSize, photoId: updatedPhoto.id!)
      }

      return updatedPhoto
    } else {
      // Create new photo if it doesn't exist
      let newPhoto = Photo.from(proto: protoPhoto)
      let photo = try newPhoto.saveAndFetch(db)

      // Save all photo sizes
      for protoSize in protoPhoto.sizes {
        let photoSize = PhotoSize.from(proto: protoSize, photoId: photo.id!)
        try photoSize.save(db)
      }

      return photo
    }
  }
}

public extension PhotoSize {
  // Add this method to update from protocol while preserving local path
  static func updateFromProtocol(_ db: Database, protoSize: InlineProtocol.PhotoSize, photoId: Int64) throws {
    // Try to find existing photo size
    if let existingSize = try PhotoSize.filter(Column("photoId") == photoId)
      .filter(Column("type") == protoSize.type)
      .fetchOne(db)
    {
      // Create updated photo size with preserved local path
      var updatedSize = PhotoSize(
        id: existingSize.id,
        photoId: photoId,
        type: protoSize.type,
        width: Int(protoSize.w),
        height: Int(protoSize.h),
        size: Int(protoSize.size),
        cdnUrl: protoSize.hasCdnURL ? protoSize.cdnURL : nil,
        localPath: existingSize.localPath // Preserve local path
      )

      // Save the updated photo size
      try updatedSize.save(db, onConflict: .replace)
    } else {
      // Create new photo size if it doesn't exist
      let newSize = PhotoSize.from(proto: protoSize, photoId: photoId)
      try newSize.save(db) // Is saveAndInsert needed?
    }
  }
}
