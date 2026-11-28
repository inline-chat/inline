import Foundation
import InlineConfig
import InlineIntents
import InlineSharedSnapshot
import Logger

/// What the share extension shows: the snapshot payload and when the app wrote it.
struct SharedData {
  var shareExtensionData: ShareExtensionData
  var lastUpdate: Date
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
      source: intentAvatarSource,
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

  var intentAvatarSource: InlineMessageIntentDonation.UserAvatar.Source {
    if let intentAvatarData {
      return .imageData(intentAvatarData)
    }
    return hasConfiguredProfilePhoto ? .configuredPhotoUnavailable : .noPhotoConfigured
  }

  var hasConfiguredProfilePhoto: Bool {
    [profileCdnUrl, profileFileId, profileLocalPath, profileFileUniqueId]
      .contains { $0?.trimmedForIntent != nil }
  }
}

private extension String {
  var trimmedForIntent: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private enum SharedDataBridgeError: LocalizedError {
  case containerUnavailable

  var errorDescription: String? {
    switch self {
    case .containerUnavailable:
      "The Inline app-group container is unavailable."
    }
  }
}

/// The pre-envelope file, read only until the app writes its first snapshot after an update.
private struct LegacySharedData: Decodable {
  var shareExtensionData: ShareExtensionData
  var lastUpdate: Date
}

// Bridge manager to handle data exchange
final class BridgeManager: Sendable {
  static let shared = BridgeManager()

  private let log = Log.scoped("SharedData")

  /// Snapshots in the app group, stamped with the signed-in account from the notification fence.
  let store: SharedSnapshotStore? = SharedSnapshotStore.appGroup(userProfile: ProjectConfig.userProfile)

  var intentAvatarDirectoryName: String {
    if let profile = ProjectConfig.userProfile {
      return "IntentAvatars_\(profile)"
    }
    #if DEBUG
    return "IntentAvatars_dev"
    #else
    return "IntentAvatars"
    #endif
  }

  private var legacyShareDataFileName: String {
    if let profile = ProjectConfig.userProfile {
      return "SharedData_\(profile).json"
    }
    #if DEBUG
    return "SharedData_dev.json"
    #else
    return "SharedData.json"
    #endif
  }

  private var legacySharedDataURL: URL? {
    SharedSnapshotStore.appGroupContainerURL?.appendingPathComponent(legacyShareDataFileName)
  }

  // Save data from main app to be shared with extension
  @discardableResult
  func saveSharedData(chats: [SharedChat], users: [SharedUser]) throws -> SharedSnapshotWrite {
    guard let store else {
      throw SharedDataBridgeError.containerUnavailable
    }

    let result = try store.write(ShareExtensionData(chats: chats, users: users))
    if let legacySharedDataURL, FileManager.default.fileExists(atPath: legacySharedDataURL.path) {
      try? FileManager.default.removeItem(at: legacySharedDataURL)
    }
    return result
  }

  // Load shared data (used by both app and extension)
  func loadSharedData() -> SharedData? {
    guard let store else {
      log.error("Unable to resolve app group container for shared data")
      return nil
    }

    switch store.read(ShareExtensionData.self) {
    case let .current(snapshot), let .unverified(snapshot):
      return SharedData(shareExtensionData: snapshot.payload, lastUpdate: snapshot.writtenAt)
    case .missing:
      return loadLegacySharedData()
    case .signedOut:
      log.info("Share data hidden: no account is signed in")
      return nil
    case .otherOwner:
      log.warning("Share data ignored: written for another sign-in")
      return nil
    case .incompatible:
      log.warning("Share data ignored: unreadable or another schema version")
      return nil
    }
  }

  private func loadLegacySharedData() -> SharedData? {
    guard let legacySharedDataURL,
          let data = try? Data(contentsOf: legacySharedDataURL),
          let legacy = try? JSONDecoder().decode(LegacySharedData.self, from: data)
    else { return nil }
    return SharedData(shareExtensionData: legacy.shareExtensionData, lastUpdate: legacy.lastUpdate)
  }

  // Clear shared data file
  func clearSharedData() throws {
    guard let store, let containerURL = SharedSnapshotStore.appGroupContainerURL else {
      throw SharedDataBridgeError.containerUnavailable
    }

    try store.remove(ShareExtensionData.self)
    try store.remove(WidgetChatsSnapshot.self)
    try ShareExtensionCacheCleanup.clear(
      containerURL: containerURL,
      payloadFileName: legacyShareDataFileName,
      avatarDirectoryName: intentAvatarDirectoryName
    )
    log.info("Cleared share-extension and widget data")
  }
}
