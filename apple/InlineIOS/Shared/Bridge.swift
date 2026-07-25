import Foundation
import InlineIntents
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

extension SharedUser {
  var sharedAvatarURL: URL? {
    guard let relativePath = profileSharedLocalPath?.trimmedForIntent,
          !relativePath.hasPrefix("/"),
          !relativePath.split(separator: "/").contains(".."),
          let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.chat.inline"
          )
    else { return nil }

    let standardizedContainerURL = containerURL.standardizedFileURL
    let avatarURL = standardizedContainerURL
      .appendingPathComponent(relativePath)
      .standardizedFileURL
    guard avatarURL.path.hasPrefix(standardizedContainerURL.path + "/") else {
      return nil
    }
    return avatarURL
  }
}

extension SharedChat {
  var intentConversationIdentifier: String {
    if let peerUserId {
      return InlineMessageIntentDonation.userConversationIdentifier(String(peerUserId))
    }
    if let peerThreadId {
      return InlineMessageIntentDonation.threadConversationIdentifier(String(peerThreadId))
    }
    return InlineMessageIntentDonation.chatConversationIdentifier(String(id))
  }

  func intentDonationRequest(
    users: [SharedUser],
    direction: InlineMessageIntentDonation.Direction
  ) -> InlineMessageIntentDonation.Request {
    let user = peerUserId.flatMap { userId in users.first(where: { $0.id == userId }) }
    let displayName = intentDisplayName(user: user)
    let recipient = user.map { $0.intentPerson(conversationIdentifier: intentConversationIdentifier) }
    let avatar: InlineMessageIntentDonation.Avatar = if let user {
      user.intentAvatar
    } else {
      .thread(.init(
        emoji: emoji,
        title: displayName,
        isReplyThread: isReplyThread ?? false,
        stableIdentifier: intentConversationIdentifier
      ))
    }

    return .init(
      conversation: .init(
        identifier: intentConversationIdentifier,
        displayName: displayName,
        avatar: avatar,
        recipientCount: recipient == nil ? nil : 1
      ),
      direction: direction,
      recipients: recipient.map { [$0] } ?? []
    )
  }

  private func intentDisplayName(user: SharedUser?) -> String {
    if let title = title.trimmedForIntent { return title }
    return user?.intentDisplayName ?? "Chat"
  }
}

private extension SharedUser {
  var intentDisplayName: String {
    if let displayName = displayName?.trimmedForIntent { return displayName }
    let fullName = [firstName.trimmedForIntent, lastName.trimmedForIntent]
      .compactMap(\.self)
      .joined(separator: " ")
    if !fullName.isEmpty { return fullName }
    return username?.trimmedForIntent ?? email?.trimmedForIntent ?? "Chat"
  }

  var intentAvatar: InlineMessageIntentDonation.Avatar {
    .user(.init(
      imageData: intentAvatarData,
      firstName: firstName,
      lastName: lastName,
      displayName: displayName,
      email: email,
      username: username,
      stableIdentifier: "user:\(id)"
    ))
  }

  func intentPerson(conversationIdentifier: String) -> InlineMessageIntentDonation.Person {
    let email = email?.trimmedForIntent
    let username = username?.trimmedForIntent
    return .init(
      identifier: conversationIdentifier,
      handle: email ?? username ?? conversationIdentifier,
      handleType: email == nil ? .unknown : .emailAddress,
      firstName: firstName,
      lastName: lastName,
      displayName: intentDisplayName,
      avatar: intentAvatar
    )
  }

  var intentAvatarData: Data? {
    guard let sharedAvatarURL else { return nil }
    return try? Data(contentsOf: sharedAvatarURL)
  }
}

private extension String {
  var trimmedForIntent: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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

  private var sharedDataURL: URL? {
    guard let containerURL = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: sharedContainerIdentifier)
    else {
      Log.shared.error("Unable to resolve app group container for share data")
      return nil
    }
    return containerURL.appendingPathComponent(shareDataFileName)
  }

  // Save data from main app to be shared with extension
  func saveSharedData(chats: [SharedChat], users: [SharedUser]) {
    Task(priority: .background) {
      guard let sharedDataURL else { return }

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
    guard let sharedDataURL else { return nil }

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
    guard let sharedDataURL else { return }

    if FileManager.default.fileExists(atPath: sharedDataURL.path) {
      try FileManager.default.removeItem(at: sharedDataURL)
      Log.shared.info("Cleared shared data file")
    }
  }
}
