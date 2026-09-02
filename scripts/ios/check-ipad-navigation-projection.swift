// Compile against the production projection helper; no app, build, or simulator required.
// xcrun swiftc -parse-as-library apple/InlineIOS/Navigation/IPadNavigationProjection.swift \
//   scripts/ios/check-ipad-navigation-projection.swift -o /tmp/inline-ipad-projection-check
import Foundation

private enum Route: Equatable {
  case chat(Int)
  case message(Int, Int)
  case external(Int, Int)
  case info(Int)
  case settings
}

@main
private struct IPadNavigationProjectionChecks {
  private static var checks = 0

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
  }

  private static func sidebarRoute(_ route: Route) -> Route? {
    switch route {
    case let .chat(peer), let .message(peer, _), let .external(peer, _), let .info(peer):
      .chat(peer)
    case .settings:
      nil
    }
  }

  private static func canonicalRoute(_ route: Route) -> Route {
    sidebarRoute(route) ?? route
  }

  static func main() {
    check(
      IPadNavigationProjection.sidebarSelection(
        in: [.chat(1), .chat(2)],
        project: sidebarRoute
      ) == .chat(2),
      "Visible route owns selection"
    )
    check(
      IPadNavigationProjection.sidebarSelection(
        in: [.message(2, 42)],
        project: sidebarRoute
      ) == .chat(2),
      "Focused messages preserve conversation selection"
    )
    check(
      IPadNavigationProjection.sidebarSelection(
        in: [.chat(2), .info(2)],
        project: sidebarRoute
      ) == .chat(2),
      "Chat Info preserves conversation selection"
    )
    check(
      IPadNavigationProjection.sidebarSelection(
        in: [.chat(2), .settings],
        project: sidebarRoute
      ) == nil,
      "A visible non-chat page does not leave a stale row selected"
    )
    check(
      IPadNavigationProjection.pathReplacingSelection(
        .chat(2),
        currentPath: [.chat(2), .info(2)],
        canonicalize: canonicalRoute
      ) == [.chat(2)],
      "Reselecting a nested conversation returns to its base route"
    )
    check(
      IPadNavigationProjection.pathReplacingSelection(
        .chat(2),
        currentPath: [.message(2, 42)],
        canonicalize: canonicalRoute
      ) == [.chat(2)],
      "Reselecting clears focused-message metadata intentionally"
    )
    check(
      IPadNavigationProjection.pathReplacingSelection(
        .chat(2),
        currentPath: [.chat(2)],
        canonicalize: canonicalRoute
      ) == nil,
      "Selecting the exact base route is a no-op"
    )
    check(
      IPadNavigationProjection.pathReplacingSelection(
        nil,
        currentPath: [.chat(2)],
        canonicalize: canonicalRoute
      ) == nil,
      "Transient List nil never clears detail"
    )
    check(
      IPadNavigationProjection.pathReplacingSelection(
        .chat(3),
        currentPath: [.chat(2), .info(2)],
        canonicalize: canonicalRoute
      ) == [.chat(3)],
      "A different row replaces the whole detail route"
    )
    check(
      IPadNavigationProjection.detailPath(in: [Route.chat(1), .info(1)]) == [.info(1)],
      "The native detail stack receives only the route suffix"
    )
    print("\(checks) iPad navigation projection checks passed against the production helper")
  }
}
