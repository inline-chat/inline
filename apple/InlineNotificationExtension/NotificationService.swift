import CryptoKit
import Foundation
import ImageIO
import InlineIntents
import InlineNotificationFence
import OSLog
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
  private let logger = Logger(subsystem: "chat.inline.InlineNotificationExtension", category: "NotificationService")
  private let deliveryLock = NSLock()
  private var currentDelivery: InlineNotificationDelivery?
  private let accountFence: any NotificationAccountFenceStorage = KeychainNotificationAccountFenceStorage()
  private let pushContentKeys = PushContentKeyStore()
  private static let healthEvent = NotificationDeliveryHealth.event

  // Inline has no notification filtering entitlement: every request this extension receives is
  // displayed, whatever it publishes. Read/delete sync therefore travels as background pushes
  // handled by the app, and this extension's only job is to make the shown alert as good as it
  // can be, as early as it can be.
  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    // Counted before any work: `received` minus every recorded end (published, redacted, withheld)
    // is the number of requests whose process died first, which then show the server placeholder.
    ExtensionHealthOutbox.shared.record(Self.healthEvent, ["delivery_stage": "received"])

    // The device key outlives accounts. Before any decryption, fetch or donation, the payload's
    // recipient must be the account the app says is signed in now.
    let accountFence = accountFence
    let admission = NotificationAccountAdmission.evaluate(
      userInfo: request.content.userInfo,
      fence: accountFence.read()
    )
    let redacted = NotificationAccountRedaction.content(from: request.content)
    guard admission.isAdmitted,
          let content = request.content.mutableCopy() as? UNMutableNotificationContent
    else {
      if case let .rejected(reason) = admission {
        logger.info("notification content withheld: \(reason.rawValue, privacy: .public)")
        ExtensionHealthOutbox.shared.record(Self.healthEvent, [
          "notification_outcome": NotificationDeliveryHealth.Outcome.withheld.rawValue,
          "withheld_reason": reason.rawValue,
        ])
      }
      contentHandler(redacted)
      return
    }

    // Decrypt before installing the fallback. It is CPU-only and fast, and it means every later
    // exit (expiry, a newer request reusing this instance, a deadline) shows the real text. The
    // request's own alert is only the server's generic placeholder.
    let hydration = hydrateFromEncryptedContentIfNeeded(content: content)
    ExtensionHealthOutbox.shared.record(Self.healthEvent, hydration.healthFields)

    // Recheck on every publication path, including expiry: logout can land mid-processing.
    let publish: (UNNotificationContent) -> Void = { published in
      let isCurrent = admission.isCurrent(accountFence.read())
      ExtensionHealthOutbox.shared.record(Self.healthEvent, ["delivery_end": isCurrent ? "published" : "redacted"])
      contentHandler(isCurrent ? published : redacted)
    }
    let delivery = InlineNotificationDelivery(content: content, handler: publish)
    let previous = deliveryLock.withLock {
      let previous = currentDelivery
      currentDelivery = delivery
      return previous
    }
    if let previous, previous.isPending {
      ExtensionHealthOutbox.shared.record(Self.healthEvent, ["delivery_end": "superseded"])
      previous.finish()
    }

    let work = Task { @MainActor in
      await enrich(content, hydration: hydration, delivery: delivery) {
        admission.isCurrent(accountFence.read())
      }
    }
    delivery.cancelOnFinish { work.cancel() }
  }

  /// Optional work on top of already-published text: avatar and communication intent, photo
  /// artwork, and clearing notifications other devices already read. None of it gates delivery.
  @MainActor
  private func enrich(
    _ content: UNMutableNotificationContent,
    hydration: Hydration,
    delivery: InlineNotificationDelivery,
    isAccountCurrent: @escaping @Sendable () -> Bool
  ) async {
    guard delivery.isPending, isAccountCurrent() else {
      delivery.finish()
      return
    }
    let recipientUserID = NotificationAccountAdmission.recipientUserID(in: content.userInfo)
    var bestContent: UNNotificationContent = content

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
      guard !Task.isCancelled, delivery.isPending, isAccountCurrent() else { return }
      let avatarSource: InlineMessageIntentDonation.UserAvatar.Source
      if let avatarURL = sender.profilePhotoUrl {
        let data = await Self.loadAvatarImageData(from: avatarURL)
        avatarSource = data.map { .imageData($0) } ?? .configuredPhotoUnavailable
      } else {
        avatarSource = sender.fallbackAvatarSource
      }
      // Intent donation outlives this notification; never donate after the account changed.
      guard !Task.isCancelled, delivery.isPending, isAccountCurrent(),
            let snapshot = bestContent.mutableCopy() as? UNMutableNotificationContent
      else { return }
      let styled = await applyingIntent(sender: sender, content: snapshot, avatarSource: avatarSource)
      guard !Task.isCancelled, delivery.isPending else { return }
      // The photo can finish during intent donation. Keep its attachment and routing metadata.
      bestContent = InlineMessageIntentDonation.preservingNotificationMetadata(from: bestContent, in: styled)
      delivery.updateFallback(bestContent)
    }

    @MainActor func enrichPhoto() async {
      guard !Task.isCancelled, delivery.isPending, isAccountCurrent() else { return }
      guard let photoURL = hydration.photoURL,
            let fileURL = await InlineNotificationPhoto.file(from: photoURL)
      else { return }
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

    @MainActor func applySyncOps() async {
      // Read/delete state from the user's other devices clears notifications already handled there.
      guard let syncOps = hydration.syncOps, let recipientUserID, !Task.isCancelled, delivery.isPending,
            isAccountCurrent()
      else { return }
      await syncOps.removeCovered(recipientUserID: recipientUserID)
    }

    // Artwork jobs publish their completed fallback independently; all three share the deadline.
    async let avatar: Void = enrichAvatar()
    async let photo: Void = enrichPhoto()
    async let cleanup: Void = applySyncOps()
    _ = await (avatar, photo, cleanup)
    delivery.finish(with: bestContent)
  }

  override func serviceExtensionTimeWillExpire() {
    ExtensionHealthOutbox.shared.record(Self.healthEvent, ["delivery_end": "expired"])
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

  struct Hydration {
    var outcome: NotificationDeliveryHealth.Outcome
    var placeholderReason: String?
    var photoURL: URL?
    var syncOps: NotificationSyncOps?

    var healthFields: [String: String] {
      var fields = ["notification_outcome": outcome.rawValue]
      if let placeholderReason { fields["placeholder_reason"] = placeholderReason }
      return fields
    }
  }

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

  /// Photo capabilities and sync ops are accepted only from authenticated encrypted content,
  /// never userInfo.
  func hydrateFromEncryptedContentIfNeeded(content: UNMutableNotificationContent) -> Hydration {
    guard let envelope = EncryptedPayloadEnvelope(userInfo: content.userInfo) else {
      // The server had nothing it could encrypt to this device and sent its generic alert.
      return Hydration(
        outcome: .placeholder,
        placeholderReason: NotificationDeliveryHealth.placeholderReason(in: content.userInfo)
      )
    }

    guard envelope.version == 1, envelope.algorithm == "X25519_HKDF_SHA256_AES256_GCM" else {
      logger.error("unsupported encrypted payload metadata")
      return Hydration(outcome: .unsupportedPayload)
    }

    let privateKey: Curve25519.KeyAgreement.PrivateKey
    switch pushContentKeys.read() {
    case let .present(key):
      privateKey = key
    case .missing, .corrupt:
      logger.error("push-content private key missing")
      return Hydration(outcome: .keyMissing)
    case let .unavailable(status):
      logger.error("push-content private key unavailable: \(status, privacy: .public)")
      return Hydration(outcome: .keyUnavailable)
    }

    // Key IDs derived from the public key tell an outdated server registration (another session
    // still holding this device's token) apart from a corrupt payload.
    if let keyID = envelope.keyId, keyID.hasPrefix(PushContentKeyStore.keyIDPrefix),
       keyID != PushContentKeyStore.keyID(for: privateKey.publicKey)
    {
      logger.error("encrypted notification targets a different device key")
      return Hydration(outcome: .staleKey)
    }

    do {
      let payloadData = try decryptEnvelope(envelope, privateKey: privateKey)
      let payload = try JSONDecoder().decode(DecryptedSendMessagePayload.self, from: payloadData)
      guard payload.kind == "send_message" else {
        logger.error("unsupported decrypted payload kind")
        return Hydration(outcome: .unsupportedPayload)
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
      let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
      return Hydration(
        outcome: .decrypted,
        photoURL: InlineNotificationPhoto.url(inDecryptedContent: payloadData),
        syncOps: NotificationSyncOps(jsonObject: object?["sync"])
      )
    } catch {
      logger.error("failed to decrypt encrypted notification content")
      return Hydration(outcome: .decryptFailed)
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
