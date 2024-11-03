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
        case chat(id: Int64, item: ChatItem?)
        case settings
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
