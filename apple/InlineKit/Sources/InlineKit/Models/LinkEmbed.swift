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
  public var providerUrl: String?
  public var title: String?
  public var description: String?
  public var imageUrl: String?
  public var imageWidth: Int?
  public var imageHeight: Int?
  public var html: String?
  public var date: Date?
  public var shareUrl: String?
  public var videoId: String?
  public var duration: Double?

  public init(
    id: Int64? = Int64.random(in: 1 ... 5_000),
    url: String,
    type: LinkEmbedType,
    providerName: String?,
    providerUrl: String?,
    title: String?,
    description: String?,
    imageUrl: String?,
    imageWidth: Int?,
    imageHeight: Int?,
    html: String?,
    date: Date?,
    shareUrl: String?,
    videoId: String?,
    duration: Double?
  ) {
    self.id = id
    self.url = url
    self.type = type
    self.providerName = providerName
    self.providerUrl = providerUrl
    self.title = title
    self.description = description
    self.imageUrl = imageUrl
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
    self.html = html
    self.date = date
    self.shareUrl = shareUrl
    self.videoId = videoId
    self.duration = duration
  }
}

// Inline Protocol
public extension LinkEmbed {
  init(from protocolLinkEmbed: InlineProtocol.MessageAttachmentLinkEmbed) {
    id = protocolLinkEmbed.id
    url = protocolLinkEmbed.url
    type = protocolLinkEmbed.type
    providerName = protocolLinkEmbed.providerName
    providerUrl = protocolLinkEmbed.providerUrl
    title = protocolLinkEmbed.title
    description = protocolLinkEmbed.description
    imageUrl = protocolLinkEmbed.imageUrl
    imageWidth = protocolLinkEmbed.imageWidth
    imageHeight = protocolLinkEmbed.imageHeight
    html = protocolLinkEmbed.html
    date = protocolLinkEmbed.date
    shareUrl = protocolLinkEmbed.shareUrl
    videoId = protocolLinkEmbed.videoId
    duration = protocolLinkEmbed.duration
  }

  @discardableResult
  static func save(
    _ db: Database, linkEmbed protocolLinkEmbed: InlineProtocol.MessageAttachmentLinkEmbed
  )
    throws -> LinkEmbed
  {
    let linkEmbed = LinkEmbed(from: protocolLinkEmbed)
    try linkEmbed.save(db)

    return linkEmbed
  }
}
