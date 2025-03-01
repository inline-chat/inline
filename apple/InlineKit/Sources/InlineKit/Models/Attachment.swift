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

  public static let externalTask = belongsTo(
    ExternalTask.self,
    using: ForeignKey(["externalTaskId"], to: ["id"])
  )
  public var externalTask: QueryInterfaceRequest<ExternalTask> {
    request(for: Attachment.externalTask)
  }

  public static let message = belongsTo(
    Message.self,
    using: ForeignKey(["messageId"], to: ["globalId"])
  )
  public var message: QueryInterfaceRequest<Message> {
    request(for: Attachment.message)
  }

  public init(messageId: Int64?, externalTaskId: Int64?) {
    self.messageId = messageId
    self.externalTaskId = externalTaskId
  }
}
