import CryptoKit
import Foundation
import Security

/// The device's X25519 key for encrypted push content, shared by the iOS app (which registers its
/// public half with the server) and the notification service extension (which decrypts with it).
///
/// A read that fails for any reason other than "not found" is reported as `.unavailable` and must
/// never be treated as "no key": creating a replacement then would overwrite the key the server
/// still encrypts to, and every later notification would arrive as an undecryptable placeholder.
public struct PushContentKeyStore: Sendable {
  public enum Read: Sendable {
    case present(Curve25519.KeyAgreement.PrivateKey)
    case missing
    /// Locked keychain (before first unlock), missing entitlement or another transient failure.
    case unavailable(OSStatus)
    /// Stored bytes are not a valid key. Safe to replace: nothing can decrypt with it.
    case corrupt
  }

  public enum LoadOrCreate: Sendable {
    case key(Curve25519.KeyAgreement.PrivateKey)
    /// Try again later (for example when protected data becomes available). Never register a
    /// token without a key because of this: the server would fall back to generic alerts.
    case unavailable(OSStatus)
  }

  public static let service = "chat.inline.push-content"
  /// Per install: each build registers its own key with its own server session.
  public static let account = InlineInstallNamespace.scoped("private-key-v1")
  public static let sharedAccessGroup = "2487AN8AL4.keychainGroup"
  public static let keyIDPrefix = "x25519:"

  private let accessGroup: String
  private let account: String

  public init(accessGroup: String = Self.sharedAccessGroup, account: String = Self.account) {
    self.accessGroup = accessGroup
    self.account = account
  }

  /// Identifies a key by its public half, so the extension can tell a payload encrypted to an
  /// older key (stale server registration) from a corrupt or tampered one.
  public static func keyID(for publicKey: Curve25519.KeyAgreement.PublicKey) -> String {
    let digest = SHA256.hash(data: publicKey.rawRepresentation)
    return keyIDPrefix + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: accessGroup,
    ]
  }

  public func read() -> Read {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data,
            let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
      else { return .corrupt }
      return .present(key)
    case errSecItemNotFound:
      return .missing
    default:
      return .unavailable(status)
    }
  }

  public func loadOrCreate() -> LoadOrCreate {
    let replacesCorrupt: Bool
    switch read() {
    case let .present(key):
      return .key(key)
    case let .unavailable(status):
      return .unavailable(status)
    case .missing:
      replacesCorrupt = false
    case .corrupt:
      replacesCorrupt = true
    }
    let key = Curve25519.KeyAgreement.PrivateKey()
    let attributes: [String: Any] = [
      kSecValueData as String: key.rawRepresentation,
      // Pushes arrive while the device is locked. The key never leaves this device.
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = replacesCorrupt
      ? SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
      : SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
    if status == errSecSuccess { return .key(key) }
    if status == errSecDuplicateItem, case let .present(existing) = read() {
      // Another registration created the key first. Keep it rather than replacing it.
      return .key(existing)
    }
    return .unavailable(status)
  }

  /// Succeeds when no key remains.
  @discardableResult
  public func delete() -> OSStatus {
    let status = SecItemDelete(baseQuery as CFDictionary)
    return status == errSecItemNotFound ? errSecSuccess : status
  }
}
