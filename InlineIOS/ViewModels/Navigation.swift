import InlineKit
import SwiftUI

class Navigation: ObservableObject, @unchecked Sendable {
    static var shared = Navigation()

    enum Destination: Hashable, Equatable {
        case welcome
        case email(prevEmail: String? = nil)
        case code(email: String)
        case main
        case addAccount
        case space(id: Int64)
        case chat(peer: Peer)
        case settings
        
        func hash(into hasher: inout Hasher) {
            switch self {
            case .welcome:
                hasher.combine(0)
            case .email(let prevEmail):
                hasher.combine(1)
                hasher.combine(prevEmail)
            case .code(let email):
                hasher.combine(2)
                hasher.combine(email)
            case .main:
                hasher.combine(3)
            case .addAccount:
                hasher.combine(4)
            case .space(let id):
                hasher.combine(5)
                hasher.combine(id)
            case .chat(let peer):
                hasher.combine(6)
                hasher.combine(peer)
            case .settings:
                hasher.combine(7)
            }
        }
        
        static func == (lhs: Destination, rhs: Destination) -> Bool {
            switch (lhs, rhs) {
            case (.welcome, .welcome):
                return true
            case (.email(let lhsEmail), .email(let rhsEmail)):
                return lhsEmail == rhsEmail
            case (.code(let lhsEmail), .code(let rhsEmail)):
                return lhsEmail == rhsEmail
            case (.main, .main):
                return true
            case (.addAccount, .addAccount):
                return true
            case (.space(let lhsId), .space(let rhsId)):
                return lhsId == rhsId
            case (.chat(let lhsPeer), .chat(let rhsPeer)):
                return lhsPeer == rhsPeer
            case (.settings, .settings):
                return true
            default:
                return false
            }
        }
    }

    @Published var path = NavigationPath()

    var activeDestination: Destination = .welcome
    func push(_ destination: Destination) {
        activeDestination = destination
        path.append(destination)
    }

    func popToRoot() {
        path.removeLast(path.count)
    }

    func pop() {
        if !path.isEmpty {
            path.removeLast()
        }
    }
}
