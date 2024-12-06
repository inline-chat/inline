import Combine
import InlineKit
import SwiftUI

enum NavigationRoute: Hashable, Codable, Equatable {
  case homeRoot
  case spaceRoot
  case chat(peer: Peer)
  case chatInfo(peer: Peer)

  static func ==(lhs: NavigationRoute, rhs: NavigationRoute) -> Bool {
    switch (lhs, rhs) {
    case (.homeRoot, .homeRoot),
         (.spaceRoot, .spaceRoot):
      return true
    case let (.chat(lhsPeer), .chat(rhsPeer)):
      return lhsPeer == rhsPeer
    case let (.chatInfo(lhsPeer), .chatInfo(rhsPeer)):
      return lhsPeer == rhsPeer
    default:
      return false
    }
  }
}

enum PrimarySheet: Codable {
  case createSpace
}

// Persistent data
private struct NavigationState: Codable {
  var homePath: [NavigationRoute]
  var homeSelection: NavigationRoute
  var activeSpaceId: Int64?
  var spacePathDict: [Int64: [NavigationRoute]]
  var spaceSelectionDict: [Int64: NavigationRoute]
}

@MainActor
class NavigationModel: ObservableObject {
  static let shared = NavigationModel()

  @Published var homePath: [NavigationRoute] = []
  @Published var homeSelection: NavigationRoute = .homeRoot
  @Published var activeSpaceId: Int64?

  var currentHomeRoute: NavigationRoute {
    homePath.last ?? homeSelection
  }

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
    loadState()
    setupSubscriptions()
    setupStatePersistence()
  }

  private func setupSubscriptions() {
    $activeSpaceId
      .sink { [weak self] newValue in
        guard let self, let spaceId = newValue else { return }
        guard let w = self.windowManager, w.topLevelRoute == .main else { return }
        self.windowManager?.setUpForInnerRoute(self.spaceSelectionDict[spaceId] ?? .spaceRoot)
      }
      .store(in: &cancellables)

    $homePath.sink { [weak self] newValue in
      guard let self = self else { return }
      guard let w = self.windowManager, w.topLevelRoute == .main else { return }
      self.windowManager?.setUpForInnerRoute(newValue.last ?? self.homeSelection)
    }.store(in: &cancellables)
  }

  // Used from sidebars
  func select(_ route: NavigationRoute) {
    if let activeSpaceId {
      spaceSelectionDict[activeSpaceId] = route
      windowManager?.setUpForInnerRoute(route)
    } else {
      homeSelection = route
      homePath.removeAll()
      windowManager?.setUpForInnerRoute(route)
    }
  }

  func navigate(to route: NavigationRoute) {
    if let activeSpaceId {
      spacePathDict[activeSpaceId, default: []].append(route)
      windowManager?.setUpForInnerRoute(route)
    } else {
      homePath.append(route)
      windowManager?.setUpForInnerRoute(route)
    }
  }

  func openSpace(id: Int64) {
    activeSpaceId = id
    // TODO: Load from persistence layer
    if spacePathDict[id] == nil {
      spacePathDict[id] = []
      windowManager?.setUpForInnerRoute(.spaceRoot)
    }
  }

  func goHome() {
    activeSpaceId = nil
    // TODO: Load from persistence layer
    let currentHomeRoute = homePath.last ?? homeSelection
    windowManager?.setUpForInnerRoute(currentHomeRoute)
  }

  func navigateBack() {
    if let activeSpaceId {
      spacePathDict[activeSpaceId]?.removeLast()
      windowManager?.setUpForInnerRoute(spacePathDict[activeSpaceId]?.last ?? .spaceRoot)
    } else {
      homePath.removeLast()
      windowManager?.setUpForInnerRoute(homePath.last ?? homeSelection)
    }
  }

  private func setupStatePersistence() {
    // Combine publishers to watch for state changes
    Publishers.CombineLatest4($homePath, $homeSelection, $activeSpaceId, $spacePathDict)
      .combineLatest($spaceSelectionDict)
      .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.saveState()
      }
      .store(in: &cancellables)
  }

  // File URL for persistence
  private var stateFileURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("navigation_state.json")
  }

  private func saveState() {
    let state = NavigationState(
      homePath: homePath,
      homeSelection: homeSelection,
      activeSpaceId: activeSpaceId,
      spacePathDict: spacePathDict,
      spaceSelectionDict: spaceSelectionDict
    )

    do {
      let encoder = JSONEncoder()
      let data = try encoder.encode(state)
      try data.write(to: stateFileURL)
    } catch {
      Log.shared.error("Failed to save navigation state: \(error.localizedDescription)")
    }
  }

  private func loadState() {
    guard FileManager.default.fileExists(atPath: stateFileURL.path) else { return }

    do {
      let data = try Data(contentsOf: stateFileURL)
      let decoder = JSONDecoder()
      let state = try decoder.decode(NavigationState.self, from: data)

      // Update state
      homePath = state.homePath
      homeSelection = state.homeSelection
      activeSpaceId = state.activeSpaceId
      spacePathDict = state.spacePathDict
      spaceSelectionDict = state.spaceSelectionDict
    } catch {
      Log.shared.error("Failed to load navigation state: \(error.localizedDescription)")
      // If loading fails, reset to default state
      reset()
    }
  }

  // Called on logout
  func reset() {
    activeSpaceId = nil
    homePath = .init()
    spacePathDict = [:]
    spaceSelectionDict = [:]
    homeSelection = .homeRoot

    // Delete persisted state file
    try? FileManager.default.removeItem(at: stateFileURL)
  }

  var currentRoute: NavigationRoute {
    if let activeSpaceId {
      return spaceSelectionDict[activeSpaceId] ?? .spaceRoot
    } else {
      return homePath.last ?? homeSelection
    }
  }

  // MARK: - Sheets

  @Published var createSpaceSheetPresented: Bool = false
}
