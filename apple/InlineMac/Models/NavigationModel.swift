import InlineKit
import SwiftUI
import Combine

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
    
  static let shared = NavigationModel()
  
  @Published var homePath: [NavigationRoute] = []
  @Published var activeSpaceId: Int64?

  @Published private var spacePathDict: [Int64: [NavigationRoute]] = [:]
  @Published private var spaceSelectionDict: [Int64: NavigationRoute] = [:]
  
  public var windowManager: MainWindowViewModel?

  var spacePath: Binding<[NavigationRoute]> {
    Binding(
      get: { [weak self] in
        guard let self,
          let activeSpaceId
        else { return [] }
        return spacePathDict[activeSpaceId] ?? []
      },
      set: { [weak self] newValue in
        guard let self,
          let activeSpaceId
        else { return }
        Task { @MainActor in
          self.spacePathDict[activeSpaceId] = newValue
          self.windowManager?.setUpForInnerRoute(newValue.last ?? .spaceRoot)
        }
      }
    )
  }

  var spaceSelection: Binding<NavigationRoute> {
    Binding(
      get: { [weak self] in
        guard let self,
          let activeSpaceId
        else { return .spaceRoot }
        return spaceSelectionDict[activeSpaceId] ?? .spaceRoot
      },
      set: { [weak self] newValue in
        guard let self,
          let activeSpaceId
        else { return }
        Task { @MainActor in
          self.spaceSelectionDict[activeSpaceId] = newValue
          self.windowManager?.setUpForInnerRoute(newValue)
        }
      }
    )
  }
  
  private var cancellables = Set<AnyCancellable>()
  
  init() {
    setupSubscriptions()
  }
  
  private func setupSubscriptions() {
    $activeSpaceId
      .sink { [weak self] newValue in
        guard let self, let spaceId = newValue else { return }
        self.windowManager?.setUpForInnerRoute(self.spaceSelectionDict[spaceId] ?? .spaceRoot)
      }
      .store(in: &cancellables)
  }
  
  
  // Used from sidebars
  func select(_ route: NavigationRoute) {
    if let activeSpaceId {
      spaceSelectionDict[activeSpaceId] = route
      self.windowManager?.setUpForInnerRoute(route)
    } else {
      // todo
    }
  }

  func navigate(to route: NavigationRoute) {
    if let activeSpaceId {
      spacePathDict[activeSpaceId, default: []].append(route)
      self.windowManager?.setUpForInnerRoute(route)
    } else {
      homePath.append(route)
      self.windowManager?.setUpForInnerRoute(route)
    }
  }

  func openSpace(id: Int64) {
    activeSpaceId = id
    // TODO: Load from persistence layer
    if spacePathDict[id] == nil {
      spacePathDict[id] = []
      self.windowManager?.setUpForInnerRoute(.spaceRoot)
    }
  }

  func goHome() {
    activeSpaceId = nil
    // TODO: Load from persistence layer
    self.windowManager?.setUpForInnerRoute(.homeRoot)
  }

  func navigateBack() {
    if let activeSpaceId {
      spacePathDict[activeSpaceId]?.removeLast()
      self.windowManager?.setUpForInnerRoute(spacePathDict[activeSpaceId]?.last ?? .spaceRoot)
    } else {
      homePath.removeLast()
      self.windowManager?.setUpForInnerRoute(homePath.last ?? .homeRoot)
    }
  }

  // Called on logout
  func reset() {
    activeSpaceId = nil
    homePath = .init()
    spacePathDict = [:]
    spaceSelectionDict = [:]
  }
  
  var currentRoute: NavigationRoute {
    if let activeSpaceId {
      return spaceSelectionDict[activeSpaceId] ?? .spaceRoot
    } else {
      return homePath.last ?? .homeRoot
    }
  }

  // MARK: - Sheets

  @Published var createSpaceSheetPresented: Bool = false
}
