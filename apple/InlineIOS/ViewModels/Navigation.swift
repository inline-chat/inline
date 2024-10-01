import SwiftUI

class Navigation: ObservableObject {
    enum Destination: Hashable {
        case welcome
        case email(prevEmail: String? = nil)
        case code(email: String)
    }

    @Published var path = NavigationPath()

    func push(_ destination: Destination) {
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
