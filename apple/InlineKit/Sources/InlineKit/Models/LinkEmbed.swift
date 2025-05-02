import Foundation
import GRDB
import InlineProtocol

public enum LinkEmbedType: String, Codable, Sendable {
  case link
  case loom
}

public struct LinkEmbed: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var id: Int64?
  public var url: String
  public var type: LinkEmbedType
  public var providerName: String?
  public var title: String?
  public var description: String?
  public var imageUrl: String?
  public var imageWidth: Int32?
  public var imageHeight: Int32?
  public var html: String?
  public var date: Date?


  public var duration: Float?

  public init(
    id: Int64? = Int64.random(in: 1 ... 5_000),
    url: String,
    type: LinkEmbedType,
    providerName: String?,
    title: String?,
    description: String?,
    imageUrl: String?,
    imageWidth: Int32?,
    imageHeight: Int32?,
    html: String?,
    date: Date?,

    duration: Float?
  ) {
    self.id = id
    self.url = url
    self.type = type
    self.providerName = providerName
    self.title = title
    self.description = description
    self.imageUrl = imageUrl
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
    self.html = html
    self.date = date

    self.duration = duration
  }
}

// Inline Protocol
public extension LinkEmbed {
  init(from: InlineProtocol.MessageAttachmentLinkEmbed_Experimental) {
    id = from.id
    url = from.url
    type = from.type == .loom ? .loom : .link
    providerName = from.providerName
    title = from.title
    description = from.description_p
    imageUrl = from.imageURL
    imageWidth = from.imageWidth
    imageHeight = from.imageHeight
    html = from.html
    date = Date(timeIntervalSince1970: TimeInterval(from.date) / 1_000)
    duration = from.duration
  }

  @discardableResult
  static func save(
    _ db: Database, linkEmbed protocolLinkEmbed: InlineProtocol.MessageAttachmentLinkEmbed_Experimental
  )
    throws -> LinkEmbed
  {
    let linkEmbed = LinkEmbed(from: protocolLinkEmbed)
    try linkEmbed.save(db)

    return linkEmbed
  }
}
