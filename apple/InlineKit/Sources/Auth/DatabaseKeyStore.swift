import Foundation
import KeychainSwift
import Security

public enum DatabaseKeyAvailability: Sendable, Equatable {
  case available(key: String)
  case locked
  case notFound
  case error(status: Int32)
}

public enum DatabaseKeyStore {
  // Public so InlineKit can use the same key name if needed for diagnostics.
  public static let keychainKey = "dbKey_v1"

  public static func load(mocked: Bool = false, namespace: String? = nil) -> DatabaseKeyAvailability {
    let primary = AuthKeychainConfig.makePrimaryKeychain(mocked: mocked, namespace: namespace)
    let fallback = AuthKeychainConfig.makeFallbackKeychainIfNeeded(mocked: mocked, namespace: namespace)

    switch AuthKeychainConfig.readString(keychainKey, primary: primary, fallback: fallback) {
    case .success(let key, let usedFallback):
      if usedFallback, let fallback {
        // Migrate legacy macOS item (no access group) into the primary access group.
        if primary.set(key, forKey: keychainKey, withAccess: .accessibleAfterFirstUnlock) {
          _ = fallback.delete(keychainKey)
        }
      }
      return .available(key: key)

    case .interactionNotAllowed:
      return .locked

    case .notFound:
      return .notFound

    case .error(let status):
      return .error(status: status)
    }
  }

  public static func getOrCreate(mocked: Bool = false, namespace: String? = nil) -> DatabaseKeyAvailability {
    switch load(mocked: mocked, namespace: namespace) {
    case .available(let key):
      return .available(key: key)
    case .locked:
      return .locked
    case .error(let status):
      return .error(status: status)
    case .notFound:
      break
    }

    // Create new key if keychain is available.
    let primary = AuthKeychainConfig.makePrimaryKeychain(mocked: mocked, namespace: namespace)

    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      return .error(status: status)
    }

    let key = Data(bytes).base64EncodedString()
    let ok = primary.set(key, forKey: keychainKey, withAccess: .accessibleAfterFirstUnlock)
    if ok {
      return .available(key: key)
    }

    // KeychainSwift sets lastResultCode.
    let writeStatus = primary.lastResultCode
    if writeStatus == errSecInteractionNotAllowed || writeStatus == errSecNotAvailable {
      return .locked
    }

    // Best-effort macOS fallback if the primary access-group isn't working.
    if let fallback = AuthKeychainConfig.makeFallbackKeychainIfNeeded(mocked: mocked, namespace: namespace) {
      let okFallback = fallback.set(key, forKey: keychainKey, withAccess: .accessibleAfterFirstUnlock)
      if okFallback {
        return .available(key: key)
      }

      let fallbackStatus = fallback.lastResultCode
      if fallbackStatus == errSecInteractionNotAllowed || fallbackStatus == errSecNotAvailable {
        return .locked
      }
      return .error(status: fallbackStatus)
    }

    return .error(status: writeStatus)
  }

  public static func delete(mocked: Bool = false, namespace: String? = nil) {
    let primary = AuthKeychainConfig.makePrimaryKeychain(mocked: mocked, namespace: namespace)
    _ = primary.delete(keychainKey)
    if let fallback = AuthKeychainConfig.makeFallbackKeychainIfNeeded(mocked: mocked, namespace: namespace) {
      _ = fallback.delete(keychainKey)
    }
  }
}
