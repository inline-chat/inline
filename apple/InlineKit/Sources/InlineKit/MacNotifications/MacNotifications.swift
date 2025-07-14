import Foundation
import InlineProtocol
import UserNotifications

actor MacNotifications: Sendable {
  static let shared = MacNotifications()

  func requestPermission() async throws -> Bool {
    try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
  }

  nonisolated func showMessageNotification(
    title: String,
    subtitle: String? = nil,
    body: String,
    userInfo: [AnyHashable: Any],
    imageURL: URL? = nil
  ) async {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let subtitle {
      content.subtitle = subtitle
    }
    content.userInfo = userInfo
    content.sound = .default

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
          "threadId": chat?.id,
        ],
        imageURL: imageURL
        // userInfo: ["chatId": message.chatID],
      )
    }
  }
}
