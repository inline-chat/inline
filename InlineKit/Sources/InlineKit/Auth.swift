import Combine
import Foundation
import KeychainSwift
import SwiftUI

// TODO: Remove @unchecked
public final class Auth: ObservableObject, @unchecked Sendable {
  public static let shared = Auth()
  private var cachedToken: String?
  private var cachedUserId: Int64?
  private let keychain: KeychainSwift
  private var accessGroup: String
  private var keyChainPrefix: String

  @Published public var isLoggedIn: Bool

  public func saveToken(_ token: String) {
    keychain.set(token, forKey: "token")
    cachedToken = token
    evaluateIsLoggedIn()
  }

  private func evaluateIsLoggedIn() {
    isLoggedIn = cachedToken != nil && cachedUserId != nil
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
    #else
      accessGroup = "2487AN8AL4.keychainGroup"
      keyChainPrefix = ""
    #endif
    keychain = KeychainSwift(keyPrefix: keyChainPrefix)
    keychain.accessGroup = accessGroup
    cachedToken = keychain.get("token")
    cachedUserId = Self.getCurrentUserId()

    isLoggedIn = cachedToken != nil && cachedUserId != nil
  }

  private init(mockAuthenticated: Bool) {
    keychain = KeychainSwift()
    accessGroup = "2487AN8AL4.keychainGroup"
    keyChainPrefix = "mock"

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

  public func saveCurrentUserId(userId: Int64) {
    UserDefaults.standard.set(userId, forKey: "userId")
    cachedUserId = userId
    evaluateIsLoggedIn()
  }

  static func getCurrentUserId() -> Int64? {
    let userDefaultsKey = "userId"
    if UserDefaults.standard.object(forKey: userDefaultsKey) != nil {
      return Int64(UserDefaults.standard.integer(forKey: userDefaultsKey))
    }
    return nil
  }

  public func getCurrentUserId() -> Int64? {
    if let userId = cachedUserId {
      return userId
    } else {
      let userId = Self.getCurrentUserId()
      cachedUserId = userId
      return userId
    }
  }

  public func logOut() {
    // clear userId
    UserDefaults.standard.removeObject(forKey: "userId")

    // clear token
    keychain.delete("token")

    // clear cache
    cachedToken = nil
    cachedUserId = nil
    isLoggedIn = false
  }

  /// Used in previews
  public static func mocked(authenticated: Bool) -> Auth {
    Auth(mockAuthenticated: authenticated)
  }
}
