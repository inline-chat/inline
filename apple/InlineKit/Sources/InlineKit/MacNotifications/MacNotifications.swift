#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import InlineProtocol
import Kingfisher
import Logger
import UserNotifications
import UniformTypeIdentifiers

public actor MacNotifications: Sendable {
  public static let shared = MacNotifications()

  private static let urgentNudgeText = "\u{1F6A8}"

  private var soundEnabled = true
  private let log = Log.scoped("MacNotifications")
  private let avatarBuilder = AvatarAttachmentBuilder(avatarDiameter: 44)

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
        log.error("Failed to create notification attachment", error: error)
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
      log.error("Failed to show notification", error: error)
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

    let avatarURL = await avatarBuilder.attachmentURL(for: user)
    let trimmedText = protocolMsg.hasMessage ? protocolMsg.message.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    let isUrgentNudge = {
      guard case .nudge = protocolMsg.media.media else { return false }
      return trimmedText == Self.urgentNudgeText
    }()

    await showMessageNotification(
      title: title,
      subtitle: subtitle,
      body: body,
      userInfo: [
        // sender user ID
        "userId": protocolMsg.fromID,
        "isThread": chat?.type == .thread,
        "threadId": chat?.id as Any,
      ],
      imageURL: avatarURL,
      forceSound: isUrgentNudge
    )
  }
}

// MARK: - Avatar attachments

private actor AvatarAttachmentBuilder {
  private let log = Log.scoped("NotificationAvatar")
  private let avatarDiameter: CGFloat
  private let thumbnailMaxPixel: Int
  private let timeoutSeconds: TimeInterval = 3
  private let cacheLimit: Int = 64
  private var cachedAttachments: [String: URL] = [:]
  private var cacheOrder: [String] = []
  private let downloader: ImageDownloader

  init(avatarDiameter: CGFloat) {
    self.avatarDiameter = avatarDiameter
    thumbnailMaxPixel = max(Int(avatarDiameter * 3), 132)
    let downloader = ImageDownloader(name: "notification-avatar")
    downloader.downloadTimeout = timeoutSeconds
    self.downloader = downloader
  }

  func attachmentURL(for userInfo: UserInfo?) async -> URL? {
    guard let source = await loadAvatarSource(for: userInfo) else {
      return nil
    }

    if let cached = cachedAttachments[source.cacheKey] {
      if FileManager.default.fileExists(atPath: cached.path) {
        return cached
      }
      removeCachedAttachment(forKey: source.cacheKey)
    }

    guard let outputURL = makeCircularAvatarImage(from: source.image) else {
      log.error("Failed to create circular avatar image")
      return nil
    }

    cacheAttachment(outputURL, forKey: source.cacheKey)
    return outputURL
  }

  private func loadAvatarSource(for userInfo: UserInfo?) async -> AvatarSource? {
    guard let userInfo else {
      return nil
    }

    if let localURL = userInfo.profilePhoto?.first?.getLocalURL(),
       FileManager.default.fileExists(atPath: localURL.path),
       let image = await retrieveImage(from: .provider(LocalFileImageDataProvider(fileURL: localURL)))
    {
      return AvatarSource(cacheKey: cacheKey(for: localURL), image: image)
    }

    if let localURL = userInfo.user.getLocalURL(),
       FileManager.default.fileExists(atPath: localURL.path),
       let image = await retrieveImage(from: .provider(LocalFileImageDataProvider(fileURL: localURL)))
    {
      return AvatarSource(cacheKey: cacheKey(for: localURL), image: image)
    }

    if let remoteURL = userInfo.profilePhoto?.first?.getRemoteURL() ?? userInfo.user.getRemoteURL() {
      if let image = await retrieveImage(from: .network(remoteURL)) {
        return AvatarSource(cacheKey: remoteURL.absoluteString, image: image)
      }
    }

    return nil
  }

  private func cacheKey(for localURL: URL) -> String {
    if let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
       let modifiedAt = attributes[.modificationDate] as? Date
    {
      return "\(localURL.path)-\(modifiedAt.timeIntervalSince1970)"
    }

    return localURL.path
  }

  private func retrieveImage(from source: Source) async -> CGImage? {
    let options: KingfisherOptionsInfo = [
      .callbackQueue(.dispatch(DispatchQueue.global(qos: .utility))),
      .processor(DownsamplingImageProcessor(size: CGSize(
        width: CGFloat(thumbnailMaxPixel),
        height: CGFloat(thumbnailMaxPixel)
      ))),
      .downloader(downloader),
      .cacheMemoryOnly,
      .scaleFactor(1),
    ]

    let logger = log

    return await withCheckedContinuation { continuation in
      _ = KingfisherManager.shared.retrieveImage(
        with: source,
        options: options
      ) { result in
        switch result {
        case let .success(value):
          DispatchQueue.main.async {
            var rect = CGRect(origin: .zero, size: value.image.size)
            let cgImage = value.image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            continuation.resume(returning: cgImage)
          }
        case let .failure(error):
          logger.error("Failed to download avatar image", error: error)
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private func makeCircularAvatarImage(from image: CGImage) -> URL? {
    let size = CGSize(width: avatarDiameter, height: avatarDiameter)
    let width = Int(size.width)
    let height = Int(size.height)

    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      log.error("Failed to create bitmap context for avatar")
      return nil
    }

    context.interpolationQuality = .high
    context.addEllipse(in: CGRect(origin: .zero, size: size))
    context.clip()

    let drawRect = aspectFillRect(
      for: CGSize(width: image.width, height: image.height),
      in: CGRect(origin: .zero, size: size)
    )
    context.draw(image, in: drawRect)

    guard let outputImage = context.makeImage() else {
      log.error("Failed to render avatar image")
      return nil
    }

    let fileName = "notification-avatar-\(UUID().uuidString).png"
    let fileURL = FileHelpers.getTrueTemporaryDirectory().appendingPathComponent(fileName)
    guard let destination = CGImageDestinationCreateWithURL(
      fileURL as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      log.error("Failed to create image destination for avatar")
      return nil
    }

    CGImageDestinationAddImage(destination, outputImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      log.error("Failed to write avatar image to disk")
      return nil
    }

    return fileURL
  }

  private func aspectFillRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return bounds
    }

    let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let origin = CGPoint(
      x: bounds.midX - scaledSize.width / 2,
      y: bounds.midY - scaledSize.height / 2
    )
    return CGRect(origin: origin, size: scaledSize)
  }

  private func cacheAttachment(_ url: URL, forKey key: String) {
    if cachedAttachments[key] != nil {
      removeCacheOrderEntry(forKey: key)
    }

    cachedAttachments[key] = url
    cacheOrder.append(key)

    while cacheOrder.count > cacheLimit {
      let evictedKey = cacheOrder.removeFirst()
      if let evictedURL = cachedAttachments.removeValue(forKey: evictedKey) {
        try? FileManager.default.removeItem(at: evictedURL)
      }
    }
  }

  private func removeCachedAttachment(forKey key: String) {
    if let url = cachedAttachments.removeValue(forKey: key) {
      try? FileManager.default.removeItem(at: url)
    }
    removeCacheOrderEntry(forKey: key)
  }

  private func removeCacheOrderEntry(forKey key: String) {
    if let index = cacheOrder.firstIndex(of: key) {
      cacheOrder.remove(at: index)
    }
  }

}

private struct AvatarSource {
  let cacheKey: String
  let image: CGImage
}
#endif
