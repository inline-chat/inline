import Combine
import Foundation
import KeychainSwift
import SwiftUI

public final class Auth: @unchecked Sendable {
    public static let shared = Auth()
    private var cachedToken: String?
    private let keychain: KeychainSwift
    private var accessGroup: String

    public func saveToken(_ token: String?) {
        if let token = token {
            keychain.set(token, forKey: "token")
        } else {
            keychain.delete("token")
        }
        cachedToken = token
    }

    public func getToken() -> String? {
        if cachedToken == nil {
            cachedToken = keychain.get("token")
        }

        return cachedToken
    }

    private init() {
        accessGroup = "2487AN8AL4.keychainGroup"
        keychain = KeychainSwift()
        keychain.accessGroup = accessGroup
        cachedToken = keychain.get("token")
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
}
