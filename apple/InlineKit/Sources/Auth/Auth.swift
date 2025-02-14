import Combine
import Foundation
import KeychainSwift
import SwiftUI
import InlineConfig
import Logger

// Store userId and token and check is logged in
// TODO: Remove @unchecked
public final class Auth: ObservableObject, @unchecked Sendable {
  let log = Log.scoped("Auth")
  public static let shared = Auth()
  private var cachedToken: String?
  var cachedUserId: Int64?
  private let keychain: KeychainSwift
  private var accessGroup: String
  private var keyChainPrefix: String
  private let userDefaultsPrefix: String

  @Published public var isLoggedIn: Bool

  public func saveToken(_ token: String) {
    keychain.set(token, forKey: "token")
    cachedToken = token
    evaluateIsLoggedIn()
  }

  private func evaluateIsLoggedIn() {
    isLoggedIn =
      cachedToken != nil && cachedUserId != nil
  }

  public func getToken() -> String? {
    if cachedToken == nil {
      cachedToken = keychain.get("token")
    }

    return cachedToken
  }

  private init() {
    #if os(macOS)
    accessGroup = "2487AN8AL4.chat.inline.InlineMac"
    #if DEBUG
    keyChainPrefix = "inline_dev_"
    #else
    keyChainPrefix = "inline_"
    #endif
    #elseif os(iOS)
    accessGroup = "2487AN8AL4.keychainGroup"
    #if DEBUG
    keyChainPrefix = "inline_dev_"
    #else
    keyChainPrefix = ""
    #endif
    #endif

    // Check if user profile is set so we need to log in to another account
    if let userProfile = ProjectConfig.userProfile {
      log.debug("Using user profile \(userProfile)")
      keyChainPrefix = "\(keyChainPrefix)\(userProfile)_"
      userDefaultsPrefix = "\(userProfile)_"
    } else {
      userDefaultsPrefix = ""
    }

    keychain = KeychainSwift(keyPrefix: keyChainPrefix)
    keychain.accessGroup = accessGroup
    cachedToken = keychain.get("token")
    // temp so it doesn't error out
    isLoggedIn = false
    cachedUserId = getCurrentUserId()
    isLoggedIn = cachedToken != nil && cachedUserId != nil
  }

  private init(mockAuthenticated: Bool) {
    keychain = KeychainSwift()
    accessGroup = "2487AN8AL4.keychainGroup"
    keyChainPrefix = "mock"
    userDefaultsPrefix = "mock"

    if mockAuthenticated {
      cachedToken = "1:mockToken"
      cachedUserId = 1
    } else {
      cachedToken = nil
      cachedUserId = nil
      keychain.clear()
    }

    isLoggedIn = mockAuthenticated
  }

  var userIdKey: String {
    "\(userDefaultsPrefix)userId"
  }

  public func saveCurrentUserId(userId: Int64) {
    UserDefaults.standard.set(userId, forKey: userIdKey)
    cachedUserId = userId
    evaluateIsLoggedIn()
  }

  public func getCurrentUserId() -> Int64? {
    if let userId = cachedUserId {
      return userId
    } else {
      if UserDefaults.standard.object(forKey: userIdKey) != nil {
        let cachedUserId = Int64(UserDefaults.standard.integer(forKey: userIdKey))
        return cachedUserId
      }
    }
    return nil
  }

  //  public func getCurrentUserId() -> Int64? {
  //    if let userId = cachedUserId {
  //      return userId
  //    } else {
  //      let userId = Self.getCurrentUserId()
  //      cachedUserId = userId
  //      return userId
  //    }
  //  }

  public func logOut() {
    // clear userId
    UserDefaults.standard.removeObject(forKey: userIdKey)

    keychain.delete("token")

    cachedToken = nil
    cachedUserId = nil
    isLoggedIn = false
  }

  /// Used in previews
  public static func mocked(authenticated: Bool) -> Auth {
    Auth(mockAuthenticated: authenticated)
  }
}
