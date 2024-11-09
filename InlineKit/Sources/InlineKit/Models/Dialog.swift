import Foundation
import GRDB

public struct ApiDialog: Codable, Hashable, Sendable {
  public var peerId: Peer
  public var pinned: Bool?
  public var spaceId: Int64?
  public var unreadCount: Int?
  public var readInboxMaxId: Int64?
  public var readOutboxMaxId: Int64?
}

public struct Dialog: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, Sendable
{
  // Equal to peerId it contains information about. For threads bit sign will be "-" and users positive.
  public var id: Int64
  public var peerUserId: Int64?
  public var peerThreadId: Int64?
  public var spaceId: Int64?
  public var unreadCount: Int?
  public var readInboxMaxId: Int64?
  public var readOutboxMaxId: Int64?
  public var pinned: Bool?

  public static let space = belongsTo(Space.self)
  public var space: QueryInterfaceRequest<Space> {
    request(for: Dialog.space)
  }

  public static let peerUser = belongsTo(User.self)
  public var peerUser: QueryInterfaceRequest<User> {
    request(for: Dialog.peerUser)
  }

  public static let peerThread = belongsTo(Chat.self)
  public var peerThread: QueryInterfaceRequest<Chat> {
    request(for: Dialog.peerThread)
  }
}

extension Dialog {
  public init(from: ApiDialog) {
    switch from.peerId {
    case .user(let id):
      self.peerUserId = id
      self.peerThreadId = nil
      self.id = id
    case .thread(let id):
      self.peerUserId = nil
      self.peerThreadId = id
      self.id = -id
    }

    self.spaceId = from.spaceId
    self.unreadCount = from.unreadCount
    self.readInboxMaxId = from.readInboxMaxId
    self.readOutboxMaxId = from.readOutboxMaxId
    self.pinned = from.pinned
  }
}
