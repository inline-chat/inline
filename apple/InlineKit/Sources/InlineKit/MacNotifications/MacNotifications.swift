import Foundation
import InlineProtocol
import UserNotifications

public actor MacNotifications: Sendable {
  public static let shared = MacNotifications()

  private static let urgentNudgeText = "\u{1F6A8}"

  private var soundEnabled = true

  func requestPermission() async throws -> Bool {
    try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
  }

  public func setSoundEnabled(_ enabled: Bool) {
    soundEnabled = enabled
  }

  private func isSoundEnabled() -> Bool {
    soundEnabled
  }

  nonisolated func showMessageNotification(
    title: String,
    subtitle: String? = nil,
    body: String,
    userInfo: [AnyHashable: Any],
    imageURL: URL? = nil,
    forceSound: Bool = false
  ) async {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let subtitle {
      content.subtitle = subtitle
    }
    content.userInfo = userInfo
    let isSoundEnabled = await self.isSoundEnabled()
    content.sound = (forceSound || isSoundEnabled) ? .default : nil

    if let imageURL {
      do {
        let attachment = try UNNotificationAttachment(
          identifier: UUID().uuidString,
          url: imageURL,
          options: nil
        )
        content.attachments = [attachment]

      } catch {
        print("Failed to create notification attachment: \(error)")
      }
    }

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil
    )

    do {
      let center = UNUserNotificationCenter.current()
      try await center.add(request)
    } catch {
      print("Failed to show notification: \(error)")
    }
  }
}

extension MacNotifications {
  public func showMessageFailedNotification(
    chatId: Int64,
    peerId: Peer
  ) async {
    let chat = await ObjectCache.shared.getChat(id: chatId)
    let chatName = chat?.title ?? "Chat"

    let title = "Message failed to send"
    let body = "Tap to open \(chatName) and retry"

    var userInfo: [String: Any] = [
      "type": "messageFailed",
      "chatId": chatId,
      "isThread": peerId.isThread,
    ]

    if peerId.isThread {
      userInfo["threadId"] = peerId.id
    } else if let userId = peerId.asUserId() {
      userInfo["userId"] = userId
    }

    await showMessageNotification(
      title: title,
      body: body,
      userInfo: userInfo
    )
  }

  func handleNewMessage(protocolMsg: InlineProtocol.Message) async {
    // Only show notification for incoming messages
    guard protocolMsg.out == false else { return }

    let user = await ObjectCache.shared.getUser(id: protocolMsg.fromID)
    let chat = await ObjectCache.shared.getChat(id: protocolMsg.chatID)
    let space: Space? = if let spaceId = chat?.spaceId {
      await ObjectCache.shared.getSpace(id: spaceId)
    } else {
      nil
    }

    let senderName = user?.user.displayName ?? "Unknown"
    let chatName = chat?.title ?? "New Message"

    // Prepare notification content
    let title: String
    let subtitle: String?
    let body: String

    if chat?.type == .thread {
      title = "\(chatName) \(space != nil ? "(\(space!.name))" : "")"
      subtitle = senderName
      body = protocolMsg.stringRepresentationWithEmoji
    } else {
      title = senderName
      subtitle = nil
      body = protocolMsg.stringRepresentationWithEmoji
    }

    // // Get sender avatar if available
    var imageURL: URL?

    if let file = user?.profilePhoto?.first, let localUrl = file.getLocalURL() {
      imageURL = localUrl
    }
    // if let sender {
    //   do {
    //     try await AppDatabase.shared.reader.read { db in
    //       // Get the most recent profile photo
    //       if let photo = try sender.photos
    //         .order(Column("date").desc)
    //         .fetchOne(db)
    //       {
    //         imageURL = photo.getRemoteURL()
    //       }
    //     }
    //   } catch {
    //     print("Failed to fetch user photo: \(error)")
    //   }
    // }

    let trimmedText = protocolMsg.hasMessage ? protocolMsg.message.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    let isUrgentNudge = {
      guard case .nudge = protocolMsg.media.media else { return false }
      return trimmedText == Self.urgentNudgeText
    }()

    Task {
      // Show notification
      await MacNotifications.shared.showMessageNotification(
        title: title,
        subtitle: subtitle,
        body: body,
        userInfo: [
          // sender user ID
          "userId": protocolMsg.fromID,
          "isThread": chat?.type == .thread,
          "threadId": chat?.id as Any,
        ],
        imageURL: imageURL,
        forceSound: isUrgentNudge
        // userInfo: ["chatId": message.chatID],
      )
    }
  }
}
