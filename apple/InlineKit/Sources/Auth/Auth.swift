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

  /// True when the current process has observed a token (or determined none is available) at least once after launch.
  /// Used to distinguish "no token yet" vs "definitely logged out" in callers that want to wait for credential
  /// hydration.
  @Published public private(set) var didHydrateCredentials: Bool = false

  // state
  @Published public private(set) var isLoggedIn: Bool
  @Published public private(set) var currentUserId: Int64?
  @Published public private(set) var token: String?

  public var events: AsyncChannel<AuthEvent>

  private var task: Task<Void, Never>?

  private init() {
    authManager = AuthManager.shared

    // Initialize isLoggedIn synchronously
    isLoggedIn = authManager.initialIsLoggedIn
    currentUserId = authManager.initialUserId
    token = authManager.initialToken
    task = nil

    events = AsyncChannel<AuthEvent>()

    // Listen to changes
    task = Task { [weak self] in
      guard let self else { return }

      for await isLoggedIn in await authManager.isLoggedIn {
        let newCUID = await authManager.getCurrentUserId()
        let newToken = await authManager.getToken()
        let didHydrateCredentials = await authManager.getDidHydrateCredentials()

        Task { @MainActor in
          self.lock.withLock {
            self.isLoggedIn = isLoggedIn
            self.currentUserId = newCUID
            self.token = newToken
            self.didHydrateCredentials = didHydrateCredentials
          }
        }

        if isLoggedIn {
          if let userId = newCUID, let token = newToken {
            await events.send(.login(
              userId: userId,
              token: token
            ))
          } else {
            // This is a key signal for diagnosing "app looks logged-in but can't connect" issues.
            // Do not log the token itself (sensitive).
            log.warning(
              "AUTH_LOGGED_IN_WITHOUT_CREDENTIALS userIdPresent=\(newCUID != nil ? 1 : 0) tokenPresent=\(newToken != nil ? 1 : 0)"
            )
          }
        } else {
          await events.send(.logout)
        }
      }
    }
  }

  init(mockAuthenticated: Bool) {
    authManager = AuthManager(mockAuthenticated: mockAuthenticated)

    isLoggedIn = authManager.initialIsLoggedIn
    currentUserId = authManager.initialUserId
    token = authManager.initialToken

    events = AsyncChannel<AuthEvent>()
  }

  public func getToken() -> String? {
    // Always access `token` under lock to ensure visibility across threads.
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
    log.info("AUTH_SAVE_CREDENTIALS called userId=\(userId)")
    await authManager.saveCredentials(token: token, userId: userId)
    await update()
  }

  public func logOut() async {
    log.info("AUTH_LOGOUT called")
    Task { @MainActor in
      isLoggedIn = false
      currentUserId = nil
      token = nil
      didHydrateCredentials = true
    }
    await authManager.logOut()
    await update()
  }

  /// Re-reads token/userId from persistent storage (keychain + user defaults) and publishes updated state.
  ///
  /// This is primarily used to recover from iOS early-launch / background launches where keychain reads can
  /// transiently return `nil` (e.g. protected data unavailable).
  public func refreshFromStorage() async {
    await authManager.reloadFromStorage()
    await update()
  }

  private func update() async {
    let newCUID = await authManager.getCurrentUserId()
    let newToken = await authManager.getToken()
    let didHydrateCredentials = await authManager.getDidHydrateCredentials()

    let task = Task { @MainActor in
      self.lock.withLock {
        self.currentUserId = newCUID
        self.token = newToken
        self.isLoggedIn = newCUID != nil
        self.didHydrateCredentials = didHydrateCredentials
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
  static let shared = AuthManager()

  private let log = Log.scoped("AuthManager")

  nonisolated let initialUserId: Int64?
  nonisolated let initialToken: String?
  nonisolated let initialIsLoggedIn: Bool

  // cache
  private var cachedUserId: Int64?
  private var cachedToken: String?
  private var userDefaultsKey: String
  private var didHydrateCredentials: Bool = false
  private var didLogMissingTokenForLoggedInUser: Bool = false

  // config
  private var accessGroup: String
  private var userDefaultsPrefix: String
  private var mocked: Bool = false

  // internals
  private let keychain: KeychainSwift

  // public
  var isLoggedIn = AsyncChannel<Bool>()

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

    #if os(iOS)
    keychain.accessGroup = accessGroup
    #endif

    userDefaultsKey = "\(userDefaultsPrefix)userId"
    // load
    cachedToken = keychain.get("token")
    cachedUserId = Self.readUserId(key: userDefaultsKey)
    didHydrateCredentials = true
    if cachedUserId != nil, cachedToken == nil {
      // Captured to Sentry as a warning so we can monitor how often this happens in production.
      // Usually indicates keychain / protected data unavailable during early/background launch.
      log.warning("AUTH_TOKEN_MISSING_FOR_LOGGED_IN_USER phase=init userIdPresent=1 tokenPresent=0")
      didLogMissingTokenForLoggedInUser = true
    }

    // set initial values
    initialToken = cachedToken
    initialUserId = cachedUserId
    // During early launch keychain reads can fail; consider a stored userId as logged in for routing.
    initialIsLoggedIn = initialUserId != nil

    Task {
      await self.updateLoginStatus()
      // Try to recover token/userId if keychain was temporarily unavailable during init.
      await self.refreshKeychainAfterLaunch()
    }
  }

  nonisolated static func getCurrentUserId() -> Int64? {
    readUserId(key: "\(getUserDefaultsPrefix(mocked: false))userId")
  }

  // Mock for testing/previews
  init(mockAuthenticated: Bool) {
    keychain = KeychainSwift(keyPrefix: "mock")
    accessGroup = "2487AN8AL4.keychainGroup"
    userDefaultsPrefix = Self.getUserDefaultsPrefix(mocked: true)
    userDefaultsKey = "\(userDefaultsPrefix)userId"
    mocked = true
    if mockAuthenticated {
      cachedToken = "1:mockToken"
      cachedUserId = 1
    } else {
      cachedToken = nil
      cachedUserId = nil
      keychain.clear()
    }
    didHydrateCredentials = true

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
    // Use after-first-unlock so background launches (e.g. notification taps / background fetch) can read the token.
    // Without this, keychain reads may return `nil` in those launches, leaving the app "logged in" without a token.
    let didSaveToken = keychain.set(token, forKey: "token", withAccess: .accessibleAfterFirstUnlock)
    Self.writeUserId(userId, key: userDefaultsKey)
    log.info("AUTH_SAVE_CREDENTIALS persisted userId=\(userId) tokenSaved=\(didSaveToken ? 1 : 0)")

    // cache
    cachedToken = token
    cachedUserId = userId
    didHydrateCredentials = true
    didLogMissingTokenForLoggedInUser = false

    // publish
    await updateLoginStatus()
  }

  func getToken() -> String? {
    cachedToken
  }

  func getCurrentUserId() -> Int64? {
    cachedUserId
  }

  func getDidHydrateCredentials() -> Bool {
    didHydrateCredentials
  }

  func logOut() async {
    // persist
    let didDeleteToken = keychain.delete("token")
    UserDefaults.standard.removeObject(forKey: userDefaultsKey)

    // cache
    cachedToken = nil
    cachedUserId = nil
    didHydrateCredentials = true
    didLogMissingTokenForLoggedInUser = false

    log.info("AUTH_LOGOUT persisted tokenDeleted=\(didDeleteToken ? 1 : 0)")

    // publish
    await updateLoginStatus()
  }

  /// Re-read keychain + user defaults and update caches.
  ///
  /// This is safe to call repeatedly; it only publishes if values change.
  func reloadFromStorage() async {
    let refreshedToken = keychain.get("token")
    let refreshedUserId = Self.readUserId(key: userDefaultsKey)

    didHydrateCredentials = true

    var changed = false

    if refreshedToken != cachedToken {
      cachedToken = refreshedToken
      changed = true
    }

    if refreshedUserId != cachedUserId {
      cachedUserId = refreshedUserId
      changed = true
    }

    // If we can read a token, re-save it with after-first-unlock accessibility to prevent future background failures.
    if let token = refreshedToken {
      _ = keychain.set(token, forKey: "token", withAccess: .accessibleAfterFirstUnlock)
      didLogMissingTokenForLoggedInUser = false
    } else if refreshedUserId != nil, !didLogMissingTokenForLoggedInUser {
      // Only log once per "missing token while logged in" episode to avoid spamming Sentry.
      log.warning("AUTH_TOKEN_MISSING_FOR_LOGGED_IN_USER phase=reload userIdPresent=1 tokenPresent=0")
      didLogMissingTokenForLoggedInUser = true
    }

    if changed {
      await updateLoginStatus()
    }
  }

  private func updateLoginStatus() async {
    let loggedIn = cachedUserId != nil

    // Use Task to make this non-blocking
    Task {
      await isLoggedIn.send(loggedIn)
    }
  }

  /// Keychain can be unavailable right at startup; re-read after a brief delay so token is picked up.
  private func refreshKeychainAfterLaunch() async {
    // Keep this simple: a single delayed re-read handles common "keychain not ready at init" cases.
    // Longer recovery (e.g. device unlock after background notification launch) is handled by the iOS app hook
    // calling `Auth.refreshFromStorage()` on protected-data availability.
    guard cachedUserId != nil, cachedToken == nil else { return }
    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
    await reloadFromStorage()
  }

  private static func readUserId(key: String) -> Int64? {
    // UserDefaults bridges numeric values as NSNumber on iOS; cast safely.
    guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else {
      return nil
    }
    return number.int64Value
  }

  private static func writeUserId(_ userId: Int64, key: String) {
    UserDefaults.standard.set(NSNumber(value: userId), forKey: key)
  }
}

public enum AuthEvent: Sendable {
  case login(userId: Int64, token: String)
  case logout
}
