import Combine
import Foundation
import KeychainSwift
import SwiftUI

public final class Auth: @unchecked Sendable {
    public static let shared = Auth()

    public var token: String?

    private let keychain = KeychainSwift()
    private var groupKey: String {
        #if os(macOS)
        return "2487AN8AL4.chat.inline"
        #elseif os(iOS)
        return "group.chat.inline"
        #endif
    }

    public func saveToken(_ token: String) {
        self.token = token
        keychain.set(token, forKey: groupKey)
    }

    public init() {
        token = keychain.get(groupKey)
    }
}
