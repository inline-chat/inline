import Foundation
import InlineConfig
import KeychainSwift
import Security

enum KeychainReadOutcome<Value> {
  case success(Value, usedFallback: Bool)
  case notFound(status: OSStatus)
  case interactionNotAllowed(status: OSStatus)
  case error(status: OSStatus)

  var status: OSStatus {
    switch self {
    case .success: noErr
    case .notFound(let status): status
    case .interactionNotAllowed(let status): status
    case .error(let status): status
    }
  }
}

enum AuthKeychainConfig {
  static func userDefaultsPrefix(mocked: Bool, namespace: String? = nil) -> String {
    if mocked {
      if let namespace, !namespace.isEmpty {
        return "mock_\(namespace)_"
      }
      return "mock"
    }
    else if let userProfile = ProjectConfig.userProfile { return "\(userProfile)_" }
    else { return "" }
  }

  static func keychainPrefix(mocked: Bool, namespace: String? = nil) -> String {
    if mocked {
      if let namespace, !namespace.isEmpty {
        return "mock_\(namespace)_"
      }
      return "mock"
    }

    #if os(macOS)
    #if DEBUG
    var prefix = "inline_dev_"
    #else
    var prefix = "inline_"
    #endif
    #elseif os(iOS)
    #if DEBUG
    var prefix = "inline_dev_"
    #else
    var prefix = ""
    #endif
    #endif

    if let userProfile = ProjectConfig.userProfile {
      prefix = "\(prefix)\(userProfile)_"
    }

    return prefix
  }

  static func primaryAccessGroup(mocked: Bool) -> String? {
    guard mocked == false else { return nil }
    #if os(macOS)
    return "2487AN8AL4.chat.inline.InlineMac"
    #elseif os(iOS)
    return "2487AN8AL4.keychainGroup"
    #else
    return nil
    #endif
  }

  static func makePrimaryKeychain(mocked: Bool, namespace: String? = nil) -> KeychainSwift {
    let keychain = KeychainSwift(keyPrefix: keychainPrefix(mocked: mocked, namespace: namespace))
    if let accessGroup = primaryAccessGroup(mocked: mocked) {
      keychain.accessGroup = accessGroup
    }
    return keychain
  }

  static func makeFallbackKeychainIfNeeded(mocked: Bool, namespace: String? = nil) -> KeychainSwift? {
    guard mocked == false else { return nil }
    #if os(macOS)
    // Legacy macOS builds stored items without setting a keychain access group.
    return KeychainSwift(keyPrefix: keychainPrefix(mocked: mocked, namespace: namespace))
    #else
    return nil
    #endif
  }

  static func osStatusMessage(_ status: OSStatus) -> String {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus(\(status))"
  }

  static func readData(_ key: String, primary: KeychainSwift, fallback: KeychainSwift?) -> KeychainReadOutcome<Data> {
    if let data = primary.getData(key) {
      return .success(data, usedFallback: false)
    }

    let primaryStatus = primary.lastResultCode

    // If a fallback keychain exists (macOS legacy), attempt it whenever the primary doesn't succeed.
    // This makes upgrades more resilient (e.g. access-group changes, temporary primary errors).
    if let fallback {
      if let data = fallback.getData(key) {
        return .success(data, usedFallback: true)
      }

      let fallbackStatus = fallback.lastResultCode

      if primaryStatus == errSecInteractionNotAllowed || primaryStatus == errSecNotAvailable {
        return .interactionNotAllowed(status: primaryStatus)
      }
      if fallbackStatus == errSecInteractionNotAllowed || fallbackStatus == errSecNotAvailable {
        return .interactionNotAllowed(status: fallbackStatus)
      }

      if primaryStatus == errSecItemNotFound && fallbackStatus == errSecItemNotFound {
        return .notFound(status: fallbackStatus)
      }

      // Prefer the fallback status when it yields a more specific error than "not found".
      if fallbackStatus != errSecItemNotFound {
        return .error(status: fallbackStatus)
      }

      if primaryStatus == errSecItemNotFound {
        return .notFound(status: primaryStatus)
      }

      return .error(status: primaryStatus)
    }

    if primaryStatus == errSecInteractionNotAllowed || primaryStatus == errSecNotAvailable {
      return .interactionNotAllowed(status: primaryStatus)
    }
    if primaryStatus == errSecItemNotFound {
      return .notFound(status: primaryStatus)
    }
    return .error(status: primaryStatus)
  }

  static func readString(_ key: String, primary: KeychainSwift, fallback: KeychainSwift?) -> KeychainReadOutcome<String> {
    switch readData(key, primary: primary, fallback: fallback) {
    case .success(let data, let usedFallback):
      if let string = String(data: data, encoding: .utf8) {
        return .success(string, usedFallback: usedFallback)
      }
      return .error(status: errSecInvalidEncoding)

    case .notFound(let status):
      return .notFound(status: status)

    case .interactionNotAllowed(let status):
      return .interactionNotAllowed(status: status)

    case .error(let status):
      return .error(status: status)
    }
  }
}
