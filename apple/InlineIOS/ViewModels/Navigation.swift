import SwiftUI

class Navigation: ObservableObject, @unchecked Sendable {
    static var shared = Navigation()

    enum Destination: Hashable {
        case welcome
        case email(prevEmail: String? = nil)
        case code(email: String)
        case main
        case addAccount(email: String)
        case space(id: Int64)
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
