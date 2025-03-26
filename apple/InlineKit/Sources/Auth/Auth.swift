import AsyncAlgorithms
import Combine
import Foundation
import InlineConfig
import KeychainSwift
import Logger
import SwiftUI

public final class Auth: ObservableObject, @unchecked Sendable {
  public static let shared = Auth()

  // internals
  private let log = Log.scoped("Auth")
  private let authManager: AuthManager
  private let lock = NSLock()

  // state
  @Published public private(set) var isLoggedIn: Bool
  @Published public private(set) var currentUserId: Int64?
  @Published public private(set) var token: String?

  private var task: Task<Void, Never>?

  private init() {
    authManager = AuthManager.shared

    // Initialize isLoggedIn synchronously
    isLoggedIn = authManager.initialIsLoggedIn
    currentUserId = authManager.initialUserId
    token = authManager.initialToken
    task = nil

    // Listen to changes
    task = Task { [weak self] in
      guard let self else { return }

      for await isLoggedIn in await authManager.isLoggedIn {
        let newCUID = await authManager.getCurrentUserId()
        let newToken = await authManager.getToken()

        Task { @MainActor in
          self.lock.withLock {
            self.isLoggedIn = isLoggedIn
            self.currentUserId = newCUID
            self.token = newToken
          }
        }
      }
    }
  }

  init(mockAuthenticated: Bool) {
    authManager = AuthManager(mockAuthenticated: mockAuthenticated)

    isLoggedIn = authManager.initialIsLoggedIn
    currentUserId = authManager.initialUserId
    token = authManager.initialToken
  }

  public func getToken() -> String? {
    lock.withLock {
      token
    }
  }

  public func getIsLoggedIn() -> Bool? {
    lock.withLock {
      isLoggedIn
    }
  }

  public func getCurrentUserId() -> Int64? {
    lock.withLock {
      currentUserId
    }
  }

  public func getTokenAsync() async -> String? {
    await authManager.getToken()
  }

  public func getCurrentUserIdAsync() async -> Int64? {
    await authManager.getCurrentUserId()
  }

  public func saveCredentials(token: String, userId: Int64) async {
    await authManager.saveCredentials(token: token, userId: userId)
    await update()
  }

  public func logOut() async {
    await authManager.logOut()
    await update()
  }

  private func update() async {
    let newCUID = await authManager.getCurrentUserId()
    let newToken = await authManager.getToken()

    let task = Task { @MainActor in
      self.lock.withLock {
        self.currentUserId = newCUID
        self.token = newToken
        self.isLoggedIn = newToken != nil && newCUID != nil
      }
    }
    await task.value
  }

  /// Used in previews
  public static func mocked(authenticated: Bool) -> Auth {
    Auth(mockAuthenticated: authenticated)
  }

  public nonisolated static func getCurrentUserId() -> Int64? {
    AuthManager.getCurrentUserId()
  }
}

actor AuthManager: Sendable {
  public static var shared = AuthManager()

  private let log = Log.scoped("AuthManager")

  nonisolated let initialUserId: Int64?
  nonisolated let initialToken: String?
  nonisolated let initialIsLoggedIn: Bool

  // cache
  private var cachedUserId: Int64?
  private var cachedToken: String?

  // config
  private var accessGroup: String
  private var userDefaultsPrefix: String
  private var mocked: Bool = false

  // internals
  private let keychain: KeychainSwift

  // public
  public var isLoggedIn = AsyncChannel<Bool>()

  static func getUserDefaultsPrefix(mocked: Bool) -> String {
    if mocked { "mock" }
    else if let userProfile = ProjectConfig.userProfile {
      "\(userProfile)_"
    } else {
      ""
    }
  }

  init() {
    // Initialization logic from original Auth class
    #if os(macOS)
    accessGroup = "2487AN8AL4.chat.inline.InlineMac"
    #if DEBUG
    var keyChainPrefix = "inline_dev_"
    #else
    var keyChainPrefix = "inline_"
    #endif
    #elseif os(iOS)
    accessGroup = "2487AN8AL4.keychainGroup"
    #if DEBUG
    var keyChainPrefix = "inline_dev_"
    #else
    var keyChainPrefix = ""
    #endif
    #endif

    userDefaultsPrefix = Self.getUserDefaultsPrefix(mocked: false)
    if let userProfile = ProjectConfig.userProfile {
      log.debug("Using user profile \(userProfile)")
      keyChainPrefix = "\(keyChainPrefix)\(userProfile)_"
    }

    mocked = false
    keychain = KeychainSwift(keyPrefix: keyChainPrefix)
    keychain.accessGroup = accessGroup

    // load
    cachedToken = keychain.get("token")
    cachedUserId = UserDefaults.standard.value(forKey: "\(userDefaultsPrefix)userId") as? Int64

    // set initial values
    initialToken = cachedToken
    initialUserId = cachedUserId
    initialIsLoggedIn = initialToken != nil && initialUserId != nil

    Task {
      await self.updateLoginStatus()
    }
  }

  nonisolated static func getCurrentUserId() -> Int64? {
    UserDefaults.standard.value(forKey: "\(getUserDefaultsPrefix(mocked: false))userId") as? Int64
  }

  // Mock for testing/previews
  init(mockAuthenticated: Bool) {
    keychain = KeychainSwift(keyPrefix: "mock")
    accessGroup = "2487AN8AL4.keychainGroup"
    userDefaultsPrefix = Self.getUserDefaultsPrefix(mocked: true)
    mocked = true
    if mockAuthenticated {
      cachedToken = "1:mockToken"
      cachedUserId = 1
    } else {
      cachedToken = nil
      cachedUserId = nil
      keychain.clear()
    }

    // set initial values
    initialToken = cachedToken
    initialUserId = cachedUserId
    initialIsLoggedIn = initialToken != nil && initialUserId != nil

    Task {
      await self.updateLoginStatus()
    }
  }

  func saveCredentials(token: String, userId: Int64) async {
    // persist
    keychain.set(token, forKey: "token")
    UserDefaults.standard.set(userId, forKey: "\(userDefaultsPrefix)userId")

    // cache
    cachedToken = token
    cachedUserId = userId

    // publish
    await updateLoginStatus()
  }

  func getToken() -> String? {
    cachedToken
  }

  func getCurrentUserId() -> Int64? {
    cachedUserId
  }

  func logOut() async {
    // persist
    keychain.delete("token")
    UserDefaults.standard.removeObject(forKey: "\(userDefaultsPrefix)userId")

    // cache
    cachedToken = nil
    cachedUserId = nil

    // publish
    await updateLoginStatus()
  }

  private func updateLoginStatus() async {
    let loggedIn = cachedToken != nil && cachedUserId != nil
    await isLoggedIn.send(loggedIn)
  }
}
