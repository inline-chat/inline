#if os(macOS)
import AppKit
import Auth
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import InlineAvatarCore
import InlineProtocol
import Logger
import UniformTypeIdentifiers
import UserNotifications

#if DEBUG || DEBUG_BUILD
public enum MacNotificationPlaygroundAvatarMode: String, CaseIterable, Sendable, Hashable {
  case photo
  case initials
  case none
}

public enum MacNotificationPlaygroundScenario: String, CaseIterable, Sendable, Hashable {
  case customText
  case multilineText
  case photo
  case photoWithCaption
  case video
  case gif
  case document
  case voice
  case sticker
  case nudge
  case urgentNudge
  case messageFailed
}

struct MacNotificationPlaygroundPresentation: Equatable, Sendable {
  let titleOverride: String?
  let body: String
  let forceSound: Bool
  let includesSenderArtwork: Bool
}
#endif

struct MacIncomingNotificationContext: Sendable {
  let dialog: Dialog
  let notificationSelection: DialogNotificationSettingSelection
  let directReplySenderID: Int64?
  let replyThreadAnchorSenderID: Int64?

  static func fetch(
    _ db: Database,
    peerID: Peer,
    chatID: Int64,
    replyToMessageID: Int64?
  ) throws -> Self? {
    let rows = try Row.fetchAll(
      db,
      sql: """
      WITH RECURSIVE ancestry(id, parentChatId, peerUserId, depth, path) AS (
        SELECT id, parentChatId, peerUserId, 0, printf('/%lld/', id) FROM chat WHERE id = ?
        UNION ALL
        SELECT parent.id, parent.parentChatId, parent.peerUserId, ancestry.depth + 1,
               ancestry.path || printf('%lld/', parent.id)
        FROM chat AS parent JOIN ancestry ON parent.id = ancestry.parentChatId
        WHERE instr(ancestry.path, printf('/%lld/', parent.id)) = 0
      )
      SELECT dialog.*,
             preference.notificationSettings AS inheritedNotificationSettings,
             directReply.fromId AS directReplySenderID,
             replyThreadAnchor.fromId AS replyThreadAnchorSenderID
      FROM dialog
      LEFT JOIN ancestry ON 1 = 1
      -- Match Dialog.getDialogId using the primary key, without scanning all dialogs.
      LEFT JOIN dialog AS preference
        ON preference.id = COALESCE(ancestry.peerUserId,
          CASE WHEN ancestry.id < 500 THEN ancestry.id ELSE -ancestry.id END)
       AND preference.chatId = ancestry.id
      LEFT JOIN chat AS notificationChat
        ON notificationChat.id = ?
      LEFT JOIN message AS directReply
        ON directReply.chatId = ? AND directReply.messageId = ?
      LEFT JOIN message AS replyThreadAnchor
        ON replyThreadAnchor.chatId = notificationChat.parentChatId
       AND replyThreadAnchor.messageId = notificationChat.parentMessageId
      WHERE dialog.id = ?
        AND \(Dialog.catalogActiveSQL)
      ORDER BY ancestry.depth
      """,
      arguments: [
        chatID,
        chatID,
        chatID,
        replyToMessageID,
        Dialog.getDialogId(peerId: peerID),
      ]
    )
    guard let row = rows.first else { return nil }
    let dialog = try Dialog(row: row)

    let notificationSelection = rows.lazy.compactMap { row -> DialogNotificationSettingSelection? in
      let data: Data? = row["inheritedNotificationSettings"]
      guard let data,
            let settings = try? InlineProtocol.DialogNotificationSettings(serializedBytes: data)
      else { return nil }
      switch settings.mode {
      case .all: return .all
      case .mentions: return .mentions
      case .none: return DialogNotificationSettingSelection.none
      case .unspecified, .UNRECOGNIZED: return nil
      }
    }.first ?? dialog.notificationSelection

    return Self(
      dialog: dialog,
      notificationSelection: notificationSelection,
      directReplySenderID: row["directReplySenderID"],
      replyThreadAnchorSenderID: row["replyThreadAnchorSenderID"]
    )
  }

  func isUnread(messageID: Int64) -> Bool {
    let readMaxID = dialog.readInboxMaxId ?? 0
    let collapsedMaxID = dialog.collapsedMaxId ?? 0
    return messageID > readMaxID && messageID > collapsedMaxID
  }

  func isPersonallyAddressed(
    message: InlineProtocol.Message,
    currentUserID: Int64
  ) -> Bool {
    message.mentioned
      || directReplySenderID == currentUserID
      || replyThreadAnchorSenderID == currentUserID
  }
}

public actor MacNotifications {
  public static let shared = MacNotifications()

  private static let urgentNudgeText = "\u{1F6A8}"
  static let maximumMessageAge: TimeInterval = 2 * 60
  static let attachmentPreparationTimeout: Duration = .milliseconds(500)

  enum MessageUpdateSource: Equatable, Sendable {
    case newMessage
    case explicitNotification
  }

  struct MessageDeliveryState: Equatable, Sendable {
    let isNewlyInserted: Bool
    let isUnread: Bool
    let isPersonallyAddressed: Bool
  }

  private var soundEnabled = true
  private let log = Log.scoped("MacNotifications")
  private let avatarBuilder = AvatarAttachmentBuilder(avatarDiameter: 44)

  public func setSoundEnabled(_ enabled: Bool) {
    soundEnabled = enabled
  }

  private func isSoundEnabled() -> Bool {
    soundEnabled
  }

  @discardableResult
  nonisolated func showMessageNotification(
    title: String,
    subtitle: String? = nil,
    body: String,
    userInfo: [AnyHashable: Any],
    imageURL: URL? = nil,
    forceSound: Bool = false,
    soundOverride: Bool? = nil,
    requestIdentifier: String? = nil,
    threadIdentifier: String? = nil,
    expectedAccount: AuthAccountMutationToken? = nil
  ) async -> Bool {
    guard Self.canPostSystemNotifications(bundleURL: Bundle.main.bundleURL) else { return false }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let subtitle {
      content.subtitle = subtitle
    }
    content.userInfo = userInfo
    if let threadIdentifier {
      content.threadIdentifier = threadIdentifier
    }
    let isSoundEnabled = await isSoundEnabled()
    content.sound = (soundOverride ?? (forceSound || isSoundEnabled)) ? .default : nil
    if forceSound {
      content.interruptionLevel = .timeSensitive
    }

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
      identifier: requestIdentifier ?? UUID().uuidString,
      content: content,
      trigger: nil
    )

    do {
      let center = UNUserNotificationCenter.current()
      if let expectedAccount, !MessageNotificationAccount.isCurrent(expectedAccount) { return false }
      try await center.add(request)
      return true
    } catch {
      log.error("Failed to show notification", error: error)
      return false
    }
  }

  static func canPostSystemNotifications(bundleURL: URL) -> Bool {
    bundleURL.pathExtension == "app"
  }

  nonisolated static func shouldScheduleMessageNotification(
    for message: InlineProtocol.Message,
    effectiveMode: NotificationMode,
    source: MessageUpdateSource,
    deliveryState: MessageDeliveryState,
    now: Date
  ) -> Bool {
    guard source == .newMessage else { return false }
    guard deliveryState.isNewlyInserted, deliveryState.isUnread else { return false }
    guard message.sendMode != .modeSilent else { return false }
    guard isFreshMessage(message, now: now) else { return false }

    if isUrgentNudge(message) {
      return true
    }

    let isNudge: Bool = if case .nudge = message.media.media { true } else { false }
    let isDirectMessage = message.peerID.toPeer().isPrivate
    let isAddressedToCurrentUser = message.mentioned || deliveryState.isPersonallyAddressed

    switch effectiveMode {
    case .all:
      return true
    case .none:
      return false
    case .mentions, .importantOnly:
      return isDirectMessage || isAddressedToCurrentUser || isNudge
    case .onlyMentions:
      return isAddressedToCurrentUser || isNudge
    }
  }

  nonisolated static func isFreshMessage(
    _ message: InlineProtocol.Message,
    now: Date
  ) -> Bool {
    guard message.date > 0 else { return false }
    let messageDate = Date(timeIntervalSince1970: TimeInterval(message.date))
    return now.timeIntervalSince(messageDate) <= maximumMessageAge
  }

  nonisolated static func bestEffortAttachment(
    timeout: Duration = attachmentPreparationTimeout,
    operation: @escaping @Sendable () async -> URL?
  ) async -> URL? {
    await withTaskGroup(of: URL?.self, returning: URL?.self) { group in
      group.addTask {
        await operation()
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }

      let attachment = await group.next() ?? nil
      group.cancelAll()
      return attachment
    }
  }

  nonisolated static func messageNotificationIdentifier(
    chatID: Int64,
    messageID: Int64
  ) -> String {
    "chat_\(chatID)_message_\(messageID)"
  }

  nonisolated static func notificationThreadIdentifier(chatID: Int64) -> String {
    "chat_\(chatID)"
  }

  nonisolated static func isUrgentNudge(_ message: InlineProtocol.Message) -> Bool {
    guard case .nudge = message.media.media else { return false }
    guard message.hasMessage else { return false }
    return message.message.trimmingCharacters(in: .whitespacesAndNewlines) == urgentNudgeText
  }
}

#if DEBUG || DEBUG_BUILD
extension MacNotifications {
  @discardableResult
  public func showPlaygroundNotification(
    scenario: MacNotificationPlaygroundScenario,
    avatarMode: MacNotificationPlaygroundAvatarMode,
    senderName: String,
    customBody: String,
    isThread: Bool,
    soundEnabled: Bool
  ) async -> Bool {
    let presentation = Self.playgroundPresentation(
      scenario: scenario,
      customBody: customBody,
      chatName: "Design"
    )
    let projectedSenderName = MessageNotificationPreview.singleLine(senderName)
    let displaySenderName = projectedSenderName.isEmpty ? "Ava Lin" : projectedSenderName
    let imageURL: URL? = if presentation.includesSenderArtwork {
      await avatarBuilder.playgroundAttachmentURL(
        mode: avatarMode,
        senderName: displaySenderName
      )
    } else {
      nil
    }
    let playsSound = soundEnabled || presentation.forceSound
    return await showMessageNotification(
      title: presentation.titleOverride ?? (isThread ? "Design" : displaySenderName),
      subtitle: presentation.titleOverride == nil && isThread ? displaySenderName : nil,
      body: presentation.body,
      userInfo: [
        "playgroundNotification": true,
        "playgroundAvatarMode": avatarMode.rawValue,
        "playgroundScenario": scenario.rawValue,
        "playgroundSoundEnabled": playsSound,
        "playgroundIncludesSenderArtwork": presentation.includesSenderArtwork,
        "isThread": isThread,
      ],
      imageURL: imageURL,
      forceSound: presentation.forceSound,
      soundOverride: playsSound
    )
  }

  nonisolated static func playgroundPresentation(
    scenario: MacNotificationPlaygroundScenario,
    customBody: String,
    chatName: String
  ) -> MacNotificationPlaygroundPresentation {
    if scenario == .messageFailed {
      let projectedChatName = MessageNotificationPreview.singleLine(chatName)
      return .init(
        titleOverride: "Message failed to send",
        body: "A message could not be sent in \(projectedChatName.isEmpty ? "Chat" : projectedChatName).",
        forceSound: false,
        includesSenderArtwork: false
      )
    }

    var message = InlineProtocol.Message()
    switch scenario {
    case .customText:
      message.message = customBody
    case .multilineText:
      message.message = "First line\nSecond line\n\nA new paragraph"
    case .photo:
      message.media.photo.photo.id = 1
    case .photoWithCaption:
      message.media.photo.photo.id = 1
      message.message = "Sprint whiteboard\nFinal layout"
    case .video:
      message.media.video.video.id = 1
    case .gif:
      message.media.video.video.id = 1
      message.media.video.video.isAnimated = true
    case .document:
      message.media.document.document.fileName = "Quarterly Report.pdf"
    case .voice:
      message.media.voice.voice.duration = 65
    case .sticker:
      message.media.photo.photo.id = 1
      message.isSticker = true
    case .nudge:
      message.media.nudge = .init()
    case .urgentNudge:
      message.media.nudge = .init()
      message.message = urgentNudgeText
    case .messageFailed:
      break
    }

    return .init(
      titleOverride: nil,
      body: MessageNotificationPreview.body(for: message),
      forceSound: scenario == .urgentNudge,
      includesSenderArtwork: true
    )
  }
}
#endif

extension MacNotifications {
  @discardableResult
  public func showGridScreenShareNotification(
    displayName: String,
    started: Bool,
    spaceID: Int64,
    roomID: Int64,
    userID: Int64,
    participantIdentity: String
  ) async -> Bool {
    let title = started
      ? String(
        localized: "\(displayName) started sharing their screen",
        comment: "Local notification title when the named Grid participant starts screen sharing."
      )
      : String(
        localized: "\(displayName) stopped sharing their screen",
        comment: "Local notification title when the named Grid participant stops screen sharing."
      )
    let body = started
      ? String(
        localized: "Click to view the shared screen.",
        comment: "Local notification body for a newly started Grid screen share."
      )
      : String(
        localized: "The shared screen is no longer available.",
        comment: "Local notification body when a Grid screen share ends."
      )
    return await showMessageNotification(
      title: title,
      body: body,
      userInfo: [
        "type": "gridScreenShare",
        "event": started ? "started" : "stopped",
        "spaceId": String(spaceID),
        "roomId": String(roomID),
        "userId": String(userID),
        "participantIdentity": participantIdentity,
      ],
      soundOverride: false,
      requestIdentifier: Self.gridScreenShareNotificationIdentifier(
        spaceID: spaceID,
        participantIdentity: participantIdentity
      ),
      threadIdentifier: "grid_\(spaceID)_room_\(roomID)"
    )
  }

  nonisolated static func gridScreenShareNotificationIdentifier(
    spaceID: Int64,
    participantIdentity: String
  ) -> String {
    "grid_\(spaceID)_screen_share_\(participantIdentity)"
  }

  public func showMessageFailedNotification(
    chatId: Int64,
    peerId: Peer
  ) async {
    let chat = await ObjectCache.shared.getChat(id: chatId)
    let projectedChatName = MessageNotificationPreview.singleLine(chat?.title ?? "Chat")
    let chatName = projectedChatName.isEmpty ? "Chat" : projectedChatName

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
    guard let account = try? Auth.shared.handle.beginAccountMutation() else { return }

    let user = await ObjectCache.shared.getUser(id: protocolMsg.fromID)
    let chat = await ObjectCache.shared.getChat(id: protocolMsg.chatID)
    let space: Space? = if let spaceId = chat?.spaceId {
      await ObjectCache.shared.getSpace(id: spaceId)
    } else {
      nil
    }

    let projectedSenderName = MessageNotificationPreview.singleLine(user?.user.displayName ?? "Unknown")
    let senderName = projectedSenderName.isEmpty ? "Unknown" : projectedSenderName
    let projectedChatName = MessageNotificationPreview.singleLine(chat?.title ?? "New Message")
    let chatName = projectedChatName.isEmpty ? "New Message" : projectedChatName
    let isThread = protocolMsg.peerID.toPeer().isThread

    // Prepare notification content
    let title: String
    let subtitle: String?
    let body: String

    if isThread {
      title = MessageNotificationPreview.singleLine(
        space.map { "\(chatName) (\($0.name))" } ?? chatName
      )
      subtitle = senderName
      body = MessageNotificationPreview.body(for: protocolMsg)
    } else {
      title = senderName
      subtitle = nil
      body = MessageNotificationPreview.body(for: protocolMsg)
    }

    let imageURL = if isThread {
      ThreadIconNotificationAttachmentRenderer.attachmentURL(for: chat)
    } else {
      await Self.bestEffortAttachment {
        await self.avatarBuilder.attachmentURL(for: user, fallbackUserID: protocolMsg.fromID)
      }
    }
    let isUrgentNudge = Self.isUrgentNudge(protocolMsg)
    var notificationUserInfo: [AnyHashable: Any] = [
      "userId": protocolMsg.fromID,
      "isThread": isThread,
      "messageId": String(protocolMsg.id),
      "chatId": String(protocolMsg.chatID),
      "recipientUserId": String(account.userID),
    ]
    if isThread {
      notificationUserInfo["threadId"] = protocolMsg.chatID
      notificationUserInfo["isReplyThread"] = chat?.isReplyThread == true
      if let emoji = chat?.emoji {
        notificationUserInfo["threadEmoji"] = emoji
      }
    }

    await showMessageNotification(
      title: title,
      subtitle: subtitle,
      body: body,
      userInfo: notificationUserInfo,
      imageURL: imageURL,
      forceSound: isUrgentNudge,
      requestIdentifier: Self.messageNotificationIdentifier(
        chatID: protocolMsg.chatID,
        messageID: protocolMsg.id
      ),
      threadIdentifier: Self.notificationThreadIdentifier(chatID: protocolMsg.chatID),
      expectedAccount: account
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

  func attachmentURL(for userInfo: UserInfo?, fallbackUserID: Int64) async -> URL? {
    guard !Task.isCancelled else { return nil }
    guard let userInfo else { return nil }

    let source: AvatarSource
    if let loadedSource = await loadAvatarSource(for: userInfo) {
      source = loadedSource
    } else if MacNotificationAvatarPolicy.shouldGenerateInitials(for: userInfo),
              let fallbackSource = makeFallbackAvatarSource(
                for: userInfo,
                fallbackUserID: fallbackUserID
              ) {
      source = fallbackSource
    } else {
      return nil
    }

    guard !Task.isCancelled else { return nil }
    return attachmentURL(for: source)
  }

  private func attachmentURL(for source: AvatarSource) -> URL? {
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

#if DEBUG || DEBUG_BUILD
  func playgroundAttachmentURL(
    mode: MacNotificationPlaygroundAvatarMode,
    senderName: String
  ) -> URL? {
    let source: AvatarSource?
    switch mode {
    case .photo:
      source = makePlaygroundPhotoSource()
    case .initials:
      source = makeFallbackAvatarSource(
        for: UserInfo(
          user: User(id: -100, email: nil, firstName: senderName),
          profilePhotos: nil
        ),
        fallbackUserID: -100
      )
    case .none:
      source = nil
    }

    return source.flatMap { attachmentURL(for: $0) }
  }

  private func makePlaygroundPhotoSource() -> AvatarSource? {
    let pixelSize = max(thumbnailMaxPixel, 132)
    guard let context = CGContext(
      data: nil,
      width: pixelSize,
      height: pixelSize,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }

    let size = CGFloat(pixelSize)
    context.setFillColor(NSColor.systemTeal.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.08, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: size * 0.24, y: size * 0.38, width: size * 0.52, height: size * 0.52))
    context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.56, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: size * 0.30, y: size * 0.34, width: size * 0.40, height: size * 0.46))
    context.setFillColor(NSColor.systemIndigo.cgColor)
    context.fillEllipse(in: CGRect(x: size * 0.16, y: -size * 0.20, width: size * 0.68, height: size * 0.62))

    guard let image = context.makeImage() else { return nil }
    return AvatarSource(cacheKey: "playground-photo-v1", image: image)
  }
#endif

  private func loadAvatarSource(for userInfo: UserInfo) async -> AvatarSource? {
    guard !Task.isCancelled else { return nil }

    if let localURL = userInfo.user.getLocalURL(),
       FileManager.default.fileExists(atPath: localURL.path),
       let image = await retrieveImage(from: .local(localURL)) {
      return AvatarSource(cacheKey: cacheKey(for: localURL), image: image)
    }

    guard !Task.isCancelled else { return nil }
    if let remoteURL = userInfo.user.getRemoteURL() {
      if let image = await retrieveImage(from: .remote(remoteURL)) {
        return AvatarSource(cacheKey: remoteURL.absoluteString, image: image)
      }
    }

    return nil
  }

  private func makeFallbackAvatarSource(
    for userInfo: UserInfo,
    fallbackUserID: Int64
  ) -> AvatarSource? {
    let user = userInfo.user
    let identity = InlineAvatarUserIdentity(
      firstName: user.firstName,
      lastName: user.lastName,
      displayName: nil,
      email: user.email,
      username: user.username,
      stableIdentifier: "user:\(user.id == 0 ? fallbackUserID : user.id)"
    )
    let presentation = InlineAvatarPresentation.user(identity: identity)
    let size = CGSize(width: avatarDiameter, height: avatarDiameter)
    guard let image = MacNotificationAvatarRenderer.makeImage(
      presentation: presentation,
      size: size
    ) else {
      log.error("Failed to render initials notification avatar")
      return nil
    }

    return AvatarSource(
      cacheKey: "fallback-v1:\(identity.stableIdentifier):\(presentation.seed)",
      image: image
    )
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

        guard !Task.isCancelled else { return nil }
        return downsampleImage(from: data)
      } catch is CancellationError {
        return nil
      } catch let error as URLError where error.code == .cancelled {
        return nil
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

enum MacNotificationAvatarPolicy {
  static func shouldGenerateInitials(for userInfo: UserInfo?) -> Bool {
    guard let userInfo else { return false }
    return !hasConfiguredProfilePhoto(userInfo)
  }

  private static func hasConfiguredProfilePhoto(_ userInfo: UserInfo) -> Bool {
    let user = userInfo.user
    return [
      user.profileFileId,
      user.profileCdnUrl,
      user.profileLocalPath,
      user.profileFileUniqueId,
    ].contains { value in
      guard let value else { return false }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}

enum MacNotificationAvatarRenderer {
  static func makeImage(
    presentation: InlineUserAvatarPresentation,
    size: CGSize
  ) -> CGImage? {
    let width = max(Int(size.width.rounded(.up)), 1)
    let height = max(Int(size.height.rounded(.up)), 1)
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
    drawBackground(style: presentation.style, in: bounds, context: graphicsContext.cgContext)

    if let initials = presentation.initials {
      drawText(
        initials,
        font: .systemFont(ofSize: min(size.width, size.height) * 0.55, weight: .regular),
        color: platformColor(presentation.style.foregroundColor),
        in: bounds
      )
    } else {
      drawSymbol(
        "person.fill",
        pointSize: min(size.width, size.height) * 0.46,
        color: platformColor(presentation.style.foregroundColor),
        in: bounds
      )
    }

    NSGraphicsContext.restoreGraphicsState()
    return representation.cgImage
  }

  private static func drawBackground(
    style: InlineAvatarStyle,
    in bounds: CGRect,
    context: CGContext
  ) {
    let stops = style.gradientStops
    let colors = stops.map { platformColor($0.color).cgColor } as CFArray
    let locations = stops.map { CGFloat($0.location) }

    context.saveGState()
    context.addEllipse(in: bounds)
    context.clip()
    if let gradient = CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
      colors: colors,
      locations: locations
    ) {
      context.drawLinearGradient(
        gradient,
        start: CGPoint(x: bounds.midX, y: bounds.maxY),
        end: CGPoint(x: bounds.midX, y: bounds.minY),
        options: []
      )
    } else {
      let fallbackColor = stops.last?.color ?? style.baseColor
      context.setFillColor(platformColor(fallbackColor).cgColor)
      context.fill(bounds)
    }
    context.restoreGState()

    context.saveGState()
    context.addEllipse(in: bounds.insetBy(dx: 0.25, dy: 0.25))
    context.setStrokeColor(platformColor(style.borderColor).cgColor)
    context.setLineWidth(CGFloat(style.borderWidth))
    context.strokePath()
    context.restoreGState()
  }

  private static func drawText(
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
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    let measured = attributedString.boundingRect(
      with: bounds.size,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    attributedString.draw(in: CGRect(
      x: bounds.midX - measured.width / 2,
      y: bounds.midY - measured.height / 2,
      width: measured.width,
      height: measured.height
    ))
  }

  private static func drawSymbol(
    _ symbolName: String,
    pointSize: CGFloat,
    color: NSColor,
    in bounds: CGRect
  ) {
    guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
      return
    }
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    let configuredImage = image.withSymbolConfiguration(configuration) ?? image
    let drawRect = aspectFitRect(
      for: configuredImage.size,
      in: bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2)
    )

    let tintedImage = NSImage(size: configuredImage.size)
    tintedImage.lockFocus()
    configuredImage.draw(
      in: CGRect(origin: .zero, size: configuredImage.size),
      from: .zero,
      operation: .sourceOver,
      fraction: 1
    )
    color.setFill()
    CGRect(origin: .zero, size: configuredImage.size).fill(using: .sourceIn)
    tintedImage.unlockFocus()
    tintedImage.draw(in: drawRect)
  }

  private static func platformColor(_ color: InlineAvatarColor) -> NSColor {
    NSColor(
      srgbRed: CGFloat(color.red),
      green: CGFloat(color.green),
      blue: CGFloat(color.blue),
      alpha: CGFloat(color.alpha)
    )
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

private struct AvatarSource {
  let cacheKey: String
  let image: CGImage
}

private enum AvatarImageSource {
  case local(URL)
  case remote(URL)
}
#endif
