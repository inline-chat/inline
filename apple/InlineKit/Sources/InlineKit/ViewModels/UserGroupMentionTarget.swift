import Foundation

public struct UserGroupMentionTarget: Identifiable, Equatable, Sendable {
  public var groupId: Int64
  public var spaceId: Int64?

  public var id: Int64 { groupId }

  public init(groupId: Int64, spaceId: Int64?) {
    self.groupId = groupId
    self.spaceId = spaceId
  }
}

public extension Notification.Name {
  static let userGroupMentionTapped = Notification.Name("UserGroupMentionTapped")
}
