import Combine
import Foundation
import KeychainSwift
import SwiftUI

public final class Auth: @unchecked Sendable {
    public static let shared = Auth()
    private var cachedToken: String?
    private var cachedUserId: Int64?
    private let keychain: KeychainSwift
    private var accessGroup: String
    private var keyChainPrefix: String

    public func saveToken(_ token: String) {
        keychain.set(token, forKey: "token")
        cachedToken = token
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
        cachedUserId = getCurrentUserId()
    }

public var isLoggedIn: Bool {
        (cachedToken != nil) && (cachedUserId != nil)
    }

    public func saveCurrentUserId(userId: Int64) {
        UserDefaults.standard.set(userId, forKey: "userId")
    }

    public func getCurrentUserId() -> Int64? {
        let userDefaultsKey = "userId"
        if UserDefaults.standard.object(forKey: userDefaultsKey) != nil {
            return Int64(UserDefaults.standard.integer(forKey: userDefaultsKey))
        }
        return nil
    }

    public func logOut() {
        // clear userId
        UserDefaults.standard.removeObject(forKey: "userId")

        // clear token
        keychain.delete("token")

        // clear cache
        cachedToken = nil
        cachedUserId = nil
    }
}
