import Foundation
@preconcurrency import UserNotifications

/// Read and delete state from the user's other devices, applied to notifications already on this
/// device. Every carrier uses this one model: the dedicated sync push, ops attached to message
/// pushes, and the app's own read-state sync. Applying ops twice is harmless.
public struct NotificationSyncOps: Equatable, Sendable {
  public struct Read: Equatable, Sendable {
    public var threadID: String
    public var upToMessageID: Int64

    public init(threadID: String, upToMessageID: Int64) {
      self.threadID = threadID
      self.upToMessageID = upToMessageID
    }
  }

  public struct Deleted: Equatable, Sendable {
    public var threadID: String
    public var messageIDs: Set<Int64>

    public init(threadID: String, messageIDs: Set<Int64>) {
      self.threadID = threadID
      self.messageIDs = messageIDs
    }
  }

  public static let readKind = "messages_read"
  public static let deletedKind = "message_deleted"

  public var reads: [Read]
  public var deletions: [Deleted]

  public init(reads: [Read] = [], deletions: [Deleted] = []) {
    self.reads = reads
    self.deletions = deletions
  }

  public var isEmpty: Bool { reads.isEmpty && deletions.isEmpty }

  /// Keeps the highest read marker and every deleted ID per thread.
  public mutating func merge(_ other: NotificationSyncOps) {
    for read in other.reads {
      if let index = reads.firstIndex(where: { $0.threadID == read.threadID }) {
        reads[index].upToMessageID = max(reads[index].upToMessageID, read.upToMessageID)
      } else {
        reads.append(read)
      }
    }
    for deleted in other.deletions {
      if let index = deletions.firstIndex(where: { $0.threadID == deleted.threadID }) {
        deletions[index].messageIDs.formUnion(deleted.messageIDs)
      } else {
        deletions.append(deleted)
      }
    }
  }

  /// True for the server's dedicated `messages_read` and `message_deleted` pushes, which never
  /// carry anything to show.
  public static func isSyncPush(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard let kind = userInfo["kind"] as? String else { return false }
    return kind == readKind || kind == deletedKind
  }

  /// Parses a dedicated sync push.
  public init?(syncPushUserInfo userInfo: [AnyHashable: Any]) {
    guard let threadID = userInfo["threadId"] as? String, !threadID.isEmpty else { return nil }
    switch userInfo["kind"] as? String {
    case Self.readKind:
      guard let upTo = Self.messageID(userInfo["readUpToMessageId"]) else { return nil }
      self.init(reads: [Read(threadID: threadID, upToMessageID: upTo)])
    case Self.deletedKind:
      let ids = Set((userInfo["messageIds"] as? [Any] ?? []).compactMap(Self.messageID))
      guard !ids.isEmpty else { return nil }
      self.init(deletions: [Deleted(threadID: threadID, messageIDs: ids)])
    default:
      return nil
    }
  }

  /// Parses the `sync` object inside decrypted message content:
  /// `{ "read": [{ "threadId", "upTo" }], "deleted": [{ "threadId", "ids" }] }`.
  public init?(jsonObject: Any?) {
    guard let object = jsonObject as? [String: Any] else { return nil }
    let reads = (object["read"] as? [[String: Any]] ?? []).compactMap { entry -> Read? in
      guard let threadID = entry["threadId"] as? String, !threadID.isEmpty,
            let upTo = Self.messageID(entry["upTo"])
      else { return nil }
      return Read(threadID: threadID, upToMessageID: upTo)
    }
    let deletions = (object["deleted"] as? [[String: Any]] ?? []).compactMap { entry -> Deleted? in
      guard let threadID = entry["threadId"] as? String, !threadID.isEmpty else { return nil }
      let ids = Set((entry["ids"] as? [Any] ?? []).compactMap(Self.messageID))
      return ids.isEmpty ? nil : Deleted(threadID: threadID, messageIDs: ids)
    }
    self.init(reads: reads, deletions: deletions)
    if isEmpty { return nil }
  }

  /// Whether a delivered or pending notification belongs to `recipientUserID` and is already
  /// read or deleted. Notifications without a message ID are never matched.
  public func covers(_ content: UNNotificationContent, recipientUserID: Int64) -> Bool {
    guard Self.belongs(content, to: recipientUserID),
          let messageID = Self.messageID(content.userInfo["messageId"])
    else { return false }
    if reads.contains(where: { Self.thread(of: content, is: $0.threadID) && messageID <= $0.upToMessageID }) {
      return true
    }
    return deletions.contains { Self.thread(of: content, is: $0.threadID) && $0.messageIDs.contains(messageID) }
  }

  /// Removes delivered and pending notifications these ops cover and returns how many.
  @discardableResult
  public func removeCovered(
    recipientUserID: Int64,
    center: UNUserNotificationCenter = .current()
  ) async -> Int {
    guard !isEmpty else { return 0 }
    let delivered = await center.deliveredNotifications()
      .filter { covers($0.request.content, recipientUserID: recipientUserID) }
      .map(\.request.identifier)
    let pending = await center.pendingNotificationRequests()
      .filter { covers($0.content, recipientUserID: recipientUserID) }
      .map(\.identifier)
    if !delivered.isEmpty { center.removeDeliveredNotifications(withIdentifiers: delivered) }
    if !pending.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pending) }
    return delivered.count + pending.count
  }

  // MARK: - Shared matching rules

  /// Notifications predating the recipient field belong to whoever is signed in.
  public static func belongs(_ content: UNNotificationContent, to recipientUserID: Int64) -> Bool {
    guard content.userInfo["recipientUserId"] != nil else { return true }
    return NotificationAccountAdmission.recipientUserID(in: content.userInfo) == recipientUserID
  }

  public static func thread(of content: UNNotificationContent, is threadID: String) -> Bool {
    content.threadIdentifier == threadID || content.userInfo["threadId"] as? String == threadID
  }

  /// Message IDs arrive as decimal strings from the server and as numbers from local code.
  public static func messageID(_ value: Any?) -> Int64? {
    let id: Int64? = switch value {
    case let value as String: Int64(value)
    case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID(): value.int64Value
    case let value as Int64: value
    case let value as Int: Int64(value)
    default: nil
    }
    return id.flatMap { $0 > 0 ? $0 : nil }
  }
}
