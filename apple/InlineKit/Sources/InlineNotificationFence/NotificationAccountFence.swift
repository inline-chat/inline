import Foundation
import Security
import Synchronization
@preconcurrency import UserNotifications

/// The account that owns this device's notifications, published by the app for its notification
/// service extension. The extension shares no process, database or auth state with the app, so
/// this record is its only view of logout and account changes.
public struct NotificationAccountFence: Codable, Equatable, Sendable {
  /// `nil` from the moment logout begins, and while no account is signed in.
  public var userID: Int64?
  /// Changes with every owner change, including logout followed by the same account signing in.
  public var generation: UInt64

  public init(userID: Int64?, generation: UInt64) {
    self.userID = userID
    self.generation = generation
  }
}

public enum NotificationAccountFenceRead: Equatable, Sendable {
  case present(NotificationAccountFence)
  case missing
  /// Locked keychain, missing entitlement or an undecodable record.
  case unavailable
}

public protocol NotificationAccountFenceStorage: Sendable {
  func read() -> NotificationAccountFenceRead
  func write(_ fence: NotificationAccountFence) -> Bool
  /// Succeeds when no record remains.
  func delete() -> Bool
}

/// Shared-keychain record readable by the iOS app and its notification service extension.
public struct KeychainNotificationAccountFenceStorage: NotificationAccountFenceStorage {
  public static let service = "chat.inline.notification-account-fence"
  public static let account = "fence-v1"
  /// Both the app and the notification extension entitlements list this group.
  public static let sharedAccessGroup = "2487AN8AL4.keychainGroup"

  private let accessGroup: String

  public init(accessGroup: String = Self.sharedAccessGroup) {
    self.accessGroup = accessGroup
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
      kSecAttrAccessGroup as String: accessGroup,
    ]
  }

  public func read() -> NotificationAccountFenceRead {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    switch SecItemCopyMatching(query as CFDictionary, &item) {
    case errSecSuccess:
      guard let data = item as? Data,
            let fence = try? JSONDecoder().decode(NotificationAccountFence.self, from: data)
      else { return .unavailable }
      return .present(fence)
    case errSecItemNotFound:
      return .missing
    default:
      return .unavailable
    }
  }

  public func write(_ fence: NotificationAccountFence) -> Bool {
    guard let data = try? JSONEncoder().encode(fence) else { return false }
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      // Pushes arrive while the device is locked. The record never leaves this device.
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
      if status == errSecDuplicateItem {
        status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
      }
    }
    return status == errSecSuccess
  }

  public func delete() -> Bool {
    let status = SecItemDelete(baseQuery as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}

/// App-side writer. Read-modify-write is serialised so the generation never repeats.
public final class NotificationAccountFencePublisher: Sendable {
  private let storage: any NotificationAccountFenceStorage
  private let lock = Mutex(())

  public init(storage: any NotificationAccountFenceStorage) {
    self.storage = storage
  }

  /// `isCurrent` runs under the publisher lock, so a logout that starts first always wins.
  @discardableResult
  public func publishSignedIn(userID: Int64, isCurrent: () -> Bool = { true }) -> Bool {
    publish(userID: userID, isCurrent: isCurrent)
  }

  /// Fails closed: when the record cannot be replaced it is deleted, and the extension treats a
  /// missing record as signed out.
  @discardableResult
  public func publishSignedOut(isCurrent: () -> Bool = { true }) -> Bool {
    publish(userID: nil, isCurrent: isCurrent)
  }

  private func publish(userID: Int64?, isCurrent: () -> Bool) -> Bool {
    lock.withLock { _ in
      guard isCurrent() else { return false }
      let previous = storage.read()
      if case let .present(fence) = previous, fence.userID == userID { return true }
      let previousGeneration: UInt64 = if case let .present(fence) = previous {
        fence.generation
      } else {
        // A deleted or unreadable record must not restart at a generation an extension saw.
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
      }
      if storage.write(NotificationAccountFence(userID: userID, generation: previousGeneration &+ 1)) {
        return true
      }
      return userID == nil ? storage.delete() : false
    }
  }
}

/// Extension-side gate. Nothing private (decryption, artwork, intent donation) runs unless the
/// payload's recipient is the account currently signed in on this device.
public enum NotificationAccountAdmission: Equatable, Sendable {
  case admitted(NotificationAccountFence)
  case rejected(Rejection)

  public enum Rejection: String, Sendable {
    case missingRecipient
    case missingFence
    case fenceUnavailable
    case signedOut
    case otherAccount
  }

  public static func evaluate(
    userInfo: [AnyHashable: Any],
    fence: NotificationAccountFenceRead
  ) -> NotificationAccountAdmission {
    guard let recipientUserID = recipientUserID(in: userInfo) else { return .rejected(.missingRecipient) }
    switch fence {
    case .missing:
      return .rejected(.missingFence)
    case .unavailable:
      return .rejected(.fenceUnavailable)
    case let .present(fence):
      guard let owner = fence.userID else { return .rejected(.signedOut) }
      guard owner == recipientUserID else { return .rejected(.otherAccount) }
      return .admitted(fence)
    }
  }

  /// The server sends the clear-text recipient as a decimal string.
  public static func recipientUserID(in userInfo: [AnyHashable: Any]) -> Int64? {
    let value = userInfo["recipientUserId"]
    let id: Int64? = if let value = value as? String {
      Int64(value)
    } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
      Int64(value.stringValue)
    } else {
      nil
    }
    return id.flatMap { $0 > 0 ? $0 : nil }
  }

  public var isAdmitted: Bool {
    if case .admitted = self { true } else { false }
  }

  /// True only while the owner that admitted the notification is still signed in, unchanged.
  public func isCurrent(_ fence: NotificationAccountFenceRead) -> Bool {
    guard case let .admitted(admitted) = self else { return false }
    return fence == .present(admitted)
  }
}

public enum NotificationAccountRedaction {
  public static let title = "New message"
  public static let body = "Open Inline to read it."
  /// Enough for the app to check a tap against its current account and open the chat.
  public static let retainedUserInfoKeys: Set<String> = ["kind", "recipientUserId", "threadId", "messageId"]

  /// Keeps sound, grouping and routing; drops text, attachments and sender or encrypted metadata.
  public static func content(from content: UNNotificationContent) -> UNNotificationContent {
    let redacted = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    redacted.title = title
    redacted.subtitle = ""
    redacted.body = body
    redacted.attachments = []
    redacted.userInfo = content.userInfo.filter { key, _ in
      (key as? String).map(retainedUserInfoKeys.contains) ?? false
    }
    return redacted
  }
}
