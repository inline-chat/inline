import InlineKit
import SwiftUI

@MainActor
class Navigation: ObservableObject, @unchecked Sendable {
  static let shared = Navigation()

  // MARK: - Destinations

  enum Destination: Identifiable, Hashable {
    case main
    case space(id: Int64)
    case chat(peer: Peer)
    case settings
    case createSpace
    case createThread(spaceId: Int64)
    case archivedChats

    // MARK: - Identifiable Conformance

    var id: String {
      switch self {
        case .main: "main"
        case let .space(id): "space-\(id)"
        case let .chat(peer): "chat-\(peer.hashValue)"
        case .settings: "settings"
        case .createSpace: "createSpace"
        case let .createThread(spaceId): "createThread-\(spaceId)"
        case .archivedChats: "archivedChats"
      }
    }
  }

  // MARK: - Published Properties

  @Published private var navigationPath = NavigationPath()
  @Published var activeSheet: Destination?
  @Published var activeDestination: Destination?

  // MARK: - Computed Properties

  var currentStack: NavigationPath {
    navigationPath
  }

  var currentStackBinding: Binding<NavigationPath> {
    Binding(
      get: { self.navigationPath },
      set: { self.navigationPath = $0 }
    )
  }

  // MARK: - Navigation Actions

  func push(_ destination: Destination) {
    switch destination {
      case .chat:
        activeDestination = destination
        navigationPath.append(destination)
      case .createSpace, .createThread:
        activeSheet = destination
      default:
        activeDestination = destination
        navigationPath.append(destination)
    }
  }

  func popPush(_ destination: Destination) {
    activeDestination = destination
    navigationPath = NavigationPath()
    navigationPath.append(destination)
  }

  func popToRoot() {
    navigationPath = NavigationPath()
    activeSheet = nil
  }

  func pop() {
    guard !navigationPath.isEmpty else { return }
    withAnimation(.snappy) {
      navigationPath.removeLast()
    }
  }

  func dismissSheet() {
    activeSheet = nil
  }

  // MARK: - Reset

  func reset() {
    navigationPath = NavigationPath()
    activeSheet = nil
    activeDestination = .main
  }
}
