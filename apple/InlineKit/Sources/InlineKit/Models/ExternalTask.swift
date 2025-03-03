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
  public var creating: Bool

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
    creating: Bool = false,
    number: String?
  ) {
    self.application = application
    self.taskId = taskId
    self.status = status
    self.assignedUserId = assignedUserId
    self.url = url
    self.title = title
    self.date = date
    self.creating = creating
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
    creating = false
  }

  static func save(
    _ db: Database, externalTask protocolExternalTask: InlineProtocol.MessageAttachmentExternalTask
  )
    throws -> ExternalTask
  {
    let existing = try? ExternalTask.fetchOne(db, id: protocolExternalTask.id)
    var externalTask = ExternalTask(from: protocolExternalTask)

    if let existing {
      externalTask.application = existing.application
      externalTask.taskId = existing.taskId
      externalTask.status = existing.status
      externalTask.assignedUserId = existing.assignedUserId
      externalTask.url = existing.url
      externalTask.title = existing.title
      externalTask.date = existing.date
      externalTask.number = existing.number
      try externalTask.save(db)
    } else {
      try externalTask.save(db)
    }

    return externalTask
  }
}
