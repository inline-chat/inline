import UIKit

/// One gate for every source of iPad split-view navigation. Compact iPad
/// windows stay in this lane; iPhone and pre-iPadOS 26 retain the phone UI.
@MainActor
enum IPadNavigationLane {
  static let canonicalTab = AppTab.allChats
  static let routeBuckets = AppTab.allCases

  static var isEnabled: Bool {
    guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
    if #available(iOS 26.0, *) {
      return true
    }
    return false
  }

  static func normalizeRestoredState(in router: Router) {
    let visiblePath = router.selectedTabPath
    let hasHiddenPath = routeBuckets.contains { tab in
      tab != canonicalTab && !router[tab].isEmpty
    }
    guard router.selectedTab != canonicalTab || hasHiddenPath else { return }
    router.resetNavigationBoundary(
      pathsFor: routeBuckets,
      selecting: canonicalTab,
      path: visiblePath
    )
  }

  static func resetBoundary(in router: Router, path: [Destination] = []) {
    router.resetNavigationBoundary(
      pathsFor: routeBuckets,
      selecting: canonicalTab,
      path: path
    )
  }
}
