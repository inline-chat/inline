// Compile with the real Router.swift and Protocols.swift; no app or packages required.
// xcrun swiftc -parse-as-library apple/InlineIOS/Navigation/{Protocols,Router}.swift \
//   scripts/ios/check-navigation-history.swift -o /tmp/inline-navigation-history-check
import Foundation

private enum TestTab: String, TabType {
  case home, inbox
  var id: String { rawValue }
  var icon: String { "circle" }
}

private enum TestRoute: DestinationType {
  case chat(Int), info(Int), message(Int, Int), external(Int, Int, Int)
}

private enum TestSheet: String, SheetType {
  case settings
  var id: String { rawValue }
}

@main
private struct NavigationHistoryChecks {
  @MainActor private static func router(tracking: Bool = true) -> NavigationModel<TestTab, TestRoute, TestSheet> {
    let router = NavigationModel<TestTab, TestRoute, TestSheet>(
      initialTab: .home,
      defaults: UserDefaults(suiteName: "NavigationHistoryChecks.\(UUID().uuidString)")!,
      keyPrefix: "test",
      persistence: .externallyManaged,
      restoresPersistedState: false
    )
    router.tracksHistory = tracking
    return router
  }

  @MainActor private static var checks = 0

  @MainActor private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
  }

  @MainActor static func main() throws {
    phoneCompatibility()
    routeVisits()
    nativeNavigation()
    try externalRoutesAndLifecycle()
    invalidDestinations()
    replacementAndBoundaries()
    boundedHistory()
    print("\(checks) navigation history checks passed against the real Router.swift")
  }

  @MainActor private static func phoneCompatibility() {
    let phone = router(tracking: false)
    phone.push(.chat(1))
    phone.push(.info(1))
    phone.goBack()
    check(phone.selectedTabPath == [.chat(1), .info(1)], "History is opt-in")
    phone.pop()
    check(phone.selectedTabPath == [.chat(1)], "Existing phone pop remains unchanged")
    phone[.inbox] = [.chat(2)]
    phone.selectedTab = .inbox
    check(!phone.canGoBack && !phone.canGoForward, "Phone never records history")
    let phoneState = phone.encodedPersistentState()!
    let restoredPhone = router(tracking: false)
    check(restoredPhone.restorePersistentState(from: phoneState), "Existing snapshot restores")
    check(
      restoredPhone.selectedTab == .inbox && restoredPhone.selectedTabPath == [.chat(2)],
      "Tabs and paths persist unchanged"
    )
  }

  @MainActor private static func routeVisits() {
    let navigation = router()
    navigation[.home] = [.chat(1)]
    navigation[.home] = [.chat(2)]
    navigation.goBack()
    check(navigation.selectedTabPath == [.chat(1)] && navigation.canGoForward, "Back across sidebar selections")
    navigation.goForward()
    check(navigation.selectedTabPath == [.chat(2)], "Forward across sidebar selections")
    navigation.push(.info(2))
    navigation.goBack()
    check(navigation.selectedTabPath == [.chat(2)], "Back from a nested push")
    navigation.goForward()
    check(navigation.selectedTabPath == [.chat(2), .info(2)], "Forward restores the entire detail path")
    navigation.setPathFromNavigation([.chat(2)])
    check(navigation.canGoForward, "Native Back enables Forward")
    navigation.goForward()
    check(navigation.selectedTabPath == [.chat(2), .info(2)], "Native Back is not a new visit")
    navigation[.home] = [.chat(2)]
    check(!navigation.canGoForward, "Explicit prefix replacement starts a new branch")
    navigation.goBack()
    check(navigation.selectedTabPath == [.chat(2), .info(2)], "Explicit replacement records the previous route")
    navigation[.home] = [.chat(3)]
    check(!navigation.canGoForward, "A new visit clears Forward")
  }

  @MainActor private static func nativeNavigation() {
    let nested = router()
    nested.push(.chat(1))
    nested.push(.chat(2))
    nested.push(.info(2))
    nested.setPathFromNavigation([.chat(1)])
    check(nested.selectedTabPath == [.chat(1)], "Multi-level native pop reaches its target")
    nested.goForward()
    check(nested.selectedTabPath == [.chat(1), .chat(2)], "Multi-level pop retains intermediate Forward entry")
    nested.goForward()
    check(nested.selectedTabPath == [.chat(1), .chat(2), .info(2)], "Multi-level Forward restores the leaf")
  }

  @MainActor private static func externalRoutesAndLifecycle() throws {
    let external = router()
    external[.home] = [.chat(1)]
    external[.inbox] = [.message(2, 42)]
    external.selectedTab = .inbox
    external.goBack()
    check(
      external.selectedTab == .home && external.selectedTabPath == [.chat(1)],
      "External path-then-tab records one visible transition"
    )
    external.goForward()
    check(
      external.selectedTab == .inbox && external.selectedTabPath == [.message(2, 42)],
      "Forward preserves focus metadata and route bucket"
    )
    external[.inbox] = [.external(3, 9, 99)]
    external.goBack()
    external[.home] = [.chat(4)]
    check(external.canGoForward, "Inactive tab writes do not alter visible history")
    external[.inbox] = external[.inbox]
    check(external.canGoForward, "Duplicate native writes do not alter history")
    external.goForward()
    check(external.selectedTabPath == [.external(3, 9, 99)], "External context survives replay exactly")
    external.goBack()
    external.presentSheet(.settings)
    external.dismissSheet()
    check(external.canGoForward, "Sheet presentation leaves existing route history unchanged")
    external.goForward()

    let snapshot = external.encodedPersistentState()!
    guard let json = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else {
      preconditionFailure("Router snapshot is not a JSON object")
    }
    check(Set(json.keys) == Set(["paths", "selectedTab"]), "History adds no durable state")
    check(external.restorePersistentState(from: snapshot), "Snapshot restoration succeeds")
    check(!external.canGoBack && !external.canGoForward, "Restoration clears history")
    external.push(.info(3))
    external.clearHistory()
    check(!external.canGoForward, "Clearing history removes forward visits")
    check(external.selectedTabPath.last == .info(3), "History clearing does not mutate the route")
    check(external.canGoBack, "A restored nested route remains escapable without transient history")
    external.goBack()
    check(external.selectedTabPath == [.external(3, 9, 99)], "Back from restored nested route reaches its parent")
    external.goForward()
    check(external.selectedTabPath.last == .info(3), "Forward can revisit the restored nested route")
    external.popToRoot()
    external.clearHistory()
    check(!external.canGoBack && !external.canGoForward, "Workspace route reset then history clear forms a boundary")
    external.push(.chat(4))
    external.reset()
    check(
      external.selectedTab == .home && external.selectedTabPath.isEmpty && !external.canGoBack,
      "Account reset removes history and routes"
    )
  }

  @MainActor private static func invalidDestinations() {
    func isDeleted(_ route: TestRoute) -> Bool {
      switch route {
      case let .chat(id), let .info(id), let .message(id, _), let .external(id, _, _):
        id == 2
      }
    }

    let phone = router(tracking: false)
    phone[.home] = [.chat(2), .info(2)]
    phone.removeInvalidDestinations(where: isDeleted)
    check(phone.selectedTabPath == [.chat(2), .info(2)], "Phone keeps its existing deletion handler")

    let visits = router()
    visits[.home] = [.chat(1)]
    visits[.home] = [.chat(2)]
    visits[.home] = [.chat(3)]
    visits.removeInvalidDestinations(where: isDeleted)
    check(visits.selectedTabPath == [.chat(3)], "Deleting another chat does not change the visible route")
    visits.goBack()
    check(visits.selectedTabPath == [.chat(1)], "Back skips a deleted chat")
    visits.goForward()
    check(visits.selectedTabPath == [.chat(3)], "Forward retains surviving visits")

    let forward = router()
    forward[.home] = [.chat(1)]
    forward[.home] = [.external(2, 9, 99)]
    forward.goBack()
    forward.removeInvalidDestinations(where: isDeleted)
    check(!forward.canGoForward, "A confirmed deletion cannot be reopened through Forward")
    forward.goForward()
    check(forward.selectedTabPath == [.chat(1)], "Disabled Forward leaves the current route unchanged")

    let nested = router()
    nested.push(.chat(1))
    nested.push(.chat(2))
    nested.push(.info(1))
    nested[.inbox] = [.message(2, 42), .info(1)]
    nested.removeInvalidDestinations(where: isDeleted)
    check(nested.selectedTabPath == [.chat(1)], "Removing a nested parent also removes its descendants")
    check(nested[.inbox].isEmpty, "Inactive route buckets cannot retain a deleted chat")
    let revision = nested.persistenceRevision
    nested.removeInvalidDestinations(where: isDeleted)
    check(nested.persistenceRevision == revision, "Repeated deletion notifications do not rewrite paths")
    nested.goBack()
    check(nested.selectedTabPath.isEmpty, "Deletion does not leave a duplicate current route in Back")
    nested.goForward()
    check(nested.selectedTabPath == [.chat(1)] && !nested.canGoForward, "Cleanup itself is never recorded as a visit")
    let restored = router()
    check(restored.restorePersistentState(from: nested.encodedPersistentState()!), "Cleaned routes still restore")
    check(restored[.inbox].isEmpty, "Persisted inactive paths also exclude the deleted chat")

    let info = router()
    info[.home] = [.info(2)]
    info.removeInvalidDestinations(where: isDeleted)
    check(info.selectedTabPath.isEmpty && !info.canGoBack, "A standalone info route is invalidated without a no-op Back")

    let repeated = router()
    for id in [1, 2, 1, 3] { repeated[.home] = [.chat(id)] }
    repeated.removeInvalidDestinations(where: isDeleted)
    repeated.goBack()
    check(repeated.selectedTabPath == [.chat(1)], "Surviving repeated visits are coalesced after deletion")
    repeated.goBack()
    check(repeated.selectedTabPath.isEmpty, "Back does not stop twice at the same surviving snapshot")
  }

  @MainActor private static func replacementAndBoundaries() {
    let replacement = router()
    replacement[.home] = [.chat(1)]
    replacement.push(.info(1))
    replacement.replaceCurrentPath(with: [.chat(2)])
    check(replacement.selectedTabPath == [.chat(2)], "Completed flow is replaced in place")
    replacement.goBack()
    check(replacement.selectedTabPath == [.chat(1)], "Back skips the replaced completed flow")
    replacement.goForward()
    check(replacement.selectedTabPath == [.chat(2)], "Forward returns to the replacement")

    let boundary = router()
    boundary[.home] = [.chat(1)]
    boundary[.inbox] = [.chat(2), .info(2)]
    boundary.selectedTab = .inbox
    boundary.resetNavigationBoundary(pathsFor: [.home, .inbox], selecting: .home)
    check(boundary.selectedTab == .home, "Workspace boundary selects the requested route bucket")
    check(boundary[.home].isEmpty && boundary[.inbox].isEmpty, "Workspace boundary clears active and inactive paths")
    check(!boundary.canGoBack && !boundary.canGoForward, "Workspace boundary clears transient history")

    let restoredLane = router()
    restoredLane[.home] = [.chat(1)]
    restoredLane[.inbox] = [.message(2, 42)]
    restoredLane.selectedTab = .inbox
    let visiblePath = restoredLane.selectedTabPath
    let revision = restoredLane.persistenceRevision
    restoredLane.resetNavigationBoundary(
      pathsFor: [.home, .inbox],
      selecting: .home,
      path: visiblePath
    )
    check(
      restoredLane.selectedTab == .home && restoredLane.selectedTabPath == [.message(2, 42)],
      "Canonical restoration preserves the previously visible typed route"
    )
    check(restoredLane[.inbox].isEmpty, "Canonical restoration clears the hidden route bucket")
    check(
      restoredLane.persistenceRevision == revision + 1
        && !restoredLane.canGoBack
        && !restoredLane.canGoForward,
      "Canonical restoration persists one atomic boundary without transient history"
    )
  }

  @MainActor private static func boundedHistory() {
    let bounded = router()
    for id in 0..<150 { bounded[.home] = [.chat(id)] }
    var backCount = 0
    while bounded.canGoBack { bounded.goBack(); backCount += 1 }
    check(backCount == 100, "Long sessions keep bounded history")
    var forwardCount = 0
    while bounded.canGoForward { bounded.goForward(); forwardCount += 1 }
    check(
      forwardCount == 100 && bounded.selectedTabPath == [.chat(149)],
      "Bounded history retains a complete round trip"
    )
    bounded.tracksHistory = false
    check(!bounded.canGoBack && !bounded.canGoForward, "Disabling clears opt-in state")
  }

}
