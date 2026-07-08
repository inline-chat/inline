import Foundation
import GRDB
import ImageIO
import InlineAvatarRendering
import InlineKit
import Logger
import UIKit

// Class to update shared data when the app launches or before it exits
class AppDataUpdater {
  static let shared = AppDataUpdater()
  private static let sharedContainerIdentifier = "group.chat.inline"
  private static let intentAvatarDirectoryName = "IntentAvatars"
  private static let intentAvatarMaxPixelSize = 160
  private static let intentAvatarJPEGQuality: CGFloat = 0.82

  private struct IntentAvatarExport {
    let data: Data
    let identity: String
    let filenameExtension: String
  }

  private var db: AppDatabase = .shared

  // Update shared data for share extension to use
  func updateSharedData() {
    // Get recent chats and users
    DispatchQueue.global(qos: .background).async {
      self.fetchChatsAndUsers { chats, users in
        if let chats, let users {
          // Save data to shared location
          BridgeManager.shared.saveSharedData(chats: chats, users: users)
        }
      }
    }
  }

  // Fetch recent chats and users from app data
  private func fetchChatsAndUsers(completion: @escaping ([SharedChat]?, [SharedUser]?) -> Void) {
    Task.detached(priority: .background) {
      do {
        let snapshots: [HomeChatListItemSnapshot] = try await AppDatabase.shared.reader.read { db in
          let items = try HomeChatItem.all().fetchAll(db)
          return try HomeChatListItemSnapshot.snapshots(from: items, db: db)
        }

        // Convert from GRDB models to Bridge models
        var bridgeChats: [SharedChat] = []
        var bridgeUsers: [SharedUser] = []

        // Process chats
        for snapshot in snapshots {
          let item = snapshot.item
          var peerUserId: Int64?
          var peerThreadId: Int64?

          switch snapshot.peerId {
          case let .user(id):
            peerUserId = id
          case let .thread(id):
            peerThreadId = id
          }

          let bridgeChat = SharedChat(
            id: snapshot.id,
            title: snapshot.title,
            peerUserId: peerUserId,
            peerThreadId: peerThreadId,
            lastMessageDate: snapshot.sortDate,
            pinned: snapshot.pinned,
            spaceName: snapshot.spaceTitle,
            emoji: item.chat?.emoji,
            parentTitle: snapshot.parentTitle,
            preview: snapshot.preview,
            searchText: snapshot.searchText,
            unread: snapshot.unread,
            archived: snapshot.archived,
            isReplyThread: item.chat?.isReplyThread
          )

          bridgeChats.append(bridgeChat)

          // Add user info if we have a user
          if let userInfo = item.displayUserInfo {
            let user = userInfo.user
            let bridgeUser = SharedUser(
              id: user.id,
              firstName: user.firstName ?? "",
              lastName: user.lastName ?? "",
              displayName: user.displayName,
              email: user.email,
              username: user.username,
              profileCdnUrl: user.profileCdnUrl,
              profileLocalPath: user.profileLocalPath,
              profileFileUniqueId: user.profileFileUniqueId,
              profileSharedLocalPath: Self.intentAvatarLocalPath(for: user)
            )

            if !bridgeUsers.contains(where: { $0.id == bridgeUser.id }) {
              bridgeUsers.append(bridgeUser)
            }
          }
        }

        // Return the data on the main thread
        DispatchQueue.main.async {
          completion(bridgeChats, bridgeUsers)
        }
      } catch {
        Log.shared.error("👽 Error fetching chats and users: \(error)")
        DispatchQueue.main.async {
          completion(nil, nil)
        }
      }
    }
  }

  private static func intentAvatarLocalPath(for user: User) -> String? {
    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: sharedContainerIdentifier
    ) else {
      Log.shared.warning("Failed to resolve shared container for intent avatar export")
      return nil
    }

    guard let export = intentAvatarExport(for: user) else {
      return nil
    }

    let fileName = intentAvatarFileName(
      for: user,
      identity: export.identity,
      filenameExtension: export.filenameExtension
    )
    let relativePath = "\(intentAvatarDirectoryName)/\(fileName)"
    let destinationURL = containerURL.appendingPathComponent(relativePath)

    do {
      let directoryURL = destinationURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      try export.data.write(to: destinationURL, options: .atomic)
      return relativePath
    } catch {
      Log.shared.warning("Failed to prepare intent avatar for user \(user.id): \(error.localizedDescription)")
      return nil
    }
  }

  private static func intentAvatarExport(for user: User) -> IntentAvatarExport? {
    if let sourceURL = user.getLocalURL(),
       FileManager.default.fileExists(atPath: sourceURL.path),
       let data = intentAvatarJPEGData(from: sourceURL) {
      return IntentAvatarExport(
        data: data,
        identity: user.profileFileUniqueId ?? user.profileLocalPath ?? "profile",
        filenameExtension: "jpg"
      )
    }

    let identity = InlineUserAvatarRenderIdentity(
      firstName: user.firstName,
      lastName: user.lastName,
      displayName: user.displayName,
      email: user.email,
      username: user.username,
      stableIdentifier: "user:\(user.id)"
    )
    guard let fallbackData = InlineAvatarBitmapRenderer.userInitialsImageData(
      identity: identity,
      size: CGSize(width: intentAvatarMaxPixelSize, height: intentAvatarMaxPixelSize),
      scale: 1
    ) else {
      return nil
    }

    return IntentAvatarExport(
      data: fallbackData,
      identity: "fallback-\(intentAvatarFallbackIdentity(for: user))",
      filenameExtension: "png"
    )
  }

  private static func intentAvatarFallbackIdentity(for user: User) -> String {
    let components: [String?] = [
      user.firstName,
      user.lastName,
      user.displayName,
      user.email,
      user.username,
    ]

    let identity = components
      .compactMap { value -> String? in
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
      .joined(separator: "-")

    return identity.isEmpty ? String(user.id) : identity
  }

  private static func intentAvatarJPEGData(from sourceURL: URL) -> Data? {
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
    ]
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions as CFDictionary) else {
      return nil
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: intentAvatarMaxPixelSize,
    ]

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
      return nil
    }

    return UIImage(cgImage: cgImage).jpegData(compressionQuality: intentAvatarJPEGQuality)
  }

  private static func intentAvatarFileName(
    for user: User,
    identity: String,
    filenameExtension: String
  ) -> String {
    let sanitizedIdentity = identity.unicodeScalars
      .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
      .joined()
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let sanitizedExtension = filenameExtension.unicodeScalars
      .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "" }
      .joined()
    let resolvedIdentity = sanitizedIdentity.isEmpty ? "avatar" : String(sanitizedIdentity.prefix(80))
    let resolvedExtension = sanitizedExtension.isEmpty ? "png" : sanitizedExtension

    return "user-\(user.id)-\(resolvedIdentity).\(resolvedExtension)"
  }
}

// App delegate extensions to register for app lifecycle events
extension UIApplicationDelegate {
  func setupAppDataUpdater() {
    // Update shared data when app launches
    AppDataUpdater.shared.updateSharedData()

    // Register for app will terminate notification
    NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { _ in
      AppDataUpdater.shared.updateSharedData()
    }

    // Register for app will enter background notification
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      AppDataUpdater.shared.updateSharedData()
    }
  }
}
