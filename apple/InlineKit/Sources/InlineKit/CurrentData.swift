import Combine
import Foundation
import KeychainSwift
import SwiftUI

public final class Auth: @unchecked Sendable {
    public static let shared = Auth()
    private var cachedToken: String?
    private let keychain = KeychainSwift()
    private let groupKey: String = "2487AN8AL4.keychainGroup"

    public func saveToken(_ token: String?) {
        if let token = token {
            keychain.set(token, forKey: groupKey)
        } else {
            keychain.delete(groupKey)
        }
        cachedToken = token
    }

    public func getToken() -> String? {
        if cachedToken == nil {
            print("Getting token")
            cachedToken = keychain.get(groupKey)
            print("Got token \(cachedToken)")
        }
        print("CachedToken \(cachedToken)")
        return cachedToken
    }

    private init() {
        cachedToken = keychain.get(groupKey)
    }
}
