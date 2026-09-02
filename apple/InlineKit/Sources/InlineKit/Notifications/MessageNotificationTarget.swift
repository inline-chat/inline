import Auth
import CoreFoundation
import Foundation
import GRDB
import RealtimeV2
import UserNotifications

/// The same identity is used for presentation and navigation on both platforms.
public struct MessageNotificationTarget: Equatable, Sendable {
  public let peer: Peer?
  public let chatID: Int64?
  public let messageID: Int64?

  public init?(userInfo: [AnyHashable: Any], threadIdentifier: String = "") {
    if let type = userInfo["type"] as? String, type != "messageFailed" { return nil }
    if let kind = userInfo["kind"] as? String,
       !["send_message", "send_message_encrypted", "alert"].contains(kind) { return nil }

    let isThread = Self.boolValue(userInfo["isThread"])
    let payloadThreadID = Self.chatID(userInfo["threadId"])
    let payloadChatID = Self.chatID(userInfo["chatId"])
    chatID = (isThread == true ? payloadThreadID ?? payloadChatID : payloadChatID ?? payloadThreadID)
      ?? Self.chatID(threadIdentifier)
    messageID = Self.positiveID(userInfo["messageId"])
    if isThread == true {
      peer = chatID.map { .thread(id: $0) }
    } else if let userID = Self.positiveID(userInfo["userId"]) {
      peer = .user(id: userID)
    } else {
      peer = nil
    }
    guard peer != nil || chatID != nil else { return nil }
  }

  /// Encrypted fallback alerts can retain only chatID. Do not mistake a DM's
  /// chat ID for a thread or its sender ID; use existing local chat metadata.
  public func resolvePeer(fetchIfMissingFor account: AuthAccountMutationToken? = nil) async -> Peer? {
    if let peer { return peer }
    guard let chatID else { return nil }
    if let cached = try? await AppDatabase.shared.reader.read({ db in
      try Chat.fetchOne(db, id: chatID)?.peerId.toPeer()
    }) { return cached }

    // Only an explicit tap may fetch. The existing getChat endpoint authorizes a
    // chat ID for both DMs and threads and returns its canonical peer identity.
    guard let account, MessageNotificationAccount.isCurrent(account) else { return nil }
    do {
      let result = try await Api.realtime.send(.getChat(peer: .thread(id: chatID)), expectedAccount: account)
      guard MessageNotificationAccount.isCurrent(account),
            case let .getChat(response) = result, response.hasChat
      else { return nil }
      return Chat(from: response.chat).peerId.toPeer()
    } catch {
      return nil
    }
  }

  private static func chatID(_ value: Any?) -> Int64? {
    if let value = value as? String, value.hasPrefix("chat_") {
      return positiveID(String(value.dropFirst(5)))
    }
    return positiveID(value)
  }

  fileprivate static func positiveID(_ value: Any?) -> Int64? {
    let id: Int64?
    if let value = value as? String {
      id = Int64(value)
    } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
      id = Int64(value.stringValue)
    } else {
      id = nil
    }
    return id.flatMap { $0 > 0 ? $0 : nil }
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? NSNumber {
      switch value.stringValue {
      case "1": return true
      case "0": return false
      default: return nil
      }
    }
    if let value = value as? String {
      switch value.lowercased() {
      case "true", "1": return true
      case "false", "0": return false
      default: return nil
      }
    }
    return nil
  }
}

public enum MessageNotificationAccount {
  /// Older installed servers omitted recipient identity. Keep those payloads compatible.
  public static func matchesRecipient(userInfo: [AnyHashable: Any], currentUserID: Int64?) -> Bool {
    guard let currentUserID else { return false }
    guard let recipient = userInfo["recipientUserId"] else { return true }
    return MessageNotificationTarget.positiveID(recipient) == currentUserID
  }

  public static func capture(userInfo: [AnyHashable: Any]) -> AuthAccountMutationToken? {
    guard let account = try? Auth.shared.handle.beginAccountMutation(),
          matchesRecipient(userInfo: userInfo, currentUserID: account.userID)
    else { return nil }
    return account
  }

  public static func isCurrent(_ account: AuthAccountMutationToken) -> Bool {
    do {
      try Auth.shared.handle.validateAccountMutation(account)
      return true
    } catch { return false }
  }
}

public enum MessageNotificationPresentation {
  public static func foregroundOptions(
    for content: UNNotificationContent,
    isViewingConversation: Bool
  ) -> UNNotificationPresentationOptions {
    let urgent = UrgentNotificationPresentation.foregroundOptions(for: content)
    if !urgent.isEmpty { return urgent }
    guard !isViewingConversation,
          let target = MessageNotificationTarget(userInfo: content.userInfo, threadIdentifier: content.threadIdentifier),
          target.messageID != nil
    else { return [] }
    return content.sound == nil ? [.banner, .list] : [.banner, .list, .sound]
  }
}
