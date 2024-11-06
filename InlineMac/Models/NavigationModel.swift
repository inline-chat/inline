import SwiftUI

enum Peer: Hashable, Codable {
    case user(id: Int64)
    case thread(id: Int64)
}

enum NavigationRoute: Hashable, Codable {
    case home
    case space(id: Int64)
    case chat(peer: Peer)
}

enum PrimarySheet: Codable {
    case createSpace
}

@MainActor
class NavigationModel: ObservableObject {
    @Published var path: [NavigationRoute] = []
    @Published var activeSpaceId: Int64?
    @Published var goingHome: Bool = false

    func navigate(to route: NavigationRoute) {
        path.append(route)
    }

    func openSpace(id: Int64) {
        goingHome = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.activeSpaceId = id
        }
    }

    func goHome() {
        goingHome = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.activeSpaceId = nil
        }
    }

    func navigateBack() {
        path.removeLast()
    }

    // MARK: - Sheets

    @Published var createSpaceSheetPresented: Bool = false
}
