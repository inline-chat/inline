import Foundation
import Intents
import OSLog
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private let logger = Logger(subsystem: "chat.inline.InlineNotificationExtension", category: "NotificationService")
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?
  private var avatarTask: URLSessionDataTask?
  private var requestIdentifier: String?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    requestIdentifier = request.identifier
    bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

    guard let bestAttemptContent else {
      contentHandler(request.content)
      return
    }

    let userInfo = bestAttemptContent.userInfo
    guard let sender = SenderPayload(userInfo: userInfo) else {
      // No sender metadata; deliver as-is to avoid breaking existing behaviour
      contentHandler(bestAttemptContent)
      return
    }

    // If we have an avatar URL, fetch it before finalising; otherwise finish immediately
    if let avatarURL = sender.profilePhotoUrl {
      logger.info("fetching avatar from \(avatarURL.absoluteString, privacy: .public)")
      avatarTask = URLSession.shared.dataTask(with: avatarURL) { [weak self] data, _, error in
        if let error {
          self?.logger.error("avatar download failed: \(error.localizedDescription, privacy: .public)")
        }
        let image: INImage? = if let data {
          INImage(imageData: data)
        } else {
          nil
        }
        self?.applyIntent(sender: sender, image: image, requestIdentifier: request.identifier)
      }
      avatarTask?.resume()
    } else {
      logger.info("no avatar URL provided")
      applyIntent(sender: sender, image: nil, requestIdentifier: request.identifier)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    avatarTask?.cancel()
    guard let contentHandler, let bestAttemptContent else { return }
    contentHandler(bestAttemptContent)
  }
}

// MARK: - Private helpers

private extension NotificationService {
  struct SenderPayload {
    let id: String
    let displayName: String?
    let profilePhotoUrl: URL?

    init?(userInfo: [AnyHashable: Any]) {
      guard let sender = userInfo["sender"] as? [String: Any] else { return nil }
      // ID is required for communication notifications
      if let idValue = sender["id"] as? Int {
        id = String(idValue)
      } else if let idValue = sender["id"] as? String {
        id = idValue
      } else {
        return nil
      }

      displayName = sender["displayName"] as? String
      if let urlString = sender["profilePhotoUrl"] as? String {
        profilePhotoUrl = URL(string: urlString)
      } else {
        profilePhotoUrl = nil
      }
    }
  }

  func applyIntent(sender: SenderPayload, image: INImage?, requestIdentifier: String) {
    guard let bestAttemptContent, let contentHandler else { return }

    logger.info("applying intent for sender \(sender.id, privacy: .public)")

    let isThread = (bestAttemptContent.userInfo["isThread"] as? Bool) == true
    let threadTitle = bestAttemptContent.title.nonEmpty ?? bestAttemptContent.subtitle.nonEmpty
    let threadEmoji = bestAttemptContent.userInfo["threadEmoji"] as? String
    let person: INPerson
    let recipients: [INPerson]?
    if let threadTitle, isThread {
      // For threads/channels: represent the chat as the sender and the user as the sole recipient.
      person = makeGroupPerson(
        threadId: conversationId(from: bestAttemptContent) ?? sender.id,
        title: threadTitle,
        image: makeGroupAvatar(emoji: threadEmoji, title: threadTitle)
      )
      recipients = [makeMePerson()]
      bestAttemptContent.title = threadTitle
      bestAttemptContent.subtitle = ""
    } else {
      person = makePerson(from: sender, image: image)
      recipients = nil // DM path: system infers current user
    }

    let conversationIdentifier = conversationId(from: bestAttemptContent) ?? sender.id
    let groupName = isThread ? threadTitle : nil
    let groupNameLog = groupName ?? "nil"
    logger
      .info(
        "notification context: isThread=\(isThread, privacy: .public) title=\(bestAttemptContent.title, privacy: .public) subtitle=\(bestAttemptContent.subtitle, privacy: .public) groupName=\(groupNameLog, privacy: .public)"
      )

    let intent = makeSendMessageIntent(
      sender: person,
      content: bestAttemptContent.body,
      conversationIdentifier: conversationIdentifier,
      groupName: groupName,
      recipients: recipients
    )

    // Donate interaction so the system can render a communication notification
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = INInteractionDirection.incoming
    Task {
      let contentToDeliver: UNNotificationContent
      do {
        try await interaction.donate()
        logger.info("interaction donation succeeded (conversation=\(conversationIdentifier, privacy: .public))")
        let updated = try bestAttemptContent.updating(from: intent)
        contentToDeliver = updated
        self.bestAttemptContent = updated as? UNMutableNotificationContent
        logger.info("notification content updated from intent")
      } catch {
        logger.error("interaction donation or content update failed: \(error.localizedDescription, privacy: .public)")
        contentToDeliver = bestAttemptContent
      }
      contentHandler(contentToDeliver)
    }
  }

  func makePerson(from sender: SenderPayload, image: INImage?) -> INPerson {
    // TODO(privacy): Enrich from a local user object (cache/DB) so we can provide
    // stronger contact hints without including email/phone in push payloads.
    // Replace this when encrypted notification content is available.
    let handle = INPersonHandle(value: sender.id, type: .unknown)

    var nameComponents = PersonNameComponents()
    if let displayName = sender.displayName {
      // Best effort split of first/last
      let parts = displayName.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      if let first = parts.first { nameComponents.givenName = String(first) }
      if parts.count > 1 { nameComponents.familyName = String(parts[1]) }
    }

    return INPerson(
      personHandle: handle,
      nameComponents: nameComponents,
      displayName: sender.displayName,
      image: image,
      contactIdentifier: sender.id,
      customIdentifier: sender.id,
      isMe: false,
      suggestionType: .none
    )
  }

  func makeSendMessageIntent(
    sender: INPerson,
    content: String,
    conversationIdentifier: String,
    groupName: String?,
    recipients: [INPerson]?
  ) -> INSendMessageIntent {
    let intent = INSendMessageIntent(
      recipients: recipients,
      outgoingMessageType: .outgoingMessageText,
      content: content,
      speakableGroupName: groupName.map { INSpeakableString(spokenPhrase: $0) },
      conversationIdentifier: conversationIdentifier,
      serviceName: "Inline",
      sender: sender,
      attachments: nil
    )
    intent.setImage(sender.image, forParameterNamed: \.sender)
    return intent
  }

  func makeGroupPerson(threadId: String, title: String, image: INImage?) -> INPerson {
    let handle = INPersonHandle(value: threadId, type: .unknown)
    var components = PersonNameComponents()
    components.nickname = title
    return INPerson(
      personHandle: handle,
      nameComponents: components,
      displayName: title,
      image: image,
      contactIdentifier: threadId,
      customIdentifier: threadId,
      isMe: false,
      suggestionType: .none
    )
  }

  func makeMePerson() -> INPerson {
    INPerson(
      personHandle: INPersonHandle(value: "0", type: .unknown),
      nameComponents: nil,
      displayName: nil,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: nil,
      isMe: true,
      suggestionType: .none
    )
  }

  func makeGroupAvatar(emoji: String?, title: String) -> INImage? {
    let text = if let trimmed = emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
      String(trimmed.prefix(2))
    } else if let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first {
      String(first).uppercased()
    } else {
      "•"
    }

    let size = CGSize(width: 60, height: 60)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { context in
      let ctx = context.cgContext
      let bgColor = groupBackgroundColor(for: title)

      // Background gradient (top to bottom) for a bit more depth
      let gradientColors = [
        bgColor.adjustLuminosity(by: 0.15).cgColor,
        bgColor.adjustLuminosity(by: -0.05).cgColor,
      ] as CFArray
      if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradientColors, locations: [0, 1]) {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(origin: .zero, size: size))
        ctx.clip()
        ctx.drawLinearGradient(
          gradient,
          start: CGPoint(x: size.width / 2, y: 0),
          end: CGPoint(x: size.width / 2, y: size.height),
          options: []
        )
        ctx.restoreGState()
      } else {
        ctx.setFillColor(bgColor.cgColor)
        ctx.fillEllipse(in: CGRect(origin: .zero, size: size))
      }

      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      let shadow = NSShadow()
      shadow.shadowBlurRadius = 2
      shadow.shadowOffset = CGSize(width: 0, height: 1)
      shadow.shadowColor = UIColor.black.withAlphaComponent(0.25)
      let attributes: [NSAttributedString.Key: Any] = [
        // Slightly larger so emoji/letters read better in the banner
        .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
        .foregroundColor: UIColor.white,
        .paragraphStyle: paragraph,
        .shadow: shadow,
      ]
      let attr = NSAttributedString(string: text, attributes: attributes)
      let bounds = attr.boundingRect(with: size, options: .usesLineFragmentOrigin, context: nil)
      let rect = CGRect(
        x: (size.width - bounds.width) / 2,
        y: (size.height - bounds.height) / 2,
        width: bounds.width,
        height: bounds.height
      )
      attr.draw(in: rect)
    }

    guard let data = image.pngData() else { return nil }
    return INImage(imageData: data)
  }

  func groupBackgroundColor(for title: String) -> UIColor {
    // Align with InlineUI initials palette
    let palette: [UIColor] = [
      .systemPink,
      .systemOrange,
      .systemPurple,
      .systemYellow,
      .systemTeal,
      .systemBlue,
      .systemTeal,
      .systemGreen,
      .systemRed,
      .systemIndigo,
      .systemMint,
      .cyan,
    ]
    let hash = title.unicodeScalars.reduce(into: 0) { $0 = ($0 &* 31) &+ Int($1.value) }
    return palette[abs(hash) % palette.count]
  }

  func conversationId(from content: UNNotificationContent) -> String? {
    if let threadId = content.threadIdentifier.nonEmpty { return threadId }
    if let targetId = content.targetContentIdentifier?.nonEmpty { return targetId }
    if let categoryId = content.categoryIdentifier.nonEmpty { return categoryId }
    return nil
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

private extension UIColor {
  func adjustLuminosity(by amount: CGFloat) -> UIColor {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }
    let adjustedBrightness = max(min(brightness + amount, 1.0), 0.0)
    return UIColor(hue: hue, saturation: saturation, brightness: adjustedBrightness, alpha: alpha)
  }
}
