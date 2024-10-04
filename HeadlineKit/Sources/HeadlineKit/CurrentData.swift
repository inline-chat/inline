import Combine
import Foundation
import KeychainSwift
import SwiftUI

public final class Auth: @unchecked Sendable {
    public static let shared = Auth()
    private var cachedToken: String?
    private let keychain = KeychainSwift()
    private var groupKey: String = "2487AN8AL4.keychainGroup"

    public func saveToken(_ token: String?) {
        cachedToken = token

        /// In logout, the token will be nil, and the keychain does not get nil data, so it keeps the token. The cachedToken is always a token after the first login, and by adding "if let" here, we just keep it always full (not nil). If the token was nil, we should delete it so that cachedToken is empty and we can return to the root path because we return cachedToken in the getToken function.
        if let token = token {
            keychain.set(token, forKey: groupKey)
        } else {
            keychain.delete(groupKey)
        }
    }

    public func getToken() -> String? {
        return cachedToken
    }

    private init() {
        cachedToken = keychain.get(groupKey)
    }
}
