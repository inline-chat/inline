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
    case .user(let id):
      self.peerUserId = id
      self.peerThreadId = nil
      self.id = Self.getDialogId(peerUserId: id)
    case .thread(let id):
      self.peerUserId = nil
      self.peerThreadId = id
      self.id = Self.getDialogId(peerThreadId: id)
    }

    self.spaceId = from.spaceId
    self.unreadCount = from.unreadCount
    self.readInboxMaxId = from.readInboxMaxId
    self.readOutboxMaxId = from.readOutboxMaxId
    self.pinned = from.pinned
  }

  // Called when user clicks a user for the first time
  init(optimisticForUserId: Int64) {
    let userId = optimisticForUserId

    self.peerUserId = userId
    self.peerThreadId = nil
    self.id = Self.getDialogId(peerUserId: userId)

    self.spaceId = nil
    self.unreadCount = nil
    self.readInboxMaxId = nil
    self.readOutboxMaxId = nil
    self.pinned = nil
  }

  static func getDialogId(peerUserId: Int64) -> Int64 {
    print("getDialogId peerUserId: \(peerUserId)")
    return peerUserId
  }

  static func getDialogId(peerThreadId: Int64) -> Int64 {
    print("getDialogId peerThreadId: \(peerThreadId)")
    return peerThreadId
  }

  static func getDialogId(peerId: Peer) -> Int64 {
    switch peerId {
    case .user(let id):
      return Self.getDialogId(peerUserId: id)
    case .thread(let id):
      return Self.getDialogId(peerThreadId: id)
    }
  }
}
