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

    public func saveCurrentUserId(userId: String) {
        UserDefaults.standard.set(userId, forKey: "userId")
    }

    public func getCurrentUserId(userId: String) -> String? {
        return UserDefaults.standard.string(forKey: userId)
    }
}
