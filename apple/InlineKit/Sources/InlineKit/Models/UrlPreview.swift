import Foundation
import GRDB
import InlineProtocol
import Logger

public struct UrlPreview: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, Sendable {
  public var id: Int64
  public var url: String
  public var siteName: String?
  public var title: String?
  public var description: String?
  public var photoId: Int64?
  public var duration: Int64?
  public var mediaType: String?
  public var displayUrl: String?
  public var provider: String?
  public var author: String?
  public var mediaKind: String?
  public var videoId: Int64?
  public var documentId: Int64?
  public var externalUrl: String?
  public var externalMimeType: String?
  public var externalWidth: Int?
  public var externalHeight: Int?
  public var externalDuration: Int?
  public var embedUrl: String?
  public var embedType: String?
  public var embedWidth: Int?
  public var embedHeight: Int?
  public var embedDuration: Int?
  public var hasLargeMedia: Bool?
  public var showLargeMedia: Bool?

  public enum Columns {
    static let id = Column(CodingKeys.id)
    static let url = Column(CodingKeys.url)
    static let siteName = Column(CodingKeys.siteName)
    static let title = Column(CodingKeys.title)
    static let description = Column(CodingKeys.description)
    static let photoId = Column(CodingKeys.photoId)
    static let duration = Column(CodingKeys.duration)
    static let mediaType = Column(CodingKeys.mediaType)
    static let displayUrl = Column(CodingKeys.displayUrl)
    static let provider = Column(CodingKeys.provider)
    static let author = Column(CodingKeys.author)
    static let mediaKind = Column(CodingKeys.mediaKind)
    static let videoId = Column(CodingKeys.videoId)
    static let documentId = Column(CodingKeys.documentId)
    static let externalUrl = Column(CodingKeys.externalUrl)
    static let externalMimeType = Column(CodingKeys.externalMimeType)
    static let externalWidth = Column(CodingKeys.externalWidth)
    static let externalHeight = Column(CodingKeys.externalHeight)
    static let externalDuration = Column(CodingKeys.externalDuration)
    static let embedUrl = Column(CodingKeys.embedUrl)
    static let embedType = Column(CodingKeys.embedType)
    static let embedWidth = Column(CodingKeys.embedWidth)
    static let embedHeight = Column(CodingKeys.embedHeight)
    static let embedDuration = Column(CodingKeys.embedDuration)
    static let hasLargeMedia = Column(CodingKeys.hasLargeMedia)
    static let showLargeMedia = Column(CodingKeys.showLargeMedia)
  }

  // Relationship to photo using photoId (server ID)
  static let photo = belongsTo(Photo.self, using: ForeignKey(["photoId"], to: ["photoId"]))
  static let video = belongsTo(Video.self, using: ForeignKey(["videoId"], to: ["videoId"]))
  static let document = belongsTo(Document.self, using: ForeignKey(["documentId"], to: ["documentId"]))

  var photo: QueryInterfaceRequest<Photo> {
    request(for: UrlPreview.photo)
  }

  var video: QueryInterfaceRequest<Video> {
    request(for: UrlPreview.video)
  }

  var document: QueryInterfaceRequest<Document> {
    request(for: UrlPreview.document)
  }

  public init(
    id: Int64 = Int64.random(in: 1 ... 5_000),
    url: String,
    siteName: String?,
    title: String?,
    description: String?,
    photoId: Int64?,
    duration: Int64?,
    mediaType: String? = nil,
    displayUrl: String? = nil,
    provider: String? = nil,
    author: String? = nil,
    mediaKind: String? = nil,
    videoId: Int64? = nil,
    documentId: Int64? = nil,
    externalUrl: String? = nil,
    externalMimeType: String? = nil,
    externalWidth: Int? = nil,
    externalHeight: Int? = nil,
    externalDuration: Int? = nil,
    embedUrl: String? = nil,
    embedType: String? = nil,
    embedWidth: Int? = nil,
    embedHeight: Int? = nil,
    embedDuration: Int? = nil,
    hasLargeMedia: Bool? = nil,
    showLargeMedia: Bool? = nil
  ) {
    self.id = id
    self.url = url
    self.siteName = siteName
    self.title = title
    self.description = description
    self.photoId = photoId
    self.duration = duration
    self.mediaType = mediaType
    self.displayUrl = displayUrl
    self.provider = provider
    self.author = author
    self.mediaKind = mediaKind
    self.videoId = videoId
    self.documentId = documentId
    self.externalUrl = externalUrl
    self.externalMimeType = externalMimeType
    self.externalWidth = externalWidth
    self.externalHeight = externalHeight
    self.externalDuration = externalDuration
    self.embedUrl = embedUrl
    self.embedType = embedType
    self.embedWidth = embedWidth
    self.embedHeight = embedHeight
    self.embedDuration = embedDuration
    self.hasLargeMedia = hasLargeMedia
    self.showLargeMedia = showLargeMedia
  }
}

public extension UrlPreview {
  var isVideoPreview: Bool {
    switch mediaKind?.urlPreviewToken {
      case "video", "external_video", "embed":
        return true
      default:
        break
    }

    switch mediaType?.urlPreviewToken {
      case "video", "embed":
        return true
      default:
        break
    }

    if embedType?.urlPreviewToken == "video" || externalMimeType?.urlPreviewToken?.hasPrefix("video/") == true {
      return true
    }

    return false
  }

  enum CodingKeys: String, CodingKey {
    case id, url, siteName, title, description, photoId, duration, mediaType
    case displayUrl, provider, author, mediaKind, videoId, documentId
    case externalUrl, externalMimeType, externalWidth, externalHeight, externalDuration
    case embedUrl, embedType, embedWidth, embedHeight, embedDuration
    case hasLargeMedia, showLargeMedia
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    url = try container.decode(String.self, forKey: .url)
    siteName = try container.decodeIfPresent(String.self, forKey: .siteName)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    photoId = try container.decodeIfPresent(Int64.self, forKey: .photoId)
    duration = try container.decodeIfPresent(Int64.self, forKey: .duration)
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
    displayUrl = try container.decodeIfPresent(String.self, forKey: .displayUrl)
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    author = try container.decodeIfPresent(String.self, forKey: .author)
    mediaKind = try container.decodeIfPresent(String.self, forKey: .mediaKind)
    videoId = try container.decodeIfPresent(Int64.self, forKey: .videoId)
    documentId = try container.decodeIfPresent(Int64.self, forKey: .documentId)
    externalUrl = try container.decodeIfPresent(String.self, forKey: .externalUrl)
    externalMimeType = try container.decodeIfPresent(String.self, forKey: .externalMimeType)
    externalWidth = try container.decodeIfPresent(Int.self, forKey: .externalWidth)
    externalHeight = try container.decodeIfPresent(Int.self, forKey: .externalHeight)
    externalDuration = try container.decodeIfPresent(Int.self, forKey: .externalDuration)
    embedUrl = try container.decodeIfPresent(String.self, forKey: .embedUrl)
    embedType = try container.decodeIfPresent(String.self, forKey: .embedType)
    embedWidth = try container.decodeIfPresent(Int.self, forKey: .embedWidth)
    embedHeight = try container.decodeIfPresent(Int.self, forKey: .embedHeight)
    embedDuration = try container.decodeIfPresent(Int.self, forKey: .embedDuration)
    hasLargeMedia = try container.decodeIfPresent(Bool.self, forKey: .hasLargeMedia)
    showLargeMedia = try container.decodeIfPresent(Bool.self, forKey: .showLargeMedia)
  }

  /// Saves an InlineProtocol.UrlPreview into the database, including its photo if present.
  /// - Parameters:
  ///   - db: The database connection
  ///   - linkEmbed: The InlineProtocol.UrlPreview to save
  /// - Returns: The saved UrlPreview object
  @discardableResult
  static func save(_ db: Database, linkEmbed: InlineProtocol.UrlPreview) throws -> UrlPreview {
    var photoId: Int64? = nil
    if linkEmbed.hasPhoto {
      let savedPhoto = try Photo.savePhotoFromProtocol(db, photo: linkEmbed.photo)
      photoId = savedPhoto.photoId
    }

    var mediaKind: String?
    var videoId: Int64?
    var documentId: Int64?
    var externalUrl: String?
    var externalMimeType: String?
    var externalWidth: Int?
    var externalHeight: Int?
    var externalDuration: Int?
    var embedUrl: String?
    var embedType: String?
    var embedWidth: Int?
    var embedHeight: Int?
    var embedDuration: Int?

    if linkEmbed.hasMedia {
      switch linkEmbed.media.media {
      case .photo(let protoPhoto):
        let savedPhoto = try Photo.savePhotoFromProtocol(db, photo: protoPhoto)
        photoId = photoId ?? savedPhoto.photoId
        mediaKind = "photo"

      case .video(let protoVideo):
        var thumbnailPhotoId: Int64?
        if protoVideo.hasPhoto {
          let savedPhoto = try Photo.savePhotoFromProtocol(db, photo: protoVideo.photo)
          thumbnailPhotoId = savedPhoto.id
          photoId = photoId ?? savedPhoto.photoId
        }

        let savedVideo = try Video.updateFromProtocol(db, protoVideo: protoVideo, thumbnailPhotoId: thumbnailPhotoId)
        videoId = savedVideo.videoId
        mediaKind = "video"

      case .document(let protoDocument):
        var thumbnailPhotoId: Int64?
        if protoDocument.hasPhoto {
          let savedPhoto = try Photo.savePhotoFromProtocol(db, photo: protoDocument.photo)
          thumbnailPhotoId = savedPhoto.id
          photoId = photoId ?? savedPhoto.photoId
        }

        let savedDocument = try Document.updateFromProtocol(
          db,
          protoDocument: protoDocument,
          thumbnailPhotoId: thumbnailPhotoId
        )
        documentId = savedDocument.documentId
        mediaKind = "document"

      case .externalVideo(let video):
        externalUrl = video.url.nilIfEmpty
        externalMimeType = video.hasMimeType ? video.mimeType : nil
        externalWidth = video.hasW ? Int(video.w) : nil
        externalHeight = video.hasH ? Int(video.h) : nil
        externalDuration = video.hasDuration ? Int(video.duration) : nil
        mediaKind = "external_video"

      case .embed(let embed):
        embedUrl = embed.url.nilIfEmpty
        embedType = embed.hasType ? embed.type : nil
        embedWidth = embed.hasW ? Int(embed.w) : nil
        embedHeight = embed.hasH ? Int(embed.h) : nil
        embedDuration = embed.hasDuration ? Int(embed.duration) : nil
        mediaKind = "embed"

      case nil:
        break
      }
    }

    // Try to find existing UrlPreview by id
    var urlPreview = UrlPreview(
      id: linkEmbed.id != 0 ? linkEmbed.id : Int64.random(in: 1 ... 5_000_000),
      url: linkEmbed.url,
      siteName: linkEmbed.hasSiteName ? linkEmbed.siteName : nil,
      title: linkEmbed.hasTitle ? linkEmbed.title : nil,
      description: linkEmbed.hasDescription_p ? linkEmbed.description_p : nil,
      photoId: photoId,
      duration: linkEmbed.hasDuration ? linkEmbed.duration : nil,
      mediaType: linkEmbed.hasMediaType ? Self.mediaTypeValue(from: linkEmbed.mediaType) : nil,
      displayUrl: linkEmbed.hasDisplayURL ? linkEmbed.displayURL : nil,
      provider: linkEmbed.hasProvider ? linkEmbed.provider : nil,
      author: linkEmbed.hasAuthor ? linkEmbed.author : nil,
      mediaKind: mediaKind,
      videoId: videoId,
      documentId: documentId,
      externalUrl: externalUrl,
      externalMimeType: externalMimeType,
      externalWidth: externalWidth,
      externalHeight: externalHeight,
      externalDuration: externalDuration,
      embedUrl: embedUrl,
      embedType: embedType,
      embedWidth: embedWidth,
      embedHeight: embedHeight,
      embedDuration: embedDuration,
      hasLargeMedia: linkEmbed.hasLayout ? linkEmbed.layout.hasLargeMedia_p : nil,
      showLargeMedia: linkEmbed.hasLayout ? linkEmbed.layout.showLargeMedia : nil
    )

    if let existing = try UrlPreview.filter(Column("id") == urlPreview.id).fetchOne(db) {
      urlPreview.id = existing.id
      try urlPreview.update(db)
    } else {
      urlPreview = try urlPreview.insertAndFetch(db)
    }

    return urlPreview
  }

  private static func mediaTypeValue(from mediaType: InlineProtocol.UrlPreview.MediaType) -> String? {
    switch mediaType {
      case .article:
        return "article"
      case .image:
        return "image"
      case .video:
        return "video"
      case .document:
        return "document"
      case .embed:
        return "embed"
      case .unspecified, .UNRECOGNIZED:
        return nil
    }
  }
}

private extension String {
  var nilIfEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  var urlPreviewToken: String? {
    nilIfEmpty?.lowercased()
  }
}
