import Foundation
import GRDB

public struct ApiDialog: Codable, Hashable, Sendable {
  public var peerId: Peer
  public var pinned: Bool?
  public var spaceId: Int64?
  public var unreadCount: Int?
  public var readInboxMaxId: Int64?
  public var readOutboxMaxId: Int64?
  public var draft: String?
  public var archived: Bool?
}

public struct Dialog: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, Sendable {
  // Equal to peerId it contains information about. For threads bit sign will be "-" and users positive.
  public var id: Int64
  public var peerUserId: Int64?
  public var peerThreadId: Int64?
  public var spaceId: Int64?
  public var unreadCount: Int?
  public var readInboxMaxId: Int64?
  public var readOutboxMaxId: Int64?
  public var pinned: Bool?
  public var draft: String?
  public var archived: Bool?

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

public extension Dialog {
  init(from: ApiDialog) {
    switch from.peerId {
      case let .user(id):
        peerUserId = id
        peerThreadId = nil
        self.id = Self.getDialogId(peerUserId: id)
      case let .thread(id):
        peerUserId = nil
        peerThreadId = id
        self.id = Self.getDialogId(peerThreadId: id)
    }

    spaceId = from.spaceId
    unreadCount = from.unreadCount
    readInboxMaxId = from.readInboxMaxId
    readOutboxMaxId = from.readOutboxMaxId
    pinned = from.pinned
    draft = from.draft
    archived = from.archived
  }

  // Called when user clicks a user for the first time
  init(optimisticForUserId: Int64) {
    let userId = optimisticForUserId

    peerUserId = userId
    peerThreadId = nil
    id = Self.getDialogId(peerUserId: userId)

    spaceId = nil
    unreadCount = nil
    readInboxMaxId = nil
    readOutboxMaxId = nil
    pinned = nil
    draft = nil
    archived = nil
  }

  static func getDialogId(peerUserId: Int64) -> Int64 {
    peerUserId
  }

  static func getDialogId(peerThreadId: Int64) -> Int64 {
    peerThreadId
  }

  static func getDialogId(peerId: Peer) -> Int64 {
    switch peerId {
      case let .user(id):
        Self.getDialogId(peerUserId: id)
      case let .thread(id):
        Self.getDialogId(peerThreadId: id)
    }
  }
}
