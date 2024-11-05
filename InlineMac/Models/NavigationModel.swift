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
    
    func navigate(to route: NavigationRoute) {
        path.append(route)
    }
    
    func navigateBack() {
        path.removeLast()
    }
    
    
    // MARK: - Sheets
    @Published var createSpaceSheetPresented: Bool = false
}
