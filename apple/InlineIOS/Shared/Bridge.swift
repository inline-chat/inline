import Foundation
import Logger

struct SharedData: Codable {
  var shareExtensionData: ShareExtensionData
  var lastUpdate: Date

  init(shareExtensionData: ShareExtensionData, lastUpdate: Date) {
    self.shareExtensionData = shareExtensionData
    self.lastUpdate = lastUpdate
  }
}

struct ShareExtensionData: Codable {
  var chats: [SharedChat]
  var users: [SharedUser]

  init(chats: [SharedChat], users: [SharedUser]) {
    self.chats = chats
    self.users = users
  }
}

struct SharedChat: Codable {
  var id: Int64
  var title: String
  var peerUserId: Int64?
  var peerThreadId: Int64?
  var lastMessageDate: Date?
  var pinned: Bool?
  var spaceName: String?
  var emoji: String?
  var parentTitle: String?
  var preview: String?
  var searchText: String?
  var unread: Bool?
  var archived: Bool?
  var isReplyThread: Bool?

  init(
    id: Int64,
    title: String,
    peerUserId: Int64?,
    peerThreadId: Int64?,
    lastMessageDate: Date?,
    pinned: Bool?,
    spaceName: String?,
    emoji: String?,
    parentTitle: String? = nil,
    preview: String? = nil,
    searchText: String? = nil,
    unread: Bool? = nil,
    archived: Bool? = nil,
    isReplyThread: Bool? = nil
  ) {
    self.id = id
    self.title = title
    self.peerUserId = peerUserId
    self.peerThreadId = peerThreadId
    self.lastMessageDate = lastMessageDate
    self.pinned = pinned
    self.spaceName = spaceName
    self.emoji = emoji
    self.parentTitle = parentTitle
    self.preview = preview
    self.searchText = searchText
    self.unread = unread
    self.archived = archived
    self.isReplyThread = isReplyThread
  }
}

struct SharedUser: Codable, Equatable {
  var id: Int64
  var firstName: String
  var lastName: String
  var displayName: String?
  var email: String?
  var username: String?
  var profileCdnUrl: String?
  var profileLocalPath: String?
  var profileFileUniqueId: String?
  var profileSharedLocalPath: String?

  init(
    id: Int64,
    firstName: String,
    lastName: String,
    displayName: String?,
    email: String? = nil,
    username: String? = nil,
    profileCdnUrl: String? = nil,
    profileLocalPath: String? = nil,
    profileFileUniqueId: String? = nil,
    profileSharedLocalPath: String? = nil
  ) {
    self.id = id
    self.firstName = firstName
    self.lastName = lastName
    self.displayName = displayName
    self.email = email
    self.username = username
    self.profileCdnUrl = profileCdnUrl
    self.profileLocalPath = profileLocalPath
    self.profileFileUniqueId = profileFileUniqueId
    self.profileSharedLocalPath = profileSharedLocalPath
  }
}

// Bridge manager to handle data exchange
class BridgeManager {
  static let shared = BridgeManager()

  private let sharedContainerIdentifier = "group.chat.inline"

  var shareDataFileName: String {
    #if DEBUG
    return "SharedData_dev.json"
    #else
    return "SharedData.json"
    #endif
  }

  private var sharedDataURL: URL {
    let containerURL = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: sharedContainerIdentifier)!
    return containerURL.appendingPathComponent(shareDataFileName)
  }

  // Save data from main app to be shared with extension
  func saveSharedData(chats: [SharedChat], users: [SharedUser]) {
    Task(priority: .background) {
      let shareExtensionData = ShareExtensionData(chats: chats, users: users)

      let sharedData = SharedData(shareExtensionData: shareExtensionData, lastUpdate: Date())

      do {
        let encoder = JSONEncoder()
        let data = try encoder.encode(sharedData)
        try data.write(to: sharedDataURL)
      } catch {
        Log.shared.error("Failed to save shared data", error: error)
      }
    }
  }

  // Load shared data (used by both app and extension)
  func loadSharedData() -> SharedData? {
    do {
      let data = try Data(contentsOf: sharedDataURL)
      let decoder = JSONDecoder()

      return try decoder.decode(SharedData.self, from: data)
    } catch {
      return nil
    }
  }

  // Clear shared data file
  func clearSharedData() throws {
    if FileManager.default.fileExists(atPath: sharedDataURL.path) {
      try FileManager.default.removeItem(at: sharedDataURL)
      Log.shared.info("Cleared shared data file")
    }
  }
}
