import Foundation
import GRDB
import InlineProtocol

public struct Attachment: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var id: Int64?
  public var attachmentId: Int64?
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

  public init(messageId: Int64?, externalTaskId: Int64?, urlPreviewId: Int64?, attachmentId: Int64?) {
    self.messageId = messageId
    self.externalTaskId = externalTaskId
    self.urlPreviewId = urlPreviewId
    self.attachmentId = attachmentId
  }
}

public extension Attachment {
  /// Saves the attachment and any inner items (e.g., UrlPreview) to the database.
  /// - Parameters:
  ///   - db: The database connection
  ///   - attachment: The protocol attachment to save
  /// - Returns: The saved Attachment object
  @discardableResult
  static func saveWithInnerItems(
    _ db: Database, attachment: InlineProtocol.MessageAttachment, messageClientGlobalId: Int64
  ) throws -> Attachment {
    var externalTaskId: Int64? = nil
    var urlPreviewId: Int64? = nil

    if let attachmentType = attachment.attachment {
      switch attachmentType {
        case let .externalTask(externalTask):
          externalTaskId = externalTask.id
        case let .urlPreview(urlPreviewProto):
          // Save the UrlPreview and use its DB id
          let savedUrlPreview = try UrlPreview.save(db, linkEmbed: urlPreviewProto)
          urlPreviewId = savedUrlPreview.id
        default:
          break
      }
    }

    let attachment = Attachment(
      messageId: messageClientGlobalId,
      externalTaskId: externalTaskId,
      urlPreviewId: urlPreviewId,
      attachmentId: attachment.id
    )

    try attachment.save(db)

    return attachment
  }
}
