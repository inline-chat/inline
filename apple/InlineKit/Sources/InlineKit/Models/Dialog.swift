import Foundation
import GRDB

public struct ApiDialog: Codable, Hashable, Sendable {
  public var peerId: Peer
  public var pinned: Bool?
  public var spaceId: Int64?
  public var unreadCount: Int?
  public var readInboxMaxId: Int64?
  public var readOutboxMaxId: Int64?
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

  static let peerUserChat = hasOne(
    Chat.self,
    through: peerUser,
    using: User.chat
  )

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
    archived = from.archived
    unreadCount = from.unreadCount
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
    unreadCount = nil
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

  var peerId: Peer {
    if let peerUserId {
      .user(id: peerUserId)
    } else if let peerThreadId {
      .thread(id: peerThreadId)
    } else {
      fatalError("One of peerUserId or peerThreadId must be set")
    }
  }
}

public extension ApiDialog {
  @discardableResult
  func saveFull(
    _ db: Database
  )
    throws -> Dialog
  {
    let existing = try? Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId))

    var dialog = Dialog(from: self)

    if let existing {
      dialog.draft = existing.draft
      try dialog.save(db, onConflict: .replace)
    } else {
      try dialog.save(db, onConflict: .replace)
    }

    return dialog
  }
}

public extension Dialog {
  static func get(peerId: Peer) -> QueryInterfaceRequest<Dialog> {
    Dialog
      .filter(
        Column("id") == Dialog.getDialogId(peerId: peerId)
      )
  }

  // use for array fetches
  static func spaceChatItemQuery() -> QueryInterfaceRequest<SpaceChatItem> {
    // chat through dialog thread
    including(
      optional: Dialog.peerThread
        .including(optional: Chat.lastMessage.including(optional: Message.from.forKey("from")
            .including(
              all: User.photos
                .forKey("profilePhoto")
            )))
    )
    // user info
    .including(
      optional: Dialog.peerUser.forKey("userInfo")
        .including(all: User.photos.forKey("profilePhoto"))
    )
    // chat through user
    .including(optional: Dialog.peerUserChat)
    .asRequest(of: SpaceChatItem.self)
  }

  static func spaceChatItemQueryForUser() -> QueryInterfaceRequest<SpaceChatItem> {
    // user info
    including(
      optional: Dialog.peerUser.forKey("userInfo")
        .including(all: User.photos.forKey("profilePhoto"))
    )
    // chat through user
    .including(optional: Dialog.peerUserChat)
    .asRequest(of: SpaceChatItem.self)
  }

  static func spaceChatItemQueryForChat() -> QueryInterfaceRequest<SpaceChatItem> {
    // chat through dialog thread
    including(
      optional: Dialog.peerThread
        .including(optional: Chat.lastMessage.including(optional: Message.from.forKey("from")
            .including(
              all: User.photos
                .forKey("profilePhoto")
            )))
    )
    .asRequest(of: SpaceChatItem.self)
  }
}
