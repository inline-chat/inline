import Foundation
import GRDB
import InlineProtocol

public struct UrlPreview: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, Sendable {
  public var id: Int64
  public var url: String
  public var siteName: String?
  public var title: String?
  public var description: String?
  public var photoId: Int64?
  public var duration: Int64?

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

// Inline Protocol
public extension UrlPreview {
  init(from: InlineProtocol.UrlPreview) {
    id = from.id
    url = from.url
    siteName = from.siteName
    title = from.title
    description = from.description_p
    photoId = from.photo.id
    duration = from.duration
  }

  @discardableResult
  static func save(
    _ db: Database,
    linkEmbed protocolLinkEmbed: InlineProtocol.UrlPreview
  )
    throws -> UrlPreview
  {
    let linkEmbed = UrlPreview(from: protocolLinkEmbed)
    try linkEmbed.save(db)

    return linkEmbed
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
}
