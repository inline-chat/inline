import Foundation

/// Pure path projection used by the iPad split binding. Keeping it independent
/// from SwiftUI makes the selection contract directly executable.
enum IPadNavigationProjection {
  static func sidebarSelection<Route>(
    in path: [Route],
    project: (Route) -> Route?
  ) -> Route? {
    path.last.flatMap(project)
  }

  /// Returns nil when a List write should not change navigation.
  static func pathReplacingSelection<Route: Equatable>(
    _ selection: Route?,
    currentPath: [Route],
    canonicalize: (Route) -> Route
  ) -> [Route]? {
    guard let selection else { return nil }
    let replacement = [canonicalize(selection)]
    return replacement == currentPath ? nil : replacement
  }

  static func detailPath<Route>(in path: [Route]) -> [Route] {
    Array(path.dropFirst())
  }
}
