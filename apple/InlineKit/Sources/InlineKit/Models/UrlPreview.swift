import Foundation
import GRDB
import InlineProtocol

public struct UrlPreview: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var id: Int64?
  public var url: String
  public var siteName: String?
  public var title: String?
  public var description: String?
  public var photoId: Int64?
  public var date: Date?
  public var duration: Int64?

  // Relationship to photo using photoId (server ID)
  static let photo = belongsTo(Photo.self, using: ForeignKey(["photoId"], to: ["photoId"]))

  var photo: QueryInterfaceRequest<Photo> {
    request(for: Message.photo)
  }

  public init(
    id: Int64? = Int64.random(in: 1...5_000),
    url: String,
    siteName: String?,
    title: String?,
    description: String?,
    photoId: Int64?,
    date: Date?,
    duration: Int64?
  ) {
    self.id = id
    self.url = url
    self.siteName = siteName
    self.title = title
    self.description = description
    self.photoId = photoId
    self.date = date
    self.duration = duration
  }
}

// Inline Protocol
extension UrlPreview {
  public init(from: InlineProtocol.UrlPreview) {
    id = from.id
    url = from.url
    siteName = from.siteName
    title = from.title
    description = from.description_p
    photoId = from.photo.photoId
    date = Date(timeIntervalSince1970: TimeInterval(from.date) / 1_000)
    duration = from.duration
  }

  @discardableResult
  public static func save(
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
