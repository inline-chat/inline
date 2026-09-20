import Foundation
import Security

/// The session stays in the companion app's login Keychain. The widget receives aggregates only.
enum SessionKeychain {
  private static var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "chat.inline.tools.metrics.admin-session",
     kSecAttrAccount as String: "admin"]
  }

  static func load() throws -> AdminSession? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(status: status) }
    return try JSONDecoder().decode(AdminSession.self, from: data)
  }

  static func save(_ session: AdminSession) throws {
    let data = try JSONEncoder().encode(session)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrLabel as String] = "Inline Metrics admin session"
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw KeychainFailure(status: added) }
    } else if status != errSecSuccess { throw KeychainFailure(status: status) }
  }

  static func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
  }
}

private struct KeychainFailure: LocalizedError {
  let status: OSStatus
  var errorDescription: String? { "Could not access the saved admin session in Keychain (\(status))." }
}
