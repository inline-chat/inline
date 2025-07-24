import Foundation
import GRDB
import InlineProtocol

public struct ApiDialog: Codable, Hashable, Sendable {
  public var peerId: Peer
  public var pinned: Bool?
  public var chatId: Int64?
  public var spaceId: Int64?
  public var unreadCount: Int?
  public var readInboxMaxId: Int64?
  public var readOutboxMaxId: Int64?
  public var archived: Bool?
}

public struct Dialog: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
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
  public var draftMessage: DraftMessage?
  public var archived: Bool?
  public var chatId: Int64?

  public enum Columns {
    public static let id = Column(CodingKeys.id)
    public static let peerUserId = Column(CodingKeys.peerUserId)
    public static let peerThreadId = Column(CodingKeys.peerThreadId)
    public static let spaceId = Column(CodingKeys.spaceId)
    public static let unreadCount = Column(CodingKeys.unreadCount)
    public static let readInboxMaxId = Column(CodingKeys.readInboxMaxId)
    public static let readOutboxMaxId = Column(CodingKeys.readOutboxMaxId)
    public static let pinned = Column(CodingKeys.pinned)
    public static let draftMessage = Column(CodingKeys.draftMessage)
    public static let archived = Column(CodingKeys.archived)
    public static let chatId = Column(CodingKeys.chatId)
  }

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

  public static let chat = belongsTo(
    Chat.self,
    using: ForeignKey(["chatId"], to: ["id"])
  )
  public var chat: QueryInterfaceRequest<Chat> {
    request(for: Dialog.chat)
  }

  public static let peerThread = belongsTo(
    Chat.self,
    using: ForeignKey(["peerThreadId"], to: ["id"])
  )
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
    chatId = from.chatId
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
    draftMessage = nil
    archived = nil
    unreadCount = nil
    chatId = nil
  }

  init(optimisticForChat chat: Chat) {
    if let chatPeerUserId = chat.peerUserId {
      peerUserId = chatPeerUserId
      id = Self.getDialogId(peerUserId: chatPeerUserId)
    } else {
      peerThreadId = chat.id
      id = Self.getDialogId(peerThreadId: chat.id)
    }

    spaceId = chat.spaceId
    unreadCount = 0
    readInboxMaxId = nil
    readOutboxMaxId = nil
    pinned = nil
    draftMessage = nil
    archived = false
    unreadCount = nil
    chatId = chat.id
  }

  init(from: InlineProtocol.Dialog) {
    switch from.peer.type {
      case let .chat(chat):
        peerUserId = nil
        peerThreadId = chat.chatID
        id = Self.getDialogId(peerThreadId: chat.chatID)
      case let .user(user):
        peerUserId = user.userID
        peerThreadId = nil
        id = Self.getDialogId(peerUserId: user.userID)
      case .none:
        fatalError("Dialog.peer invalid")
    }

    spaceId = from.hasSpaceID ? from.spaceID : nil
    unreadCount = Int(from.unreadCount)
    readInboxMaxId = from.hasReadMaxID ? from.readMaxID : nil
    readOutboxMaxId = nil
    pinned = from.pinned
    archived = from.archived
    draftMessage = nil
    chatId = from.hasChatID ? from.chatID : nil
  }

  static func getDialogId(peerUserId: Int64) -> Int64 {
    peerUserId
  }

  static func getDialogId(peerThreadId: Int64) -> Int64 {
    if peerThreadId < 500 {
      peerThreadId
    } else {
      peerThreadId * -1
    }
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

public extension Dialog {
  static var previewDm: Self {
    Self(
      id: 1,
      peerUserId: 1,
      peerThreadId: nil,
      spaceId: nil,
      unreadCount: nil,
      readInboxMaxId: nil,
      readOutboxMaxId: nil,
      pinned: false,
      draftMessage: nil,
      archived: false
    )
  }

  static var previewThread: Self {
    Self(
      id: 1,
      peerUserId: nil,
      peerThreadId: 1,
      spaceId: nil,
      unreadCount: nil,
      readInboxMaxId: nil,
      readOutboxMaxId: nil,
      pinned: false,
      draftMessage: nil,
      archived: false
    )
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
      dialog.draftMessage = existing.draftMessage
      try dialog.save(db)
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
        .including(optional: Chat.lastMessage.including(
          optional: Message.from.forKey("from")
            .including(
              all: User.photos
                .forKey("profilePhoto")
            )
        ))
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
        .including(optional: Chat.lastMessage.including(
          optional: Message.from.forKey("from")
            .including(
              all: User.photos
                .forKey("profilePhoto")
            )
        ))
    )
    .asRequest(of: SpaceChatItem.self)
  }
}

public extension Dialog {
  /// Deletes this dialog and its associated chat (and all messages) from the local database.
  /// - Throws: Any database error.
  @discardableResult
  func deleteFromLocalDatabase() async throws {
    try await AppDatabase.shared.dbWriter.write { db in
      // Use peerId to fetch the associated chat
      if var chat = try Chat.getByPeerId(peerId: self.peerId) {
        chat.lastMsgId = nil
        try chat.save(db)
        try Message.filter(Column("chatId") == chat.id).deleteAll(db)
        try Chat.filter(Column("id") == chat.id).deleteAll(db)
      }
      // Delete the dialog itself
      try Dialog.filter(Column("id") == self.id).deleteAll(db)
    }
  }
}
