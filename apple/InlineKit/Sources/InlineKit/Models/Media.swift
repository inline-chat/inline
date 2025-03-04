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

  enum Columns {
    static let id = Column(CodingKeys.id)
    static let photoId = Column(CodingKeys.photoId)
    static let date = Column(CodingKeys.date)
    static let format = Column(CodingKeys.format)
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

  enum Columns {
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

  enum Columns {
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
  public var fileUniqueId: String?

  enum Columns {
    static let id = Column(CodingKeys.id)
    static let documentId = Column(CodingKeys.documentId)
    static let date = Column(CodingKeys.date)
    static let fileName = Column(CodingKeys.fileName)
    static let mimeType = Column(CodingKeys.mimeType)
    static let size = Column(CodingKeys.size)
    static let cdnUrl = Column(CodingKeys.cdnUrl)
    static let localPath = Column(CodingKeys.localPath)
    static let thumbnailPhotoId = Column(CodingKeys.thumbnailPhotoId)
    static let fileUniqueId = Column(CodingKeys.fileUniqueId)
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

    // Update the photo with the server ID
    var updatedPhoto = localPhoto
    updatedPhoto.photoId = serverId
    try updatedPhoto.update(db)

    // Update any messages that reference the old temporary ID
    try db.execute(sql: """
        UPDATE message
        SET photoId = ?
        WHERE photoId = ?
    """, arguments: [serverId, oldPhotoId])
  }

  // Update a video with the server-provided ID
  static func updateVideoWithServerId(_ db: Database, localVideo: Video, serverId: Int64) throws {
    // Get the old videoId
    let oldVideoId = localVideo.videoId

    // Update the video with the server ID
    var updatedVideo = localVideo
    updatedVideo.videoId = serverId
    try updatedVideo.update(db)

    // Update any messages that reference the old temporary ID
    try db.execute(sql: """
        UPDATE message
        SET videoId = ?
        WHERE videoId = ?
    """, arguments: [serverId, oldVideoId])
  }

  // Update a document with the server-provided ID
  static func updateDocumentWithServerId(_ db: Database, localDocument: Document, serverId: Int64) throws {
    // Get the old documentId
    let oldDocumentId = localDocument.documentId

    // Update the document with the server ID
    var updatedDocument = localDocument
    updatedDocument.documentId = serverId
    try updatedDocument.update(db)

    // Update any messages that reference the old temporary ID
    try db.execute(sql: """
        UPDATE message
        SET documentId = ?
        WHERE documentId = ?
    """, arguments: [serverId, oldDocumentId])
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
