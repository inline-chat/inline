import CryptoKit
import Foundation
import ImageIO
import InlineIntents
import OSLog
import Security
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
  private let logger = Logger(subsystem: "chat.inline.InlineNotificationExtension", category: "NotificationService")
  private let deliveryLock = NSLock()
  private var currentDelivery: InlineNotificationDelivery?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    // Install a fallback synchronously: system expiry cannot depend on the main queue.
    let delivery = InlineNotificationDelivery(content: request.content, handler: contentHandler)
    let previous = deliveryLock.withLock {
      let previous = currentDelivery
      currentDelivery = delivery
      return previous
    }
    previous?.finish()
    let work = Task { @MainActor in
      await process(request, delivery: delivery)
    }
    delivery.cancelOnFinish { work.cancel() }
  }

  @MainActor
  private func process(_ request: UNNotificationRequest, delivery: InlineNotificationDelivery) async {
    guard delivery.isPending else { return }
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      delivery.finish()
      return
    }
    let photoURL = hydrateFromEncryptedContentIfNeeded(content: content)
    guard !Task.isCancelled, delivery.isPending else { return }
    var bestContent: UNNotificationContent = content
    delivery.updateFallback(bestContent)

    // Artwork and intent donation share a total deadline; neither gates text delivery.
    let deadline = Task.detached {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      delivery.finish()
    }
    delivery.cancelOnFinish { deadline.cancel() }

    guard let sender = SenderPayload(userInfo: content.userInfo) else {
      delivery.finish()
      return
    }

    @MainActor func enrichAvatar() async {
      guard !Task.isCancelled, delivery.isPending else { return }
      let avatarSource: InlineMessageIntentDonation.UserAvatar.Source
      if let avatarURL = sender.profilePhotoUrl {
        let data = await Self.loadAvatarImageData(from: avatarURL)
        avatarSource = data.map { .imageData($0) } ?? .configuredPhotoUnavailable
      } else {
        avatarSource = sender.fallbackAvatarSource
      }
      guard !Task.isCancelled, delivery.isPending,
            let snapshot = bestContent.mutableCopy() as? UNMutableNotificationContent
      else { return }
      let styled = await applyingIntent(sender: sender, content: snapshot, avatarSource: avatarSource)
      guard !Task.isCancelled, delivery.isPending else { return }
      // The photo can finish during intent donation. Keep its attachment and routing metadata.
      bestContent = InlineMessageIntentDonation.preservingNotificationMetadata(from: bestContent, in: styled)
      delivery.updateFallback(bestContent)
    }

    @MainActor func enrichPhoto() async {
      guard !Task.isCancelled, delivery.isPending else { return }
      guard let photoURL, let fileURL = await InlineNotificationPhoto.file(from: photoURL) else { return }
      guard !Task.isCancelled, delivery.isPending,
            let updated = bestContent.mutableCopy() as? UNMutableNotificationContent
      else {
        try? FileManager.default.removeItem(at: fileURL)
        return
      }
      do {
        let attachment = try UNNotificationAttachment(identifier: "message-photo", url: fileURL)
        updated.attachments.append(attachment)
        bestContent = updated
        if !delivery.updateFallback(bestContent) {
          // Expiry can win after the pending check. This file was never submitted.
          try? FileManager.default.removeItem(at: fileURL)
        }
      } catch {
        try? FileManager.default.removeItem(at: fileURL)
      }
    }

    // Both jobs publish their completed fallback independently and share the existing deadline.
    async let avatar: Void = enrichAvatar()
    async let photo: Void = enrichPhoto()
    _ = await (avatar, photo)
    delivery.finish(with: bestContent)
  }

  override func serviceExtensionTimeWillExpire() {
    deliveryLock.withLock { currentDelivery }?.finish()
  }
}

// MARK: - Private helpers

private extension NotificationService {
  @concurrent
  static func loadAvatarImageData(from url: URL) async -> Data? {
    guard !Task.isCancelled else { return nil }
    guard let data = await InlineNotificationAvatar.data(from: url), !Task.isCancelled,
          data.count <= InlineNotificationAvatar.maximumBytes,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
          ] as CFDictionary)
    else { return nil }
    return UIImage(cgImage: image).pngData()
  }

  static let pushContentHkdfInfo = Data("inline.push-content.v1".utf8)
  static let pushContentKeychainService = "chat.inline.push-content"
  static let pushContentPrivateKeyAccount = "private-key-v1"
  static let pushContentKeychainAccessGroup = "2487AN8AL4.keychainGroup"

  struct EncryptedPayloadEnvelope {
    let version: Int
    let algorithm: String
    let keyId: String?
    let ephemeralPublicKey: String
    let salt: String
    let iv: String
    let ciphertext: String
    let tag: String

    init?(userInfo: [AnyHashable: Any]) {
      guard let rawEnvelope = userInfo["encryptedContent"] as? [String: Any] else { return nil }
      guard
        let version = rawEnvelope["version"] as? Int,
        let algorithm = rawEnvelope["algorithm"] as? String,
        let ephemeralPublicKey = rawEnvelope["ephemeralPublicKey"] as? String,
        let salt = rawEnvelope["salt"] as? String,
        let iv = rawEnvelope["iv"] as? String,
        let ciphertext = rawEnvelope["ciphertext"] as? String,
        let tag = rawEnvelope["tag"] as? String
      else {
        return nil
      }

      self.version = version
      self.algorithm = algorithm
      self.keyId = rawEnvelope["keyId"] as? String
      self.ephemeralPublicKey = ephemeralPublicKey
      self.salt = salt
      self.iv = iv
      self.ciphertext = ciphertext
      self.tag = tag
    }
  }

  struct DecryptedSendMessagePayload: Decodable {
    struct Sender: Decodable {
      let id: Int
      let displayName: String?
      let profilePhotoUrl: String?
      let hasProfilePhoto: Bool?
    }

    let kind: String
    let sender: Sender
    let title: String
    let body: String
    let subtitle: String?
    let threadId: String
    let messageId: String
    let isThread: Bool
    let isReplyThread: Bool?
    let threadEmoji: String?
  }

  /// Photo capabilities are accepted only from authenticated encrypted content, never userInfo.
  func hydrateFromEncryptedContentIfNeeded(content: UNMutableNotificationContent) -> URL? {
    guard let envelope = EncryptedPayloadEnvelope(userInfo: content.userInfo) else {
      return nil
    }

    guard envelope.version == 1, envelope.algorithm == "X25519_HKDF_SHA256_AES256_GCM" else {
      logger.error("unsupported encrypted payload metadata")
      return nil
    }

    guard let privateKeyData = loadPushContentPrivateKeyData() else {
      logger.error("push-content private key missing")
      return nil
    }

    do {
      let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
      let payloadData = try decryptEnvelope(envelope, privateKey: privateKey)
      let payload = try JSONDecoder().decode(DecryptedSendMessagePayload.self, from: payloadData)
      guard payload.kind == "send_message" else {
        logger.error("unsupported decrypted payload kind")
        return nil
      }

      content.title = payload.title
      content.body = payload.body
      content.subtitle = payload.subtitle ?? ""

      var userInfo = content.userInfo
      userInfo["userId"] = payload.sender.id
      userInfo["threadId"] = payload.threadId
      userInfo["messageId"] = payload.messageId
      userInfo["isThread"] = payload.isThread
      userInfo["isReplyThread"] = payload.isReplyThread ?? false
      if let threadEmoji = payload.threadEmoji {
        userInfo["threadEmoji"] = threadEmoji
      }

      var senderInfo: [String: Any] = ["id": payload.sender.id]
      if let displayName = payload.sender.displayName {
        senderInfo["displayName"] = displayName
      }
      if let profilePhotoUrl = payload.sender.profilePhotoUrl {
        senderInfo["profilePhotoUrl"] = profilePhotoUrl
      }
      if let hasProfilePhoto = payload.sender.hasProfilePhoto {
        senderInfo["hasProfilePhoto"] = hasProfilePhoto
      }
      userInfo["sender"] = senderInfo
      content.userInfo = userInfo

      logger.info("decrypted encrypted notification content")
      return InlineNotificationPhoto.url(inDecryptedContent: payloadData)
    } catch {
      logger.error("failed to decrypt encrypted notification content")
      return nil
    }
  }

  func decryptEnvelope(
    _ envelope: EncryptedPayloadEnvelope,
    privateKey: Curve25519.KeyAgreement.PrivateKey
  ) throws -> Data {
    let ephemeralPublicKeyData = try decodeBase64URL(envelope.ephemeralPublicKey)
    let salt = try decodeBase64URL(envelope.salt)
    let iv = try decodeBase64URL(envelope.iv)
    let ciphertext = try decodeBase64URL(envelope.ciphertext)
    let tag = try decodeBase64URL(envelope.tag)

    let ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKeyData)
    let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
    let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: salt,
      sharedInfo: Self.pushContentHkdfInfo,
      outputByteCount: 32
    )

    let nonce = try AES.GCM.Nonce(data: iv)
    let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
    return try AES.GCM.open(sealedBox, using: symmetricKey)
  }

  func decodeBase64URL(_ value: String) throws -> Data {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
      base64.append(String(repeating: "=", count: 4 - remainder))
    }

    guard let data = Data(base64Encoded: base64) else {
      throw NSError(domain: "NotificationService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid base64url"])
    }
    return data
  }

  func loadPushContentPrivateKeyData() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.pushContentKeychainService,
      kSecAttrAccount as String: Self.pushContentPrivateKeyAccount,
      kSecAttrAccessGroup as String: Self.pushContentKeychainAccessGroup,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess {
      return item as? Data
    }
    if status != errSecItemNotFound {
      logger.error("failed to read push-content keychain item: \(status, privacy: .public)")
    }
    return nil
  }

  struct SenderPayload: Sendable {
    let id: String
    let displayName: String?
    let profilePhotoUrl: URL?
    let fallbackAvatarSource: InlineMessageIntentDonation.UserAvatar.Source

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
      let urlString = sender["profilePhotoUrl"] as? String
      // Missing metadata is unknown, not proof that this person has no photo.
      fallbackAvatarSource = InlineNotificationAvatar.fallbackSource(
        hasProfilePhoto: sender["hasProfilePhoto"] as? Bool,
        hasPhotoURL: urlString?.isEmpty == false
      )
      if let urlString, let url = URL(string: urlString), url.scheme == "https", url.host != nil {
        profilePhotoUrl = url
      } else {
        profilePhotoUrl = nil
      }
    }
  }

  @MainActor
  func applyingIntent(
    sender: SenderPayload,
    content bestAttemptContent: UNMutableNotificationContent,
    avatarSource: InlineMessageIntentDonation.UserAvatar.Source
  ) async -> UNNotificationContent {
    guard !Task.isCancelled else { return bestAttemptContent }

    logger.info("applying notification intent")

    let isThread = boolValue(bestAttemptContent.userInfo["isThread"])
    let isReplyThread = boolValue(bestAttemptContent.userInfo["isReplyThread"])
    let threadTitle = bestAttemptContent.title.nonEmpty ?? bestAttemptContent.subtitle.nonEmpty
    let threadEmoji = bestAttemptContent.userInfo["threadEmoji"] as? String
    let rawConversationIdentifier = conversationId(from: bestAttemptContent) ?? sender.id
    let conversationIdentifier = canonicalConversationIdentifier(
      rawConversationIdentifier,
      isThread: isThread,
      senderId: sender.id
    )
    if let threadTitle, isThread {
      bestAttemptContent.title = threadTitle
      bestAttemptContent.subtitle = ""
    }

    let groupName = isThread ? threadTitle : nil
    logger.info("notification context: isThread=\(isThread, privacy: .public)")

    let senderName = senderNameComponents(sender.displayName)
    let senderAvatar = InlineMessageIntentDonation.Avatar.user(.init(
      source: avatarSource,
      firstName: senderName.givenName,
      lastName: senderName.familyName,
      displayName: sender.displayName,
      email: nil,
      username: nil,
      stableIdentifier: "sender:\(sender.id)"
    ))
    let conversationAvatar: InlineMessageIntentDonation.Avatar = if let threadTitle, isThread {
      .thread(.init(
        emoji: threadEmoji,
        title: threadTitle,
        isReplyThread: isReplyThread,
        stableIdentifier: conversationIdentifier
      ))
    } else {
      senderAvatar
    }
    let intentSender: InlineMessageIntentDonation.Person
    let recipients: [InlineMessageIntentDonation.Person]
    if let threadTitle, isThread {
      // Preserve Inline's established communication-notification presentation:
      // the chat is the displayed sender and the current user is its recipient.
      intentSender = .init(
        identifier: conversationIdentifier,
        handle: conversationIdentifier,
        displayName: threadTitle,
        avatar: conversationAvatar
      )
      recipients = [.init(
        identifier: "inline:current-user",
        handle: "0",
        isCurrentUser: true
      )]
    } else {
      intentSender = .init(
        identifier: InlineMessageIntentDonation.userConversationIdentifier(sender.id),
        handle: sender.id,
        firstName: senderName.givenName,
        lastName: senderName.familyName,
        displayName: sender.displayName,
        avatar: senderAvatar
      )
      recipients = []
    }
    let request = InlineMessageIntentDonation.Request(
      conversation: .init(
        identifier: conversationIdentifier,
        displayName: groupName ?? sender.displayName,
        avatar: conversationAvatar
      ),
      direction: .incoming,
      sender: intentSender,
      recipients: recipients,
      content: bestAttemptContent.body
    )

    do {
      let intent = try await InlineMessageIntentDonation.donate(request)
      guard !Task.isCancelled else { return bestAttemptContent }
      return InlineMessageIntentDonation.preservingNotificationMetadata(
        from: bestAttemptContent,
        in: try bestAttemptContent.updating(from: intent)
      )
    } catch {
      logger.error("notification interaction donation or content update failed")
      return bestAttemptContent
    }
  }

  func senderNameComponents(_ displayName: String?) -> PersonNameComponents {
    var nameComponents = PersonNameComponents()
    if let displayName {
      let parts = displayName.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      if let first = parts.first { nameComponents.givenName = String(first) }
      if parts.count > 1 { nameComponents.familyName = String(parts[1]) }
    }
    return nameComponents
  }

  func canonicalConversationIdentifier(_ rawValue: String, isThread: Bool, senderId: String) -> String {
    if rawValue.hasPrefix("inline:") { return rawValue }
    return isThread
      ? InlineMessageIntentDonation.threadConversationIdentifier(rawValue)
      : InlineMessageIntentDonation.userConversationIdentifier(senderId)
  }

  func boolValue(_ value: Any?) -> Bool {
    switch value {
    case let value as Bool:
      value
    case let value as NSNumber:
      value.boolValue
    case let value as String:
      ["1", "true", "yes"].contains(value.lowercased())
    default:
      false
    }
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
