import Foundation
import GRDB
import InlineProtocol

public enum Status: String, Codable, Sendable {
  case backlog
  case todo
  case inProgress = "in_progress"
  case done
  case cancelled
}

public struct ExternalTask: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var id: Int64?
  public var application: String
  public var taskId: String?
  public var status: Status
  public var assignedUserId: Int64?
  public var number: String?
  public var url: String?
  public var title: String?
  public var date: Date?

  static let assignedUser = belongsTo(User.self, using: ForeignKey(["assignedUserId"], to: ["id"]))
  var assignedUser: QueryInterfaceRequest<User> {
    request(for: ExternalTask.assignedUser)
  }

  public init(
    application: String,
    taskId: String?,
    status: Status,
    assignedUserId: Int64?,
    url: String?,
    title: String?,
    date: Date?,
    number: String?
  ) {
    self.application = application
    self.taskId = taskId
    self.status = status
    self.assignedUserId = assignedUserId
    self.url = url
    self.title = title
    self.date = date
    self.number = number
  }
}

// Inline Protocol
public extension ExternalTask {
  init(from externalTask: InlineProtocol.MessageAttachmentExternalTask) {
    id = externalTask.id
    application = externalTask.application
    taskId = externalTask.taskID
    status = .todo
    assignedUserId = externalTask.assignedUserID
    url = externalTask.url
    title = externalTask.title
    number = externalTask.number
  }

  @discardableResult
  static func save(
    _ db: Database, externalTask protocolExternalTask: InlineProtocol.MessageAttachmentExternalTask
  )
    throws -> ExternalTask
  {
    let externalTask = ExternalTask(from: protocolExternalTask)
    try externalTask.save(db)

    return externalTask
  }
}
