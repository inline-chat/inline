import Auth
import Combine
import GRDB
import Logger
import SwiftUI

public struct HomeSpaceItem: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var space: Space
  public var members: [Member]

  public var id: Int64 {
    space.id
  }

  public init(space: Space, members: [Member]) {
    self.space = space
    self.members = members
  }
}

public struct UserInfo: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable, Identifiable {
  public var user: User
  public var profilePhoto: [File]?
  public var id: Int64 { user.id }

  // coding keys
  public enum CodingKeys: String, CodingKey {
    case user
    case profilePhoto
  }

  public init(user: User, profilePhotos: [File]? = nil) {
    self.user = user
    profilePhoto = profilePhotos
  }

  public static let deleted = Self(user: .deletedInstance, profilePhotos: nil)
  public static let preview = Self(user: .preview, profilePhotos: nil)
}

public struct EmbeddedMessage: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable, Identifiable {
  public var message: Message
  public var senderInfo: UserInfo?
  public var translations: [Translation]
  // FIXME: can fetch only one thumbnail in the future
  public var photoInfo: PhotoInfo?
  public var videoInfo: VideoInfo?

  public var id: Int64 { message.id }

  public var from: User? {
    senderInfo?.user
  }

  public func translation(for language: String) -> Translation? {
    translations.first { $0.language == language }
  }

  public enum CodingKeys: String, CodingKey {
    case message
    case senderInfo
    case translations
    case photoInfo
    case videoInfo
  }

  public init(
    message: Message,
    senderInfo: UserInfo? = nil,
    translations: [Translation] = [],
    photoInfo: PhotoInfo? = nil,
    videoInfo: VideoInfo? = nil
  ) {
    self.message = message
    self.senderInfo = senderInfo
    self.translations = translations
    self.photoInfo = photoInfo
    self.videoInfo = videoInfo
  }
}

public struct HomeChatItem: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable,
  Identifiable
{
  public var dialog: Dialog
  /// peerUser
  public var user: UserInfo?
  public var chat: Chat?
  public var lastMessage: EmbeddedMessage?

  // public var spaceName: String?
  public var space: Space?
  public var id: Int64 { dialog.id }

  public var peerId: Peer {
    dialog.peerId
  }

  public init(
    dialog: Dialog,
    user: UserInfo?,
    chat: Chat?,
    lastMessage: EmbeddedMessage?,
    space: Space?
    // spaceName: String? = nil
  ) {
    self.dialog = dialog
    self.user = user
    self.chat = chat
    self.lastMessage = lastMessage
    self.space = space
    // self.spaceName = spaceName
  }

  // Add a static method to create the request
  static func all() -> QueryInterfaceRequest<HomeChatItem> {
    Dialog
      .including(
        optional: Dialog.peerUser
          .forKey(CodingKeys.user)
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      )

      .including(
        optional: Dialog.chat
          .forKey(CodingKeys.chat)
          .including(
            optional: Chat.lastMessage
              .forKey(CodingKeys.lastMessage)
              .including(
                optional: Message.from
                  .forKey(EmbeddedMessage.CodingKeys.senderInfo)
                  .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
              )
              .including(all: Message.translations.forKey(EmbeddedMessage.CodingKeys.translations))
              .including(
                optional: Message.photo.forKey(EmbeddedMessage.CodingKeys.photoInfo)
                  .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
              )
              .including(
                optional: Message.video.forKey(EmbeddedMessage.CodingKeys.videoInfo)
                  .including(
                    optional: Video.thumbnail
                      .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
                      .forKey(VideoInfo.CodingKeys.thumbnail)
                  )
              )
          )
      )

      // TODO: make it just name
      .including(
        optional: Dialog.space
      )
//      .including(
//        optional: Dialog.peerThread
//          .forKey(CodingKeys.chat)
//          .including(
//            optional: Chat.lastMessage
//              .forKey(CodingKeys.message)
//              .including(
//                optional: Message.from
//                  .forKey(CodingKeys.from)
//                  .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
//              )
//          )
//      )
      .asRequest(of: HomeChatItem.self)
  }
}

@MainActor
public final class HomeViewModel: ObservableObject {
  @Published public private(set) var chats: [HomeChatItem] = []
  @Published public private(set) var spaces: [HomeSpaceItem] = []

  // NEW
  @Published public private(set) var myChats: [HomeChatItem] = []
  @Published public private(set) var archivedChats: [HomeChatItem] = []

  private var chatsCancellable: AnyCancellable?
  private var spacesCancellable: AnyCancellable?
  private var db: AppDatabase

  public init(db: AppDatabase) {
    self.db = db
    start()
  }

  public func start() {
    fetchChats()
    fetchSpaces()
  }

  private func fetchChats() {
    chatsCancellable = ValueObservation
      .tracking { db in
        try HomeChatItem
          .all()
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { error in
          Log.shared.error("Failed to get home chats \(error)")
        },
        receiveValue: { [weak self] chats in
          guard let self else { return }

          let isInitial = self.chats.isEmpty

          self.chats = chats

          if isInitial {
            let sortedChats = Self.sortChats(Self.filterEmptyChats(chats))
            let filteredArchived = Self.filterArchived(sortedChats, archived: true)
            let filteredMyChats = Self.filterArchived(sortedChats, archived: false)

            archivedChats = filteredArchived
            myChats = filteredMyChats
          } else {
            Task.detached {
              // FIXME: Optimize this madness
              let sortedChats = Self.sortChats(Self.filterEmptyChats(chats))
              let filteredArchived = Self.filterArchived(sortedChats, archived: true)
              let filteredMyChats = Self.filterArchived(sortedChats, archived: false)

              Task { @MainActor in
                withAnimation(.smooth) {
                  self.archivedChats = filteredArchived
                  self.myChats = filteredMyChats
                }
              }
            }
          }
        }
      )
  }

  private func fetchSpaces() {
    spacesCancellable = ValueObservation
      .tracking { db in
        try Space
          .including(all: Space.members)
          .asRequest(of: HomeSpaceItem.self)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { error in
          Log.shared.error("Failed to get home spaces \(error)")
        },
        receiveValue: { [weak self] spaces in
          self?.spaces = spaces
        }
      )
  }
}

public extension AppDatabase {
  func getHomeChatItems() async throws -> [HomeChatItem] {
    // Fetch all chat items
    try await reader.read { db in
      try HomeChatItem.all().fetchAll(db)
    }
  }
}

public extension HomeViewModel {
  nonisolated static func sortChats(_ chats: [HomeChatItem]) -> [HomeChatItem] {
    chats.sorted { item1, item2 in
      // First sort by pinned status
      let pinned1 = item1.dialog.pinned ?? false
      let pinned2 = item2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }

      // Then sort by date
      let date1 = item1.lastMessage?.message.date ?? item1.chat?.date ?? Date.distantPast
      let date2 = item2.lastMessage?.message.date ?? item2.chat?.date ?? Date.distantPast
      return date1 > date2
    }
  }

  nonisolated static func filterArchived(_ chats: [HomeChatItem], archived: Bool) -> [HomeChatItem] {
    chats.filter { $0.dialog.archived == archived }
  }

  nonisolated static func filterEmptyChats(_ chats: [HomeChatItem]) -> [HomeChatItem] {
    chats.filter { $0.chat != nil }
  }
}
