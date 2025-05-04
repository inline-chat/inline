import Foundation
import GRDB
import InlineProtocol

public struct Attachment: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var id: Int64?
  public var messageId: Int64?
  public var externalTaskId: Int64?
  public var urlPreviewId: Int64?

  public static let externalTask = belongsTo(
    ExternalTask.self,
    using: ForeignKey(["externalTaskId"], to: ["id"])
  )

  public var externalTask: QueryInterfaceRequest<ExternalTask> {
    request(for: Attachment.externalTask)
  }

  public static let urlPreview = belongsTo(
    UrlPreview.self,
    using: ForeignKey(["urlPreviewId"], to: ["id"])
  )

  public var urlPreview: QueryInterfaceRequest<UrlPreview> {
    request(for: Attachment.urlPreview)
  }

  public static let message = belongsTo(
    Message.self,
    using: ForeignKey(["messageId"], to: ["globalId"])
  )
  public var message: QueryInterfaceRequest<Message> {
    request(for: Attachment.message)
  }

  public init(messageId: Int64?, externalTaskId: Int64?, urlPreviewId: Int64?) {
    self.messageId = messageId
    self.externalTaskId = externalTaskId
    self.urlPreviewId = urlPreviewId
  }
}

public extension Attachment {
  @discardableResult
  static func save(
    _ db: Database, attachment: InlineProtocol.MessageAttachment
  )
    throws -> Attachment
  {
    let message = try Message.filter(Column("messageId") == attachment.messageID).fetchOne(db)

    var externalTaskId: Int64? = nil
    var urlPreviewId: Int64? = nil

    if let attachmentType = attachment.attachment {
      switch attachmentType {
        case let .externalTask(externalTask):
          externalTaskId = externalTask.id
        case let .urlPreview(urlPreview):
          urlPreviewId = urlPreview.id
        default:
          break
      }
    }

    let attachment = Attachment(
      messageId: message?.globalId,
      externalTaskId: externalTaskId,
      urlPreviewId: urlPreviewId
    )

    try attachment.save(db)

    return attachment
  }
}
