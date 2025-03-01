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
    creating: Bool = false
  ) {
    self.application = application
    self.taskId = taskId
    self.status = status
    self.assignedUserId = assignedUserId
    self.url = url
    self.title = title
    self.date = date
    self.creating = creating
  }
}
