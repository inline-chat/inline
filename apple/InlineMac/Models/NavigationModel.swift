import InlineKit
import SwiftUI

enum NavigationRoute: Hashable, Codable {
    case homeRoot
    case spaceRoot
    case chat(peer: Peer)
}

enum PrimarySheet: Codable {
    case createSpace
}

@MainActor
class NavigationModel: ObservableObject {
    @Published var homePath: NavigationPath = .init()
    @Published var activeSpaceId: Int64?
    
    @Published private var spacePathDict: [Int64: NavigationPath] = [:]
    @Published private var spaceSelectionDict: [Int64: NavigationRoute] = [:]
    
    var spacePath: Binding<NavigationPath> {
        Binding(
            get: { [weak self] in
                guard let self,
                      let activeSpaceId else { return NavigationPath() }
                return spacePathDict[activeSpaceId] ?? NavigationPath()
            },
            set: { [weak self] newValue in
                guard let self,
                      let activeSpaceId else { return }
                Task { @MainActor in
                    self.spacePathDict[activeSpaceId] = newValue
                }
            }
        )
    }
    
    var spaceSelection: Binding<NavigationRoute> {
        Binding(
            get: { [weak self] in
                guard let self,
                      let activeSpaceId else { return .spaceRoot }
                return spaceSelectionDict[activeSpaceId] ?? .spaceRoot
            },
            set: { [weak self] newValue in
                guard let self,
                      let activeSpaceId else { return }
                Task { @MainActor in
                    self.spaceSelectionDict[activeSpaceId] = newValue
                }
            }
        )
    }
    
    func navigate(to route: NavigationRoute) {
        if let activeSpaceId {
            spacePathDict[activeSpaceId, default: NavigationPath()].append(route)
        } else {
            homePath.append(route)
        }
    }
    
    func openSpace(id: Int64) {
        activeSpaceId = id
        // TODO: Load from persistence layer
        if spacePathDict[id] == nil {
            spacePathDict[id] = NavigationPath()
        }
    }
    
    func goHome() {
        activeSpaceId = nil
        // TODO: Load from persistence layer
    }
    
    func navigateBack() {
        if let activeSpaceId {
            spacePathDict[activeSpaceId]?.removeLast()
        } else {
            homePath.removeLast()
        }
    }
    
    // MARK: - Sheets
    
    @Published var createSpaceSheetPresented: Bool = false
}
