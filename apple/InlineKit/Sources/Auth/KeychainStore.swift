import Foundation
import Security

enum KeychainAccess {
  case accessibleWhenUnlocked
  case accessibleAfterFirstUnlock

  var value: String {
    switch self {
    case .accessibleWhenUnlocked:
      kSecAttrAccessibleWhenUnlocked as String
    case .accessibleAfterFirstUnlock:
      kSecAttrAccessibleAfterFirstUnlock as String
    }
  }
}

protocol KeychainClient: AnyObject, Sendable {
  var lastResultCode: OSStatus { get }

  @discardableResult
  func set(_ value: String, forKey key: String, withAccess access: KeychainAccess?) -> Bool

  @discardableResult
  func set(_ value: Data, forKey key: String, withAccess access: KeychainAccess?) -> Bool

  func getData(_ key: String) -> Data?

  @discardableResult
  func delete(_ key: String) -> Bool
}

final class KeychainStore: KeychainClient, @unchecked Sendable {
  var accessGroup: String?
  private(set) var lastResultCode: OSStatus = noErr

  private let keyPrefix: String
  private let lock = NSLock()

  init(keyPrefix: String = "") {
    self.keyPrefix = keyPrefix
  }

  @discardableResult
  func set(_ value: String, forKey key: String, withAccess access: KeychainAccess? = nil) -> Bool {
    set(Data(value.utf8), forKey: key, withAccess: access)
  }

  @discardableResult
  func set(_ value: Data, forKey key: String, withAccess access: KeychainAccess? = nil) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    _ = deleteNoLock(key)

    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: keyWithPrefix(key),
      kSecValueData as String: value,
      kSecAttrAccessible as String: (access ?? .accessibleWhenUnlocked).value,
    ]
    addAccessGroup(to: &query)

    lastResultCode = SecItemAdd(query as CFDictionary, nil)
    return lastResultCode == errSecSuccess
  }

  func getData(_ key: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }

    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: keyWithPrefix(key),
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    addAccessGroup(to: &query)

    var result: CFTypeRef?
    lastResultCode = SecItemCopyMatching(query as CFDictionary, &result)

    if lastResultCode == errSecSuccess {
      return result as? Data
    }

    return nil
  }

  @discardableResult
  func delete(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    return deleteNoLock(key)
  }

  private func deleteNoLock(_ key: String) -> Bool {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: keyWithPrefix(key),
    ]
    addAccessGroup(to: &query)

    lastResultCode = SecItemDelete(query as CFDictionary)
    return lastResultCode == errSecSuccess
  }

  private func keyWithPrefix(_ key: String) -> String {
    "\(keyPrefix)\(key)"
  }

  private func addAccessGroup(to query: inout [String: Any]) {
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
  }
}
