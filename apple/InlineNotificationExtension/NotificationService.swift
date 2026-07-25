import CryptoKit
import Foundation
import InlineIntents
import OSLog
import Security
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private let logger = Logger(subsystem: "chat.inline.InlineNotificationExtension", category: "NotificationService")
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?
  private var avatarTask: URLSessionDataTask?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

    guard let bestAttemptContent else {
      contentHandler(request.content)
      return
    }

    hydrateFromEncryptedContentIfNeeded(content: bestAttemptContent)

    let userInfo = bestAttemptContent.userInfo
    guard let sender = SenderPayload(userInfo: userInfo) else {
      // No sender metadata; deliver as-is to avoid breaking existing behaviour
      finish(with: bestAttemptContent)
      return
    }

    // If we have an avatar URL, fetch it before finalising; otherwise finish immediately
    if let avatarURL = sender.profilePhotoUrl {
      logger.info("fetching avatar from \(avatarURL.absoluteString, privacy: .public)")
      avatarTask = URLSession.shared.dataTask(with: avatarURL) { [weak self] data, _, error in
        if let error {
          self?.logger.error("avatar download failed: \(error.localizedDescription, privacy: .public)")
        }
        let imageData: Data? = if let data, UIImage(data: data) != nil {
          data
        } else {
          nil
        }
        self?.applyIntent(sender: sender, imageData: imageData)
      }
      avatarTask?.resume()
    } else {
      logger.info("no avatar URL provided")
      applyIntent(sender: sender, imageData: nil)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    avatarTask?.cancel()
    guard let bestAttemptContent else { return }
    finish(with: bestAttemptContent)
  }
}

// MARK: - Private helpers

private extension NotificationService {
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

  func hydrateFromEncryptedContentIfNeeded(content: UNMutableNotificationContent) {
    guard let envelope = EncryptedPayloadEnvelope(userInfo: content.userInfo) else {
      return
    }

    guard envelope.version == 1, envelope.algorithm == "X25519_HKDF_SHA256_AES256_GCM" else {
      logger.error("unsupported encrypted payload metadata")
      return
    }

    guard let privateKeyData = loadPushContentPrivateKeyData() else {
      logger.error("push-content private key missing")
      return
    }

    do {
      let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
      let payloadData = try decryptEnvelope(envelope, privateKey: privateKey)
      let payload = try JSONDecoder().decode(DecryptedSendMessagePayload.self, from: payloadData)
      guard payload.kind == "send_message" else {
        logger.error("unsupported decrypted payload kind")
        return
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
      userInfo["sender"] = senderInfo
      content.userInfo = userInfo

      logger.info("decrypted encrypted notification content")
    } catch {
      logger.error("failed to decrypt encrypted notification content: \(error.localizedDescription, privacy: .public)")
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

  func applyIntent(sender: SenderPayload, imageData: Data?) {
    guard let bestAttemptContent else { return }

    logger.info("applying intent for sender \(sender.id, privacy: .public)")

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
    let groupNameLog = groupName ?? "nil"
    logger
      .info(
        "notification context: isThread=\(isThread, privacy: .public) title=\(bestAttemptContent.title, privacy: .public) subtitle=\(bestAttemptContent.subtitle, privacy: .public) groupName=\(groupNameLog, privacy: .public)"
      )

    let senderName = senderNameComponents(sender.displayName)
    let senderAvatar = InlineMessageIntentDonation.Avatar.user(.init(
      imageData: imageData,
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

    Task {
      let contentToDeliver: UNNotificationContent
      do {
        let intent = try await InlineMessageIntentDonation.donate(request)
        logger.info("interaction donation succeeded (conversation=\(conversationIdentifier, privacy: .public))")
        let updated = try bestAttemptContent.updating(from: intent)
        contentToDeliver = updated
        self.bestAttemptContent = updated as? UNMutableNotificationContent
        logger.info("notification content updated from intent")
      } catch {
        logger.error("interaction donation or content update failed: \(error.localizedDescription, privacy: .public)")
        contentToDeliver = bestAttemptContent
      }
      finish(with: contentToDeliver)
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

  func finish(with content: UNNotificationContent) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let contentHandler = self.contentHandler else { return }
      self.contentHandler = nil
      contentHandler(content)
    }
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
