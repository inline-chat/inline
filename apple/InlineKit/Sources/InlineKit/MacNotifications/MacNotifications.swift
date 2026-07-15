#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import InlineProtocol
import Logger
import UniformTypeIdentifiers
import UserNotifications

public actor MacNotifications {
  public static let shared = MacNotifications()

  private static let urgentNudgeText = "\u{1F6A8}"

  private var soundEnabled = true
  private let log = Log.scoped("MacNotifications")
  private let avatarBuilder = AvatarAttachmentBuilder(avatarDiameter: 44)

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
    guard Self.canPostSystemNotifications(bundleURL: Bundle.main.bundleURL) else { return }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let subtitle {
      content.subtitle = subtitle
    }
    content.userInfo = userInfo
    let isSoundEnabled = await isSoundEnabled()
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

  static func canPostSystemNotifications(bundleURL: URL) -> Bool {
    bundleURL.pathExtension == "app"
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

    let imageURL = if chat?.type == .thread {
      ThreadIconNotificationAttachmentRenderer.attachmentURL(for: chat)
    } else {
      await avatarBuilder.attachmentURL(for: user)
    }
    let trimmedText = protocolMsg.hasMessage ? protocolMsg.message.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    let isUrgentNudge = {
      guard case .nudge = protocolMsg.media.media else { return false }
      return trimmedText == Self.urgentNudgeText
    }()
    var notificationUserInfo: [AnyHashable: Any] = [
      "userId": protocolMsg.fromID,
      "isThread": chat?.type == .thread,
    ]
    if let chat, chat.type == .thread {
      notificationUserInfo["threadId"] = chat.id
      notificationUserInfo["isReplyThread"] = chat.isReplyThread
      if let emoji = chat.emoji {
        notificationUserInfo["threadEmoji"] = emoji
      }
    }

    await showMessageNotification(
      title: title,
      subtitle: subtitle,
      body: body,
      userInfo: notificationUserInfo,
      imageURL: imageURL,
      forceSound: isUrgentNudge
    )
  }
}

// MARK: - Thread icon attachments

private enum ThreadIconNotificationAttachmentRenderer {
  private static let iconDiameter: CGFloat = 60
  private static let log = Log.scoped("NotificationThreadIcon")

  static func attachmentURL(for chat: Chat?) -> URL? {
    guard let data = NotificationThreadIconRenderer.makePNGData(
      emoji: chat?.emoji,
      title: chat?.title ?? "Thread",
      isReplyThread: chat?.isReplyThread == true,
      size: CGSize(width: iconDiameter, height: iconDiameter)
    ) else {
      log.error("Failed to render thread notification icon")
      return nil
    }

    let fileName = "notification-thread-icon-\(UUID().uuidString).png"
    let fileURL = FileHelpers.getTrueTemporaryDirectory().appendingPathComponent(fileName)
    do {
      try data.write(to: fileURL, options: .atomic)
      return fileURL
    } catch {
      log.error("Failed to write thread notification icon", error: error)
      return nil
    }
  }
}

// Keep this mirror in sync with InlineUI/Sources/InlineUI/ThreadIconView.swift.
// InlineKit cannot import InlineUI because InlineUI depends on InlineKit.
private enum NotificationThreadIconRenderer {
  private static let normalFallbackSymbol = "bubble.middle.bottom.fill"
  private static let replyFallbackSymbol = "arrow.turn.down.right"

  static func makePNGData(
    emoji: String?,
    title _: String,
    isReplyThread: Bool,
    size: CGSize
  ) -> Data? {
    let width = Int(size.width.rounded(.up))
    let height = Int(size.height.rounded(.up))
    guard let representation = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      return nil
    }
    representation.size = size

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
      return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.imageInterpolation = .high

    let bounds = CGRect(origin: .zero, size: size)
    drawBackground(in: bounds)
    let iconSize = min(size.width, size.height)
    let ratios = contentRatios(for: iconSize)

    if let emoji = normalizedEmoji(emoji) {
      drawCenteredText(
        emoji,
        font: .systemFont(ofSize: iconSize * ratios.emoji, weight: .regular),
        color: symbolColor(),
        in: bounds
      )
    } else {
      drawCenteredSymbol(
        isReplyThread ? replyFallbackSymbol : normalFallbackSymbol,
        pointSize: iconSize * ratios.symbol,
        color: symbolColor(),
        in: bounds
      )
    }

    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])
  }

  private static func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji else { return nil }
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstCharacter = trimmed.first else { return nil }
    return String(firstCharacter)
  }

  private static func drawBackground(in bounds: CGRect) {
    NSGraphicsContext.current?.cgContext.clear(bounds)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: bounds).addClip()

    if let gradient = NSGradient(colors: [
      NSColor(calibratedWhite: 0.50, alpha: 0.96),
      NSColor(calibratedWhite: 0.36, alpha: 0.96),
    ]) {
      gradient.draw(in: bounds, angle: -90)
    } else {
      NSColor(calibratedWhite: 0.43, alpha: 0.96).setFill()
      NSBezierPath(rect: bounds).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
  }

  private static func symbolColor() -> NSColor {
    NSColor(calibratedWhite: 1, alpha: 0.94)
  }

  private static func contentRatios(for size: CGFloat) -> (emoji: CGFloat, symbol: CGFloat) {
    switch size {
    case ..<25:
      return (0.66, 0.52)
    case ..<37:
      return (0.56, 0.44)
    case ..<71:
      return (0.46, 0.38)
    default:
      return (0.38, 0.32)
    }
  }

  private static func drawCenteredText(
    _ text: String,
    font: NSFont,
    color: NSColor,
    in bounds: CGRect
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ]
    let attr = NSAttributedString(string: text, attributes: attributes)
    let measured = attr.boundingRect(
      with: bounds.size,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    let drawRect = CGRect(
      x: bounds.midX - measured.width / 2,
      y: bounds.midY - measured.height / 2,
      width: measured.width,
      height: measured.height
    )
    attr.draw(in: drawRect)
  }

  private static func drawCenteredSymbol(
    _ symbolName: String,
    pointSize: CGFloat,
    color: NSColor,
    in bounds: CGRect
  ) {
    guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
      return
    }
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
    let configuredImage = image.withSymbolConfiguration(configuration) ?? image
    let drawRect = aspectFitRect(
      for: configuredImage.size,
      in: bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2)
    )
    tintedImage(configuredImage, color: color).draw(in: drawRect)
  }

  private static func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
    let tinted = NSImage(size: image.size)
    tinted.lockFocus()
    image.draw(
      in: CGRect(origin: .zero, size: image.size),
      from: .zero,
      operation: .sourceOver,
      fraction: 1
    )
    color.setFill()
    CGRect(origin: .zero, size: image.size).fill(using: .sourceIn)
    tinted.unlockFocus()
    return tinted
  }

  private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return bounds
    }

    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
      x: bounds.midX - scaledSize.width / 2,
      y: bounds.midY - scaledSize.height / 2,
      width: scaledSize.width,
      height: scaledSize.height
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

  init(avatarDiameter: CGFloat) {
    self.avatarDiameter = avatarDiameter
    thumbnailMaxPixel = max(Int(avatarDiameter * 3), 132)
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
       let image = await retrieveImage(from: .local(localURL)) {
      return AvatarSource(cacheKey: cacheKey(for: localURL), image: image)
    }

    if let localURL = userInfo.user.getLocalURL(),
       FileManager.default.fileExists(atPath: localURL.path),
       let image = await retrieveImage(from: .local(localURL)) {
      return AvatarSource(cacheKey: cacheKey(for: localURL), image: image)
    }

    if let remoteURL = userInfo.profilePhoto?.first?.getRemoteURL() ?? userInfo.user.getRemoteURL() {
      if let image = await retrieveImage(from: .remote(remoteURL)) {
        return AvatarSource(cacheKey: remoteURL.absoluteString, image: image)
      }
    }

    return nil
  }

  private func cacheKey(for localURL: URL) -> String {
    if let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
       let modifiedAt = attributes[.modificationDate] as? Date {
      return "\(localURL.path)-\(modifiedAt.timeIntervalSince1970)"
    }

    return localURL.path
  }

  private func retrieveImage(from source: AvatarImageSource) async -> CGImage? {
    switch source {
    case .local(let url):
      return downsampleImage(from: url)

    case .remote(let url):
      do {
        let request = URLRequest(
          url: url,
          cachePolicy: .reloadIgnoringLocalCacheData,
          timeoutInterval: timeoutSeconds
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200 ..< 400).contains(httpResponse.statusCode) {
          log.warning("Failed to download avatar image status=\(httpResponse.statusCode)")
          return nil
        }

        return downsampleImage(from: data)
      } catch {
        log.error("Failed to download avatar image", error: error)
        return nil
      }
    }
  }

  private func downsampleImage(from url: URL) -> CGImage? {
    let sourceOptions = [
      kCGImageSourceShouldCache: false,
    ] as CFDictionary

    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
      log.error("Failed to read avatar image")
      return nil
    }

    return downsampleImage(from: source)
  }

  private func downsampleImage(from data: Data) -> CGImage? {
    let sourceOptions = [
      kCGImageSourceShouldCache: false,
    ] as CFDictionary

    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
      log.error("Failed to decode avatar image")
      return nil
    }

    return downsampleImage(from: source)
  }

  private func downsampleImage(from source: CGImageSource) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel,
    ]

    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      log.error("Failed to create avatar thumbnail")
      return nil
    }

    return image
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

private enum AvatarImageSource {
  case local(URL)
  case remote(URL)
}
#endif
