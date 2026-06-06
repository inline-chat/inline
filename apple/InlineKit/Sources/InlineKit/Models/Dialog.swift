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
  public var open: Bool?
  public var openedDate: Int64?
  public var order: String?
  public var pinnedOrder: String?
  public var sidebarVisible: Bool?
  public var chatListHidden: Bool?
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
  public var unreadMark: Bool?
  public var notificationSettings: DialogNotificationSettings?
  /// True when this dialog is a stable member of the sidebar inbox.
  public var open: Bool = false
  public var openedDate: Date?
  public var order: String?
  public var pinnedOrder: String?
  /// True when this dialog should not be shown as its own chat row in chat lists.
  public var chatListHidden: Bool? = nil
  /// Reply-thread automatic surfacing policy; nil means relevance-only default.
  public var followMode: DialogFollowMode? = nil

  private enum CodingKeys: String, CodingKey {
    case id
    case peerUserId
    case peerThreadId
    case spaceId
    case unreadCount
    case readInboxMaxId
    case readOutboxMaxId
    case pinned
    case draftMessage
    case archived
    case chatId
    case unreadMark
    case notificationSettings
    case open
    case openedDate
    case order
    case pinnedOrder
    case chatListHidden
    case followMode
  }

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
    public static let unreadMark = Column(CodingKeys.unreadMark)
    public static let notificationSettings = Column(CodingKeys.notificationSettings)
    public static let open = Column(CodingKeys.open)
    public static let openedDate = Column(CodingKeys.openedDate)
    public static let order = Column(CodingKeys.order)
    public static let pinnedOrder = Column(CodingKeys.pinnedOrder)
    public static let chatListHidden = Column(CodingKeys.chatListHidden)
    public static let followMode = Column(CodingKeys.followMode)
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
    notificationSettings = nil
    open = from.open ?? false
    openedDate = from.openedDate.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    order = from.order
    pinnedOrder = from.pinnedOrder
    chatListHidden = Self.chatListHidden(from: from.chatListHidden, sidebarVisible: from.sidebarVisible)
    followMode = nil
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
    unreadMark = nil
    unreadCount = nil
    chatId = nil
    notificationSettings = nil
    open = false
    openedDate = nil
    order = nil
    pinnedOrder = nil
    chatListHidden = nil
    followMode = nil
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
    unreadMark = nil
    unreadCount = nil
    chatId = chat.id
    notificationSettings = nil
    open = false
    openedDate = nil
    order = nil
    pinnedOrder = nil
    chatListHidden = nil
    followMode = nil
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
    unreadMark = from.unreadMark
    draftMessage = nil
    chatId = from.hasChatID ? from.chatID : nil
    notificationSettings = from.hasNotificationSettings ? from.notificationSettings : nil
    open = from.hasOpen ? from.open : false
    openedDate = from.hasOpenedDate ? Date(timeIntervalSince1970: TimeInterval(from.openedDate)) : nil
    order = from.hasOrder ? from.order : nil
    pinnedOrder = from.hasPinnedOrder ? from.pinnedOrder : nil
    if from.hasChatListHidden {
      chatListHidden = from.chatListHidden
    } else if from.hasSidebarVisible {
      chatListHidden = from.sidebarVisible ? nil : true
    } else {
      chatListHidden = nil
    }
    followMode = from.hasFollowMode ? from.followMode : nil
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
      archived: false,
      chatId: nil,
      unreadMark: nil,
      notificationSettings: nil,
      open: false,
      openedDate: nil,
      order: nil,
      pinnedOrder: nil,
      chatListHidden: nil,
      followMode: nil
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
      archived: false,
      chatId: nil,
      unreadMark: nil,
      notificationSettings: nil,
      open: false,
      openedDate: nil,
      order: nil,
      pinnedOrder: nil,
      chatListHidden: nil,
      followMode: nil
    )
  }
}

// MARK: - Save

public extension ApiDialog {
  @discardableResult
  func saveFull(
    _ db: Database
  )
    throws -> Dialog
  {
    let existing = try? Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId))

    var dialog = Dialog(from: self)
    try dialog.clearMissingOptionalReferences(db)

    if let existing {
      dialog.draftMessage = existing.draftMessage
      dialog.notificationSettings = existing.notificationSettings
      dialog.unreadMark = existing.unreadMark
      if open == nil {
        dialog.open = existing.open
      }
      if open == false {
        dialog.openedDate = nil
        dialog.order = nil
      } else if openedDate == nil {
        dialog.openedDate = existing.openedDate
      }
      if open != false, order == nil {
        dialog.order = existing.order
      }
      if pinnedOrder == nil {
        dialog.pinnedOrder = existing.pinnedOrder
      }
      if chatListHidden == nil, sidebarVisible == nil {
        dialog.chatListHidden = existing.chatListHidden
      }
      dialog.followMode = existing.followMode
      try dialog.save(db)
    } else {
      try dialog.save(db, onConflict: .replace)
    }

    return dialog
  }
}

public extension InlineProtocol.Dialog {
  @discardableResult
  func saveFull(
    _ db: Database
  )
    throws -> Dialog
  {
    let existing = try? Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peer.toPeer()))
    if let existing {
      var newDialog = Dialog(from: self)
      try newDialog.clearMissingOptionalReferences(db)
      newDialog.draftMessage = existing.draftMessage
      if !hasNotificationSettings {
        newDialog.notificationSettings = existing.notificationSettings
      }
      if !hasOpen {
        newDialog.open = existing.open
      }
      if hasOpen, open == false {
        newDialog.openedDate = nil
        newDialog.order = nil
      } else if !hasOpenedDate {
        newDialog.openedDate = existing.openedDate
      }
      if !(hasOpen && open == false), !hasOrder {
        newDialog.order = existing.order
      }
      if !hasPinnedOrder {
        newDialog.pinnedOrder = existing.pinnedOrder
      }
      if !hasChatListHidden, !hasSidebarVisible {
        newDialog.chatListHidden = existing.chatListHidden
      }
      if !hasFollowMode {
        newDialog.followMode = existing.followMode
      }
      try newDialog.save(db, onConflict: .replace)
      return newDialog
    } else {
      var newDialog = Dialog(from: self)
      try newDialog.clearMissingOptionalReferences(db)
      try newDialog.save(db, onConflict: .replace)
      return newDialog
    }
  }
}

private extension Dialog {
  mutating func clearMissingOptionalReferences(_ db: Database) throws {
    if let spaceId, try Space.fetchOne(db, id: spaceId) == nil {
      self.spaceId = nil
    }
  }
}

public extension Dialog {
  static func chatListHidden(from chatListHidden: Bool?, sidebarVisible: Bool?) -> Bool? {
    if let chatListHidden {
      return chatListHidden
    }

    guard let sidebarVisible else {
      return nil
    }

    return sidebarVisible ? nil : true
  }

  static let chatListVisibilitySQL =
    "(\"dialog\".\"chatListHidden\" IS NULL OR \"dialog\".\"chatListHidden\" = 0)"
  static let sidebarInboxVisibilitySQL =
    "(\(chatListVisibilitySQL) AND (\"dialog\".\"open\" = 1 OR \"dialog\".\"pinned\" = 1))"

  static func nextSidebarOrder(_ db: Database) throws -> String {
    try nextOrder(
      db,
      column: "order",
      filter: """
      AND "open" = 1
      AND ("pinned" IS NULL OR "pinned" = 0)
      """
    )
  }

  static func nextPinnedOrder(_ db: Database) throws -> String {
    try nextOrder(
      db,
      column: "pinnedOrder",
      filter: """
      AND "pinned" = 1
      """
    )
  }

  private static func nextOrder(_ db: Database, column: String, filter: String) throws -> String {
    let request = SQLRequest<String>(
      sql: """
      SELECT "\(column)"
      FROM "dialog"
      WHERE "\(column)" IS NOT NULL
      \(filter)
      ORDER BY "\(column)" DESC
      LIMIT 1
      """
    )

    return FractionalIndex.after(try request.fetchOne(db))
  }

  static func applyingChatListVisibilityFilter<T: DerivableRequest>(_ request: T) -> T {
    request.filter(sql: chatListVisibilitySQL)
  }

  static func get(peerId: Peer) -> QueryInterfaceRequest<Dialog> {
    Dialog
      .filter(
        Column("id") == Dialog.getDialogId(peerId: peerId)
      )
  }

  static func sidebarSpaceChatItemQuery(spaceId: Int64) -> QueryInterfaceRequest<SpaceChatItem> {
    applyingChatListVisibilityFilter(
      spaceChatItemQuery()
        .filter(Columns.spaceId == spaceId)
    )
  }

  // use for array fetches
  static func spaceChatItemQuery() -> QueryInterfaceRequest<SpaceChatItem> {
    // chat through dialog thread
    including(
      optional: Dialog.peerThread
        .including(
          optional: Chat.lastMessage.including(
            optional: Message.from.forKey("from")
              .including(
                all: User.photos
                  .forKey("profilePhoto")
              )
          )
          .including(all: Message.translations.forKey("translations"))
          .including(
            optional: Message.photo
              .forKey("photoInfo")
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          )
          .including(optional: Message.document.forKey("document"))
        )
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
    .including(
      optional: Dialog.peerUserChat
        .including(
          optional: Chat.lastMessage.including(
            optional: Message.from.forKey("from")
              .including(
                all: User.photos
                  .forKey("profilePhoto")
              )
          )
          .including(all: Message.translations.forKey("translations"))
          .including(
            optional: Message.photo
              .forKey("photoInfo")
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          )
          .including(optional: Message.document.forKey("document"))
        )
    )
    .asRequest(of: SpaceChatItem.self)
  }

  static func spaceChatItemQueryForChat() -> QueryInterfaceRequest<SpaceChatItem> {
    // chat through dialog thread
    including(
      optional: Dialog.peerThread
        .including(
          optional: Chat.lastMessage.including(
            optional: Message.from.forKey("from")
              .including(
                all: User.photos
                  .forKey("profilePhoto")
              )
          )
          .including(all: Message.translations.forKey("translations"))
          .including(
            optional: Message.photo
              .forKey("photoInfo")
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          )
          .including(optional: Message.document.forKey("document"))
        )
    )

    .asRequest(of: SpaceChatItem.self)
  }
}

public extension Dialog {
  /// Deletes this dialog and its associated chat (and all messages) from the local database.
  /// - Throws: Any database error.
  func deleteFromLocalDatabase() async throws {
    try await AppDatabase.shared.dbWriter.write { db in
      // Use peerId to fetch the associated chat
      if var chat = try Chat.getByPeerId(db: db, peerId: self.peerId) {
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
