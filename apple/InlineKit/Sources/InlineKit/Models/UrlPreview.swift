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

  public enum Columns {
    static let id = Column(CodingKeys.id)
    static let url = Column(CodingKeys.url)
    static let siteName = Column(CodingKeys.siteName)
    static let title = Column(CodingKeys.title)
    static let description = Column(CodingKeys.description)
    static let photoId = Column(CodingKeys.photoId)
    static let duration = Column(CodingKeys.duration)
  }

  // Relationship to photo using photoId (server ID)
  static let photo = belongsTo(Photo.self, using: ForeignKey(["photoId"], to: ["photoId"]))

  var photo: QueryInterfaceRequest<Photo> {
    request(for: UrlPreview.photo)
  }

  public init(
    id: Int64 = Int64.random(in: 1 ... 5_000),
    url: String,
    siteName: String?,
    title: String?,
    description: String?,
    photoId: Int64?,
    duration: Int64?
  ) {
    self.id = id
    self.url = url
    self.siteName = siteName
    self.title = title
    self.description = description
    self.photoId = photoId
    self.duration = duration
  }
}

public extension UrlPreview {
  enum CodingKeys: String, CodingKey {
    case id, url, siteName, title, description, photoId, duration
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
  }

  /// Saves an InlineProtocol.UrlPreview into the database, including its photo if present.
  /// - Parameters:
  ///   - db: The database connection
  ///   - linkEmbed: The InlineProtocol.UrlPreview to save
  /// - Returns: The saved UrlPreview object
  @discardableResult
  static func save(_ db: Database, linkEmbed: InlineProtocol.UrlPreview) throws -> UrlPreview {
    // Save the photo if present

    var photoId: Int64? = nil
    if linkEmbed.hasPhoto {
      let savedPhoto = try Photo.savePhotoFromProtocol(db, photo: linkEmbed.photo)
      photoId = savedPhoto.photoId
    }

    // Try to find existing UrlPreview by id
    var urlPreview = UrlPreview(
      id: linkEmbed.id != 0 ? linkEmbed.id : Int64.random(in: 1 ... 5_000_000),
      url: linkEmbed.url,
      siteName: linkEmbed.hasSiteName ? linkEmbed.siteName : nil,
      title: linkEmbed.hasTitle ? linkEmbed.title : nil,
      description: linkEmbed.hasDescription_p ? linkEmbed.description_p : nil,
      photoId: photoId,
      duration: linkEmbed.hasDuration ? linkEmbed.duration : nil
    )

    if let existing = try UrlPreview.filter(Column("id") == urlPreview.id).fetchOne(db) {
      urlPreview.id = existing.id
      try urlPreview.update(db)
    } else {
      urlPreview = try urlPreview.insertAndFetch(db)
    }

    return urlPreview
  }
}
