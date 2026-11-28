import Foundation
import GRDB
import ImageIO
import InlineAvatarRendering
import InlineIntents
import InlineKit
import InlineSharedSnapshot
import Logger
import UIKit
import WidgetKit

actor AppDataUpdater {
  static let shared = AppDataUpdater()
  private static let log = Log.scoped("AppDataUpdater")
  private static let sharedContainerIdentifier = "group.chat.inline"
  private static let intentAvatarMaxPixelSize = Int(InlineMessageIntentDonation.preferredAvatarPixelSize)
  private static let intentAvatarJPEGQuality: CGFloat = 0.82

  private var refreshTask: Task<Void, Never>?
  private var refreshRequestedWhileRunning = false
  private var areSharedDataUpdatesEnabled = true

  private struct IntentAvatarExport {
    let data: Data
    let identity: String
    let filenameExtension: String
  }

  /// Refreshes the app-group snapshot and coalesces concurrent lifecycle requests.
  func updateSharedData() async {
    guard areSharedDataUpdatesEnabled else { return }

    // Preserve the last valid share snapshot when protected data is unavailable at launch.
    // The in-memory fallback is intentionally empty and must never replace account data.
    guard AppDatabase.shared.isPersistent else {
      Self.log.warning("Skipped share-extension data refresh while the persistent database is unavailable")
      return
    }

    if let refreshTask {
      refreshRequestedWhileRunning = true
      await refreshTask.value
      return
    }

    repeat {
      refreshRequestedWhileRunning = false
      let task = Task.detached(priority: .utility) {
        do {
          let snapshots = try await Self.fetchHomeSnapshots()
          let data = try Self.makeShareExtensionData(from: snapshots)
          try Task.checkCancellation()
          let shareWrite = try BridgeManager.shared.saveSharedData(chats: data.chats, users: data.users)
          Self.log.info("Share-extension data for \(data.chats.count) chats: \(shareWrite)")

          try Task.checkCancellation()
          let widget = Self.makeWidgetSnapshot(from: snapshots, shareData: data)
          if try BridgeManager.shared.store?.write(widget) == .written {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetChatsSnapshot.widgetKind)
            Self.log.info("Widget data for \(widget.chats.count) chats written")
          }
        } catch is CancellationError {
          // Logout owns cache cleanup and intentionally cancels an in-flight refresh.
        } catch let error as SharedSnapshotError {
          // Signed out, or the keychain is locked: keep the last snapshot for its owner to check.
          Self.log.info("Skipped shared data refresh: \(error)")
        } catch {
          Self.log.error("Failed to refresh share-extension data", error: error)
        }
      }
      refreshTask = task
      await task.value
      refreshTask = nil
    } while refreshRequestedWhileRunning
  }

  func clearSharedData() async throws {
    areSharedDataUpdatesEnabled = false
    refreshRequestedWhileRunning = false
    if let refreshTask {
      refreshTask.cancel()
      await refreshTask.value
      self.refreshTask = nil
    }
    try BridgeManager.shared.clearSharedData()
    WidgetCenter.shared.reloadTimelines(ofKind: WidgetChatsSnapshot.widgetKind)
  }

  func resumeSharedDataUpdates() {
    areSharedDataUpdatesEnabled = true
  }

  func cancelRefresh() async {
    refreshRequestedWhileRunning = false
    guard let refreshTask else { return }
    refreshTask.cancel()
    await refreshTask.value
    self.refreshTask = nil
  }

  func outgoingIntentRequest(
    peerId: Peer,
    chatId _: Int64
  ) async -> InlineMessageIntentDonation.Request? {
    await Task.detached(priority: .userInitiated) {
      if let data = BridgeManager.shared.loadSharedData(),
         let request = Self.outgoingIntentRequest(
           peerId: peerId,
           data: data.shareExtensionData
         ) {
        return request
      }

      do {
        guard let data = try await Self.fetchShareExtensionData(
          peerId: peerId
        ) else {
          return nil
        }
        return Self.outgoingIntentRequest(
          peerId: peerId,
          data: data
        )
      } catch {
        Self.log.error("Failed to load outgoing intent metadata", error: error)
        return nil
      }
    }.value
  }

  private static func outgoingIntentRequest(
    peerId: Peer,
    data: ShareExtensionData
  ) -> InlineMessageIntentDonation.Request? {
    let chat = data.chats.first { chat in
      switch peerId {
      case let .user(userId):
        return chat.peerUserId == userId
      case let .thread(threadId):
        return chat.peerThreadId == threadId
      }
    }
    return chat?.intentDonationRequest(users: data.users, direction: .outgoing)
  }

  private static func fetchHomeSnapshots() async throws -> [HomeChatListItemSnapshot] {
    try await AppDatabase.shared.reader.read { db in
      let items = try HomeChatItem.all().fetchAll(db)
      return try HomeChatListItemSnapshot.snapshots(from: items, db: db)
    }
  }

  /// The top of the chat list in its on-screen order. Avatars reuse the exports made for the share
  /// extension, so the widget never decodes a full-size photo.
  private static func makeWidgetSnapshot(
    from snapshots: [HomeChatListItemSnapshot],
    shareData: ShareExtensionData
  ) -> WidgetChatsSnapshot {
    let visible = snapshots.filter { !$0.archived }
    let avatarPaths = Dictionary(
      shareData.users.compactMap { user in user.profileSharedLocalPath.map { (user.id, $0) } },
      uniquingKeysWith: { first, _ in first }
    )

    let chats = visible.prefix(WidgetChatsSnapshot.maximumChatCount).map { snapshot in
      let item = snapshot.item
      let kind: WidgetChat.Kind
      let avatarPath: String?
      let deepLink: InlineDeepLink?
      switch snapshot.peerId {
      case let .user(id):
        kind = .user
        avatarPath = avatarPaths[id]
        deepLink = .user(id: id)
      case let .thread(id):
        kind = .thread
        avatarPath = nil
        deepLink = .chat(id: snapshot.chatId ?? id)
      }

      return WidgetChat(
        id: snapshot.id,
        kind: kind,
        title: snapshot.title,
        preview: snapshot.preview
          .components(separatedBy: .newlines)
          .joined(separator: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines),
        date: snapshot.sortDate == .distantPast ? nil : snapshot.sortDate,
        unreadCount: max(item.dialog.unreadCount ?? 0, 0),
        isUnread: snapshot.unread,
        isPinned: snapshot.pinned,
        emoji: item.chat?.emoji,
        initials: WidgetChat.initials(for: snapshot.title),
        avatarPath: avatarPath,
        deepLink: deepLink?.url?.absoluteString
      )
    }

    return WidgetChatsSnapshot(
      chats: Array(chats),
      unreadChatCount: visible.count(where: \.unread)
    )
  }

  private static func fetchShareExtensionData(
    peerId: Peer
  ) async throws -> ShareExtensionData? {
    let snapshot: HomeChatListItemSnapshot? = try await AppDatabase.shared.reader.read { db in
      let peerItem: HomeChatItem? = switch peerId {
      case let .user(userId):
        try HomeChatItem.all()
          .filter(Dialog.Columns.peerUserId == userId)
          .fetchOne(db)
      case let .thread(threadId):
        try HomeChatItem.all()
          .filter(Dialog.Columns.peerThreadId == threadId)
          .fetchOne(db)
      }

      guard let item = peerItem else { return nil }
      return try HomeChatListItemSnapshot.snapshots(from: [item], db: db).first
    }

    return try snapshot.map { try makeShareExtensionData(from: [$0]) }
  }

  private static func makeShareExtensionData(
    from snapshots: [HomeChatListItemSnapshot]
  ) throws -> ShareExtensionData {
    var chats: [SharedChat] = []
    var users: [SharedUser] = []
    var userIds = Set<Int64>()

    for snapshot in snapshots {
      try Task.checkCancellation()
      let item = snapshot.item
      let peerUserId: Int64?
      let peerThreadId: Int64?

      switch snapshot.peerId {
      case let .user(id):
        peerUserId = id
        peerThreadId = nil
      case let .thread(id):
        peerUserId = nil
        peerThreadId = id
      }

      chats.append(SharedChat(
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
      ))

      guard let user = item.displayUserInfo?.user,
            userIds.insert(user.id).inserted
      else { continue }

      users.append(SharedUser(
        id: user.id,
        firstName: user.firstName ?? "",
        lastName: user.lastName ?? "",
        displayName: user.displayName,
        email: user.email,
        username: user.username,
        profileCdnUrl: user.profileCdnUrl,
        profileFileId: user.profileFileId,
        profileLocalPath: user.profileLocalPath,
        profileFileUniqueId: user.profileFileUniqueId,
        profileSharedLocalPath: intentAvatarLocalPath(for: user)
      ))
    }

    return ShareExtensionData(chats: chats, users: users)
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
    let relativePath = "\(BridgeManager.shared.intentAvatarDirectoryName)/\(fileName)"
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

    // A configured photo that is temporarily unavailable must stay visibly
    // unavailable. Initials mean the account has no configured profile photo.
    guard !hasConfiguredProfilePhoto(user) else {
      return nil
    }

    let identity = InlineUserAvatarRenderIdentity(
      firstName: user.firstName,
      lastName: user.lastName,
      displayName: nil,
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

  private static func hasConfiguredProfilePhoto(_ user: User) -> Bool {
    [
      user.profileFileId,
      user.profileCdnUrl,
      user.profileLocalPath,
      user.profileFileUniqueId,
    ].contains { value in
      guard let value else { return false }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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

extension UIApplicationDelegate {
  func setupAppDataUpdater() {
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task {
        _ = await AppDatabase.promoteSharedToPersistentIfPossible()
        await AppDataUpdater.shared.updateSharedData()
      }
    }

    NotificationCenter.default.addObserver(
      forName: .authenticationChanged,
      object: nil,
      queue: .main
    ) { notification in
      guard notification.object as? Bool == true else { return }
      Task {
        await AppDataUpdater.shared.resumeSharedDataUpdates()
        IntentDonationCoordinator.resume()
        _ = await AppDatabase.promoteSharedToPersistentIfPossible()
        await AppDataUpdater.shared.updateSharedData()
      }
    }

    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        SharedDataBackgroundRefresh(application: UIApplication.shared).start()
      }
    }
  }
}

@MainActor
private final class SharedDataBackgroundRefresh {
  private let application: UIApplication
  private var identifier = UIBackgroundTaskIdentifier.invalid
  private var task: Task<Void, Never>?

  init(application: UIApplication) {
    self.application = application
  }

  func start() {
    guard task == nil else { return }

    identifier = application.beginBackgroundTask(withName: "Refresh Inline share data") { [weak self] in
      Task { @MainActor in
        self?.expire()
      }
    }
    task = Task { @MainActor in
      _ = await AppDatabase.promoteSharedToPersistentIfPossible()
      guard !Task.isCancelled else { return }
      await AppDataUpdater.shared.updateSharedData()
      finish()
    }
  }

  private func expire() {
    task?.cancel()
    Task {
      await AppDataUpdater.shared.cancelRefresh()
    }
    finish()
  }

  private func finish() {
    let identifierToEnd = identifier
    identifier = .invalid
    task = nil
    guard identifierToEnd != .invalid else { return }
    application.endBackgroundTask(identifierToEnd)
  }
}
